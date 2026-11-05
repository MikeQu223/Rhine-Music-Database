# Android（arm64-v8a）构建与平台说明

面板的 Android 版本只承诺一个 ABI：`arm64-v8a`。目标设备是 Android 9（API 28）以上的手机与平板，
固定横屏显示。产物用工作区内的调试密钥签名，可以直接侧载；上架或分发需要自行换一套发布密钥。

## 前置条件

| 依赖                  | 说明                                                                                                                                                      |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Qt 6.12.0 Android kit | 两选一：Qt 在线安装器的 `Android` 组件（`android_arm64_v8a`，默认找 `~/Qt/6.12.0/android_arm64_v8a`），或用仓库里的 `third_party/qt` 自行构建（见下一节） |
| Android SDK           | 至少一套 `platforms/android-*`（Qt 的 Java 库按最高版本编）与一套 `build-tools`；默认找 `~/Android/Sdk`                                                   |
| Android NDK           | r27 及以上；默认用 `$ANDROID_SDK_ROOT/ndk` 下版本号最大的那套                                                                                             |
| JDK                   | 17–25（Gradle 9 的运行上限，推荐 21；系统的 JDK 27 会让 Groovy 报 `Unsupported class file major version 71`）；默认找 `output/android-work/jdk`           |
| Node.js               | 构建脚本与桥接打包用，和桌面构建相同                                                                                                                      |

路径都可以用环境变量覆盖：`RHINE_ANDROID_QT`、`JAVA_HOME`、`ANDROID_SDK_ROOT`、`ANDROID_NDK_ROOT`。
Gradle 缓存默认用标准的 `~/.gradle`（搬进工作区会让 wrapper 与 AGP 依赖重下几百 MB）；
要让构建完全落在工作区里，把 `RHINE_GRADLE_HOME` 指到任意目录即可。

## 从固定提交构建 Qt kit

Qt 6.12 的 Android 预编译包没有公开下载（Qt 在线仓库的 Android 组件只到 6.6.3），所以仓库把用到的
五个模块按 `v6.12.0` 标签记成 submodule，和 FFmpeg/dxc 一样用 pinned-commit 固定版本：

```sh
git submodule update --init --depth 1 third_party/qt
npm run build:qt:android          # 体检：npm run build:qt:android -- --check
```

脚本按 `OpenSSL（静态）→ qtbase → qtshadertools → qtdeclarative → qtsvg → qtmultimedia` 的顺序
交叉编译，产物装到 `output/dependencies/qt-android`，中间构建树在 `output/qt-android-build`。
换 Qt 版本时改 `.gitmodules` 里的 `branch`/`pinned-commit` 和脚本里的 `qtVersion`，再带 `--force` 重跑。

host 侧工具（moc/rcc/qsb/qmlcachegen）用系统 Qt 6.12（`RHINE_HOST_QT`，默认 `/usr`），
版本必须与目标一致，否则 Qt 的 configure 会直接报错。

Qt 的 jar 规则是 `cmake -E env ANDROID_SDK_ROOT=… gradlew …`，`JAVA_HOME` 只能靠继承调用方的
环境。脚本给 configure / build / install 每一步都注入 `JAVA_HOME`（指向 JDK 21），并在生成的
`build.ninja` 里给这些 Gradle 规则补上同一个 `JAVA_HOME`：构建被打断后直接重跑 `ninja`，
也不会退回系统默认的 Java 27（Gradle 9 的 Groovy 读不了它的 class 文件）。

OpenSSL 采用静态链接：APK 的 `lib/arm64-v8a/` 只接受 `lib*.so` 形态，带版本号的 `libssl.so.3`
塞不进去；静态库直接进 `libQt6Network.so`，既没有 SONAME 问题，也不用额外往包里加两份 `.so`。

## 构建

```sh
npm run build:android
```

只体检不出包（几秒内跑完，缺什么直接列出来）：

```sh
npm run build:android -- --check
```

脚本按顺序做四件事：

1. 解包 pin 住的 nodejs-mobile Android 包（`vendor/nodejs-mobile/android-source.json`，校验 sha256），
   取出 `bin/arm64-v8a/libnode.so`。
2. 准备资源：`scripts/build.cjs --resources-only` 生成场景与字体，再用
   `RHINE_ANDROID_BUILD=1` 打一份 Node 18 语法的桥接 bundle，最后按白名单组装到
   `output/android-resources`。
3. 用 kit 里的 `qt-cmake` 配置 `output/android-build`，再构建 `apk` 目标（走 Gradle）。
4. `zipalign` → `apksigner` 签出 `output/RhineMusicDatabase-<版本>-android-arm64-v8a.apk`，
   最后跑 `scripts/audit-android.py` 校验 ABI、横屏声明、权限与签名。

`ANDROID_USER_HOME` 指向 `output/android-work`，Gradle 缓存用标准的 `~/.gradle`（见上一节的
`RHINE_GRADLE_HOME`）。

## CI

