package rhine.music.database;

import android.content.Context;
import android.content.res.Resources;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.URL;
import java.util.Collections;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 极简 IP 地区判定：只回答"本机所在网络属于中国大陆 / 欧盟地区 / 其他"。
 *
 * 判定顺序（IPv4 与 IPv6 都支持，**不缓存**，每次启动都实时判一次）：
 *   1. 本机网卡若是公网 IPv4（不是 10/8、192.168/16、100.64/10 这类私有地址），直接查表；
 *   2. 否则本机若是公网 IPv6（排除 ULA、链路本地、v4-mapped），直接查表；
 *   3. 都没有（典型是 Wi-Fi 下只有私有 IPv4）才取一次公网地址回显，再查表：
 *      有 IPv4 网络时先试 IPv4 端点，否则先试 IPv6 端点（纯 IPv6 网络）。
 *
 * 请求总预算 3 秒（所有端点共享，不是每个 3 秒）：超时、断网、解析失败
 * 一律按**其他地区**处理——调用方据此不弹许可、按默认策略启动。
 *
 * 两张表来自 RIPE Stat 的 country-resource-list（scripts/gen-region-tables.py 生成）：
 *   res/raw/ipv4_regions.bin  按起始地址排序的闭区间 + 地区字节，二分查找；
 *   res/raw/ipv6_regions.bin  128 位地址拆成两个 64 位整数，同样二分。
 *
 * 第 3 步是同意之前唯一的网络请求，只用于确定该弹哪份许可，不携带任何设备信息。
 */
public final class GeoIp {
    /** 表内未命中：仅作 lookup 的内部返回值，resolveRegion 不会把它交出去。 */
    private static final int REGION_NONE = 0;
    public static final int REGION_CN = 1;
    /** 欧盟地区（EU 27 国；EEA 三国 / 英国 / 瑞士不在表内）。 */
    public static final int REGION_EU = 2;
    /** 既不在中国大陆也不在欧盟地区，或判定不出来（超时、断网、纯 IPv6）。 */
    public static final int REGION_OTHER = 3;

    private static final String TAG = "RhineGeoIp";
    private static final String TABLE_V4 = "ipv4_regions";
    private static final String TABLE_V6 = "ipv6_regions";
    /** 取公网地址的**总**预算：所有端点共享，超时即按其他地区处理。 */
    public static final int TOTAL_TIMEOUT_MS = 3000;
    /** 公网 IPv4 回显；按可达性排序，任一成功即返回。 */
    private static final String[] ECHO_ENDPOINTS_V4 = {
            "https://myip.ipip.net",
            "https://api-ipv4.ipify.org",
            "https://ipv4.icanhazip.com",
    };
    /** 公网 IPv6 回显：这些域名有 AAAA 记录，纯 IPv6 网络下才可达。 */
    private static final String[] ECHO_ENDPOINTS_V6 = {
            "https://api6.ipify.org",
            "https://ipv6.icanhazip.com",
            "https://v6.ident.me",
    };
    private static final Pattern IPV4 = Pattern.compile("\\b(\\d{1,3}(?:\\.\\d{1,3}){3})\\b");
    private static final Pattern IPV6_CANDIDATE = Pattern.compile("[0-9a-fA-F:]{2,45}");

    private static int[] starts;
    private static int[] ends;
    private static byte[] regions;

    private static long[] v6StartHigh;
    private static long[] v6StartLow;
    private static long[] v6EndHigh;
    private static long[] v6EndLow;
    private static byte[] v6Regions;

    private GeoIp() {
    }

