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
桌面 / Apple 的 `PresentationShell` 补帧层；FidelityFX 不编入，AA 默认 `off`。优化分两批：

1. **严格无损**（第一轮 + 第二轮）：只改 buffer 组织、render pass 存储策略，以及
   Android 上白跑的 CPU 侧工作，不改任何像素。
2. **观感档位默认全开**（本轮）：按「不要考虑省电，就是限制帧数那种不要，其他全打开」，
   把会轻微改变像素的两项 GPU 杠杆也设成 Android 默认值——渲染分辨率 90% 与
   合成 9→4 双线性折叠。**人为限帧刻意不做**：`RHINE_TICK_MS` /
   `Engine::frameIntervalMs()` / `FramePacingPolicy` 一行未改，仍走动态自适应节奏。
   会明显损坏画面的手段（砍后处理链、降 MSAA / 模型顶点数等）仍不在范围内。

默认值集中在 `Qt/src/render/AndroidRenderPolicy.h`，`Qt/src/RhiScene.cpp` 只负责取值；
渲染分辨率与合成折叠另有各自的开关（见下）。

| 优化 | Android 默认 | 桌面 / iOS | 收益 | 为什么画面不变 |
| --- | --- | --- | --- | --- |
| 紧凑实例 80 B（`RHINE_VK_COMPACT_INSTANCES`） | 开 | 关 | 每实例少传 64 B，实例载荷省约 44% | `opticalGeometry.vert` 的 `previousModel` 整段包在 `RHINE_SINGLE_PASS_MOTION` 里，该宏只给桌面 Linux / Apple 定义；Android 主变体本就只读 location 0..7，与 `/opticalCompact` 在 GLES 下逐字同构。shader 读到的 80 字节完全相同 |
| 丢弃无人读取的深度（`RHINE_VK_DISCARD_UNUSED_DEPTH`） | 开 | 关 | tile-based GPU 每帧少一次 D32F 写回主存（1080p 约 8 MB） | 只改 pass 结束后的 `storeOp`，不改深度测试与颜色；`resize()` 用保守的 `depthStoreRequired()` 兜底，motion / TAA / warp / MetalFX 任一存在就照旧 store |
| GLES 实例池（原 `ensureInstancePool()` 只放行 Vulkan） | 放行 `OpenGLES2` | 仍只放行 Vulkan | 几十个逐 draw 小 VertexBuffer 合成一个大 buffer，配合内容差分把每帧约 165 KB 上传压到接近 0 | 只改 buffer 组织与 `VertexInput::offset`，顶点 / 材质 / 纹理内容不变；容量或对齐放不下时 `poolInstances()` 整帧回退逐 draw |
| 跳过无消费者的运动矢量收尾（`RHINE_VK_SKIP_IDLE_MOTION`） | 开 | 关 | 每帧省掉 `publishMotionInputs()` 的矩阵解析 / `atan` / 近远平面计算，以及 Globals 尾部 128 B 的两次矩阵填充 | `Q_OS_ANDROID` 蕴含 `Q_OS_LINUX`，这段原本会跟着桌面 Linux 分支一起跑；但 300es 主变体没有 `RHINE_SINGLE_PASS_MOTION`，shader 不读那两个矩阵，`FgFrameTap::publish()` 在 tap 未启用时也只是空操作。打开 TAA / FSR / FG / `RHINE_WARP_PROBE` 时 `idleMotionWork` 自动翻回 false，不会静默丢运动矢量 |
| Globals 差分上传（`RHINE_VK_DIFF_GLOBALS`） | 开 | 关 | 相机 / 选中项 / 主题不变的帧里省掉一次 832 B 拷贝和一条 `resourceUpdate` 记录 | 只在内容逐字节相同时跳过上传；`qrhigles2.cpp:2846` 把 Dynamic UniformBuffer 存成 `QByteArray` 字节镜像、内容跨帧保留，uniform 仍由 `setShaderResources` 每帧从镜像读值下发，结果不变。Vulkan 的 per-frame ring 不在此列，所以只在 Android 启用 |
| 材质 UBO arena（`RHINE_VK_UNIFORM_ARENA`） | **关**（保持原样） | 关 | — | 见下 |

**收益量级要说清楚**：无损那几项清掉的是每帧白跑的 CPU 工作（一次 `QJsonObject`
矩阵解析 / `atan` / 近远平面计算、两次矩阵填充，以及一次 832 B 拷贝），不改任何像素；
静态分析证明不了实际帧率提升，真机上看 `RHINE_STEP_PROBE` 的 CPU 分段即可。
GPU 侧的大头由本轮两项观感档位承接：90% 让内部渲染目标与所有全屏 pass 的像素数降到
约 81%，折叠让唯一常驻全屏 pass 在 `k==1` 区域的纹理读取从 9 次降到 4 次。两者叠加会
**改变像素**，所以逐像素 A/B 不能再要求「结果完全一致」，只能用来量差异与找回归。

