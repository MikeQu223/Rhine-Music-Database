# iOS / iPadOS 本地维护说明

更新日期：2026-10-24

## 维护原则：业务只改一份

音乐账号、歌单、搜索、播放状态、音频解码、歌词和场景都继续使用原来的公共实现。
没有新增 iOS 专用的 MusicLibrary、MusicPlayer、MusicApi、AudioPlayer 或协议分发器。
`MusicBridge/worker.cjs`、`qq.cjs`、`kugou.cjs` 和上游协议源码没有为 iOS 复制一份。

```text
公共 QML / NativeHud / Engine / MusicLibrary / MusicPlayer
                         |
                       Host
                         |
             BridgeProcess 同一调用接口
              /                       \
桌面：原 QProcess                 iOS：进程内 NodeMobile + Worker
              \                       /
               同一 MusicBridge/worker.cjs
                 同一锁定的上游协议模块
```

今后修改普通功能或修业务 bug，仍修改原来的公共文件，两端重新构建即可生效。
只有系统窗口、触摸、钥匙串、媒体中心、运行时启动、系统证书信任和打包需要维护 iOS 适配文件。
桌面 `BridgeProcess` 是 `QProcess` 的类型别名，不增加另一层进程行为实现。

平台能力集中在 `Qt/src/PlatformFeatures.h`。iOS 关闭官方客户端播放、本地音乐、应用内音量和桌面窗口控制；
桌面能力保持开启。不要在业务中另写一套 iOS 状态机，也不要把功能代码复制到平台文件。
本地库类仍由公共核心编译，但 iOS 不展示入口、不允许切入本地来源，并使用离线实例避免持久索引；
不为删除这部分共用类而大范围改变原有对象结构。

## 本次逐文件变更

以下每行对应一个实际新增或修改的版本控制文件；没有把构建生成物当作维护源码。

### 构建、依赖和归属