Android 构建在独立工作流 `.github/workflows/android.yml` 里，与其他平台完全隔离：它失败
不会影响 `desktop.yml`（桌面/iOS）的构建与发布，反之亦然。

- 与本机走同一套脚本（`build:qt:android` → `build:android`），不额外维护第二套流程。
- Qt kit 从五个 `third_party/qt` 子模块现场交叉编译；产物（`output/dependencies/qt-android`
  与 `output/dependencies/openssl-android`）按「子模块提交 + 构建/补丁脚本内容 + NDK 与宿主
  Qt 版本」做缓存键。缓存命中后几分钟出包，冷启动约 2 小时。
- 构建期补丁（`scripts/qt-android-patches.cjs`）在 CI 里同样按内容锚点生效，子模块保持干净。
- 产物用 `keytool` 现场生成的调试密钥签名，密钥不入库，因此每次运行的 APK 签名不同；
  需要可覆盖升级的发布包时应换成固定发布密钥（见上一节）。
- 上传的 artifact 名为 `RHINE-MUSIC-DATABASE-Android-arm64`。它暂不进入桌面更新源：
  `scripts/release-version.cjs` 的 `distributionPlatforms` 只列桌面三平台与 iOS。

## 签名

调试密钥在第一次构建时由 `keytool` 生成到 `output/android-work/debug.keystore`
（`storepass`/`keypass` 均为 `android`，别名 `rhine-debug`）。换成发布密钥时不必改脚本：
把 `apksigner` 那一步换成自己的 keystore 即可，或直接对 `output/android-build` 里的
未签名 APK 自行处理。

脚本只签名、不安装，也不调用 `adb`——真机验收不在这里做。

## 横屏

"横屏"在 Android 上是三件事，缺一件就会看到竖屏或旋转后重排：

1. **清单声明**：`Qt/android/AndroidManifest.xml` 里
   `android:screenOrientation="sensorLandscape"`。`sensorLandscape` 允许左右两个横屏方向，
   转 180° 时界面跟着翻转；`landscape` 会锁死一个方向，倒过来拿就是上下颠倒的画面。
2. **运行期再请求一次**：`Qt/src/AndroidWindow.cpp` 通过 JNI 调
   `Activity.setRequestedOrientation(SCREEN_ORIENTATION_SENSOR_LANDSCAPE)`。
   分屏、多窗口、进程被系统回收后重建 Activity 都可能把方向改回竖屏，只靠清单不够。
3. **configChanges 必须包含方向与尺寸**：清单里的
   `orientation|screenLayout|screenSize|smallestScreenSize` 让旋转走 `onConfigurationChanged`
   而不是重建 Activity——Qt 的渲染表面会跟着尺寸变化，不需要重走一遍启动流程。

同一处 JNI 还负责另外两个窗口属性：`FLAG_FULLSCREEN`（隐藏状态栏）与
`FLAG_KEEP_SCREEN_ON`（播放时不息屏），以及 `setSystemUiVisibility` 的沉浸式粘滞模式
（隐藏导航栏，边缘滑动临时唤出）。

## 权限

只申请普通权限，安装时不需要用户授权：

- `android.permission.INTERNET`：面板的全部内容来自远端接口。
- `android.permission.ACCESS_NETWORK_STATE`：判断当前是否联网，用于把请求失败区分为"无网络"与"接口报错"。
- `android.permission.FOREGROUND_SERVICE` 与 `FOREGROUND_SERVICE_MEDIA_PLAYBACK`：系统媒体控件的
  前台服务（后者是 targetSdk 34+ 对 mediaPlayback 类型的配套要求）。
- `android.permission.POST_NOTIFICATIONS`：Android 13+ 的运行时权限，首次播放时申请。

存储权限不申请（Android 端不提供本地音乐扫描）。

清单里的 `android:usesCleartextTraffic="true"` 是有意保留的：上游接口返回的部分试听与封面地址
仍是 `http`，Android 9 起默认拒绝明文连接，表现为"封面灰块、试听无声"。

`android:glEsVersion="0x00030000"` 让低于 OpenGL ES 3.0 的设备在安装期就被过滤掉——
自绘场景的着色器只烘了 GLSL ES 300，装上去也只会黑屏。

## 第三方 SDK 与 Gradle

Gradle 工程由 androiddeployqt 按 kit 里的模板（`<kit>/src/android/templates/build.gradle`）现场生成，
包源目录里的同名文件会**整份覆盖**它——这是 Qt 应用添加第三方依赖的唯一入口。
`Qt/android/build.gradle` 因此是「模板逐字节副本 + 末尾追加段」：

- 上半部分来自当前 Qt 模板，不要手改；
- `// ===== RHINE additions below` 之后才是我们的内容（Clarity、Bugly 与 ABI 过滤）；
- `scripts/build-android.cjs` 在构建前校验前缀，模板对不上就直接失败，不会静默沿用旧配置；
  升级 Qt 后跑一次 `node scripts/android-gradle-sync.cjs` 重新生成（追加段原样保留）。