**材质 arena 为什么刻意不在 GLES 上默认开**：Qt 的 GLES2 后端把
`QRhi::NonDynamicUniformBuffers` 报为 true——没有真正的 UBO，uniform 靠 `glUniform`
逐次下发；SRB 一旦带动态偏移，后端就跳过「相同 SRB 不重绑」的优化、每个 draw 都重设一遍
uniform。arena 的「一次绑定 + 动态偏移」收益在 GLES 上拿不到，甚至可能比逐材质 buffer 更慢。
想实机 A/B 可显式设 `RHINE_VK_UNIFORM_ARENA=1`，`ensureMaterialArena()` 有能力探测，
不满足会自动回退并在日志里给出原因。

### 默认全开：观感档位（限帧除外）

| 档位 | Android 默认 | 桌面 / iOS | 收益 | 观感代价 |
| --- | --- | --- | --- | --- |
| 渲染分辨率 90% | **开** | 100（原生） | 内部渲染目标与全屏合成的像素数约降到 81%，GLES 上最直接的 GPU 杠杆 | 略软；合成本来就有常驻 3×3 二项柔化，90% 通常不明显 |
| 合成 9→4 双线性折叠 | **开** | 关（宏不定义） | 唯一常驻全屏 pass 在 `k==1` 区域的纹理读取 9 → 4 次 | 原生分辨率且 `k==1` 时与九点逐项等价，最多差 1~2 ULP；叠加 90% 时属于肉眼不可见的极轻微变化 |
| 动画期帧率上限（`RHINE_TICK_MS=16`） | **刻意不做** | 不做 | 主要省电与发热 | 高刷设备流畅度降到约 60 fps、触控多最多 16 ms 延迟；用户明确排除 |

**渲染分辨率 90%** 的默认值由 `AndroidRenderPolicy.h::androidDefaultRenderScale()` 给出，
两个消费点必须一致，否则设置页显示与实际生效值会打架：

- `Qt/src/main.cpp::applyRenderScaleSetting()` 把它作为 `panel/render-scale` 的缺省值，
  非 100 时写入 `RHINE_RENDER_SCALE`；`Qt/src/render/ScenePostProcess.cpp::renderSize()`
  读这个环境变量并按 `qBound(.5, percent/100., 1.)` 换算内部渲染尺寸。
- `Qt/src/SettingsSchema.cpp` 的 `render-scale` 描述符 `.defaultValue` 用同一个函数，
  档位仍是 `{50, 60, 75, 90, 100}`。

优先级：显式 `RHINE_RENDER_SCALE` 环境变量 > 用户在设置页存下的 preference > 默认 90。
`RHINE_ANDROID_RENDER_SCALE=50..100` 可以只改默认值，`RHINE_ANDROID_RENDER_TUNING=0`
退回 100。桌面 / iOS 恒为 100，`applyRenderScaleSetting()` 在它们身上的分支逐值不变。

**合成 9→4 折叠** 由 `CMakeLists.txt` 的 `if(ANDROID)` 块控制：
`option(RHINE_ANDROID_QUAD_FOLD ... ON)` 给 `RHINE_OPTICAL_SHADER_DEFINES` 追加
`RHINE_OPTICAL_QUAD_FOLD=1`。`Qt/shaders/enhancement/opticalFinalFragment.frag` 在宏下新增
一条 `k≈1` 分支，用 `v_uv ± 0.5 texel` 的四个对角双线性采样求和乘 4；线性采样器把它们
展开后正是 `[1 2 1; 2 4 2; 1 2 1]`，末尾统一 `/16`，与原九点加权和等价。
`k>1`（焦点外柔化半径放大）时走 `else` 的九点分支，宏未定义时则整块只有九点路径。

> 更正：上一版文档说 `RHINE_OPTICAL_SHADER_DEFINES` 是全局烘给 `130,150,300es`、
> 「不能只给 Android 加 define」，这个判断是错的。`DEFINES` 是 **CMake 配置期**参数，
> Android 与桌面 / iOS 是各自独立 configure 出来的构建树，`if(ANDROID)` 只影响 Android
> 的 qsb 烘焙；不需要另起 `/opticalMobile` 变体，也不用在运行期切换 qrc 路径。
> 桌面 / iOS 不带这个宏，着色器产物与改动前逐字节相同。

**限帧刻意没做**：`RHINE_TICK_MS` 只是 `Engine::frameIntervalMs()` 里的排障覆盖旋钮，
默认返回 `-1` 交给 `tick()` 动态自适应；静止 750 ms 后 timer 本来就会停。本轮没有给它
任何 Android 默认值，也没有改 `FramePacingPolicy`。