| 文件 | 改了什么 | 为什么要改 |
| --- | --- | --- |
| `.github/workflows/desktop.yml` | 增加独立 iOS arm64 job：Qt 6.12 主机/设备 kit、构建审计与 IPA artifact 上传。 | 四平台并行使用各自工作区；iOS 不使用签名凭据，不改变桌面矩阵的运行方式。 |
| `.github/workflows/publish.yml` | 预检运行三组发布/安装器检查，并从共用平台清单收集四平台版本化产物。 | 默认 npm test 精简；正式发布仍校验全部产物，包含未签名 IPA。 |
| `scripts/release-version.cjs` | 导出统一的四平台分发后缀清单，已有版本解析逻辑继续共用。 | 发布收集、上传及更新清单只维护一份平台定义；iOS 不另写版本逻辑。 |
| `scripts/create-update-feed.cjs` | 使用统一平台清单生成包含 IPA 的四平台更新元数据。 | 保证发布的文件、校验和与 iOS 更新识别一致。 |
| `scripts/publish-release.cjs` | 从统一平台清单生成待上传及校验的文件名。 | iOS 与其他平台共用原有草稿 ID、上传、校验和发布流程。 |
| `CMakeLists.txt` | 新增独立 IOS 平台分支，链接 iOS 实现，跳过桌面部署和桌面测试可执行目标。 | `APPLE` 同时涵盖 macOS 和 iOS，iOS 不能链接 AppKit 或执行 macdeployqt。 |
| `Qt/CMakeLists.txt` | 注册 IOSInput、LocalMusicDialogs 两个 QML 组件和资源别名。 | 平台交互独立封装，仍使用同一个 Main 和同一个 QML 模块。 |
| `Qt/IOS.cmake` | 集中配置 iOS 原生源码、NodeMobile、FFmpeg、图标、资源和应用属性。 | 平台打包规则独立维护，公共 CMake 只保留接入点。 |
| `Qt/InfoIOS.plist.in` | 新建 iPhone/iPad 元数据、应用 ID、图标、后台音频及仅横屏配置。 | iOS Bundle 与 macOS 布局不同；系统需要读取完整身份及方向信息。 |
| `package.json` | 增加 build:ios 和 build:ios:simulator 命令。 | 提供独立构建入口，不替换桌面 build。 |
| `MusicBridge/package.json` | 固定新增 node-fetch 2.7.0。 | NodeMobile 的 iOS 运行环境禁用 WebAssembly，不能使用内置 undici fetch。 |
| `MusicBridge/package-lock.json` | 锁定 node-fetch 及其新增依赖。原有 380 条依赖记录保持不变。 | 兼容层可复现构建，不升级或替换既有音乐协议依赖。 |
| `scripts/build-ios.cjs` | 串行准备、构建和审计 IPA；复用公共版本解析器，保留本地固定文件名并增加带 tag/提交号的 IPA。 | 支持本地与全新 CI 环境；iOS 正式版本与其他平台保持一致，artifact 和发布能精确收集。 |
| `scripts/prepare-ios-ffmpeg.cjs` | 从固定源码在 output 中构建 arm64 模拟器 FFmpeg 框架，并缓存结果。 | 当前 Qt 模拟器包所附 FFmpeg 不完整；不修改已安装的 Qt kit。 |
| `scripts/audit-ios.py` | 审计 Apple CFBundle 实际识别、横屏、架构、平台、动态库、资源及无 Swift 依赖。 | 仅能解析 Info.plist 不代表系统可以安装；预先拦截曾出现的 Missing bundle ID。 |
| `scripts/build.cjs` | 增加 --resources-only；把 iOS 适配入口与公共 worker 一起复制到已有依赖暂存目录。 | 复用公共资源准备；兼容层不再依赖源码旁额外安装 node_modules。桌面包白名单仍不打入这些 iOS 源文件。 |
| `scripts/bundle-bridge.cjs` | 允许独立输出目录；iOS 使用 node18 目标和独立构建插件，桌面保持原目标。 | 同一协议源码生成适配不同运行时的产物，不维护第二份 worker。 |
| `scripts/ios-bridge-plugin.cjs` | 仅 iOS 注入暂存目录中的 Web API 兼容入口，并将上游 UTF-8 有效性谓词替换为等价的 Node 内置检查。 | 暂存目录已有锁定依赖，干净 CI 不依赖本机 node_modules；仍不修改协议实现，上游片段变化时明确失败。 |
| `scripts/format.cjs` | 将自维护 .cmake 文件纳入原有格式检查。 | 新的 Qt/IOS.cmake 也需要执行规范检查，不扩大忽略范围。 |
| `scripts/test.cjs` | 默认只运行核心业务、iOS 传输/证书门控及最终包检查；移出三组发布/安装器脚本测试。 | 减少默认入口中的非核心用例；原发布检查保留在 publish.yml 的预检步骤。 |
| `vendor/nodejs-mobile/source.json` | 记录 NodeMobile 18.20.4 来源、下载地址、SHA-256 和许可证路径。 | 固定运行时来源，二进制只落在 output。 |
| `vendor/ffmpeg/source.json` | 记录模拟器 FFmpeg 9.0.1 的来源和 SHA-256。 | 保证模拟器补充库可复现，并保留来源信息。 |
| `licenses/nodejs-mobile/LICENSE` | 原样保留 NodeMobile 发行许可证。 | 随包交付依赖的原始法律归属。 |
| `licenses/FFmpeg/COPYING.LGPLv2.1` | 原样保留 FFmpeg LGPL 许可证。 | 随包交付模拟器依赖的原始法律归属。 |
| `README.md` | 只新增 iOS 构建、禁用能力、系统证书信任和验证边界说明。 | 对外仅保留使用说明；详细维护记录保存在本地本文。 |

### 原生适配和公共接入

