# CAP 用量后端接入合同

本模块读取 CAP Token Usage Tracker 的只读统计资源，不修改插件配置、价格、数据库或 CPA 账号。公开协议参考固定提交 `b7748ecfc1a5352acd10df8f17b1ba88ee2a591b`（v2.0.11），不代表用户实例安装版本；尚未连接真实部署。

## 连接与权限

```swift
if let client = await session.makeCAPUsageClient() {
    let store = CAPUsageStore(client: client, access: .anonymous)
    await store.refresh(window: CAPUsageWindow(now: Date()))
}
```

优先从当前 `CPAQuotaSession` / `CPAQuotaStore` / `CPAClient` 的 `makeCAPUsageClient()` 派生，以复用传输、时钟及同一管理请求协调器。View 不需要也不应重新读取管理密钥。创建返回时校验活动连接；已经交出的客户端引用不会因为之后切换连接而自动失效，上层必须取消旧请求并丢弃旧客户端与 Store。

资源认证必须由部署方明确选择。`.anonymous` 不携带 Authorization，`.managementKey` 显式使用当前管理 Bearer。不会在匿名请求失败后自动改用管理密钥，也不建立 full-mode capability、解密或读取调用方原始 API Key。管理统计始终使用管理认证。资源反向代理与鉴权是否允许移动端直连仍需部署验收，不能根据 management 路由推断。

## 只读接口

| 客户端方法 | 路由后缀 | 输出 |
| --- | --- | --- |
| `loadManagementStats(window:)` | `/v0/management/plugins/cap-token-usage-tracker/stats` | 原始聚合、维度分组、时间序列 |
| `loadInitialStats(window:access:)` | `/v0/resource/plugins/cap-token-usage-tracker/stats/initial` | 概览、模型统计、桶宽、保留起点 |
| `loadTrends(window:access:)` | `/v0/resource/plugins/cap-token-usage-tracker/stats/trends` | 逐模型时间桶 |
| `loadGroups(window:offset:limit:access:)` | `/v0/resource/plugins/cap-token-usage-tracker/stats/groups` | 一页详细维度，返回总行数 |
| `loadCosts(window:access:)` | `/v0/resource/plugins/cap-token-usage-tracker/costs` | USD 估算、计价覆盖、缺价列表及价格簿版本 |
| `loadRequestPage(window:offset:limit:access:)` | `/v0/resource/plugins/cap-token-usage-tracker/requests` | 一页请求明细 |
| `loadWindowRequests(window:access:)` | 同上 | 有界分页集合与完整性标记 |

所有请求固定 `range=custom` 和 RFC3339 start/end，保留 CPA 反向代理路径前缀。日期、source、model/provider、API Key 身份和额度 auth-file 是不同维度，不按昵称、邮箱或 Source 强行配对。普通资源返回的 API Key 维度可能被插件隐藏；未知字段和缺失计数不能当作零。

## 窗口与速度

`CAPUsageWindow(now:range:)` 仅允许 `CAPUsageRange` 的 30 分钟、24 小时、7 天三个有界选项，默认仍为 30 分钟。终点为 `floor(now/60)*60`，起点为终点减去对应的 1800 / 86400 / 604800 秒；它们是经过时长，不是本地自然日。固定版本 `aggregate.go` 的 `usageRangeFromQuery` 明确接受 `range=custom`、RFC3339 起止时间且要求 start < end，`presetUsageRange` 也明确列有 `24h` 和 `7d`。客户端继续发送 custom 起止值，使各区域和翻页复用同一绝对窗口；这项源码证据不代表用户实例已完成兼容性验收。

选择范围只取消在途读取并更新待查询窗口，不自动请求端点。旧结果保留自己的窗口与生成时间并标为“上次读数”；刷新当前栏目使用所选窗口，失败区域重试始终使用该区域失败时的窗口和分页参数。切换为较长范围不会放宽分页、请求条数或字节预算。