**仍未纳入的一项**：烘焙表面图集 `archive-baked-surface-bc7.bin`（1.4 MB）在 GLES 上
永不被读（`RhiScene.cpp:717` 回落到 5.6 MB RGBA8）。改 ETC2/ASTC 能省带宽与内存，但要
离线重烘贴图并补一条压缩纹理加载路径，属于需要跑构建/烘焙才能验证的改动，在项目
「不做构建验证」的前提下没有落地；它需要用户侧执行重烘后再评估。

### 回退与 A/B

- 无损项单项：`RHINE_VK_COMPACT_INSTANCES` / `RHINE_VK_DISCARD_UNUSED_DEPTH` /
  `RHINE_VK_SKIP_IDLE_MOTION` / `RHINE_VK_DIFF_GLOBALS` 写 `=0` 即关（也可写 `=1`
  在桌面强制开做对照）；`RHINE_VK_UNIFORM_ARENA` 仍默认关。显式设置永远优先。
- 渲染分辨率：`RHINE_RENDER_SCALE=100` 或设置页改回 100 即恢复原生；
  `RHINE_ANDROID_RENDER_SCALE=100` 只改默认值。
- 合成折叠：`-DRHINE_ANDROID_QUAD_FOLD=OFF` 重新配置 Android 构建树即可关掉，
  不改源码、不动其它平台。
- 总开关：`RHINE_ANDROID_RENDER_TUNING=0` 把 Android 的全部默认值（含 GLES 实例池与
  90% 分辨率）整体退回改动前；它管不到 CMake 的 `RHINE_ANDROID_QUAD_FOLD`，那个要用
  上面的 `-D...=OFF`。
- `Renderer::vulkanConfig()` 分别上报「请求值 / 生效值 / 回退原因」，可据此确认实际命中；
  紧凑实例还有 `compactInstancesAllowed()` 兜底——开了 TAA / FSR 或 warp 探针时存在运动矢量
  消费者，会自动回到 144 B。

**A/B 观测入口**：`RHINE_STEP_PROBE` / `RHINE_POST_PROBE` / `RHINE_DRAW_PROBE` 分别记
CPU 分段、全屏 pass 数、draw 数；`Renderer::vulkanConfig()` 上报请求值 / 生效值 /
回退原因。逐像素对照可用 `RhiScene::renderReference()`（Android 上以 `OpenGLES 3.0` +
`QRhi::OpenGLES2` 渲一帧并读回 `QImage`）：比较
`RHINE_ANDROID_RENDER_SCALE=100` + `-DRHINE_ANDROID_QUAD_FOLD=OFF` 与默认配置，
即可把两项观感差异单独量出来。运行期还可看 `Renderer` 上报的 `samples` /
`renderSize` / `drawCalls` / GPU 分项，确认分辨率、采样与绘制次数的变化符合预期。

**仍然刻意没做的**（会明显改变观感，不在授权范围）：砍后处理链、降 MSAA / 模型顶点数 /
`DiscGeometry::Segments`、下调单帧上传预算（会改变封面出现的时机）。

**隔离性**：`renderFlag()` 在桌面 / iOS 恒返回 `legacyDefault`，
`androidInstancePoolOnGles()` 恒为 false，`ensureInstancePool()` 的 `backendAllowed`
也就退化为原来的 `rhi->backend() == QRhi::Vulkan`；`androidDefaultRenderScale()` 恒返回
100。CMake 的折叠开关包在 `if(ANDROID)` 里，着色器改动包在 `#ifdef` 里，
非 Android 分支展开后与改动前逐字相同。新头文件在非 Android 平台只是几个返回常量的
内联函数，不参与任何渲染路径；资源打包与其它平台脚本一行未改。

## 滑动列表掉帧：HUD 软件栅格（Android）

**现场**：OPD2511（Adreno 730 / Vulkan / 120 Hz / 窗口 1219×762 逻辑、DPR 2.36），
`RHINE Diagnostics` 里 19.2 秒、322 帧的采样（`rhine-performance-20261106-103531-133-*.json`）。

| 指标 | 数值 |
|---|---|
| `latestSyncCpuMs` | 均值 **41.8 ms**，p50 47.5，p90 61.2，max 76.3 |
| `latestSubmitCpuMs` | 均值 **2.4 ms**（渲染 + 提交整段） |
| `presentGapMs` | 均值 **59.6 ms**，p50 63.1，p90 80.6 |
| `stepMeanCpuMs` | 约 15 ms（GUI 线程每拍） |
| `over33ms` | 每 500 ms 采样里 7~11 帧，几乎全超 |
| `mainProcessCpuOneCorePercent` | 150~180%（≈1.5 核） |