| 文件 | 改了什么 | 为什么要改 |
| --- | --- | --- |
| `Qt/src/BridgeProcess.h` | 桌面直接别名 QProcess；iOS 声明 Host 所需的进程式接口。 | Qt 的 iOS 平台不支持启动桌面 Node 子进程；保持 Host 调用方式和请求语义。 |
| `Qt/src/BridgeProcessIOS.cpp` | 在独立线程启动一次 NodeMobile，通过带随机令牌的回环通道控制 Worker，并转交系统信任请求。 | iOS 使用进程内运行时；每次注销或切换会话销毁 Worker，继续复用 Host 的请求代数隔离。 |
| `Qt/src/PlatformFeatures.h` | 统一声明四项平台能力。 | 业务层查询能力，而不是四处扩展平台条件编译或另写业务实现。 |
| `Qt/src/PlatformIOS.mm` | 实现 iOS 钥匙串、系统音频会话、媒体中心及中断/路由变化处理。 | 使用 iOS 原生能力，不能复用依赖 AppKit 的 macOS 适配。没有新增音频解码或播放状态机。 |
| `Qt/src/IOSServerTrust.h` | 声明异步系统服务端证书校验接口。 | 把 Node 通信与 Apple Security 实现隔离。 |
| `Qt/src/IOSServerTrust.mm` | 后台调用 Apple SSL 策略和 SecTrustEvaluateWithError，沿用系统及用户信任库。 | 允许系统已明确信任的代理根证书，同时验证域名、证书链和有效期；不添加任意锚点。 |
| `Qt/src/IOSWindow.h` | 声明 iOS 窗口配置入口。 | main 只保留一个平台调用，不承载原生窗口细节。 |
| `Qt/src/IOSWindow.mm` | 设置横屏、全屏，并在应用进入后台时释放可重建的图形资源。 | iOS 按应用生命周期管理窗口，音频和账号仍交给公共业务层。 |
| `Qt/src/Host.h` | 使用 BridgeProcess 类型并引入平台能力声明。 | 同一个 Host 可以连接桌面进程或 iOS Worker。 |
| `Qt/src/Host.cpp` | 信号和状态引用改为 BridgeProcess；只分开启动参数；能力检查拦截官方播放并固定 iOS 面板音量。 | 请求合并、缓存、账号隔离、Cookie、封面和音频调用继续共用，平台差异只限运行时边界。 |
| `Qt/src/Platform.cpp` | 排除 iOS 的空媒体控制回退实现。 | iOS 使用 PlatformIOS.mm 的真实系统接口，避免重复符号。 |
| `Qt/src/ProcessMetrics.cpp` | macOS 专属宏改为涵盖 Darwin 平台，继续共用 Mach 指标读取。 | 同一套系统 API 可用于 iOS，无须复制指标代码。 |
| `Qt/src/AppUpdater.cpp` | 为 iOS 返回独立的 IPA 资产后缀。 | 平台识别不能把 iOS 当作 macOS 或返回其他系统安装包。 |
| `Qt/src/main.cpp` | 增加 iOS 资源目录候选，并在 iOS 调用独立窗口配置函数。 | 保持公共启动顺序，资源发现和窗口配置仅增加必要接入点。 |
| `Qt/src/Engine.cpp` | 读帧字段改为不插入字段的 value 读取，并在现有 selfTest 中加入首帧回归。 | 启动时非 const JSON 下标读取会把空帧变成非空帧，导致渲染器读取空矩阵；这是共用根因修复。 |
| `Qt/src/RhiScene.cpp` | 渲染前检查相机矩阵是否就绪；Darwin 平台共用 Metal 离屏入口。 | 阻止首帧空矩阵崩溃，同时让 iOS 使用已有 Metal 渲染实现。 |
| `Qt/src/OpticalScene.cpp` | 使用相同的相机就绪检查，未就绪只清空目标。 | 增强渲染管线也必须遵守同一首帧边界，不复制整套渲染器。 |

