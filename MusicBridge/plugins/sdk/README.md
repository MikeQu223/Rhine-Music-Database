# Rhine Plugin SDK（P0）

这是平台插件的契约层，不是运行时实现。P0 只冻结接口和数据形状，不改变现有 bridge 行为。

主仓库只保留通用契约；平台特定的 descriptor、fixture 和检查配置放在本地 `docs/PLUGIN/`（已 gitignore），不进入主仓库。

## 文件

| 文件                           | 作用                                         |
| ------------------------------ | -------------------------------------------- |
| `port.d.ts`                    | `MusicProvider` Port、Host API、插件模块导出 |
| `registry.d.ts`                | Registry 契约、Provider 状态、生命周期       |
| `manifest.schema.json`         | 插件 manifest v1                             |
| `descriptor.schema.json`       | 供 Qt 渲染的 descriptor v1                   |
| `models.schema.json`           | 统一数据模型 schema                          |
| `models.cjs`                   | 轻量运行时校验器（无外部依赖）               |
| `fixtures/fixture.schema.json` | fixture 格式 schema                          |

## 版本

- `schemaVersion`：manifest/descriptor 结构版本，当前 `1`。
- `apiVersion`：插件 API 语义版本，当前 `"1.0"`。
- `requiresHost`：插件要求的最低 host 版本（semver range）。
- 同一 major 内只加字段；旧 host 忽略未知字段，新 host 不得改变已知字段语义。

## 边界

- 插件不得直接写 stdout/stderr；日志走 `host.log`。
- 插件不得读取其他 provider 的凭据；`host.credentials` 只返回当前插件切片。
- 插件不得把原始路由暴露给 Qt；Qt 只调用统一 operation。
- core 不得包含平台协议、上游包、平台专属资产/文案。
- 主仓库新增文件不得出现第三方平台名称；平台特定内容只放 `docs/PLUGIN/` 或独立插件仓库。

## P0 状态

- 契约与 schema：已建立。
- 平台基线：在 `docs/PLUGIN/` 本地维护，`check-descriptor-parity.cjs` 只在该目录下运行。
- 通用检查：`npm run check:core-boundary`、`npm run check:plugin-contracts`；缺少本地基线时安全退出。
- fixture：格式已建立；完整覆盖在 P0 剩余工作/P1 补齐。