    /**
     * 判定当前网络所在地区。会阻塞（最多一次 3 秒的 HTTP 请求），必须在后台线程调用。
     * 判定不出来的情况一律返回 {@link #REGION_OTHER}。
     */
    public static int resolveRegion(Context context) {
        ensureLoaded(context);

        // 1) 本机就是公网 IPv4（少见，但可省掉一次请求）。
        final int localV4 = localIpv4();
        if (localV4 != 0 && isPublicIpv4(localV4)) {
            final int region = regionOfV4(localV4);
            Log.i(TAG, "local IPv4 " + formatV4(localV4) + " -> region " + region);
            return region;
        }

        // 2) 本机是公网 IPv6：手机流量、开了 IPv6 的路由器都常走这条，不用联网。
        final long[] localV6 = localPublicIpv6();
        if (localV6 != null) {
            final int region = regionOfV6(localV6);
            Log.i(TAG, "local IPv6 " + formatV6(localV6) + " -> region " + region);
            return region;
        }

        // 3) 只有私有地址（典型：Wi-Fi 下的 192.168.x）：取一次公网出口地址。
        final long deadline = System.currentTimeMillis() + TOTAL_TIMEOUT_MS;
        final boolean hasIpv4 = localV4 != 0 && !isLinkLocalIpv4(localV4);
        if (hasIpv4) {
            final int address = fetchPublicIpv4(deadline);
            if (address != 0) {
                final int region = regionOfV4(address);
                Log.i(TAG, "public IPv4 " + formatV4(address) + " -> region " + region);
                return region;
            }
        }
        final long[] address6 = fetchPublicIpv6(deadline);
        if (address6 != null) {
            final int region = regionOfV6(address6);
            Log.i(TAG, "public IPv6 " + formatV6(address6) + " -> region " + region);
            return region;
        }
        if (!hasIpv4) {
            // 纯 IPv6 但 IPv6 回显失败（NAT64 / 双栈异常）：再给 IPv4 一次机会。
            final int address = fetchPublicIpv4(deadline);
            if (address != 0) {
                final int region = regionOfV4(address);
                Log.i(TAG, "public IPv4 " + formatV4(address) + " -> region " + region);
                return region;
            }
        }
        Log.w(TAG, "no public address within " + TOTAL_TIMEOUT_MS + "ms; treat as other region");
        return REGION_OTHER;
    }

    /** IPv4 表内未命中即"其他地区"——表只收录中国大陆与欧盟地区。 */
    private static int regionOfV4(int address) {
        final int matched = lookupV4(address);
        return matched == REGION_NONE ? REGION_OTHER : matched;
    }

    /** IPv6 表内未命中即"其他地区"。 */
    private static int regionOfV6(long[] address) {
        final int matched = lookupV6(address[0], address[1]);
        return matched == REGION_NONE ? REGION_OTHER : matched;
    }

    private static int lookupV4(int address) {
        if (starts == null || starts.length == 0) {
            return REGION_NONE;
        }
        final long target = Integer.toUnsignedLong(address);
        int low = 0;
        int high = starts.length - 1;
        while (low <= high) {
            final int middle = (low + high) >>> 1;
            final long start = Integer.toUnsignedLong(starts[middle]);
            final long end = Integer.toUnsignedLong(ends[middle]);
            if (target < start) {
                high = middle - 1;
            } else if (target > end) {
                low = middle + 1;
            } else {
                return regions[middle];
            }
        }
        return REGION_NONE;
    }

    /** IPv6 二分查找：128 位地址按 (高 64 位, 低 64 位) 无符号比较。 */
    private static int lookupV6(long high, long low) {
        if (v6Regions == null || v6Regions.length == 0) {
            return REGION_NONE;
        }
        int from = 0;
        int to = v6Regions.length - 1;
        while (from <= to) {
            final int middle = (from + to) >>> 1;
            if (compareV6(high, low, v6StartHigh[middle], v6StartLow[middle]) < 0) {
                to = middle - 1;
            } else if (compareV6(high, low, v6EndHigh[middle], v6EndLow[middle]) > 0) {
                from = middle + 1;
            } else {
                return v6Regions[middle];
            }
        }
        return REGION_NONE;
    }

    private static int compareV6(long aHigh, long aLow, long bHigh, long bLow) {
        final int highOrder = Long.compareUnsigned(aHigh, bHigh);
        return highOrder != 0 ? highOrder : Long.compareUnsigned(aLow, bLow);
    }

    private static boolean isLinkLocalIpv4(int address) {
        return ((address >>> 24) & 0xFF) == 169 && ((address >>> 16) & 0xFF) == 254;
    }