帧时间的账能对上：**GUI 15 ms + sync 42 ms + 渲染 2.4 ms ≈ 59.6 ms**，
也就是 17 fps 左右，掉帧发生在 `sync` 段。`submit` 只有 2.4 ms、FG 层未启用、
`gpuTimingStatus=noSample`，所以**不是 3D、不是后处理、也不是纹理上传**。

`sync` 段里唯一的重活是 `Hud`：它是 `QQuickPaintedItem`，`Overlay.qml` 里
`anchors.fill: parent`，每次 `Engine::hudUpdated` → `update()` 都是整窗重绘
（QPainter 软件栅格，2880×1800），而 `QSGDefaultPainterNode` 在没有 `update(rect)`
时会裁都不裁，连 20 MB 的整张纹理一起刷。列表页每帧都在动（`UiMotion::ReelCurve`），
于是每帧全付开销。

**两条 Android-only 尝试**（在 `Qt/src/Glyphs.cpp`，**实测是负优化，默认已关闭**）：

- **整段文本 / 整串字形合成一条路径**（`textRunPath` / `artRunPath` + `runPaths` 缓存）：
  原本逐字符 `save + translate + scale + fillPath + restore`，改成按
  `(文本, 字重, 字距)` 缓存一条 em 单位路径，每帧只做一次 `fillPath`。
  `RHINE_HUD_RUN_CACHE=1` 可重新打开。
- **归档页右侧淡出遮罩烘成一行图**（`drawCachedMask`）：
  把 `right-mask` 的 789×984 线性渐变烘成 W×1 图再拉伸。`RHINE_HUD_MASK_CACHE=1`。

**为什么翻案**：把这两条默认打开后重编，同机同场景再录一份，结果是

| | 10:35（两条都关） | 11:21（两条都开） |
|---|---|---|
| `latestSyncCpuMs` 均值 | 41.8 ms | **63.0 ms** |
| `headlineFps` | 17.2 | **12.1** |
| `mainProcessCpuOneCorePercent` | 154% | **183%** |
| `latestSubmitCpuMs` | 3.05 ms | 2.60 ms（没变差） |

原因：`QRasterizer` 的覆盖率是按**包围盒**遍历的，不是按墨水面积。把一行字并成一条
复合路径后，包围盒变成整行，而逐字形时每个字形只扫自己那个紧包围盒——合并把扫描线
工作量放大了；腾出的「变换次数」根本抵不过。遮罩那条同理：776k 像素上双线性拉伸
（4 次采样 + 2 次插值）比水平 `QLinearGradient` 的色表查找更贵。

教训：**HUD 这种软件栅格的瓶颈是覆盖率面积，别用「减少 draw call 次数」的直觉去优化它。**
两条代码保留，作为 A/B 用的负样本。

**隔离性**：新成员与快路径全部包在 `#if defined(Q_OS_ANDROID)`；
非 Android 仍然走原来的逐字形循环与实时渐变，展开后与改动前逐字相同。

**为什么调渲染分辨率没用**：`RHINE_RENDER_SCALE` 只改 `ScenePostProcess::renderSize()`，
那是 3D 场景的内部渲染目标；`Hud` 是独立的 QML item，尺寸跟窗口走（2880×1800 设备像素），
不吃这个开关。所以「分辨率降了帧率没变」恰恰是「瓶颈不在 3D 填充率」的证据，不是反证。

## 滑动列表：HUD 局部重绘与子区域上传（Android）

上一节把每帧的重复计算换成了缓存，但**每帧仍然在整张 2880×1800 画布上重来一遍**：
`QPainter` 全量栅格（写 20.7 MB）+ `QSGDefaultPainterNode` 全量 `uploadTexture`
（再写 20.7 MB），60 fps 下就是 **≈2.5 GB/s 的纯搬运**。这才是「带宽」那一层的账，
但它是结果不是原因——原因是「不该重画的地方也重画了」。

### 做法

- **差异计算**（`Qt/src/render/HudDirtyRect.h`，新文件）：`Engine::update()` 在把新命令流
  覆盖旧快照之前，逐条比对两份 `QJsonArray`，算出真正变化的舞台矩形（1080 高度坐标系）。
  语义与 `Glyphs::renderCommands` 对齐：`fill/ellipse/image/right-mask` 取参数矩形；
  `text/art` 取「当前裁剪区整幅宽度 + 基线上下 1.35/1.85 em」的保守条带；
  `fill-path/path/arc` 解析路径代价太高，直接用当前裁剪区兜底；
  `alpha` 变化标记整个 save 作用域为脏；`clip` 变化把新旧裁剪区都算进来
  （否则「旧画过、新不该显示」的像素会留残影）。
  出现 `translate/scale/rotate`、`save/restore` 结构变化、命令条数变化或未登记命令，
  一律 `full = true` 退回整块重画——**宁可多画一帧，也不能留残影**。
