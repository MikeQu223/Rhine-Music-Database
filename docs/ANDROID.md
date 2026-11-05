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

## 第三方依赖与 Clarity

Gradle 工程由 androiddeployqt 按 kit 里的模板（`<kit>/src/android/templates/build.gradle`）现场生成，
包源目录里的同名文件会**整份覆盖**它——这是 Qt 应用添加第三方依赖的唯一入口。
`Qt/android/build.gradle` 因此是「模板逐字节副本 + 末尾追加段」：

- 上半部分来自当前 Qt 模板，不要手改；
- `// ===== RHINE additions below` 之后才是我们的内容（目前只有 Microsoft Clarity）；
- `scripts/build-android.cjs` 在构建前校验前缀，模板对不上就直接失败，不会静默沿用旧配置；
  升级 Qt 后跑一次 `node scripts/android-gradle-sync.cjs` 重新生成（追加段原样保留）。

Clarity（会话行为分析，项目 ID `z8vbz4b078`）在 `RhineApplication.onCreate()` 里初始化：
Qt 的启动 Activity 在 Qt 自己的 jar 里、插不了代码，所以清单的 `android:name` 从
`org.qtproject.qt.android.bindings.QtApplication` 换成继承它的
`rhine.music.database.RhineApplication`。初始化整段用 `try/catch` 包住——分析 SDK 出问题
不该拖垮面板本身。日志级别取 `LogLevel.None`，排查初始化问题时可临时改 `Verbose`。

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
| Clarity 后台没有会话                             | 清单 `android:name` 被改回 `QtApplication`；`scripts/audit-android.py` 会报 `RhineApplication (Clarity entry point) missing`                  |
| Clarity 回放只有点击、没有画面                   | 已知限制：Clarity 只重画 View 树，拍不到 GL 内容，换容器或后端都没用（见「已知限制：Clarity 无法获取录制画面」）                              |