Clarity（会话行为分析，项目 ID `z8vbz4b078`）与 Bugly（崩溃上报，AppID `22c01c69b9`）
都不在 `RhineApplication.onCreate()` 里无条件初始化：统一入口是
`ConsentStore.startSdks()`，只有启动许可闸门放行后才调用（见下节）。
清单的 `android:name` 仍要从 `org.qtproject.qt.android.bindings.QtApplication` 换成继承它的
`rhine.music.database.RhineApplication`——Qt 的启动 Activity 在 Qt 自己的 jar 里、插不了代码，
而 Application 还能覆盖「后台任务唤醒进程」这条路径。初始化整段用 `try/catch` 包住：
分析/上报 SDK 出问题不该拖垮面板本身。Clarity 日志级别取 `LogLevel.None`，
排查初始化问题时可临时改 `Verbose`。

依赖链：`com.microsoft.clarity:clarity:3.10.0` → `kotlin-stdlib`、`protobuf-javalite`
（Maven Central）、`com.android.installreferrer`（Google Maven）。两个仓库 Qt 模板都已声明，
无需补配置；最后者的清单会带进一条 `BIND_GET_INSTALL_REFERRER_SERVICE` 权限（Play 商店
signature 级，非 Play 渠道等于没有），`scripts/audit-android.py` 的白名单里注明了来源。
`kotlin-stdlib` 只出现在 Clarity 的 runtime 变体里，编译期并不在 classpath 上。追加段里那条
`compileOnly` 只是防将来用到带 `kotlin.*` 签名的成员时，javac 抛出「cannot access
kotlin.jvm.functions.Function2」这类没头没脑的错误——当前用法（`ClarityConfig(String)` +
`setLogLevel`）不加它也编得过。`compileOnly` 不进 APK，运行期的 stdlib 由 Clarity 自己传递。

### 已知限制：Clarity 无法获取录制画面

Clarity 的截屏是把 **View 树重画进 Bitmap**：反编译 `classes.jar` 可见
`Picture.beginRecording` + `Canvas` + `getDecorView`（配 `hardwareBitmapCache`），SDK 里
**没有** `PixelCopy` / `MediaProjection` / `SurfaceControl` / `AccessibilityNodeInfo`。
Qt 的界面由 GPU 直接画到 Surface 上，不属于任何 View 的绘制内容，因此回放里**永远没有画面**，
只有会话与点击事件。

真机验证（2026-11-05，OPD2511）：

- Qt 默认的 SurfaceView 与强制 TextureView（`QT_ANDROID_SURFACE_CONTAINER_TYPE=1`）都试过：
  `dumpsys activity top` 确认视图树里已是 `QtTextureView`、`dumpsys SurfaceFlinger --list`
  也没有 SurfaceView 层——容器确实换了，回放依旧空白。
- 同一时刻 `adb exec-out screencap -p` 能抓到完整界面（2880×1800，1.4 MB），说明像素存在，
  只是 Clarity 不读。

这是采集方式带来的限制，不是配置问题：元素遮罩、遮罩模式、换渲染后端都改变不了。
若将来确实需要画面，只能换采集方式：

- 基于 `PixelCopy` 的 SDK（例如 Sentry Session Replay 的 `isCaptureSurfaceViews`），
  或自己按帧抓取（`PixelCopy.request(SurfaceView, …)`，本项目已实测可取到画面）；
- `MediaProjection` 录屏（每次会话都需要用户授权）。

> 历史：曾尝试 TextureView、按时间 `Clarity.pause()/resume()`、登录失败事件化上报等手段
> 绕开限制，均无法让 Clarity 产出画面，相关改动已撤回。Clarity 现在只承担会话与事件统计。

### Bugly：地区限定与 native 接管

依赖 `com.tencent.bugly:crashreport:4.1.9.7`（Maven Central），初始化在
`ConsentStore.startSdks()`：

```java
CrashReport.UserStrategy strategy = new CrashReport.UserStrategy(application);
strategy.setEnableNativeCrashMonitor(BUGLY_NATIVE_MONITOR);
CrashReport.initCrashReport(application, BUGLY_APP_ID, BUGLY_DEBUG, strategy);
```

官方要求「务必在用户授权隐私政策后再初始化」，且不要放到异步线程；调用点是
`RhineApplication.onCreate()` 与 `ConsentActivity`，都在主线程，且都在许可闸门之后。
AppID `22c01c69b9` 写在 `ConsentStore.BUGLY_APP_ID`；提供的 **AppKey 不参与客户端
初始化**——它用于 Bugly 后台开放接口与符号表上传，本项目当前不上传符号表，
因此没有写进仓库。若日后在 CI 里配置符号表上传，请放进 CI secret，不要提交到源码。

**只在 CN 放行时启动。** 欧盟地区许可文案只写 Clarity、其他地区没有许可流程，所以
`startSdks(context, region)` 只在 `region == REGION_CN` 时拉起 Bugly；后台任务唤醒进程
时，地区从 `grantedRegion()` 读取。Clarity 则在所有放行的情况下启动（沿用既有行为）。
两个 SDK 各自记幂等标志，避免「先按其他地区启动 Clarity」挡掉随后 CN 同意下的 Bugly。

