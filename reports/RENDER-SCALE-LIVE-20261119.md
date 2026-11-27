# 渲染分辨率 / AA 设置「当场生效」修复（2026-11-19）

用户问题：设置里的「渲染分辨率」百分比是否真的生效？保存是否对、3D 层是否按百分比处理？

## 结论

| 环节 | 结论 | 证据 |
| --- | --- | --- |
| 选项与落盘 | 正确 | `lib/hud/modals/settings_modal.dart:2897-2911`（steps 50/60/75/90/100）、`lib/basic/basic_settings_store.dart:286`（`panel/` 前缀）、`lib/basic/basic_settings_runtime.dart:148`（缺省 75）、设备实读 `panel/render-scale=75` |
| 下发到 Qt | 正确 | `lib/basic/basic_app.dart:1140` → `lib/basic/qt_scene_view.dart:63` → `Qt/src/EmbeddedSceneHost.cpp:545` `writeNextLaunch` → `Qt/src/Host.cpp:1115` |
| 3D 层按百分比渲染 | 正确 | `Qt/src/render/ScenePostProcess.cpp:63-86`（`factor = supersample × percent/100 × aaScale / fsrDivisor`）、`Qt/src/RhiScene.cpp:1301` 内部目标尺寸、`:1361-1370` 附件全按该尺寸建、`:3130` 几何视口=缩小尺寸、`:3353` 最终合成回全尺寸并用 linear 放大 |
| **生效时机** | **原为 bug，已修** | 见下 |

75% 时 3D 光栅化在 2160×1350，再线性放大回 2880×1800；100% 才是全尺寸。因此这条路是真正降低每帧像素量的杠杆（240Hz 方向可用）。

## 原 bug

- 全仓唯一把偏好翻成环境变量的地方是 `Qt/src/main.cpp:802-812` 的 `applyRenderScaleSetting()`，它只在 **`main()`**（`Qt/src/main.cpp:927`）里调用，**一个进程一次**。
- Android 内嵌路径的 Qt 运行时跨 Activity 常驻（`Qt/src/main.cpp:1073-1086` `setQuitOnLastWindowClosed(false)`；实测 Back 后 pid 不变、重开同 pid），所以「下次启动」**不会**重跑 `main()`。
- `Qt/src/EmbeddedSceneHost.cpp` 设置块只写偏好，没有 `qputenv`；桌面路径 `Qt/src/NativeHudController.cpp:805/823/830-841` 则是选完立刻 `qputenv`。
- 结果：渲染分辨率、AA 模式/倍率、MSAA、超采样四项在 Android 上改完**永不生效**，`lib/basic/basic_app.dart` 里「下次启动生效」的提示与实际不符（该项描述符本身没有 restartHint，UI 也从未把它标成待重启）。

## 修复（commit b0503af，feat/flutter，默认身份 subject-only）

`Qt/src/EmbeddedSceneHost.cpp` 设置块在写偏好后追加即时应用，语义与桌面端逐条对齐：

- `render-scale` → `RHINE_RENDER_SCALE`，clamp 50..100
- `aa-scale` → `RHINE_AA_SCALE`，clamp 100..200
- `aa-mode` → `RHINE_AA_MODE`，仅接受 `off/fxaa/ssaa/msaa/taa`（FSR 按用户 m03406 暂缓）
- `msaa` → `RHINE_MSAA`，仅 2/4/8
- `supersample` → `RHINE_SUPERSAMPLE`，>1 时取 min(v,2)，否则 `qunsetenv`

`graphics-backend` / `vsync` 保持「下次进程启动」（本来就要重建窗口/呈现链）。
`lib/basic/basic_app.dart` 同步改注释（说明这四项是当场生效、只有后端与垂直同步要重启）。

渲染器每帧在 `RhiScene::render` 里调 `resize(dimensions, …)`（`Qt/src/RhiScene.cpp:3449`），早退比较含 size/sampleCount/AA 模式，所以环境变量一变就在下一帧重建目标，不需要重启。

