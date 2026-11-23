# Ledger

「安装时记账、卸载时对账」的本地知情工具（macOS 菜单栏应用，原生 SwiftUI）。规范先行：所有标准文件在 docs/，工作规则见下。

## 标准文件索引

| 文件 | 内容 |
|---|---|
| [docs/01-requirements.md](docs/01-requirements.md) | 实现规格（§0–§19 规范性要求，验收对照 §16） |
| [docs/02-architecture.md](docs/02-architecture.md) | 技术架构（模块、线程、数据流、构建链） |
| [docs/03-design.md](docs/03-design.md) | UI 设计规范（布局、判定展示、勾选规则、文案） |
| [docs/04-workflow.md](docs/04-workflow.md) | 开发流程与工程规范（阶段门禁、git、devlog、验证） |
| [devlog/](devlog/) | 每日开发日志 `YYYY-MM-DD.md`（## 完成 / ## 待办） |
| [scripts/](scripts/) | 构建与验证脚本（build-app.sh、smoke-db.sh） |

## 工作规则

1. 与用户交流、汇报、文档一律**中文**。
2. 每次会话开始读当天 devlog，会话结束前更新当天 devlog（完成 / 待办两节）。
3. 按 docs/04-workflow.md 的阶段门禁推进：自检 → 汇报 → 确认 → 提交；**小步推进，一次不做超出当前阶段的事**。
4. git 提交：中文 + 类型前缀（feat/fix/docs/chore/refactor/test），结尾带 `Co-Authored-By: Claude Code <noreply@anthropic.com>` 署名行；自检通过才提交。
5. 规格未覆盖处按 §0 做最小合理推断并记入 devlog；「必须/禁止」条款不可放宽。
6. 铁律：记账先于清理、知情先于行动、本机先于一切；零联网、观察模式零写入、删除动作唯一 = 移入废纸篓。

## 常用命令

- 构建：`./scripts/build-app.sh`（内部用 `DEVELOPER_DIR` 指向 Xcode 26.3，不修改系统 xcode-select）
- 数据库冒烟：`scripts/smoke-db.sh`
- 运行：`open build/Ledger.app`

## 环境

- Xcode 26.3 已装（/Applications/Xcode.app）；Swift 5.9+/SwiftUI，macOS 14+。
- 无第三方依赖（仅系统框架 + 系统 SQLite3）。