    /**
     * 公网 IPv6：排除回环、链路本地（fe80::/10）、唯一本地（fc00::/7）、组播（ff00::/8）
     * 与 v4-mapped（::ffff:a.b.c.d，它代表的是 IPv4 地址，不该走 v6 表）。
     */
    private static boolean isPublicIpv6(byte[] raw) {
        if (raw == null || raw.length != 16) {
            return false;
        }
        final int first = raw[0] & 0xFF;
        final int second = raw[1] & 0xFF;
        if ((first & 0xFE) == 0xFC) {
            return false;
        }
        if (first == 0xFE && (second & 0xC0) == 0x80) {
            return false;
        }
        if (first == 0xFF) {
            return false;
        }
        if (first == 0 && second == 0) {
            // ::、::1 以及所有 0000::/8 的保留段。
            return false;
        }
        // ::ffff:a.b.c.d（v4-mapped）：前 10 字节为 0，第 11、12 字节为 0xFF。
        boolean mapped = true;
        for (int index = 0; index < 10 && mapped; ++index) {
            mapped = raw[index] == 0;
        }
        if (mapped && (raw[10] & 0xFF) == 0xFF && (raw[11] & 0xFF) == 0xFF) {
            return false;
        }
        return true;
    }

    private static long[] toLongPair(byte[] raw) {
        long high = 0;
        long low = 0;
        for (int index = 0; index < 8; ++index) {
            high = (high << 8) | (raw[index] & 0xFFL);
            low = (low << 8) | (raw[index + 8] & 0xFFL);
        }
        return new long[] {high, low};
    }

