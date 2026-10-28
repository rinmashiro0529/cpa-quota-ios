# Rin，CAP 用量后端接入合同

Rin，本模块读取 CAP Token Usage Tracker 的只读统计资源，不修改插件配置、价格、数据库或 CPA 账号。公开协议参考固定提交 `b7748ecfc1a5352acd10df8f17b1ba88ee2a591b`（v2.0.11），不代表用户实例安装版本；尚未连接真实部署。

## Rin，连接与权限

```swift
if let client = await session.makeCAPUsageClient() {
    let store = CAPUsageStore(client: client, access: .anonymous)
    await store.refresh(window: CAPUsageWindow(now: Date()))
}
```

Rin，优先从当前 `CPAQuotaSession` / `CPAQuotaStore` / `CPAClient` 的 `makeCAPUsageClient()` 派生，以复用传输、时钟及同一管理请求协调器。View 不需要也不应重新读取管理密钥。创建返回时校验活动连接；已经交出的客户端引用不会因为之后切换连接而自动失效，上层必须取消旧请求并丢弃旧客户端与 Store。

Rin，资源认证必须由部署方明确选择。`.anonymous` 不携带 Authorization，`.managementKey` 显式使用当前管理 Bearer。不会先匿名失败后偷偷重发管理密钥，也不建立 full-mode capability、解密或读取调用方原始 API Key。管理统计始终使用管理认证。资源反向代理与鉴权是否允许移动端直连仍需部署验收，不能根据 management 路由推断。

## Rin，只读接口

| 客户端方法 | 路由后缀 | 输出 |
| --- | --- | --- |
| `loadManagementStats(window:)` | `/v0/management/plugins/cap-token-usage-tracker/stats` | 原始聚合、维度分组、时间序列 |
| `loadInitialStats(window:access:)` | `/v0/resource/plugins/cap-token-usage-tracker/stats/initial` | 概览、模型统计、桶宽、保留起点 |
| `loadTrends(window:access:)` | `/v0/resource/plugins/cap-token-usage-tracker/stats/trends` | 逐模型时间桶 |
| `loadGroups(window:offset:limit:access:)` | `/v0/resource/plugins/cap-token-usage-tracker/stats/groups` | 一页详细维度，返回总行数 |
| `loadCosts(window:access:)` | `/v0/resource/plugins/cap-token-usage-tracker/costs` | USD 估算、计价覆盖、缺价列表及价格簿版本 |
| `loadRequestPage(window:offset:limit:access:)` | `/v0/resource/plugins/cap-token-usage-tracker/requests` | 一页请求明细 |
| `loadWindowRequests(window:access:)` | 同上 | 有界分页集合与完整性标记 |

Rin，所有请求固定 `range=custom` 和 RFC3339 start/end，保留 CPA 反向代理路径前缀。日期、source、model/provider、API Key 身份和额度 auth-file 是不同维度，不按昵称、邮箱或 Source 强行配对。普通资源返回的 API Key 维度可能被插件隐藏；未知字段和缺失计数不能当作零。

## Rin，窗口与速度

Rin，`CAPUsageWindow(now:)` 生成 `[floor(now/60)*60-1800, floor(now/60)*60)`，即截至最后完整分钟的近30分钟；上层应显示“截至 HH:mm”。此处 now 是调用方提供的可信时钟，公开资源并未提供独立服务器时钟同步协议。`generated_at` 是插件生成响应时间，不是每次请求观察时间；`bucket_seconds` 明确时间桶分辨率，不能冒充秒级完整数据。

```text
严格加权生成 TPS = sum(有效输出 Token) / (sum(latency_ns - ttft_ns) / 1e9)
端到端输出速度 = sum(有效输出 Token) / (sum(latency_ns) / 1e9)
```

Rin，生成 TPS 仅计算已知成功、输出口径可判定、TTFT>0 且 latency>TTFT 的样本。缺 TTFT 不能把插件兼容回退冒充生成时长；端到端速度单列。OpenAI-compatible/Anthropic 等已含 reasoning 的 output 不重复加 reasoning，也不要求无关的 reasoning 字段存在；Gemini 等独立计量需要 reasoning 数据。未知口径保守排除并显示样本覆盖，不猜测。不同 provider、model 以及 stream 值分别分组；同名模型不跨 provider 合并。