- **只重画脏区**（`Hud::scheduleUpdate()`）：脏区换算到 item 逻辑坐标、外扩 2 像素
  （抗锯齿溢出）、交给 `QQuickPaintedItem::update(rect)`，QPainter 自动只栅格化这块。
  脏区超过画布 92% 时直接退回整窗。
- **只上传脏区**（`Hud::updatePaintNode()` Android 分支 + `HudUploadTexture::paintRegion()`）：
  换掉 Qt 默认的 painter 节点——它不看脏区，每次 `commit` 都整张 `uploadTexture`。
  现在是一张自管的 `QRhiTexture`，`paintRegion()` 只把这块清成透明、只画这块，
  `commitTextureOperations()` 只上传这块子矩形。尺寸变化时自动退回整块。
- **封面到达要补一帧**：`image` 命令只带 key，封面解码完成时命令流逐字相同，
  差异比对会认为「什么都没变」。`Engine` 用 `coverRevision` 单独记一笔，强制整块重画一次。

### 「滑列表时 3D 层所有元素都在动」为什么不影响这套做法

这是两个**互相独立的层**，动的东西不是同一张画布：

- **3D 场景**（`RhiScene` / `QQuickRhiItem`）：每帧都重新渲染，`renderFrames == presentCount`。
  它的旋转、镜头推拉、材质动画全部发生在 GPU 上，**每帧本来就要整屏重画**，从来不存在
  「复用上一帧」的问题，也没有被这次改动碰过。
- **HUD**（`Hud`，`QQuickPaintedItem`）：一张独立的 ARGB 画布，用 QPainter 软件栅格，
  再作为一个贴图四边形**叠加在 3D 之上**合成。它的像素只由自己的命令流决定，
  不采样 3D 的任何内容，也没有背景模糊/毛玻璃依赖场景。

所以合成链路是「新 3D 帧 + HUD 贴图」每帧重新合成，而 HUD 贴图里没变的那部分
**内容本来就没变**——复用是安全的。脏块省掉的是「HUD 贴图的 CPU 重画与上传」，
3D 那 2.4 ms 的 `submit` 一分不少地照付。这也正是为什么先把两者分开量：
`sync 42 ms` 是 HUD，`submit 2.4 ms` 是 3D，只有前者能被脏块回收。

### 带宽账（1219×762 逻辑 / DPR 2.36 / 2880×1800 像素）

| | 每帧 CPU 写 | 每帧纹理上传 | 60 fps 合计 |
|---|---|---|---|
| 改动前（整窗） | 20.7 MB 清屏 + 全量栅格 | 20.7 MB | ≈2.5 GB/s |
| 改动后（只画曲目条带） | 约 8 MB（条带面积占比 ≈40%） | 约 8 MB | ≈1 GB/s |

条带占比是估的：`archiveTrackList` 的裁剪区是 `(x-4, 219, width-x, 610)`，在舞台坐标里
约 1274×610 / 1727×1080。真实占比看下面这条探针，不要照抄。

### 三次实测与两个根因（11:21 / 11:32）

| | sync 均值 | fps | submit | 说明 |
|---|---|---|---|---|
| 10:35 | 41.8 ms | 17.2 | 3.05 ms | 基线：整窗重绘、缓存关 |
| 11:21 | **63.0 ms** | 12.1 | 2.60 ms | 两个 HUD 缓存打开（负优化） |
| 11:32 | **47.5 ms** | ~18 | **5.83 ms** | 缓存关、脏区重绘生效但算成整屏 |

- 11:21 的 +21 ms 来自 `runPaths` / `maskGradients` 两个缓存，机理见上一节，已默认关闭。
- 11:32 的 +5.6 ms 落在 `submit`（不是 `sync`）：脏区算成了整屏，于是每帧多做一次
  `canvas.copy(20.7MB)` 交给上传批次。根因是 `hudDirtyRect` 在 `clip` 变化时把**父裁剪**
  也并进了脏区——而滚动文字的 `clip` 每帧都在动，它的父裁剪就是整屏。改成只并
  「本作用域裁剪之后的两块」即可。这一条是回归测试抓不到的，只能靠 `hudDirtyPercent` 看。

**教训**：脏区算法里任何"并上一个更大的矩形求稳"的写法，都会把优化整条吃掉；
宁可在小区域上多画几次，也不能把父容器拉进来。

### 探针与回退

- **`hudDirtyPercent`（性能 JSON 新字段，主通道）**：每个 500 ms 采样里
  「重画像素 / 画布像素」。接近 100 就是整屏重绘（优化没生效），40 左右说明只重画了
  曲目条带；`hudPaints` 是同窗口的绘制次数。设备上设不了环境变量、OPPO 的 logcat
  配额还会把行挤掉，而 `RHINE Diagnostics` 每次都会拉回来，所以优先看这个。
