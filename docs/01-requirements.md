# Ledger · 实现规格（规范源）

> 本规格完整定义了要构建的软件，是**规范性要求**的单一来源。所有小节均为规范性要求；“必须”= 不满足即验收失败；“禁止”= 出现即验收失败。实现时若发现本规格未覆盖的细节，一律按第 0 节的原则做最小合理推断，并把推断记入 devlog。

## 0. 本质

Ledger 是“安装时记账、卸载时对账”的本地知情工具。它在 App 落盘那一刻记下它留下了什么；App 消失后把账本摊开——还剩什么、每一样是什么、能不能动。

- 现有卸载工具在 App 死后验尸（扫描 + 猜），必然遗漏。Ledger 在出生时开出生证明：证据完整时记录，事后无需猜。
- 归属只有两种证据：结构性（路径在哪）与时间性（何时出现）。Ledger 靠“更早的在场”，并自觉标注“在场时看到了什么、没看到什么”。
- 两本账：安装账（manifest，闭区间）与使用账（changes，开区间）。卸载残留 = 并集，标注来源。
- 完整 ≠ 绝对；完整 = 可观测范围内无遗漏，盲区必须显式标出。
- 机制（记账→对账）与立场（知情优先、删除可选）缺一不可。成功标准：用户看完选择不清，依然觉得值。
- 铁律：① 记账先于清理；② 知情先于行动；③ 本机先于一切。
- 禁令：不做清理器式首页；不在卸载时扫描猜归属；不用 LLM 判断事实。

## 1. 产品定义

| 项 | 值 |
|---|---|
| 名称 / Bundle ID | Ledger / `com.ledger.app` |
| 目标用户 | 不懂文件系统、只用 CleanMyMac 类工具的普通 macOS 用户 |
| 核心承诺 | 装过的 App 卸了之后，看得见它留下的每一样东西 |
| 默认行为 | 只记录、只提示，不动任何文件 |
| 可选行为 | 用户确认后，把可安全删除的残留移入废纸篓 |
| 边界 | 只对记账过的 App 完整；更早安装的走识别轨（尽力而为） |

## 2. 硬性约束

1. 观察模式禁止写用户文件；删除模式唯一动作 = 移入废纸篓。
2. 默认零联网：禁止遥测、崩溃上报、后台更新检查、任何隐式网络调用。
3. 不强制权限：授权被拒时功能降级 + 标注盲区，禁止反复弹窗。
4. 不强制删除：用户未确认，禁止任何改动。
5. 每条信息必须带 `evidence ∈ {fact, inference, unknown}`。
6. MVP 禁止接入任何 LLM；解释层 = 本地规则 + 本地知识库。
7. 原生 Swift 5.9+ / SwiftUI；禁止跨平台框架。

## 3. 技术栈与形态

| 项 | 选型 |
|---|---|
| 语言 / UI | Swift 5.9+ / SwiftUI，macOS 14+ |
| 常驻 | LaunchAgent（登录自启、无窗口）+ `NSStatusItem` |
| 文件监听 | FSEvents，必须带 `kFSEventStreamCreateFlagFileEvents`，latency 0.5s |
| 存储 | SQLite（WAL）+ 内存索引 |
| 单实例 | 启动时发现同 bundle-id 已运行则退出 |

运行形态：登录自启 → 后台常驻 → 菜单栏图标 → 点击打开独立窗口。

## 4. 权限与隐私

| 能力 | 权限 | MVP |
|---|---|---|
| 读 `~/Library` 常规目录、`/Library/LaunchAgents`、`/Library/LaunchDaemons`、`/Library/PrivilegedHelperTools` | 无 | ✅ |
| 读 TCC 保护目录（Mail/Messages/Safari/Cookies/通讯录） | Full Disk Access | 可选，未授权即盲区 |
| 读 BTM（`sfltool dumpbtm`） | 管理员 | ❌ P2 |
| 移入废纸篓（用户级） | 无 | ✅ 用户点击后 |
| 删除系统项 | 管理员 | ❌ P2，只提示 |
| 检查更新 | 一次性网络 | ❌ P2 |