### UI、能力限制与 Node 适配

| 文件 | 改了什么 | 为什么要改 |
| --- | --- | --- |
| `Qt/qml/IOSInput.qml` | 把触屏纵向拖动转换为现有 wheelInput。 | 复用原滚动状态机，不再实现一套 iOS 列表交互逻辑。 |
| `Qt/qml/LocalMusicDialogs.qml` | 将原来的文件/文件夹选择器及信号连接整体移到共享组件。 | 桌面仍使用原交互；iOS 不实例化不需要的本地音乐对话框。 |
| `Qt/qml/Main.qml` | 按平台加载组件；iOS 放开桌面最小窗口限制，轻触在点击完成时触发动作，并移除音量输入区。 | 适配触屏拖动与全屏尺寸，保留一个主界面。 |
| `Qt/src/MusicAccount.cpp` | 通过能力开关拒绝切换到本地来源。 | 即使从动作字符串进入，也不能绕过 iOS 限制。登录和换账号逻辑不分叉。 |
| `Qt/src/MusicLibrary.cpp` | iOS 恢复本地来源时回退网易云，本地库使用离线实例，并拦截官方客户端播放。 | 不读取或维护 iOS 本地音乐索引，不建立第二套资料库。 |
| `Qt/src/MusicPlayer.cpp` | 不支持应用音量的平台把面板增益固定为 1。 | 使用系统音量，避免继承桌面保存的低音量偏好；播放核心仍为同一份。 |
| `Qt/src/NativeHudController.cpp` | 入口处统一拦截被平台禁用的动作。 | UI 隐藏之外也保证动作分发边界一致，不改变正常桌面动作顺序。 |
| `Qt/src/NativeHudPlayer.cpp` | 根据能力隐藏音量区和官方客户端按钮。 | 不显示 iOS 无法使用的入口，其他播放条实现不分叉。 |
| `Qt/src/NativeHudDetail.cpp` | 根据能力调整播放方式文字及官方客户端入口。 | 详情页面和播放条使用一致的平台能力。 |
| `Qt/src/NativeHudModal.cpp` | 根据能力过滤本地来源、官方客户端设置和桌面窗口设置。 | 从现有页面数据中删除不可用项，不维护 iOS 专用设置页。 |
| `MusicBridge/ios-runtime.cjs` | 新增 Node 控制入口，串行管理 Worker、标准输入输出及系统信任消息。 | 只承担运行时传输；不含音乐路由、登录、歌单或播放业务。 |
| `MusicBridge/ios-web-apis.cjs` | 在上游加载前补齐 fetch、Headers、Response、FormData 和 Web Crypto，并接入系统信任。 | 解决无 WebAssembly 的 fetch、QQ 多 Cookie 读取和首次创建设备随机数问题；只在 iOS bundle 注入。 |
| `MusicBridge/ios-system-trust.cjs` | 让 HTTPS Agent 私有持有 TLS 握手连接，先请求 Apple 校验，通过后才交付 Socket。 | iOS 用户根证书不在 Node 固定根库中；兼容 HTTPS 和 WSS，验证前不得发送登录等应用数据。 |

### 回归