**native 崩溃由 Bugly 接管**（`BUGLY_NATIVE_MONITOR = true`）。AAR 里的
`libBugly_Native.so` 会注册自己的 SIGSEGV/SIGBUS/SIGABRT handler 并上报 tombstone 现场。
为避免两套 handler 抢同一组信号，`Qt/src/main.cpp` 的 RHINE-SIGNAL 诊断链默认
**整段不编译**（文件顶部 `RHINE_ANDROID_SIGNAL_DIAG = 0`），两处调用点
`rhineInstallSignalDiag()` / `rhineOpenSignalDiagFile()` 一并关闭；Android 的 include
仍保留在宏外，文件后面的代码不受影响。需要离线抓自有链现场时，把宏改成 `1`，
并同时把 `BUGLY_NATIVE_MONITOR` 改回 `false`——两者永远只开一个。
`scripts/audit-android.py` 会断言 `lib/arm64-v8a/libBugly_Native.so` 确实在包里。

native 堆栈要可读，还得按 Bugly 官方《符号表配置》上传带调试信息的 `.so`；
本项目当前没有配置这一步（AppKey 也因此没进仓库），后台看到的 native 栈可能只有地址。

依赖本身：POM 无传递依赖，AAR 的清单只声明 `uses-sdk`、**不带任何权限**，所以
`scripts/audit-android.py` 的权限白名单没有变化；官方建议的 `ACCESS_WIFI_STATE`
不是必须的，网络类型用已有的 `ACCESS_NETWORK_STATE` 即可，不额外申请权限。
AAR 自带 5 个 ABI 的 so，追加段按 `qtTargetAbiList` 排除其余 ABI，保证 APK 里只有
`lib/arm64-v8a/`。工程未启用 `minifyEnabled`，官方的 `-keep com.tencent.bugly.**`
混淆规则暂时用不上；将来开启混淆时再补。

## 启动许可闸门

清单里唯一的 LAUNCHER 是 `ConsentActivity`，`QtActivity` 改为 `exported=false`：
**同意之前 Qt 界面、Clarity、Bugly 一个都不会启动**，不是先画界面再补一个弹窗。

判定顺序（`ConsentActivity.onCreate` → 后台线程 → `GeoIp.resolveRegion`）：

1. `SharedPreferences("rhine-consent")` 里 `granted=true` → 直接进入，SDK 由
   `RhineApplication` 重新拉起（后台任务唤醒进程时也走这条路）。
2. 否则判定地区（IPv4 / IPv6 都支持）：
    - 本机网卡若是**公网 IPv4** → 直接查表；
    - 否则若是**公网 IPv6**（排除 ULA `fc00::/7`、链路本地 `fe80::/10`、v4-mapped）→ 直接查 IPv6 表；
    - 两者都是私有地址时（典型：Wi-Fi 只有 `192.168.x`）才取一次公网地址回显：
      有 IPv4 网络先试 `myip.ipip.net` / `api-ipv4.ipify.org` / `ipv4.icanhazip.com`，
      否则先试 `api6.ipify.org` / `ipv6.icanhazip.com` / `v6.ident.me`（纯 IPv6 网络）。
      这是同意前唯一的网络请求，只为决定弹哪份许可，不携带设备信息。
      **不缓存判定结果**：每次启动都重新请求一次，所有端点共享 **3 秒总预算**
      （`GeoIp.TOTAL_TIMEOUT_MS`，不是每个端点各 3 秒）。另有一层硬闸门
      （`Future.get(3s)`）——`connectTimeout` 管不住 DNS 解析，这样启动页最多等 3 秒。
3. 中国大陆 → 中文许可（Clarity 跨境数据传输 + Bugly 隐私政策与信息类型）；
   欧盟地区（EU 27 国）→ 英文许可（只写 Clarity，也不启动 Bugly）。
   EEA 的挪威/冰岛/列支敦士登、英国、瑞士不再属于需要确认的地区。
   同意写入 `granted` 并启动 SDK；拒绝则 `finishAffinity()` 退出。
   **每个地区只确认一次**：点过同意就永久记住，此后既不弹窗也不再请求地区。
4. 其他地区 → 不弹窗，正常启动，只启动 Clarity。
5. 3 秒内取不到地址（超时、断网、解析失败）→ **按其他地区处理**：不弹窗、
   照常启动界面与 Clarity（仅本次运行；下次启动重新判定）。这是有意的取舍——地区判定是
   "该不该弹许可"的依据，不是采集开关。

许可对话框只有两个按钮：**同意** / **退出**。空白区域与返回键都不生效
（`setCancelable(false)` + `setCanceledOnTouchOutside(false)` + 拦截 `KEYCODE_BACK`），
不存在"点一下就等于默认同意"的路径；未同意时 Activity 的返回键也被吞掉，只能点"退出"。