隐私：数据只存 `~/Library/Application Support/com.ledger.app/`；数据库依赖 FileVault 不额外加密；禁止任何网络请求。

## 5. 核心机制

### 5.1 术语
- **扫描根**：§9 的 17 个目录。
- **索引**：`Map<path, {size, mtime, inode}>`，仅含扫描根内条目。
- **安装窗口**：`[install_started_at, install_finished_at]`。

### 5.2 新装判定
- FSEvents 事件路径 P 属于某顶级 `.app` 路径 A（`/Applications/<name>.app/...` 或 `~/Applications/<name>.app/...`）。
- A 在索引中不存在 且 `apps.install_path` 无 A → **新装**，创建 install context。
- A 已存在 → 修改/更新，不触发记账。
- 每个 A 独立 context，可并发处理。

### 5.3 记账时序（必须严格按此实现）
1. context 创建：`install_started_at = 事件时间 - 2s`；`pre_install_state` = 当前索引深拷贝。
2. 稳定判定：A 的 mtime 连续 30s 无变化 → `install_finished_at = now`；30 分钟未稳定 → 按 broken(partial) 处理。
3. 结构校验：`A/Contents/Info.plist` 存在 + `CFBundleExecutable` 指向的可执行文件存在。**失败 = broken**。
4. 签名校验：`codesign --verify A`。失败仅记 `warning`（可能是未签名开发构建），**不判 broken**。
5. 状态：结构通过 → `recorded`，manifest `status=complete`；结构失败 → `broken`，仍生成 manifest `status=partial`（半成品也要记录，否则无法清理）。
6. **manifest_items 选取（三集合并、去重、排除 A 自身子树）**：
   a. 索引中 `mtime ∈ [install_started_at - 5s, install_finished_at + 30s]` 的路径；
   b. 当前索引存在但 `pre_install_state` 不存在的路径；
   c. 前后均存在但 `size` 变化的路径。
7. 注册项差分：窗口内执行一次 `pkgutil --pkgs`、`systemextensionsctl list`，与窗口前状态对比，新增项计入 manifest（`item_type=registration`）。
8. 归属与 evidence：见 §10.3。
9. 落库：`manifest` + `manifest_items`，记录 `observed_scope`、`blind_spots`。

### 5.4 重启对账（正确机制）
- **FSEvents 的文件级事件不跨重启持久；重启后只能重放目录级事件。**
- 流程：读 `meta.last_fsevent_id` → 重放目录级事件 → 对发生变化的目录重扫并比对 mtime → 重建索引差异。
- `last_fsevent_id` 丢失 → 全量重扫（后台、带进度）。
- 监听 `NSWorkspace.didWakeNotification` → 唤醒后执行轻量对账。

### 5.5 卸载判定（含误报处理）
- FSEvents 额外监听 `~/.Trash`（**仅用于判定，不是扫描根**）。
- `.app` A 从 `/Applications`、`~/Applications` 消失：
  - 新路径在 `~/.Trash/` 下 → **卸载**（触发对账提示）；
  - 新路径在其它位置 → **移动**（更新 `install_path`，不触发）；
  - 找不到新路径（跨卷移动或真删）→ **判为卸载**，但提示必须带 **“只是移动了它？标为移动”** 入口；用户点选后状态回 `tracked`，撤下待处理。
- 禁止用 inode 区分“移动/移入废纸篓”（同卷重命名 inode 不变）。
- 只监控 `/Applications`、`~/Applications`；`/System/Applications` 忽略。