- **日志副本**：同一组数字每 240 次绘制还会打一行 `HUD 脏区: 平均 x% / 峰值 y% 画布`。
- `RHINE_HUD_TEXTURE_SCALE=50..100`（默认 **100**）：HUD 纹理分辨率档。
  脏区再小，遇到整块重画（换页、启动动画、封面到达）时这是唯一能直接砍像素数的旋钮；
  85 就是 0.72 倍像素、上传量同比例下降。纹理被缩过会自动切成线性过滤。
- `RHINE_HUD_DIRTY_RECT=0`：一键退回 Qt 默认节点 + 整窗重绘，用于 A/B。**默认开启**。

**开关默认值的坑**：`qEnvironmentVariableIntValue(name) != 0` 在变量**未设置**时返回 0，
拿它当「默认开启」会让开关实际是关的——11:21 那轮就踩了这一下，白费一次构建。
默认开启必须写 `qEnvironmentVariable(name).isEmpty() || value != "0"`。
自检脚本里已加断言防回归。


### 隔离性

`render/HudDirtyRect.h` 只在 `Engine.cpp` 的 `#if defined(Q_OS_ANDROID)` 分支里 include
和调用；`Hud` 的脏区成员、`scheduleUpdate()` 的局部分支、`updatePaintNode()` 的
Android 实现全部包在 `#if defined(Q_OS_ANDROID)`；`HudUploadTexture` 只是新增了
`paintRegion()`，macOS 用的 `paint()` + `findDirtyPixels()` 逐字未动。
非 Android 仍然每帧整窗重绘、走 Qt 默认节点，展开后与改动前一致。

**验证方法**：装新包后重录一份 `RHINE Diagnostics`，看三件事——
`latestSyncCpuMs` 是否从 ~42 ms 掉下来、`presentGapMs` p50 是否接近 33 ms（30 fps）、
`over33ms` 是否明显变少；同时抓一行 `HUD 脏区` 日志确认占比。
**没有实机数据前不要下结论。**

**还没做**：把 HUD 命令流按「静态背景 / 动态条带」拆成两张纹理叠层——那样静态层
（brand、导航、footer、播放栏、右侧遮罩）连脏区那 40% 都不用重画，
是这条路的终点；需要先给命令流打上分区标记。

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
- **设置页只响应右侧控件。** `Qt/src/SettingsCard.cpp` 的 `drawChoice()` 在
  `#if !defined(Q_OS_ANDROID)` 里注册左侧标题热区——那条热区绑定的是旧版
  `binding.action`「点名称循环到下一个值」，手指擦过名称就会误改设置且无法撤销。Android
  编译期不注册它，因此左侧标题区完全没有热区（但仍可拖动滚动列表）；设置项只能点右侧
  300 宽的控件：Choice / Switch 先点 `expand:<id>` 展开下拉、再点具体选项走
  `setting:<id>:<value>` 精确设值，Stepper 点 ± 或轨道，Action / TextInput / Link 与自定义
  区块的按钮本来也都在右侧。所有 Choice 行都带 `actionPrefix`，所以去掉标题热区不会让
  任何设置项变得不可修改。`touchHitPadding` 仍会把这些右侧热区外扩 16。桌面 / iOS 的
  `drawChoice()` 逐字不变，点标题仍可循环切值。

## 前台 ANR：系统无障碍服务把 Qt 主线程拖死

**现象**：前台滑动时界面突然消失。它**不是**后台被杀、不是 OEM 管控，也不是 native 崩溃——
是 `Input dispatching timed out` 触发的 ANR，系统随后按 `user request after error` 杀掉进程，
`ApplicationExitInfo reason=6 (ANR)`。所以「无后台限制」「自启动白名单」都帮不上。

**证据**（2026-11-06 17:12:33 / 17:13:30 / 17:56:09 / 17:56:34，OPD2511）：

- `am_anr`：两次 `Input dispatching timed out`（17:12:33 / PID 23323、17:56:09 /
  PID 14494，`Waited 5000ms for MotionEvent(... action=MOVE ...)`），两次
  `No response to onStartJob`（17:13:30 / PID 26327、17:56:34 / PID 20840，
  超时的是 Clarity 的 `UploadSessionJob`）。后两次**没有应用栈**，不是「Clarity 自己
  卡住」的证据：17:13:30 是
  `libdebuggerd_client: failed to read status response from tombstoned: timeout reached?`
  且随即 `No such process`；17:56:34 是 OPPO 主动跳过抓栈
  （`WatchdogExtImpl: Skip the stacktraces of ANR because anr too frquency`）。