SDK 启动集中在 `ConsentStore.startSdks(context, region)`（Clarity / Bugly 各自幂等）。
`RhineApplication` 只在已同意时调用无参重载（地区取自许可记录），`ConsentActivity`
把本次判定的地区一路传进来：Clarity 放行即启动，**Bugly 仅 `REGION_CN` 启动**——
欧盟地区许可文案没写它，其他地区没有许可流程。

### 内置地区表（IPv4 + IPv6）

由 `python3 scripts/gen-region-tables.py [--refresh]` 一次生成两张表，数据取 RIPE Stat 的
country-resource-list（按国家汇总各 RIR 分配），把中国大陆与**欧盟地区（EU 27 国）**的前缀
转成闭区间、合并相邻段后写入二进制。EEA 三国、英国、瑞士不收，它们的用户不再需要确认许可。

| 文件                       | 规模               | 格式（大端）                                                                                 |
| -------------------------- | ------------------ | -------------------------------------------------------------------------------------------- |
| `res/raw/ipv4_regions.bin` | 25,995 段 / 228 KB | `"RHIP"` + 版本 + 条数 + `(start u32, end u32, region u8)`×N                                 |
| `res/raw/ipv6_regions.bin` | 16,755 段 / 540 KB | `"RH6P"` + 版本 + 条数 + `(start_hi u64, start_lo u64, end_hi u64, end_lo u64, region u8)`×N |

`region`：1 = 中国大陆，2 = 欧盟地区（EU 27 国）。IPv6 在 Java 侧拆成两个 64 位整数，用
`Long.compareUnsigned` 比较（128 位地址没有原生整数类型）。

**为什么要 IPv6 表**：手机流量和多数家用宽带的 IPv6 是公网地址。没有这张表时，
纯 IPv6 网络（或 Wi-Fi 下只有私有 IPv4、靠 IPv6 上网）只能走公网回显，一旦回显超时
就按"其他地区"放行——中国大陆/欧盟地区用户会漏掉许可弹窗。有了本机 IPv6 直查，这类网络
连请求都不需要发。

抓取缓存在 `.workbuddy/tmp/geo/`，删掉它并加 `--refresh` 即可更新。表只用于
"是否需要弹隐私许可"，不追求精确到城市。

> 国内许可文案里的 Bugly 段落对应 `ConsentStore.startSdks()` 里的实际初始化（见上节）。
> 若日后移除 Bugly，必须同步删掉这段文案、Gradle 依赖和审计脚本里的 dex 断言。

## 架构：三个和桌面不同的决定

**Node 运行时编进进程。** Android 不允许从应用私有目录执行可执行文件，桌面那条
"起一个 `node` 子进程"的路子在这里不存在。`libnode.so`（nodejs-mobile 18.20.4，与 iOS 同一个版本）
被链接进 `RhineCore`，`Qt/src/BridgeProcessAndroid.cpp` 用 8 MB 栈的 pthread 调 `node::Start`，
再通过 `127.0.0.1` 的回环连接 + 随机令牌控制 Worker。协议与 iOS 完全一致，
`MusicBridge/ios-runtime.cjs` 两个平台共用——它本身只是一条按行 JSON 的通道，
里面对 `system-trust` 的转发只有在装了 iOS 信任补丁时才会触发。

**资源用 Qt 资源而不是 APK assets。** Android 的 `assets/` 目录枚举依赖 `AAssetDir`，
它不保证列出子目录；靠构建期清单兜底，一旦资源切片变化就会静默漏文件。改成
`qt_add_resources`（前缀 `/rhine-assets`）编进二进制后，枚举语义在所有平台一致。
首次启动时 `Qt/src/AndroidAssets.cpp` 把资源解包到应用私有目录，用
`RHINE_VERSION|RHINE_COMMIT_SHA` 做标记——Node 与 `QFontDatabase` 都需要真实文件路径，
APK 内的路径只有 Qt 的 qrc 引擎认得。

**Vulkan 优先、GLES 回退。** `qt_add_shaders` 烘出的 .qsb 本来就含 SPIR-V
（`GLSL 130,150,300es` 只是附加的翻译产物），所以 Android 与桌面共用同一条后端选择链：
`RHINE_GRAPHICS` → 设置页偏好 → Vulkan 可用则优先，否则退回 OpenGL ES。
FidelityFX/FSR3 在 Android 仍默认关闭（`RHINE_ENABLE_FIDELITYFX=OFF`，无 D3D12/Vulkan 呈现层）。

其他平台行为不变的判定收在 `Qt/src/MobileTarget.h` 的 `RHINE_MOBILE` 与 `RHINE_LINUX_DESKTOP`
里：移动端没有独立播放服务、没有桌面窗口装饰；Android 虽然定义 `Q_OS_LINUX`，
但桌面 Linux 专有的判断（X11/DRI3、显卡选择）都用 `RHINE_LINUX_DESKTOP` 排除。

## 3D 资源：独立副本与重定向

Android 的 3D 配置与模型从一套**独立副本**生成，别的平台继续用公共源。副本目前逐字节复制自
公共资源，内容没有任何改动；这一步只把「单独调整 Android 3D」的入口留出来。

