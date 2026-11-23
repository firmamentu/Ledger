# Ledger · 技术架构

> 本文是 docs/01-requirements.md 的技术落地方案。已实现部分标注「已落地（M1）」，其余为规划。改动此文件需同步更新代码或 devlog。

## 1. 概览

Ledger 是「安装时记账、卸载时对账」的本地知情工具：原生 Swift 5.9+/SwiftUI，macOS 14+，仅本机工作，默认零联网，无第三方依赖（仅系统框架 + 系统 SQLite3）。

## 2. 运行形态

- 单一可执行文件打包为 `Ledger.app`（`LSUIElement`，菜单栏常驻，无 Dock 图标、无启动窗口）。
- 启动序列：单实例 flock 锁 → 初始化本地账本 → 安装菜单栏图标 → 点击打开 SwiftUI 窗口。
- 窗口由 AppKit `NSWindow` + `NSHostingController` 承载 SwiftUI `RootView`；关闭窗口不退出应用。
- 登录自启 LaunchAgent 待接入（设置页管理，开发构建不自动写入）。

## 3. 模块划分

| 模块 | 职责 | 状态 |
|---|---|---|
| `AppPaths` | bundleID 单一真源（读 Info.plist）、数据目录/锁文件路径 | 已落地（M1） |
| `Database` | SQLite 连接（WAL、`user_version=1`、NSLock 串行化）、§8 七张表、迁移 | 已落地（M1） |
| `AppDelegate` | 单实例锁、菜单栏、窗口生命周期 | 已落地（M1） |
| `IndexStore` | 扫描根内存索引 `Map<path, {size, mtime, inode}>`，dirty 增量 60s 落盘 | 已落地（M2） |
| `ScanService` | 子进程 `/usr/bin/find` 扫描（15s 无输出超时保护）+ 定时落盘 + 唤醒对账 | 已落地（M2） |
| `FileMonitor` | FSEvents（`kFSEventStreamCreateFlagFileEvents`，latency 0.5s）；额外监听 `~/.Trash`（仅卸载判定，非扫描根）；`last_fsevent_id` 持久化 | 已落地（M2） |
| `InstallContext`（M3） | 新装判定 + §5.3 记账时序（30s 稳定、结构/签名校验、manifest 落库） | 规划 |
| `Reconciler`（M4） | 启动/唤醒对账（§5.4 目录级事件重放）、卸载判定（§5.5） | 规划 |
| `VerdictService`（M5） | verdict / requires_admin / evidence 判定（§10）+ `knowledge.json` 解释匹配 | 规划 |
| `TrashService`（M5） | 移入废纸篓（唯一删除动作，逐项校验） | 规划 |
| `WeeklyReport`（M6） | changes 聚合 + 周报柱状图数据 | 规划 |
| UI | `RootView` 四 Tab + 残留清单 Sheet | 骨架已落地（M1） |

## 4. 线程模型

- 主线程：UI + AppKit 生命周期 + `Database` 调用（NSLock 保护）。
- `com.ledger.app.scan` 串行队列：全量扫描、目录重扫、60s 落盘；扫描本体跑在子进程 `/usr/bin/find`（本机存在 readdir 永久阻塞的目录，子进程 + 超时才可杀死）。
- `com.ledger.app.events` 串行队列：FSEvents 回调（FileEvents）→ 文件级 upsert / 目录级交扫描队列重扫。
- `Database` 是进程内唯一 SQLite 连接；单实例锁保证全系统只有一个 Ledger 进程。

## 4.1 扫描防御（环境实测）

- `com.apple.*` 目录整树跳过（系统目录非 App 残留；`com.apple.CloudPhotosConfiguration` readdir 永久阻塞）。
- 多个 Group Containers 目录 readdir 永久阻塞（微信/钉钉/OneDrive 等）：find 子进程 15s 无输出即终止，该根记盲区「不完整」。

## 5. 数据流（安装 → 卸载 → 清理）

```
FSEvents 事件（/Applications, ~/Applications）
  → InstallContext（30s 稳定判定）
  → 结构/签名校验（失败=broken，manifest status=partial）
  → manifest_items（三集合并去重，§5.3.6）+ 注册项差分
  → 落库（apps/manifests/manifest_items/app_events）
追踪期：FSEvents → changes（created/modified/removed/moved）
卸载：.app 消失 → ~/.Trash 判定（§5.5）→ 状态 vanished → 待处理
核对：四组判定（§10.4）→ 用户勾选 → TrashService 移废纸篓 → reports 落库
```

## 6. 持久化

- SQLite 单文件 `~/Library/Application Support/com.ledger.app/ledger.sqlite`，WAL、`synchronous=NORMAL`、busy_timeout 5s。
- 内存索引落盘到 `index_entries` 表（§8 未覆盖的内部表，见 devlog 推断）；`meta.last_fsevent_id` 用于重启对账；`meta.baseline_blind_spots` 存基线盲区 JSON。
- 崩溃安全：flock 由内核在进程退出时释放；SQLite 事务保证迁移与批量写原子性。

## 7. 构建链

- SwiftPM 工程（`Package.swift`，tools 5.9）+ **Xcode 26.3 工具链**（脚本内 `DEVELOPER_DIR` 指向 `/Applications/Xcode.app/Contents/Developer`，不修改系统 `xcode-select`）。
- `scripts/build-app.sh`：`swift build -c release` → 组装 `.app`（Info.plist + Resources）→ ad-hoc 签名。
- `scripts/smoke-db.sh`：数据库冒烟测试（schema、`user_version`、迁移幂等）。

## 8. 安全与隐私

- 观察模式零写入；删除模式唯一动作 = `FileManager.trashItem`。
- 无任何网络请求；数据只存本机目录；不加密（依赖 FileVault）。
- 权限被拒 → 盲区显式标注（`blind_spots`），禁止反复弹窗。

## 9. 状态机

discovered → installing → recorded → tracked → vanished → verified → settled；
broken / 恢复（同路径）/ 重装（异路径）/ 重新安装分支见 requirements §7。