Rin，100 Token/2秒和900 Token/30秒的已知向量结果为31.25 Token/s，不是单请求速率的算术平均40，也不是1000/1800的窗口吞吐。`average_latency_ns` 与 `average_ttft_ns` 的样本集合可能不同，不能相减推导生成时长。失败请求的部分用量仍属于用量数据，但不纳入成功生成 TPS。

## Rin，分页与保守完整性

Rin，每页最多500条，自动集合最多10页、5000条，单响应最多4MiB，累计请求页预算8MiB。下一页大小未知时预留整个单响应上限，因此可能在达到8MiB之前保守停止；不会为追求“完整”自动读取全历史或数据库备份。

| 标记 | 真实含义 |
| --- | --- |
| `singlePage` | 这一次响应报告的全部记录在一页内；不是对历史迟到写入的保证 |
| `offsetUnverified` | 已按固定窗口读到报告的末页，但 offset 不提供冻结快照证明 |
| `truncated` | 达到资源预算，或发现重复、total变化、页缺口等异常；已取得部分数据不能称完整 |

Rin，固定终点、去重和 total 相同都不能证明跨页强一致。界面必须显示完整性和有效 TPS 样本覆盖；不要把截断样本推导出的速度称为全窗口精确平均。

## Rin，可观察状态与错误

Rin，`CAPUsageStore` 的 `refresh(window:)` 更新概览快照和逐模型统计，`summary.counters` 同时提供该已取得请求集合的基础计数：失败请求的部分 Token 保留在用量中，字段缺失或整数溢出时对应合计为 nil。所有统计仍受 `requests.completeness` 约束，不能把部分集合的计数当作插件报告的全量。

Rin，`refreshDetails(window:groupOffset:groupLimit:)` 在同一固定窗口内读取 initial/trends/groups/costs，整批成功后发布 `details`，默认分组页为 offset=0、limit=100。独立的 `detailsError`/`isLoadingDetails` 不覆盖概览状态；刷新失败保留上次详情。分组页的 total、当前 items、groupOffset 与 groupLimit 同时保留，不能把一页当作全量。四个端点不共享冻结数据库快照，固定窗口不代表跨端点原子一致性。

Rin，新一轮刷新会取消同类旧任务；取消会向底层传输传播，并在 HTTP 返回及 JSON 解码后检查。代际校验同时禁止旧结果覆盖新结果。调用方取消外层 Task 时，Store 也取消自己持有的子任务，不会脱离外层继续翻页。

Rin，管理401/403触发共享管理熔断，管理429遵守 Retry-After，缺少有效截止时间时保守60秒；force 或重新探测不清除保护。匿名资源的429使用本用量客户端独立的资源冷却，不污染管理凭据熔断；换详情路由不能绕过资源冷却，`resourceRejected(statusCode:retryAt:)` 和 `error.retryAt` 提供可读期限。404表达插件路由不可用，不返回伪造的空统计。网络错误使用安全类别，不回显底层任意文本、响应正文或认证头。

## Rin，验证与上线边界

Rin，测试采用固定公开协议的合成 JSON、受控时钟及注入 HTTP 传输，不访问真实 CPA 或凭据。最终验证回执、源码哈希和未验收项目以 `docs/BACKEND_VERIFICATION.md` 为准；部分切片的通过不代表完整工程通过。没有新增第三方运行时依赖，也未操作 Apple 账号、签名、安装或部署。

## Rin，一手协议来源

- Rin，[固定版 aggregate.go](https://github.com/AITNR/cap-token-usage-tracker/blob/b7748ecfc1a5352acd10df8f17b1ba88ee2a591b/internal/plugin/aggregate.go)：计数、维度、概览、分组与时间桶。
- Rin，[固定版 request_log.go](https://github.com/AITNR/cap-token-usage-tracker/blob/b7748ecfc1a5352acd10df8f17b1ba88ee2a591b/internal/plugin/request_log.go)：请求字段、推理口径及插件TPS回退。
- Rin，[固定版 management.go](https://github.com/AITNR/cap-token-usage-tracker/blob/b7748ecfc1a5352acd10df8f17b1ba88ee2a591b/internal/plugin/management.go)：只读路由、查询与分页。