`retained_since` 只能说明服务端保留历史的起点。缺失、无法解析或尚未读取时显示“保留范围尚未确认”；窗口早于保留起点时明确提示较早时段不可用，不能把零记录当作该时段零用量。保留起点覆盖窗口仍不证明迟到写入、分页或跨端点快照完整。上游配置默认值不能用于推断用户实例的实际保留期。

此处 now 是调用方提供的可信时钟，公开资源并未提供独立服务器时钟同步协议。界面显示窗口两端的绝对日期与时间。`generated_at` 是插件生成响应时间，不是每次请求观察时间；`bucket_seconds` 明确时间桶分辨率，不能冒充秒级完整数据。

```text
严格加权生成 TPS = sum(有效输出 Token) / (sum(latency_ns - ttft_ns) / 1e9)
端到端输出速度 = sum(有效输出 Token) / (sum(latency_ns) / 1e9)
```

生成 TPS 仅计算已知成功、输出口径可判定、TTFT>0 且 latency>TTFT 的样本。缺 TTFT 不能把插件兼容回退冒充生成时长；端到端速度单列。OpenAI-compatible/Anthropic 等已含 reasoning 的 output 不重复加 reasoning，也不要求无关的 reasoning 字段存在；Gemini 等独立计量需要 reasoning 数据。未知口径保守排除并显示样本覆盖，不猜测。不同 provider、model 以及 stream 值分别分组；同名模型不跨 provider 合并。

输出口径按明确优先级判断：兼容接口或 Anthropic 的已包含语义优先，其次为 Gemini 的独立 reasoning，最后才考虑通用 executor/provider。这样不会因 executor 与 provider 同时命中不同类别而重复加 reasoning。reasoning 为 0 或已知 executor 可证明口径的样本仍可计算，不把所有未知元数据一律排除；无法证明的样本继续排除。

CPA 账号清单身份（id/name/auth_index 与嵌套 Codex account ID）优先使用字符串。此处数字身份仅接受可证明无损的安全整数；小数、布尔值、浮点来源及超出 ±(2^53−1) 的数值身份拒绝，不通过 Double 舍入后制造另一个 ID。大整数必须由上游以字符串传输。度量值仍按其原有数值合同解析，此限制不会把用量、金额等字段整体改为字符串；CAP 请求 sequence 仍按 UInt64 合同解码，不适用这一账号身份限制。

100 Token/2 秒和 900 Token/30 秒的已知向量结果为 31.25 Token/s，不是单请求速率的算术平均40，也不是1000/1800的窗口吞吐。`average_latency_ns` 与 `average_ttft_ns` 的样本集合可能不同，不能相减推导生成时长。失败请求的部分用量仍属于用量数据，但不纳入成功生成 TPS。

## 分页与保守完整性

每页最多 500 条，自动集合最多 10 页、5000 条，单响应最多 4 MiB，累计请求页预算 8 MiB。下一页大小未知时预留整个单响应上限，因此可能在达到 8 MiB 之前保守停止；不会为追求“完整”自动读取全历史或数据库备份。

| 标记 | 真实含义 |
| --- | --- |
| `singlePage` | 这一次响应报告的全部记录在一页内；不是对历史迟到写入的保证 |
| `offsetUnverified` | 已按固定窗口读到报告的末页，但 offset 不提供冻结快照证明 |
| `truncated` | 达到资源预算，或发现重复、total变化、页缺口等异常；已取得部分数据不能称完整 |

固定终点、去重和 total 相同都不能证明跨页强一致。界面必须显示完整性和有效 TPS 样本覆盖；不要把截断样本推导出的速度称为全窗口精确平均。

## 可观察状态与错误

`CAPUsageStore` 的 `refresh(window:)` 更新概览快照和逐模型统计，`summary.counters` 同时提供该已取得请求集合的基础计数：失败请求的部分 Token 保留在用量中，字段缺失或整数溢出时对应合计为 nil。所有统计仍受 `requests.completeness` 约束，不能把部分集合的计数当作插件报告的全量。