- 两次有栈的 ANR，Java 主线程都停在
  `QtNativeAccessibility.childIdListForAccessibleObject` /
  `descriptionForAccessibleObject`，调用链为
  `QtAccessibilityDelegate.getEventForVirtualViewId` ← `invalidateVirtualViewId`
  ← `notifyObjectShow` / `notifyObjectHide`。
- Qt 主线程（`qtMainLoopThread`，`state=R`）一次栈顶是
  `QInternal::activateCallbacks` + `sendPostedEvents`，另一次是
  `QAccessibleQuickWindow::child` 的四层递归 + `sendPostedEvents`——正是 Java 侧
  `runInObjectContext()` 用 `Qt::BlockingQueuedConnection` 同步投递过来的调用。
- `QtThread`（渲染线程）在 `pthread_cond_wait`，与渲染无关；两次 ANR 的调用链同类
  （栈顶帧不同，但都落在可访问树遍历 / `sendPostedEvents`）。
- 设备上 `accessibility_enabled=1`，唯一启用的是系统常驻服务
  `com.itos.metric.monitor/...RealtimeNotificationAccessibilityService`（"Metric 实时通知"）。
  **不是 Clarity 注册的**：Clarity 重画 View 树，本身不读 `QAccessible` 节点。
- 11-06 没有任何属于本应用的 native crash tombstone（当天两份是系统 facehal 的 SIGBUS）。

**机制**：系统有无障碍服务 → `QtNativeAccessibility.setActive(true)` →
`QAndroidPlatformAccessibility::notifyAccessibilityUpdate()` 把每次 QML 对象的显示/隐藏
转发给 Java delegate → delegate 的 `getEventForVirtualViewId()` 经 JNI 用
`BlockingQueuedConnection` 同步回 Qt 主线程递归遍历整棵可访问树。QML 面板对象多，
滑动时 `ObjectShow/Hide` 高频，Qt 主线程被打满，Java UI 线程一直等，5 秒后 ANR。

### Clarity 的准确定位：不是病灶，是报警器 + 放大器

这里之前写「`UploadSessionJob` 被连带拖超时、**不是** Clarity 引起的」。作为**根因判断**
这句没错；但它把「谁让主线程卡住」和「系统拿谁的超时判死」混成了一件事。按 dump 复核后补正：

- **根因没变，也不是 Clarity 引起的**。两次有栈的 ANR 里，Java 主线程都在
  `QtNativeAccessibility.*`，Qt 主线程都在可访问树遍历，主线程栈没有一帧 Clarity；
  Clarity 自有的 `Thread-11/12/13` 全是 `Waiting` 在
  `LinkedBlockingQueue.take` / `LinkedBlockingDeque.take`，处于空闲。Clarity 也没有
  注册无障碍服务（它重画 View 树）。
- **但 Clarity 是 4 次 ANR 中 2 次的判死超时点**。`No response to onStartJob` 是系统
  `JobServiceContext` 监视 `UploadSessionJob.onStartJob()` 的超时到期；`onStartJob`
  跑在应用主线程，主线程被 Qt 无障碍递归占住时，job 的绑定回调排在消息队列里出不来，
  系统**不需要任何触摸输入**也能据此把进程判死。所以更准确的说法是「报警器」，
  而不是「完全无关的旁观者」。
- **它放大了故障**。dropbox 的 `Debug Store` 里 `SvcCreate`/`SvcBind` 成对出现，
  `UploadSessionJob` 大致每 8.4~11.4 秒被调度一次：PID 14494 的间隔是
  `8418 / 8934 / 10052 ms`（最后一次距 ANR 14.9 秒），PID 23323 是
  `9317 / 11416 ms`（最后一次距 ANR 2.5 秒，中间夹一次 33 秒间隔）。任何超过
  8 秒的主线程停顿都更容易撞上这个周期性 deadline。JobScheduler 的 job 跨进程存活，
  上次崩溃遗留的待上传会话会在冷启动期重试——17:56:34 的 PID 20840
  `Process-Runtime: 23541`（只活了 23 秒）、CPU 118%、201840 次 minor fault，
  正是冷启动与重试 job 撞在一起的时刻。
- 结论：**不要因为 `No response to onStartJob` 就去动 Clarity 本身**；但把它写成
  「完全无关」也不对。关掉 Qt 无障碍桥之后，必须重新验证这条 job 超时是否随之消失。

**修法（仅 Android）**：`Qt/src/AndroidWindow.cpp::configureAndroidAccessibility()` 在
`QGuiApplication` 创建后、任何 QML 场景加载前，装一个空的 `QAccessible::UpdateHandler`
并调 `QAccessible::setActive(false)`。`updateAccessibility()` 会优先调用 handler 并直接
`return`，事件不再到达 `notifyAccessibilityUpdate()`；这一步是关键，因为 Java 侧随时可能
把 `QPlatformAccessibility::m_active` 改回 true，但碰不到这个全局函数指针。