- 仓库副本 `Assets/android-3d/`：两个 `glb` 模型（`archive-assembly` / `archive-cassette`）、
  `slots.json` 与 `scene-fixture.json`（场景与槽位配置）。**不含** `boot-tracks.json`
  （启动动画走 qrc）与 `boot-lettering-art.json`（2D 字形），这两个仍与桌面共用。
- 构建期：`scripts/build-android.cjs` 用 `RHINE_3D_SOURCE` / `RHINE_3D_OUTPUT` 把
  `scripts/export-assets.py` 与 `scripts/bake-archive-lighting.py` 指向副本，重新导出/烘焙到
  `output/android-3d/`。烘焙贴图由同一套脚本按程序化参数生成，仓库里没有它的源二进制，
  当前产物与公共目录一致；将来要单独换一套，把同名 `.bin` 放进 `Assets/android-3d/` 就会
  被打包优先采用，或在脚本里加 Android 分支参数。
- 打包期：`scripts/package-resources.cjs` 在 `RHINE_ANDROID_BUILD=1` 时，白名单里 12 个 3D
  文件（模型导出 6 个、烘焙 4 个、配置 2 个）**优先取 `Assets/android-3d/` 里的同名文件**，
  没有则取 `output/android-3d/` 里重新生成的产物；字体、质量图标、`boot-lettering-art.json`、
  桥接与许可证仍取 `output/resources`。**文件名不变**，所以 `Qt/Android.cmake` 的 qrc 装配
  与运行时的 `root + 文件名` 读取都不需要改。
- 桌面 / iOS 不设置这两个环境变量：两个 Python 脚本的默认路径仍逐值是
  `Assets/models`、`Resources/`、`output/resources`，`package-resources.cjs` 的 Android 分支
  也不命中——源路径、生成产物、打包清单都不变。

将来单独调整 Android 的 3D，改 `Assets/android-3d/` 里的文件即可；`archive-*.json` 里记着源
glb 的 SHA-256，换模型后重新跑 `npm run build:android` 会一并更新。

## 3D 渲染性能：Android 专属默认策略

Android 的 3D 走 `RhiScene`（`QQuickRhiItem`）+ `QRhi::OpenGLES2`（GLES 3.0），**不进**
桌面 / Apple 的 `PresentationShell` 补帧层；FidelityFX 不编入，AA 默认 `off`。也就是说
渲染分辨率、MSAA、后处理链、模型精度、烘焙贴图规格这些**会改变观感的旋钮一个都没动**。
这一节只做一件事：把几项「原本为 Vulkan 写的、只改 buffer 组织或 render pass 存储策略、
不改任何像素」的优化在 Android 上默认打开。

策略集中在 `Qt/src/render/AndroidRenderPolicy.h`，`Qt/src/RhiScene.cpp` 只负责取值：

| 优化 | Android 默认 | 桌面 / iOS | 收益 | 为什么画面不变 |
| --- | --- | --- | --- | --- |
| 紧凑实例 80 B（`RHINE_VK_COMPACT_INSTANCES`） | 开 | 关 | 每实例少传 64 B，实例载荷省约 44% | `opticalGeometry.vert` 的 `previousModel` 整段包在 `RHINE_SINGLE_PASS_MOTION` 里，该宏只给桌面 Linux / Apple 定义；Android 主变体本就只读 location 0..7，与 `/opticalCompact` 在 GLES 下逐字同构。shader 读到的 80 字节完全相同 |
| 丢弃无人读取的深度（`RHINE_VK_DISCARD_UNUSED_DEPTH`） | 开 | 关 | tile-based GPU 每帧少一次 D32F 写回主存（1080p 约 8 MB） | 只改 pass 结束后的 `storeOp`，不改深度测试与颜色；`resize()` 用保守的 `depthStoreRequired()` 兜底，motion / TAA / warp / MetalFX 任一存在就照旧 store |
| GLES 实例池（原 `ensureInstancePool()` 只放行 Vulkan） | 放行 `OpenGLES2` | 仍只放行 Vulkan | 几十个逐 draw 小 VertexBuffer 合成一个大 buffer，配合内容差分把每帧约 165 KB 上传压到接近 0 | 只改 buffer 组织与 `VertexInput::offset`，顶点 / 材质 / 纹理内容不变；容量或对齐放不下时 `poolInstances()` 整帧回退逐 draw |
| 材质 UBO arena（`RHINE_VK_UNIFORM_ARENA`） | **关**（保持原样） | 关 | — | 见下 |

**材质 arena 为什么刻意不在 GLES 上默认开**：Qt 的 GLES2 后端把
`QRhi::NonDynamicUniformBuffers` 报为 true——没有真正的 UBO，uniform 靠 `glUniform`
逐次下发；SRB 一旦带动态偏移，后端就跳过「相同 SRB 不重绑」的优化、每个 draw 都重设一遍
uniform。arena 的「一次绑定 + 动态偏移」收益在 GLES 上拿不到，甚至可能比逐材质 buffer 更慢。
想实机 A/B 可显式设 `RHINE_VK_UNIFORM_ARENA=1`，`ensureMaterialArena()` 有能力探测，
不满足会自动回退并在日志里给出原因。