### 5.6 更新 / 重装 / 恢复
- 同 bundle-id 且状态 ∈ {recorded, tracked} → **更新**：沿用原 manifest，变化进 `changes`，不新建 manifest。
- `vanished` 后重现，且新 `install_path` == 旧 `install_path` → **恢复**：状态回 `tracked`，撤下待处理，保留原 manifest。
- `vanished` 后重现，路径不同 → **重装**：新 manifest，旧标 `superseded`。

### 5.7 基线未完成期间的安装
- 基线扫描未完成时检测到新装 → context 进入 `pending`，基线完成后生成 manifest；若基线完成晚于 `install_started_at`，该 manifest `status=partial`，全部 `evidence` 降为 `inference`，UI 注明“记账不完整”。

## 6. 七步闭环

| 步 | 触发 | 输出 | 失败处理 |
|---|---|---|---|
| ① 基线 | 首次启动/索引缺失 | 索引 + 持久化 | 后台带进度，不阻塞 UI |
| ② 记账 | 新 `.app` 稳定 | manifest | 结构失败 → broken(partial) |
| ③ 追踪 | FSEvents 变化 | changes + 周报数据 | 重启补课（§5.4） |
| ④ 触发 | App 消失/启动对账 | 提示“还有 N 处” | 误报入口（§5.5） |
| ⑤ 核对 | 用户打开清单 | 四组结果 | 不一致 → 标“已变化” |
| ⑥ 执行 | 用户勾选确认 | 移入废纸篓 + 日志 | 单项失败跳过并记录 |
| ⑦ 报告 | 清理完成 | 删了什么/留了什么/怎么恢复 | 更新基线 |

闭环终点 = 知情 + 做出选择；选择“不清”同样闭合。

## 7. 状态机

```
discovered → installing → recorded → tracked → vanished → verified → settled
                    ↓        ↑                            │
                 broken ─────┘（重新安装：mtime 再变化→重走稳定判定）│
                                                           │
        vanished → tracked（恢复，同路径重现）              │
        vanished → installing（重装，异路径重现）           │
        broken → installing（用户重新安装）                 │
```

| 转移 | 条件 |
|---|---|
| discovered → installing | `.app` 出现，mtime 在变 |
| installing → recorded | 30s 稳定 + 结构校验通过 |
| installing → broken | 30s 稳定 + 结构失败；或 30 分钟未稳定 |
| recorded → tracked | 开始追踪 |
| tracked → vanished | §5.5 判定卸载 |
| vanished → verified | 用户打开残留清单 |
| verified → settled | 清理完成，或用户明确选择“保留” |
| vanished → tracked | §5.6 恢复 |
| vanished → installing | §5.6 重装 |
| broken → installing | A 的 mtime 再次变化，重走记账；新 manifest 合并旧 partial |

## 8. 数据模型（SQLite，`PRAGMA user_version=1`）

```sql
apps(
  bundle_id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT,
  install_path TEXT,            -- 最后已知路径
  icon_path TEXT,               -- 记账时缓存，App 消失后仍可展示
  first_seen REAL, state TEXT
)
manifests(
  id INTEGER PRIMARY KEY, app_bundle_id TEXT,
  install_started_at REAL, install_finished_at REAL,
  observed_scope_json TEXT, blind_spots_json TEXT,
  status TEXT,                  -- complete|partial|superseded
  created_at REAL
)
manifest_items(
  id INTEGER PRIMARY KEY, manifest_id INTEGER, path TEXT,
  item_type TEXT,               -- file|dir|registration
  category TEXT,                -- app_data|cache|log|preference|registration|unknown
  size_bytes INTEGER, mtime REAL, inode INTEGER,
  registration_kind TEXT,       -- launch_agent|launch_daemon|privileged_helper|btm|tcc|system_extension|receipt|NULL
  verdict TEXT,                 -- safe|caution|dont_touch|unknown（仅安全性）
  requires_admin INTEGER,       -- 0|1（仅权限）
  evidence TEXT                 -- fact|inference|unknown
)
changes(id INTEGER PRIMARY KEY, ts REAL, path TEXT, app_bundle_id TEXT,
        kind TEXT,              -- created|modified|removed|moved
        size_delta INTEGER, evidence TEXT)
app_events(id INTEGER PRIMARY KEY, ts REAL, app_bundle_id TEXT,
           kind TEXT, detail TEXT)   -- installed|broken|vanished|reinstalled|restored|settled|superseded
reports(id INTEGER PRIMARY KEY, created_at REAL, kind TEXT, content_json TEXT)
meta(key TEXT PRIMARY KEY, value TEXT)  -- last_fsevent_id|schema_version|pause_state
```

