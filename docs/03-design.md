# Ledger · UI 设计规范

> 依据 docs/01-requirements.md §14（GUI 规格）与 §10（判定规则）制定。实现 UI 时以此为准。

## 1. 布局

### 菜单栏
- 图标：SF Symbol `book.closed`（模板图，随明暗模式）；待处理残留时叠加红点（M4）。
- 左键：打开主窗口；右键菜单：打开 Ledger / 暂停记录（M7）/ 退出。
- 工具提示：Ledger。

### 主窗口（940×620，最小 780×520）
四个 Tab：概览 / 待处理 / 周报 / 设置。

- **概览**：三张指标卡（已记录 App 数 / 未知项数 / 今日新增字节）+ App 列表（名称、图标、足迹大小、状态徽标：正常 / 已卸载 / 安装未完成 / 签名警告）；点击行 → 详情。
- **待处理**：vanished、broken 的 App 按残留大小降序；行 = 名称 + 残留项数 + 注册项数 + 总大小；点击 → 残留清单 Sheet。
- **周报**：主图堆叠柱状图（X=周一至周日，Y=新增字节，堆叠=App）；副图按 category 堆叠；抬头 = 本周新增总量 / 新装 App 数 / 未知项数 / Top5；按钮导出 Markdown。
- **设置**：扫描根勾选；权限状态（FDA 已授权 / 未授权 / 盲区数）；保留策略（30 天 / 500MB）；通知开关；暂停开关。

### 残留清单（Sheet）
- 行：路径 / 类型 / 大小 / verdict / requires_admin / evidence / 展开解释（knowledge.json）。
- 底部：已选 N 项共 X MB + 「移入废纸篓」。
- 需管理员项单独分区：§13 命令 + 「复制命令」按钮，不可勾选、不可代执行。
- 确认对话框文案：「将把 N 项移入废纸篓，共 X MB，可从废纸篓恢复。系统项不会删除，只给出处理方式。」

## 2. 判定与勾选规则（必须严格遵守 §10）

- **verdict（安全性）与 requires_admin（权限）分开两列展示**，禁止合并成一个「危险度」。
- **evidence 三值徽标**：fact = 「确证」/ inference = 「推断」/ unknown = 「未知」。
- 默认勾选：fact + safe。
- 手动可选：fact + caution。
- 永不可勾选：dont_touch、unknown、requires_admin=1（置灰 + 说明原因）。
- **inference 项永不默认勾选**（即使 safe）。
- 已变化项默认不勾选，并提示「可能不是原来那个」。
- 每项提供「为什么这么判」的本地解释（knowledge.json，命中失败显示「未收录 / 暂无解释」，禁止猜测）。

## 3. 报告页

- 三节：删了什么 / 留了什么 / 怎么恢复。
- 导出路径：`~/Library/Application Support/com.ledger.app/reports/uninstall-<bundle-id>-<date>.md`；周报 `weekly-<date>.md`。

## 4. 通知

- UserNotifications 授权缺失 → 仅菜单栏红点，不反复请求；设置页提供授权入口。

## 5. 文案与语气

- 全中文；不恐吓、不夸大；**禁止**「一键清理 XX GB」类文案。
- 每条可执行提示必须能回答「为什么」；盲区显式标注，不假装完整。
- 「新增字节」统一定义：`Σ(created.size) + Σ(max(0, modified.size_delta))`；removed 只作副指标；moved 不计字节。

## 6. 视觉基线

- 使用系统标准控件与材质（SF Symbols、系统色）；支持浅色/深色模式。
- 空状态用 `ContentUnavailableView` 诚实说明「为什么没有数据」。
- 状态徽标配色：正常=系统绿、已卸载=系统橙、安装未完成/签名警告=系统黄。