**回退与 A/B**

- 单项：上面三个环境变量写 `=0` 即关（也可写 `=1` 在桌面强制开做对照）。显式设置永远优先。
- 总开关：`RHINE_ANDROID_RENDER_TUNING=0` 把 Android 的三项默认值整体退回改动前。
- `Renderer::vulkanConfig()` 分别上报「请求值 / 生效值 / 回退原因」，可据此确认实际命中；
  紧凑实例还有 `compactInstancesAllowed()` 兜底——开了 TAA / FSR 或 warp 探针时存在运动矢量
  消费者，会自动回到 144 B。

验证观感不变可用 `RhiScene::renderReference()`（Android 上以 `OpenGLES 3.0` +
`QRhi::OpenGLES2` 渲一帧并读回 `QImage`）对同一场景做逐像素 A/B；运行期看
`Renderer` 上报的 `samples` / `renderSize` / `drawCalls` / GPU 分项，确认分辨率与
绘制次数都没变，只有 CPU 侧上传量下降。

**刻意没做的**（都会改变观感，按需求排除）：降 render scale / DPR / MSAA、砍后处理链、
降模型顶点数或 `DiscGeometry::Segments`、降烘焙贴图规格、限帧。缩小封面纹理或下调单帧
上传预算虽然不改最终像素，但会改变封面出现的时机，也没有动。

**隔离性**：`renderFlag()` 在桌面 / iOS 恒返回 `legacyDefault`，
`androidInstancePoolOnGles()` 恒为 false，`ensureInstancePool()` 的 `backendAllowed`
也就退化为原来的 `rhi->backend() == QRhi::Vulkan`。新头文件在非 Android 平台只是几个
返回常量的内联函数，不参与任何渲染路径；CMake、着色器烘焙、资源打包一行未改。

## 音频与系统媒体控件

- 播放走 Qt Multimedia 的 Android 后端（系统 MediaPlayer）。它的 `setMedia` 会忽略
  `QIODevice`，所以 `AudioPlayer` 在 Android 上不启动 `HttpAudioStream` 预下载，
  而是把锁定链接直接交给系统播放器流式播放——Range 续传与 seek 由系统处理。
- `rhine.music.database.RhineMediaService`（`Qt/android/src/`）提供 MediaSession +
  MediaStyle 通知 + 音频焦点：通知栏/锁屏的播放、暂停、上下曲，耳机与蓝牙按键，
  拔耳机自动暂停，被其它应用抢占焦点时暂停。
- 通知按钮的动作经 JNI 送回 `Host::mediaAction`，与桌面快捷键、iOS 遥控共用一条通路；
  动作字符串与 iOS 的 MPRemoteCommandCenter 完全一致。
- `POST_NOTIFICATIONS` 在 Android 13+ 于首次播放时向用户申请；拒绝只是通知不显示，
  会话与耳机按键仍可用。
- 通知栏/锁屏显示专辑封面：`Host` 把 QML 上报的封面地址经既有下载缓存取到应用私有目录，
  路径随元数据一并传给服务，Java 侧解码成 `METADATA_KEY_ALBUM_ART`（路径变化才重新解码）。
- **待机保活。** 播放清空后服务不撤岗：通知转入"未在播放"的待机态，前台服务持续持有，
  系统不会回收进程，重新打开立即可续播；音频焦点在待机时释放，不拦其它应用出声。
- **会话状态与桌面一致地恢复。** 移动端没有干净退出（滑掉应用是 SIGKILL，aboutToQuit
  不会触发），所以每 15 秒与退后台时把 `session.json` 落盘一次，启动时按同一份格式恢复。

## 触摸与滑动

- 点击/拖动由 Qt 的合成鼠标事件走桌面同一条 pointer 通路。
- 滚动：`Qt/qml/TouchInput.qml` 把纵向拖动换算成 `wheelInput`（与桌面滚轮同一条通路）；
  iOS 只在弹层与详情里启用，Android 全程启用。
- 系统返回手势/返回键由 Qt 转成 Escape 键，与桌面的 Esc 语义一致。

### 命中范围与滑动步进（仅 Android）

- **命中范围。** `Qt/qml/Overlay.qml` 的 `touchHitPadding`（舞台像素，Android `16`、其它平台 `0`）
  把 `rhine.hits` 的每个热区四周外扩，`hitArea()` 同时用于 Repeater 的 MouseArea 和弹层列表的
  手工命中判定；播放栏 seek/volume 只**竖向**外扩，横向保持原样，否则 `adjustPlayer` 用
  `mouse.x / width` 算出的进度比例会偏。舞台坐标按 1080 高归一化，16 在常见手机上约
  1~1.5 mm，按手感改这一个值即可。相邻热区很近时会有少量重叠（后者在上层），这是
  手指命中率的取舍；桌面与 iOS 取 0，`hitArea()` 逐值返回原矩形，行为不变。
