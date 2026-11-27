---
id: "1be61c52-ccb0-4c43-a9ec-6bc51799eca5"
title: "Rhine 仓库 .agents 控制面归档（2026-11-19 删除）"
description: "Qt→Flutter 迁移期本机控制面目录的归档去向、残留材料重放方法与关键技术结论索引；需要找回实验分支、未提交补丁或设备实测数字时读这份。"
status: "active"
created_at: "2026-11-19T02:44:56.268Z"
updated_at: "2026-11-19T03:05:45.859Z"
content_hash: "2f7d93de6b341745088dc5abf92b0fe851600b35b6abe5a4ff63f89512c3504b"
source_paths:
  - "docs/flutter-migration/archive/2026-11-19-control-plane.md"
  - "docs/flutter-migration/archive/qt-flutter-state-2026-11-19.md"
  - "docs/flutter-migration/archive/worktree-salvage-2026-11-19.tar.gz"
session_ids:
  - "session-2472cab8-1e5b-4461-a75d-ddd9c2c315d0"
memory_body_ids:
  []
---

# .agents 控制面归档（2026-11-19）

## 事实
- `.agents/` 是 2026-11-08 → 11-19 期间本机私有的控制面目录，约 66 GB：227 个 git worktree（52 个早期 `worktrees/` + 151 个 `parity-20261109/worktrees/`）、1128 份控制面报告、525 份 `control/*.json`、443 份日志、20 GB 构建产物、1.4 GB 隔离 toolchain、172 份 `final-reports/`。
- 仓库从未跟踪它：`.gitignore` 曾以 `/.agents/` 整目录忽略（第 17 行）。2026-11-19 删除后该行已移除。
- 删除时 feat/flutter tip = 「播放条补上封面字段，插件页不再与歌词页重叠」（`v0.3.1-874`）；该 commit 的 hash 当天被 filter-branch 反复改写（`65af97b`→`061300a`→`4beb444`），定位提交要按 subject，不要按 hash。252 个本地分支保留。

## 归档去哪了
- `docs/flutter-migration/archive/2026-11-19-control-plane.md`：目录原貌、时间线、规划期不变式与数值契约、残留材料清单、删除后仍残留的历史引用索引、开放问题。
- `docs/flutter-migration/archive/qt-flutter-state-2026-11-19.md`：架构现状、设备实测数字表、缺陷根因、构建与取证流程。
- `docs/flutter-migration/archive/worktree-salvage-2026-11-19.tar.gz`：23 个带非 generated 改动的工作树补丁（合计 762,824 B）+ 104 个未跟踪文本文件，含 MANIFEST。重放：`git apply -p1`，须在表中记录的基线 HEAD 上。

## 迁移时不变量（仍有效）
- Flutter 是业务唯一权威（Siren 曲库/播放/账号/设置），Qt 是 3D 场景渲染与拾取权威；禁第二个 audio backend、禁第二个场景视图。
- Qt 协议四元组 `commands` / `hits` / `state` / `frame`：命中矩形与绘制同源，控件树无法复刻。
- 横屏 1:1 有 Qt 基准（`stageScale = height/1080`）；竖屏在 Qt 中不存在，是新增重排，不得声称 1:1。
- 证据分级 E0 设备 / E1 源码 / E2 产物 / E3 推断；E3 不得当验收依据。

## 设备与后端结论
- Impeller 必须关闭（`android/app/src/main/AndroidManifest.xml` `EnableImpeller=false`），走 Skia(OpenGL)。原因：Impeller/Vulkan 在本机 Adreno 730 上 ImageReader `maxImages=3` 被击穿 → `ErrorDeviceLost` → SIGSEGV。
- 瓶颈是 Qt 帧产出与 GPU fence 饥饿（Qt 单帧 460 ms、GPU busy 99.9%），不是 HUD 分层/节流常量：HUD 双纹理、帧在途 cap=1、HUD 预算 8→4 ms 三次实测均零收益，其中 cap=1 已 revert。
- 列表惯性按 Qt 摩擦+吸附口径实现（`3f6d133`）；渲染倍率/AA 必须当场生效（`fa2d671`）；启动页按舞台尺寸布局（`2250e6b`）。

## 未解决问题
- Qt 宿主生命周期泄漏（JNI global 持 MainActivity）是唯一 FAIL 收口项。
- 竖屏 SIGSEGV 仅止血，`maxImages=5–6` 未验证；第 4 次重开 SIGABRT、null-SurfaceFrame 崩溃未定位。
- Qt 嵌入路径的 render-only 闸门未收口（`Qt/src/main.cpp:1055-1059` 早于 `:1066`）。