`verdict`（安全性）与 `requires_admin`（权限）必须分开存、分开展示。

## 9. 扫描范围

**17 个扫描根**：`~/Library/{Caches, Containers, Group Containers, Application Support, Logs, HTTPStorages, WebKit, Saved Application State, Preferences, LaunchAgents, Application Scripts}`、`/Library/{Application Support, Preferences, Logs, LaunchAgents, LaunchDaemons, PrivilegedHelperTools}`。

**FSEvents 额外监听（非扫描根）**：`~/.Trash`（仅用于卸载判定）。

**注册项来源**：`pkgutil --pkgs`、`systemextensionsctl list`（均可无管理员读取）。BTM/TCC：MVP 只记录“存在未观测注册类别”，不读取内容。

**扫描规则**：只读元数据（size/mtime/inode），不读文件内容；跳过符号链接；不可读根记入 `blind_spots` 并展示为盲区（禁止静默跳过）。

## 10. 判定规则

### 10.1 verdict（按路径前缀首次命中）

| verdict | 路径 |
|---|---|
| safe | Caches、Logs、HTTPStorages、WebKit、Saved Application State、DiagnosticReports |
| caution | Application Support、Containers、Group Containers、Application Scripts、Preferences |
| dont_touch | TCC、BTM、Keychain、System Extensions |
| unknown | 未匹配 |

### 10.2 requires_admin
`1`：`/Library/LaunchAgents`、`/Library/LaunchDaemons`、`/Library/PrivilegedHelperTools`、system_extension、btm、tcc、receipt；其余 `0`。

### 10.3 归属与 evidence
- `fact`：路径某段目录名 == bundle-id、或以其开头（如 `<bundle-id>.savedState`）、或与 CFBundleDisplayName/CFBundleName 大小写不敏感相等。
- `inference`：不满足上述但落在安装窗口。
- bundle-id 从 `A/Contents/Info.plist` 读取（安装完成时）；读取失败按 App 名匹配。

### 10.4 核对四组

| 组 | 判定 |
|---|---|
| 可删 | 存在 + size/inode 与记录一致 + verdict∈{safe,caution} + requires_admin=0 |
| 已消失 | 路径不存在 |
| 已变化 | 存在但 size/inode 不一致 → 默认不勾选，提示“可能不是原来那个” |
| 需管理员 | requires_admin=1 → 不可勾选，仅展示处理方式 |

### 10.5 勾选与删除
- 默认勾选：`fact` + `safe`。
- 手动可选：`fact` + `caution`。
- 永不可删：`dont_touch`、`unknown`、`requires_admin=1`。
- **`inference` 项永不默认勾选**（即使 safe）。
- 删除动作 = `FileManager.trashItem`；逐项执行，单项失败 → 跳过并记入失败清单，不中断整体。
- 删除前再次校验 size/inode；不一致 → 跳过并标“已变化”。

## 11. 解释层（本地知识库，非 AI）

`Resources/knowledge.json` 随包分发。条目：

```json
{"id":"cache","match":{"type":"path_prefix","value":"~/Library/Caches/"},
 "category":"cache","verdict":"safe","requires_admin":false,
 "title":"应用缓存","explanation":"应用运行时的临时数据，可重建；删除后首次启动变慢，不丢数据。",
 "verify":"du -sh <path>"}
```