- 本项目是 GPU 自绘面板，没有原生可访问控件，关掉这条桥不影响任何功能，
  也不影响 Clarity 的**采集**（它重画 View 树，本来也拍不到 GL 内容）；
  但 Clarity 的 `UploadSessionJob` 仍是 ANR 判死路径之一，见上一节。
- `AndroidWindow.cpp` 只在 `Qt/Android.cmake` 里编入，`main.cpp` 的调用包在
  `#if defined(Q_OS_ANDROID)`，桌面 / iOS 逐值不变。
- 取舍：依赖 TalkBack 的用户会失去 QML 内容的可访问节点。
  `RHINE_ANDROID_ACCESSIBILITY=1` 可保留原行为做 A/B，日志会打
  `Qt accessibility bridge kept`。

**装新包后的验证要点**（一次性 `adb logcat -d -b all`，不要常驻 logcat）：

1. 启动日志出现 `Android: Qt accessibility bridge disabled (foreground ANR safeguard)`；
2. 复现滑动、锁屏解锁、快速换面，`am_anr` 里 `Input dispatching timed out`
   与 `No response to onStartJob` **两条都不再出现**；
3. 若只剩 `No response to onStartJob`（尤其是冷启动 30 秒内），说明冷启动本身仍会
   堵住主线程超过 8 秒。这时再考虑 Android-only 的启动宽限：把
   `ConsentStore.startSdks()` 里的 Clarity 初始化推迟到 Qt 首帧之后，让
   `UploadSessionJob` 不与约 500 MB 的资源加载抢主线程。**这是候选方案，本轮未实现**——
   不动 SDK、不动许可闸门，也不碰其他平台；
4. A/B 复现旧行为用 `RHINE_ANDROID_ACCESSIBILITY=1`。

**和 11-04 的 Vulkan surface 崩溃是两个独立问题**。那一批是 `SIGABRT` +
`FORTIFY: pthread_mutex_lock called on a destroyed mutex`，栈为
`QRhi::endFrame` → `QueuePresentKHR` → `android::Surface::hook_queueBuffer`，
由**前台 Surface 换面**（BLAST relayout）触发，`applicationStateChanged` 根本不跑。
`scripts/qt-android-patches.cjs` 里的 qtbase 竞态补丁仍在，且按设计只改构建期源码、
submodule 工作树保持干净；但 `output/dependencies/qt-android/plugins/platforms/
libplugins_platforms_qtforandroid_arm64-v8a.so` 的 mtime 停在 2026-11-03 20:54、
BuildId 与当前 APK 里那份完全一致，补丁新增的 `destroySurfaceResources` 也不在其中——
**说明它从未编译进 kit**。要让那条修复生效，需重跑 `npm run build:qt:android`
再重建 APK；在此之前前台换面仍可能复发旧的 SIGABRT。两条线别混为一谈。

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
| Android 画面比桌面略软                           | 预期行为：Android 默认渲染分辨率 90%（`androidDefaultRenderScale()`）。要原生清晰度用设置页改回 100、`RHINE_RENDER_SCALE=100`，或 `RHINE_ANDROID_RENDER_TUNING=0` 整体回退        |
| Android 想关掉合成 9→4 折叠做对照               | 用 `-DRHINE_ANDROID_QUAD_FOLD=OFF` 重新配置 Android 构建树；这是 CMake 配置期开关，桌面 / iOS 本来就没有这个宏                                   |
| 前台滑动时界面突然消失（无响应后退出）           | ANR：`Input dispatching timed out`，系统按 `user request after error` 杀进程。根因是系统无障碍服务激活了 Qt 的可访问树遍历，见「前台 ANR」一节；默认已关闭该桥，`RHINE_ANDROID_ACCESSIBILITY=1` 可恢复             |
| logcat 出现 `No response to onStartJob` / `com.microsoft.clarity.jobs.UploadSessionJob` | 不是 Clarity 崩溃，也不是本应用 native crash：`onStartJob` 跑在主线程，主线程被卡住时它的 8 秒 deadline 到期，系统据此判 ANR 并杀进程；该 job 每 ~10 秒调度一次、跨进程存活，冷启动重试时最容易撞上。见「Clarity 的准确定位」，先按上一行修无障碍桥，再看冷启动是否仍超时 |
| logcat 又出现 `destroyed mutex` 的 SIGABRT      | 与前台 ANR 不同的老问题：Vulkan surface 换面竞态。`scripts/qt-android-patches.cjs` 的补丁还在，但 kit 没重编过；重跑 `npm run build:qt:android` 再重建 APK 才会生效                              |