`refreshDetails(window:groupOffset:groupLimit:)` 在同一固定窗口内顺序读取 initial/trends/groups/costs，保持最多一个详情端点在途。四个资源分别持有 `initialState`、`trendsState`、`groupsState`、`costsState`：成功响应立即发布，不等待其他区域成功。每个状态保留自己的 `snapshot.query`（原始窗口及分组分页参数）、本次 `requestedQuery`、错误、加载状态和“上次读数”标记；每个响应的 `generated_at` 原样保留。一个区域失败不会清空其他三个区域，也不会把旧结果的时间重新标成新结果。

`retryDetailResource(_:)` 只重试指定失败区域；`retryFailedDetails()` 只读取当前失败区域，逐个复用各自失败时的查询。`refreshGroupPage` 始终只读 groups，即使其他分析尚未成功，也不会补发整个分析批次。默认分组页仍为 offset=0、limit=100；分组 total、当前 items、groupOffset 与 groupLimit 同时保留，不能把一页当作全量。重试通过原有客户端与协调器，不切换认证方式，不清除冷却或熔断。

兼容属性 `details` 仅保留最近一组窗口一致的四类快照，`detailsError` 为首个资源错误，`isLoadingDetails` 为各资源加载状态的并集；新界面使用独立状态，不以兼容整组快照作为显示门槛。固定窗口不代表四个端点共享冻结数据库快照，也不代表它们的生成时间相同。

新一轮刷新会取消同类旧任务；取消会向底层传输传播，并在 HTTP 返回及 JSON 解码后检查。代际校验同时禁止旧结果覆盖新结果。调用方取消外层 Task 时，Store 也取消自己持有的子任务，不会脱离外层继续翻页。

管理401/403触发共享管理熔断，管理429遵守 Retry-After，缺少有效截止时间时保守60秒；force 或重新探测不清除保护。匿名资源的429使用本用量客户端独立的资源冷却，不污染管理凭据熔断；换详情路由不能绕过资源冷却，`resourceRejected(statusCode:retryAt:)` 和 `error.retryAt` 提供可读期限。404表达插件路由不可用，不返回伪造的空统计。网络错误使用安全类别，不回显底层任意文本、响应正文或认证头。

## 验证与上线边界

测试采用固定公开协议的合成 JSON、受控时钟及注入 HTTP 传输，不访问真实 CPA 或凭据。本轮审计整改与验证边界见 `AUDIT_REMEDIATION_20261107.md` 及对应 PR 最新 Checks。新增 Swift 回归用例已加入源码；当前工作环境没有 Swift 编译器，未在本地执行，不能以静态检查替代编译或原生运行结果。`BACKEND_RELIABILITY_PR.md`、`verification/backend-reliability-20261029.json` 与 `BACKEND_VERIFICATION.md` 仅为此前版本的历史证据，不证明本轮变更通过。部分切片的通过不代表完整工程通过。没有新增第三方运行时依赖，也未操作 Apple 账号、签名、安装或部署。

## 一手协议来源

- [固定版 aggregate.go](https://github.com/AITNR/cap-token-usage-tracker/blob/b7748ecfc1a5352acd10df8f17b1ba88ee2a591b/internal/plugin/aggregate.go)：计数、维度、概览、分组、时间桶，以及 `usageRangeFromQuery` / `presetUsageRange` 的窗口合同。
- [固定版 config.go](https://github.com/AITNR/cap-token-usage-tracker/blob/b7748ecfc1a5352acd10df8f17b1ba88ee2a591b/internal/plugin/config.go)：可配置保留天数；默认配置不构成用户实例实际保留范围的证据。
- [固定版 request_log.go](https://github.com/AITNR/cap-token-usage-tracker/blob/b7748ecfc1a5352acd10df8f17b1ba88ee2a591b/internal/plugin/request_log.go)：请求字段、推理口径及插件TPS回退。
- [固定版 management.go](https://github.com/AITNR/cap-token-usage-tracker/blob/b7748ecfc1a5352acd10df8f17b1ba88ee2a591b/internal/plugin/management.go)：只读路由、查询与分页。