- `match.type ∈ {path_prefix, filename_suffix, bundle_dir}`。
- **匹配优先级**：最长 `path_prefix` 命中优先 → 其次 `filename_suffix` → 再 `bundle_dir`（目录名 == 任一已登记 bundle-id）→ 全不中 = `unknown`（`title="未收录"`、`explanation="暂无解释"`，禁止猜测）。
- v1 覆盖目标：17 个根 + 7 种注册项 + 10 类常见文件后缀（plist/sqlite/log/cache/savedState/binarycookies/lock/pid/tmp/db-wal）。

## 12. 场景与对策

| 场景 | 检测 | 对策 |
|---|---|---|
| 拖进废纸篓 | 新路径在 `~/.Trash/` | 判卸载 → 查 manifest → 提示残留 |
| 第三方卸载器卸载 | 同上 | 同上 + 提示“第三方可能只清了部分” |
| 只删 App、注册项还在 | `.app` 消失 + 注册项仍存在 | 高亮“注册项残留” |
| 安装中断 | 稳定后结构校验失败 | broken(partial)，列半成品与悬空注册项 |
| 移动到外置盘/他处 | 新路径不在废纸篓 | 标“已移动”，不触发 |
| 跨卷移动被误判 | 找不到新路径 | 提示带“只是移动了它？”撤销入口 |
| 重装 | vanished 后异路径重现 | 新 manifest，旧 superseded |
| 从废纸篓恢复 | vanished 后同路径重现 | 状态回 tracked，撤下待处理 |
| 无 FDA | 根不可读 | 标盲区，提示可授权补全 |
| 删到一半崩溃 | 启动检测未完成操作 | 操作日志 + 废纸篓，续做 |
| App 自更新 | 同 bundle-id 已 tracked | 沿用 manifest，追加变化 |
| Ledger 退出期卸载 | 启动对账 | 补标 vanished |
| 用户暂停记录 | 菜单栏“暂停” | 停监听与扫描；状态持久化，重启保持 |

## 13. 注册项处理模板（只提示，禁止代执行）

| kind | 检测 | 提示操作 |
|---|---|---|
| launch_agent（用户） | plist 存在 / `launchctl print gui/$UID/<label>` | `launchctl bootout gui/$UID/<label>` 后删 plist |
| launch_daemon | plist 存在 / `sudo launchctl print system/<label>` | `sudo launchctl bootout system/<label>` 后删 plist |
| privileged_helper | 文件存在 | `sudo rm <path>`（先确认无进程使用） |
| btm | 仅提示可能存在 | 系统设置 → 通用 → 登录项与扩展 |
| tcc | 仅提示可能存在 | 系统设置 → 隐私与安全性 |
| system_extension | `systemextensionsctl list` 命中 | `systemextensionsctl uninstall <teamID> <bundleID>` |
| receipt | `pkgutil --pkgs` 命中 | `sudo pkgutil --forget <pkgid>` |

UI 提供“复制命令”按钮；禁止提供“代执行”。

## 14. GUI 规格

**菜单栏**：图标；未处理残留 → 红点；点击开窗；右键：打开窗口/暂停记录/退出。

**窗口四 Tab**：

- **概览**：三个数字（已记录 App 数 / 未知项数 / 今日新增字节）；App 列表（名称、图标、足迹大小、状态徽标：正常/已卸载/安装未完成/签名警告）；点击 → 详情。
- **待处理**：vanished、broken 的 App 按残留大小降序；行 = 名称 + 残留项数 + 注册项数 + 总大小；点击 → 残留清单。
- **周报**：主图 = 堆叠柱状图（X=周一至周日，Y=新增字节，堆叠=App）；副图 = 按 category 堆叠；抬头 = 本周新增总量/新装 App 数/未知项数/Top5；按钮 = 导出 Markdown。
- **设置**：扫描根勾选；权限状态（FDA 已授权/未授权/盲区数）；保留策略（30 天/500MB）；通知开关；暂停开关。