## 构建

- 原生：部署树 `.agents/parity-20261109/builds/FLUTTER-ONLY-ANDROID-20261117/qt-native/Qt` 里 `make -j8` exit 0，0 error；`libRhineMusicDatabase_arm64-v8a.so` 137909232 B / SHA `bcbadb8918b3d0bbcafe8bfd17660691a071427d5db497d080722c81ad28421a`（旧 `a2560662dc0e07f25c2beb46a6fef9aeac03fd97531f70db4d6661be3bc0a0f6`），已拷进 `android-build/libs/arm64-v8a/`。
- APK：`build/app/outputs/flutter-apk/app-debug.apk` 219498710 B / SHA `f20da3f1482444f212b88cccee477b41b175b43f84e6a07ea76fc42d90311183`（revert 后基线 `be38551b…`），日志 `.agents/parity-20261109/builds/RENDER-SCALE-LIVE-20261119/logs/build.log`。

## 设备验证（2026-11-18 19:26–19:35，设备 526f6b6d，PID 24611 全程未变）

安装本次构建（APK 2195?? B / SHA `339c536c14a97dd7c167d1180428df50f2fb63366d978a7e2855edd61e237dad`，冷启 TotalTime 3754ms），然后在设置里把「渲染分辨率」从 75% 连点两次减到 50%，再点回 75%，全程同一个 pid：

```
19:26:04.124 24611 RHINE_QT_SCENE_SETTINGS ... scale=75 ... live(scale=75 aa=off msaa= ss=)
19:28:38.969 24611 RHINE_QT_SCENE_SETTINGS ... scale=60 ... live(scale=60 aa=off msaa= ss=)
19:28:39.868 24611 RHINE_QT_SCENE_SETTINGS ... scale=50 ... live(scale=50 aa=off msaa= ss=)
19:32:59.943 24611 RHINE_QT_SCENE_SETTINGS ... scale=60 ... live(scale=60 aa=off msaa= ss=)
19:33:00.893 24611 RHINE_QT_SCENE_SETTINGS ... scale=75 ... live(scale=75 aa=off msaa= ss=)
```

`live(...)` 是从进程环境里读回来的值，改一次跟着变一次、进程号不变 ⇒ **改动当场落到渲染器读的那个环境变量**，不是等下次启动。同时 `files/settings/RhineMusicDatabase/rhine.music.database.conf` 里 `render-scale` 依次变成 60/50/60/75，落盘也对。修复前这条 `live(scale=…)` 会一直停在启动时的 75。

`RHINE_QT_SCENE_SETTINGS` 这行新增了 `live(scale= aa= msaa= ss=)` 四个字段（本次第二个提交），现场可直接用它确认有没有生效。

### 未完成：50% 对 GPU 停顿的量化对比

19:31/19:34 抓的 `rs50.pf`（SHA `30cb1dd02db55442db8fea2622280567673eee8e493b7643ebd2ac0ddeb003b2`）/`rs75.pf`（SHA `965b5f6108da94946bbba7daf11a007c3743bcf593b167f07864b5529b8b173f`）里 `draw-VRI[MainActivity]` = 0 帧、GPU 等待 max 8.0ms —— 两次 trace 其实都停在设置面板上（静态画面不产帧），只能当「设置面板打开时 Qt 不画」的旁证，**不能**用来比较 50% 与 75% 的卡顿。要比就得在资料库页面（3D 持续出帧）用同一套轻扫脚本各抓一次。

## 竖屏并行线（已完成，未合并）

`feat/portrait-fix` 的 `4cbf373`（竖屏曲目列窗口上沿 219 修正为 1080−219=861，竖屏可见行 1→4）已由子代理交付，报告在 `.agents/parity-20261109/worktrees/PORTRAIT-FIX-20261119/reports/PORTRAIT-FIX-20261119.md`，横屏回归 mean diff 0.103、受影响测试 33 passed。是否合入 `feat/flutter` 待用户决定。