| 文件 | 改了什么 | 为什么要改 |
| --- | --- | --- |
| `Qt/tests/release-version.cjs` | 原版本和更新清单测试复用平台清单，验证四平台资产。 | 检查 IPA 不会漏出正式分发；仅在发布预检运行，不重复进入默认测试。 |
| `Qt/tests/publish-release.cjs` | 原发布测试增加 IPA 夹具，校验五项资产（四个平台包及 update.json）。 | 沿用现有模拟 API 验证发布原子性，不新增另一套发布测试。 |
| `Qt/tests/IOSBridgeChecks.cpp` | 在 iOS 现有 self-test 中通过真实 NodeMobile 加载真实协议包，执行离线请求和会话重建。 | 桌面 Node 测试不能证明 iOS 的运行时可加载。 |
| `Qt/tests/NativeHostChecks.cpp` | 仅 iOS 调用上述测试，并验证被禁用的官方播放和面板音量边界。 | 接入已有核心测试，不为平台复制完整 Host 测试。 |
| `Qt/tests/ios-bridge.cjs` | 只验证认证传输、一次离线请求及两次会话的退出/启动顺序；macOS 下执行 TLS 门控核心检查。 | 移除重复的网易云/QQ/酷狗搜索与登录用例及专用 HTTP 夹具。三家业务只由既有公共测试验证一次。 |
| `Qt/tests/ios-system-trust.cjs` | 用一个临时 TLS 服务验证批准前不发数据、拒绝、域名错误及验证器失效；简化异步等待并使用兼容 OpenSSL/LibreSSL 的配置文件。 | 保留必要的安全行为回归，不给其他平台增加 OpenSSL 要求，不重复建立业务测试。 |

## 日后修改该去哪里

- 播放、队列、账号、歌单及搜索：继续修改原公共业务文件和 MusicBridge 调用层，两端一起生效。
- 新增 UI 功能：修改原 Main / NativeHud；只有功能本身存在平台差异时才增加明确的能力字段。
- 改音乐协议或升级依赖：只改锁定的公共来源和公共调用层；同时检查 iOS 构建插件的兼容片段。
- 新增 Node/Web API：先在实际 NodeMobile 验证；只把缺失的运行时 API 放到 ios-web-apis，不能把业务搬进来。
- 系统音频、锁屏及钥匙串：只改 PlatformIOS；不要复制 AudioPlayer 或 MusicPlayer。
- 触屏和横屏窗口：只改 IOSInput / IOSWindow / InfoIOS；不要派生第二个 Main.qml。
- 代理证书：维护 IOSServerTrust 和 ios-system-trust。不要设置 NODE_TLS_REJECT_UNAUTHORIZED=0，也不要绕过 Apple 的验证结果。

## 构建与打包注意点

```sh
npm run build
npm test
npm run build:ios
# 按需验证模拟器，构建必须串行执行：
npm run build:ios:simulator
PYTHON=.venv/bin/python npm run format:check
npm run lint
```

Qt 使用 6.12.0；iOS 设备和模拟器使用各自的 kit。最终未签名文件为
`output/RhineMusicDatabase-ios-unsigned.ipa`，用户自行对应用及内嵌框架签名安装。
`output/qt-build`、`output/ios-device-build`、`output/ios-simulator-build` 相互独立。
共同的资源准备步骤会写入 output/resources，因此不要并行执行构建、部署或包测试。

资源使用 `RhineAssets/`。不要在 .app 根目录新建 `resources` 目录：Apple CFBundle 会误判旧式布局，
即使根目录 Info.plist 写了正确 ID，也可能报 Missing bundle ID。
不要手工修改打包 worker 或 Xcode 生成文件来交付修复；必须回到公共源码或 iOS 适配源码重建。
NodeMobile、FFmpeg 和 Qt 二进制、下载缓存、账号数据和截图均不进入 Git。

## 系统证书信任的边界

原音乐请求仍使用同一个 Node HTTP / HTTPS / WebSocket 协议实现，没有替换音乐平台 API。
仅 iOS 的 HTTPS Agent 将握手后尚未交付的 Socket 隔离起来，取得证书链，调用 Apple 系统 SSL 验证；
通过后才把 Socket 交给 HTTP 或 WSS 请求。验证失败或超时不允许发送应用数据。
显式 CA 和额外身份约束继续保留，不缓存或导出用户根证书，不把临时测试 CA 随包发布。

手动安装的代理根证书需在 iOS“设置 → 通用 → 关于本机 → 证书信任设置”开启完全信任。
参考：https://support.apple.com/zh-cn/102390
Apple API：https://developer.apple.com/documentation/security/sectrustevaluatewitherror(_:_:)