**残留清单（Sheet）**：行 = 路径/类型/大小/verdict/requires_admin/evidence/展开解释；底部 = 已选 N 项共 X MB + “移入废纸篓”；需管理员项单独分区（§13 命令 + 复制按钮）。

**确认对话框**：“将把 N 项移入废纸篓，共 X MB，可从废纸篓恢复。系统项不会删除，只给出处理方式。”

**报告页**：删了什么/留了什么/怎么恢复；导出到 `~/Library/Application Support/com.ledger.app/reports/uninstall-<bundle-id>-<date>.md`（周报 `weekly-<date>.md`）。

**通知**：UserNotifications 授权缺失 → 仅红点，不反复请求（设置页有授权入口）。

**“新增字节”统一定义**：`Σ(created.size) + Σ(max(0, modified.size_delta))`；`removed` 只作副指标展示；`moved` 不产生字节变化。

## 15. MVP 范围

1. 基线扫描 + 内存索引 + 持久化（60s 落盘）
2. 安装检测 + 记账（含 broken/partial、签名警告降级）
3. 启动/唤醒对账 + 消失检测 + 误报撤销入口
4. 残留清单（四组、verdict 与 requires_admin 分离、inference 不默认勾选）
5. 用户级文件移废纸篓（逐项校验、失败记录）
6. 报告 + 导出 Markdown
7. 追踪 + 周报柱状图
8. 观察模式（零权限可用、盲区可见）
9. 暂停/恢复记录（持久化）

## 16. 验收标准

1. 装一个测试 App → 窗口能看到 manifest（文件数 + 注册项数）。
2. 拖进废纸篓 → 60s 内出现“还有 N 处”。
3. 清单每行含：路径、类型、大小、verdict、requires_admin、evidence。
4. 勾选清理 → 废纸篓可还原。
5. 半成品 `.app` → 标“安装未完成”（broken）。
6. 未签名但结构完整的 App → 状态 recorded + 签名警告，不误判 broken。
7. 后台空闲 1 小时：CPU < 1%，内存 < 100MB。
8. 全程零网络请求（抓包验证）。
9. 重启后数据仍在；索引加载后不触发全量重扫。
10. 无 FDA 时盲区被标出，不假装完整。
11. `unknown`、`dont_touch`、`requires_admin=1` 项均不可勾选。
12. 跨卷移动误判后，可一键“标为移动”并撤销待处理。

## 17. 不做清单

❌ 系统项删除（P2）；❌ BTM/TCC 读取处理（P2/P3）；❌ Homebrew（P2）；❌ iOS/Windows；❌ 云同步/遥测/自动更新；❌ LLM 判断归属；❌ “一键清理 XX GB”首页；❌ 用 inode 区分“移动/移入废纸篓”；❌ 在卸载时扫描猜归属。

## 18. 实现顺序

| 阶段 | 交付 |
|---|---|
| M1 | 骨架 + 菜单栏 + 窗口壳 + SQLite + 单实例 |
| M2 | 基线扫描 + 内存索引 + 持久化 + FSEvents（含 ~/.Trash 监听） |
| M3 | 安装检测 + 记账 + broken/partial + 签名警告 |
| M4 | 启动/唤醒对账 + 消失检测 + 误报撤销 + 待处理 |
| M5 | 残留清单 + 移废纸篓 + 报告 |
| M6 | 追踪 + 周报柱状图 |
| M7 | 权限/盲区 + 设置页 + 暂停恢复 + 打磨 |

每阶段：自检 → 汇报 → 等待确认 → 提交；未确认禁止进入下一阶段。

## 19. 交付物

`Ledger.app`；`README.md`（安装/权限/使用/已知限制）；`Resources/knowledge.json`（附覆盖度说明）；`devlog/`（每日进度）；验收记录（对照 §16 逐条打勾）。