    /** 取本机第一个公网 IPv6；没有就返回 null。 */
    private static long[] localPublicIpv6() {
        try {
            for (NetworkInterface nif : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!nif.isUp() || nif.isLoopback()) {
                    continue;
                }
                for (InetAddress address : Collections.list(nif.getInetAddresses())) {
                    if (!(address instanceof Inet6Address) || address.isLoopbackAddress()
                            || address.isLinkLocalAddress() || address.isSiteLocalAddress()
                            || address.isMulticastAddress()) {
                        continue;
                    }
                    final byte[] raw = address.getAddress();
                    if (isPublicIpv6(raw)) {
                        return toLongPair(raw);
                    }
                }
            }
        } catch (Throwable error) {
            Log.w(TAG, "failed to enumerate IPv6 interfaces", error);
        }
        return null;
    }

    /**
     * 从回显服务的响应里取 IPv6 字面量。只接受十六进制与冒号组成的 token，再交给
     * {@link InetAddress#getByName} 做数值解析——这样绝不会因为主机名触发 DNS。
     */
    private static long[] parseIpv6Candidate(String text) {
        final Matcher matcher = IPV6_CANDIDATE.matcher(text);
        while (matcher.find()) {
            final String candidate = matcher.group();
            if (candidate.indexOf(':') < 0) {
                continue;
            }
            try {
                final InetAddress address = InetAddress.getByName(candidate);
                if (address instanceof Inet6Address) {
                    final byte[] raw = address.getAddress();
                    if (isPublicIpv6(raw)) {
                        return toLongPair(raw);
                    }
                }
            } catch (Throwable ignored) {
                // 不是合法字面量，继续看下一个候选。
            }
        }
        return null;
    }

    /** 私有、保留、链路本地、CGNAT 都不算"能代表地区"的公网地址。 */
    private static boolean isPublicIpv4(int address) {
        final int first = (address >>> 24) & 0xFF;
        final int second = (address >>> 16) & 0xFF;
        if (first == 0 || first == 10 || first == 127 || first >= 224) {
            return false;
        }
        if (first == 169 && second == 254) {
            return false;
        }
        if (first == 172 && second >= 16 && second <= 31) {
            return false;
        }
        if (first == 192 && second == 168) {
            return false;
        }
        // 100.64/10：运营商级 NAT，同样代表不了地区。
        return !(first == 100 && second >= 64 && second <= 127);
    }

    /** 优先 Wi-Fi，其次任意非回环地址；只取 IPv4。 */
    private static int localIpv4() {
        int fallback = 0;
        try {
            for (NetworkInterface nif : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!nif.isUp() || nif.isLoopback()) {
                    continue;
                }
                for (InetAddress address : Collections.list(nif.getInetAddresses())) {
                    if (!(address instanceof Inet4Address) || address.isLoopbackAddress()) {
                        continue;
                    }
                    final byte[] raw = address.getAddress();
                    final int value = ((raw[0] & 0xFF) << 24) | ((raw[1] & 0xFF) << 16)
                            | ((raw[2] & 0xFF) << 8) | (raw[3] & 0xFF);
                    if (value == 0) {
                        continue;
                    }
                    if (nif.getName() != null && nif.getName().startsWith("wlan")) {
                        return value;
                    }
                    if (fallback == 0) {
                        fallback = value;
                    }
                }
            }
        } catch (Throwable error) {
            Log.w(TAG, "failed to enumerate network interfaces", error);
        }
        return fallback;
    }

    /**
     * 依次尝试 IPv4 回显端点，共享传入的 deadline。抢不到公网 IPv4 就返回 0。
     * 单个端点的 connect/read 超时都取"剩余预算"，所以前一个端点卡满 3 秒时后面不会再发。
     */
    private static int fetchPublicIpv4(long deadline) {
        for (String endpoint : ECHO_ENDPOINTS_V4) {
            final long remaining = deadline - System.currentTimeMillis();
            if (remaining < 300) {
                // 预算用尽（或只够握手），不再发起新的连接。
                break;
            }
            HttpURLConnection connection = null;
            try {
                connection = (HttpURLConnection) new URL(endpoint).openConnection();
                connection.setConnectTimeout((int) remaining);
                connection.setReadTimeout((int) remaining);
                connection.setInstanceFollowRedirects(true);
                try (InputStream stream = connection.getInputStream()) {
                    final String text = readText(stream);
                    final Matcher matcher = IPV4.matcher(text);
                    if (matcher.find()) {
                        final int address = parseIpv4(matcher.group(1));
                        if (address != 0 && isPublicIpv4(address)) {
                            return address;
                        }
                    }
                }
            } catch (Throwable error) {
                Log.w(TAG, "public IPv4 lookup failed via " + endpoint + ": " + error);
            } finally {
                if (connection != null) {
                    connection.disconnect();
                }
            }
        }
        return 0;
    }

    /** IPv6 版本：纯 IPv6 网络下只有这些域名可达（它们有 AAAA 记录）。 */
    private static long[] fetchPublicIpv6(long deadline) {
        for (String endpoint : ECHO_ENDPOINTS_V6) {
            final long remaining = deadline - System.currentTimeMillis();
            if (remaining < 300) {
                break;
            }
            HttpURLConnection connection = null;
            try {
                connection = (HttpURLConnection) new URL(endpoint).openConnection();
                connection.setConnectTimeout((int) remaining);
                connection.setReadTimeout((int) remaining);
                connection.setInstanceFollowRedirects(true);
                try (InputStream stream = connection.getInputStream()) {
                    final long[] address = parseIpv6Candidate(readText(stream));
                    if (address != null) {
                        return address;
                    }
                }
            } catch (Throwable error) {
                Log.w(TAG, "public IPv6 lookup failed via " + endpoint + ": " + error);
            } finally {
                if (connection != null) {
                    connection.disconnect();
                }
            }
        }
        return null;
    }

    private static String readText(InputStream stream) throws Exception {
        final ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        final byte[] chunk = new byte[1024];
        int read;
        int total = 0;
        while ((read = stream.read(chunk)) > 0) {
            total += read;
            if (total > 4096) {
                break;
            }
            buffer.write(chunk, 0, read);
        }
        return buffer.toString("UTF-8");
    }

    private static int parseIpv4(String text) {
        final String[] parts = text.split("\\.");
        if (parts.length != 4) {
            return 0;
        }
        int value = 0;
        for (String part : parts) {
            final int octet = Integer.parseInt(part);
            if (octet < 0 || octet > 255) {
                return 0;
            }
            value = (value << 8) | octet;
        }
        return value;
    }

    private static synchronized void ensureLoaded(Context context) {
        if (starts != null) {
            return;
        }
        starts = new int[0];
        ends = new int[0];
        regions = new byte[0];
        v6Regions = new byte[0];
        loadIpv4(context);
        loadIpv6(context);
    }

    private static void loadIpv4(Context context) {
        final Resources resources = context.getResources();
        // 用 getIdentifier 而不是 R.raw：这样本文件可以脱离 AGP 生成物单独做静态编译检查。
        final int id = resources.getIdentifier(TABLE_V4, "raw", context.getPackageName());
        if (id == 0) {
            Log.w(TAG, "geo table resource missing: " + TABLE_V4);
            return;
        }
        try (DataInputStream stream = new DataInputStream(resources.openRawResource(id))) {
            final byte[] magic = new byte[4];
            stream.readFully(magic);
            if (magic[0] != 'R' || magic[1] != 'H' || magic[2] != 'I' || magic[3] != 'P') {
                Log.w(TAG, "unexpected IPv4 table header");
                return;
            }
            final int version = stream.readUnsignedByte();
            stream.skipBytes(3);
            final int count = stream.readInt();
            if (version != 1 || count <= 0 || count > 1_000_000) {
                Log.w(TAG, "unsupported IPv4 table: version=" + version + " count=" + count);
                return;
            }
            final int[] loadedStarts = new int[count];
            final int[] loadedEnds = new int[count];
            final byte[] loadedRegions = new byte[count];
            for (int index = 0; index < count; ++index) {
                loadedStarts[index] = stream.readInt();
                loadedEnds[index] = stream.readInt();
                loadedRegions[index] = stream.readByte();
            }
            starts = loadedStarts;
            ends = loadedEnds;
            regions = loadedRegions;
            Log.i(TAG, "IPv4 table loaded: " + count + " ranges");
        } catch (Throwable error) {
            Log.w(TAG, "failed to load IPv4 table", error);
        }
    }

    private static void loadIpv6(Context context) {
        final Resources resources = context.getResources();
        final int id = resources.getIdentifier(TABLE_V6, "raw", context.getPackageName());
        if (id == 0) {
            Log.w(TAG, "geo table resource missing: " + TABLE_V6);
            return;
        }
        try (DataInputStream stream = new DataInputStream(resources.openRawResource(id))) {
            final byte[] magic = new byte[4];
            stream.readFully(magic);
            if (magic[0] != 'R' || magic[1] != 'H' || magic[2] != '6' || magic[3] != 'P') {
                Log.w(TAG, "unexpected IPv6 table header");
                return;
            }
            final int version = stream.readUnsignedByte();
            stream.skipBytes(3);
            final int count = stream.readInt();
            if (version != 1 || count <= 0 || count > 1_000_000) {
                Log.w(TAG, "unsupported IPv6 table: version=" + version + " count=" + count);
                return;
            }
            final long[] startHigh = new long[count];
            final long[] startLow = new long[count];
            final long[] endHigh = new long[count];
            final long[] endLow = new long[count];
            final byte[] loadedRegions = new byte[count];
            for (int index = 0; index < count; ++index) {
                startHigh[index] = stream.readLong();
                startLow[index] = stream.readLong();
                endHigh[index] = stream.readLong();
                endLow[index] = stream.readLong();
                loadedRegions[index] = stream.readByte();
            }
            v6StartHigh = startHigh;
            v6StartLow = startLow;
            v6EndHigh = endHigh;
            v6EndLow = endLow;
            v6Regions = loadedRegions;
            Log.i(TAG, "IPv6 table loaded: " + count + " ranges");
        } catch (Throwable error) {
            Log.w(TAG, "failed to load IPv6 table", error);
        }
    }

    private static String formatV4(int address) {
        return ((address >>> 24) & 0xFF) + "." + ((address >>> 16) & 0xFF) + "."
                + ((address >>> 8) & 0xFF) + "." + (address & 0xFF);
    }

    private static String formatV6(long[] address) {
        try {
            final byte[] raw = new byte[16];
            for (int index = 0; index < 8; ++index) {
                raw[index] = (byte) (address[0] >>> (56 - index * 8));
                raw[index + 8] = (byte) (address[1] >>> (56 - index * 8));
            }
            return InetAddress.getByAddress(raw).getHostAddress();
        } catch (Throwable ignored) {
            return Long.toHexString(address[0]) + ":" + Long.toHexString(address[1]);
        }
    }
}