- **滑动步进。** `Qt/src/Engine.cpp` 的 `WHEEL_STEP_PIXELS`：连续像素每累积 15 舞台像素算
  1 step，资料库 archive 模式下 1 step 切一首歌，详情/队列等列表也是 1 step 一行。Android
  编译分支把它放大 5 倍到 `75`，也就是「翻一首歌」需要约 5 倍滑动距离；列表的连续滚动
  （`m_wheelDistance`）不受影响，不会变得拖不动。桌面、iOS 与其它平台的取值仍是 `15`，
  滚轮的离散分支（`-delta / 15. * WHEEL_DISTANCE_PER_NOTCH`）也不在这个改动里。

## 已知限制

- **TLS 用 Node 自带的根证书。** Android 没有从 Node 侧访问系统信任库的通道（iOS 走 Security.framework），
  所以用户自己安装的 CA 不会被采纳；公共 CA 签发的证书正常工作。
- **没有本地音乐与官方客户端交付。** 与 iOS 一致：`PlatformFeatures` 在这两个平台关闭
  `LocalMusic` 与 `OfficialPlayback`，面板只做检索、歌词与面板内播放。
- **切后台画面冻结、声音继续。** GPU 提交在后台停止；音频由前台服务持有，
  通知栏/锁屏/耳机按键控制它的播放与暂停。

## 排障

| 现象                                             | 原因                                                                                                                                         |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `Qt for Android kit not found`                   | 没装 Qt 的 Android 组件，或路径不是 `~/Qt/6.12.0/android_arm64_v8a`；用 `RHINE_ANDROID_QT` 指定                                              |
| `libnode.so not found`                           | nodejs-mobile 的包没解出来；删掉 `output/dependencies/node-mobile` 重新构建                                                                  |
| Gradle 报 `Unsupported class file major version` | Gradle 跑在了 JDK 22 以上的 JVM 上。用 `npm run build:qt:android` 重跑（它会钉住 JDK 21），或先 `export JAVA_HOME=<JDK 21>` 再直接跑 `ninja` |
| 首次启动白屏十几秒                               | 正在解包资源（约 45 MB）到应用私有目录，只在版本号或提交变化后的第一次发生                                                                   |
| 界面能起但列表空白                               | Node 运行时没起来；`adb logcat` 里看 `Android:` 与 node 的 stderr 输出（本仓库不做实机调试）                                                 |
| 画面上下颠倒                                     | 清单被模板覆盖回 `unspecified`；`scripts/audit-android.py` 会直接报 `screenOrientation is not sensorLandscape`                               |
| `Qt/android/build.gradle 的前缀不再等于…`        | Qt 升级换了 Gradle 模板；跑 `node scripts/android-gradle-sync.cjs` 重新生成（末尾追加的依赖会保留）                                          |
| Clarity 后台没有会话                             | 清单 `android:name` 被改回 `QtApplication`；`scripts/audit-android.py` 会报 `RhineApplication (Clarity entry point) missing`                 |
| Clarity 回放只有点击、没有画面                   | 已知限制：Clarity 只重画 View 树，拍不到 GL 内容，换容器或后端都没用（见「已知限制：Clarity 无法获取录制画面」）                             |
| Bugly 后台没有崩溃数据                           | 只有中国大陆用户同意后才初始化；欧盟地区、其他地区、地区判定超时都没有 Bugly。看 `logcat` 的 `RhineConsent`，初始化失败会打 `Bugly initialization failed` |
| 崩溃列表里 native 栈只有地址、没有符号           | 需按 Bugly 官方《符号表配置》上传带调试信息的 `.so`；AppKey 放 CI secret，不要写进仓库                                                          |
| logcat 里找不到 `RHINE-SIGNAL`                   | 预期行为：native 已交给 Bugly，自有诊断链默认不编译（`RHINE_ANDROID_SIGNAL_DIAG=0`）；要抓自有现场把宏改 `1` 且把 `BUGLY_NATIVE_MONITOR` 改 `false` |
| 审计报 `unexpected ABIs`                         | Bugly AAR 的 5 个 `libBugly_Native.so` 没被排掉；检查 `Qt/android/build.gradle` 标记行之后的 `jniLibs.excludes` 是否还在                        |
| 首次启动黑屏最多 3 秒                            | 未同意、且本机只有私有地址时才会取公网出口地址（`GeoIp.TOTAL_TIMEOUT_MS`）；本机有公网 IPv4/IPv6 时直接查表、不等待。已同意后不再请求        |
| 点「退出」后应用直接关闭                         | 预期行为：未同意数据传输许可时 `finishAffinity()` 结束进程                                                                                   |
| 国内用户没看到许可弹窗                           | IP 判定失败（断网、端点超时或表未命中）→ 按其他地区放行：照常启动界面与 Clarity，不弹窗、不启动 Bugly，下次启动会重新判定                     |
