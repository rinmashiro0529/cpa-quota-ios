# 2026-11-07 审计整改对照与验证边界

本文件记录审计问题对应的源码、回归和保留边界。审计基线为 `main` 提交 `5c7762001bb6f99bce1627f946722247f582782d`。本轮变更继承 PR #12 的提交 `cb45d529fd3cfcee4bdc116c93f53feb6c47690a`，保留其中的数值缓存与监控操作反馈修复；没有关闭旧 PR，也没有合并或修改 `main`。

本轮交付覆盖 F01–F10 与 D01–D04 的仓库内整改。F01 交付容量观测、预警及安全回收协议设计，未实现历史回收；F09 交付人工门禁与服务端规则配置要求，未使受账户计划限制的 GitHub 规则生效。原生编译、完整 Swift/Go 回归、签名和设备验收仍需后续环境提供证据。最终候选 SHA、PR 链接、工作流 run ID 与检查结果以新 PR 的验证回执为准。

## 实际执行的检查

下表为本次工作会话已执行的离线 Python 检查。它们检查项目工具、源文件布局与活动扩展约束，不能证明 Swift 或 Go 能够编译，也不能证明系统活动已在设备显示。

| 检查 | 实际结果 | 结论范围 |
| --- | --- | --- |
| `python3 -I -B -m unittest discover -s tools/tests -p 'test_*.py'` | 33 项通过 | 项目离线工具回归 |
| `python3 -I -X utf8 -B ci/test_source_layout.py` | 5 项通过 | 源文件布局校验器回归 |
| `python3 -I -X utf8 -B ci/test_activity_extension.py` | 17 项通过 | 活动扩展校验器回归 |
| 上述合计 | 55 项通过 | 不含 Swift、Go 或原生 UI 测试 |
| `ci/validate_public_copy.py --root .` | 通过 | 包含已暂存新增 Markdown 的公开文案检查 |
| `ci/validate_source_layout.py --root .` | 通过 | 104 个 Swift 源文件；43/43 个测试文件；无缺失、重复或悬空原生引用 |
| `git diff --cached --check` | 通过 | 已暂存候选的差异格式校验 |

当前环境没有可执行的真实 Swift、Go 与 gofmt 工具链。因此新增和既有 Swift/Go 用例均未在本环境运行，不能声称 `gofmt -l`、`go vet`、`go test -race`、Swift 测试、Xcode 构建或原生 UI 测试已通过。PR #12 的 CI 因 GitHub 付款或支出额度限制而未启动作业；这是未执行，不是成功记录。新 PR 的 CI 结果尚待核对。审计中的历史 344 项测试及旧验证文档不能替代本候选提交的结果。

没有执行压力测试，没有连接真实 CPA、CAP 或 APNs，没有安装、签名或部署，也没有更改账户套餐、账单、仓库可见性或分支保护。

## F01–F10 问题对照

### F01：历史意图容量耗尽

新增经过 Bearer 鉴权的 `GET /v1/capabilities`，返回当前身份的历史意图 `limit`、`used`、`remaining`、`warning_at` 和 `status`，以及 `can_create_session`、`can_record_cancellation`。终态会话和取消墓碑继续占用容量；默认 256 条上限在使用 205 条时进入预警。界面显示余量与容量限制，解释停止不会释放防重放记录。

实现见 [capabilities.go](../Services/QuotaMonitor/capabilities.go)、[MonitoringCapabilities.swift](../Sources/CPAQuotaKit/MonitoringCapabilities.swift) 与 [MonitoringTabView.swift](../Sources/CPAQuotaUI/MonitoringTabView.swift)。低配额回归见 [capabilities_test.go](../Services/QuotaMonitor/capabilities_test.go)，覆盖阈值、全局名额、身份隔离、重启、终态注册重放与取消先于创建。

`remaining` 是当前身份的条目余量；两个 `can_*` 标志还考虑全局条目限制。预检不预留名额，也不能预判每个未来载荷的字节准入。最终创建或新增未知 UUID 取消记录仍可能返回 507。已接受会话的查询、重复请求和停止保持原合同。

v1 历史记录没有自动 GC 或 TTL。本轮没有删除墓碑、重置身份或清空加密状态。未来回收必须先引入绑定 UUID、身份和不可延后截止时间的服务端可验证协议，配合持久时钟防回拨、版本拒绝、升级备份及兼容回退；现有 v1 记录不能据此直接删除。设计与必要回归见 [监控服务合同](MONITOR_SERVICE.md) 和 [部署说明](MONITOR_DEPLOYMENT.md)。新增测试不能作为未来回收实现已经验收的证据。

### F02：重复刷新引起全量持久化

刷新请求增加每个活动会话 10 秒间隔和每个身份滚动 60 秒最多 6 次的预算。拒绝时返回 429 与向上取整的 `Retry-After`，不修改持久状态。已经处于相同 pending/delivery 状态的刷新不再重写完整加密状态，也不重复启动采集扫描。首次状态变化仍须持久化成功后接受。

实现见 [refresh_limits.go](../Services/QuotaMonitor/refresh_limits.go) 和 [service.go](../Services/QuotaMonitor/service.go)。[refresh_limits_test.go](../Services/QuotaMonitor/refresh_limits_test.go) 使用受控时钟、少量会话与 4 个并发请求验证单次写入、间隔边界、身份预算、隔离和时钟回拨，不进行负载测试。

客户端将普通读取、手动刷新、取消和令牌轮换的冷却分开；每条通道仍遵守自己的 429，刷新拒绝不会阻断查询、停止或令牌替换。对应回归见 [MonitoringCapabilitiesTests.swift](../Tests/CPAQuotaKitTests/MonitoringCapabilitiesTests.swift)。Nginx 模板新增普通请求与控制请求的独立区域，HTTP 层定义见 [nginx-http-limits.conf](../Services/QuotaMonitor/deploy/nginx-http-limits.conf)。

该预算是进程内请求保护，重启会重置它；持久采样冷却、租约和取消合同继续生效。Nginx 模板仍需部署方在实际配置中执行语法与路由验收。本轮没有宣称消除所有大状态持久化成本。

### F03：自由文本中的多个邮箱未统一脱敏

`QuotaFormatter.maskEmails(in:enabled:)` 逐个处理自由文本中的邮箱本地部分，支持多个地址、Unicode、全角分隔符及缺失域名等异常形式。专用邮箱字段保留缺失值处理，再复用同一规则；账号名称、诊断与 CAP 展示共用该策略。底层账号身份、查询参数和原始快照保持原值，展示及读屏使用经过脱敏的字符串。

实现见 [QuotaPresentation.swift](../Sources/CPAQuotaUI/QuotaPresentation.swift)、[AccountDiagnosticPresentation.swift](../Sources/CPAQuotaUI/AccountDiagnosticPresentation.swift) 与 [CAPUsagePresentationModels.swift](../Sources/CPAQuotaUI/CAPUsagePresentationModels.swift)。合成回归见 [IntegrationPresentationRegressionTests.swift](../Tests/CPAQuotaKitTests/IntegrationPresentationRegressionTests.swift) 和 [CAPFrontendPresentationTests.swift](../Tests/CPAQuotaKitTests/CAPFrontendPresentationTests.swift)。

本开关提供部分邮箱脱敏，不是完整内容匿名化。最长标签、动态字体和 VoiceOver 的实际朗读仍需原生验收；没有以 `.privacySensitive()` 属性代替文字脱敏。

### F04：关闭连接表单后仍接受迟到结果

提交任务改由会话持有，先同步捕获并清空密钥草稿。关闭按钮、交互式 sheet 收起、取消按钮和深链打断汇入同一取消入口：在任何异步清理前清除草稿并使候选代际失效。后续候选结果不能发布为当前连接。

凭据接受继续使用串行意图和事务基线。记住连接与不记住连接都属于可取消事务；后者清除旧凭据期间取消时也恢复先前凭据集合。明确“忘记连接”保留独立语义。接受连接后自动关闭表单不会取消已经接受的额度刷新。

实现见 [CPAQuotaSession.swift](../Sources/CPAQuotaUI/CPAQuotaSession.swift)、[LoginOnboardingView.swift](../Sources/CPAQuotaUI/LoginOnboardingView.swift) 与 [CPAQuotaRootView.swift](../Sources/CPAQuotaUI/CPAQuotaRootView.swift)。回归分布于 [BackendReliabilitySessionTests.swift](../Tests/CPAQuotaKitTests/BackendReliabilitySessionTests.swift) 和 [IntegrationSessionRegressionTests.swift](../Tests/CPAQuotaKitTests/IntegrationSessionRegressionTests.swift)，覆盖提交尚未启动、迟到清单、凭据保存或移除期间取消、旧连接与快照保留。

关闭、下拉收起和深链的真实系统事件顺序仍需原生 UI 验收。安全存储失败仍须显式报告，不能把无法完成的回滚说成已经成功。

在原有六项原生 UI 用例之外，新增关闭按钮与系统下拉两项慢连接回归。仅 DEBUG 的合成传输在五秒后继续返回响应，用例核对关闭后工作台未被打开、重新进入表单后必须重输密钥。两项用例尚未执行；深链目前由会话层受控回归覆盖，未宣称通过完整系统 URL 分发验收。

### F05：首次进入等待全部账号额度

连接流程先完成管理鉴权与账号清单，再接受凭据和连接，随后读取可选额度能力并逐项刷新账号。工作台不等待最慢额度接口；列表显示批次进度、每账号等待或失败状态，并提供单账号重试。一次额度失败保留其他成功账号，旧连接刷新完成后不能覆盖新连接。

实现见 [CPAClient.swift](../Sources/CPAQuotaKit/CPAClient.swift)、[CPAQuotaStore.swift](../Sources/CPAQuotaKit/CPAQuotaStore.swift) 和 [CPAQuotaSession.swift](../Sources/CPAQuotaUI/CPAQuotaSession.swift)。新增受控 provider/额度等待回归见 [BackendReliabilitySessionTests.swift](../Tests/CPAQuotaKitTests/BackendReliabilitySessionTests.swift)。

必要的管理鉴权、账号清单与安全存储事务仍在连接接受之前；管理 401/403 熔断和账号读取并发上限保持原约束。首屏时间改进来自流程拆分，具体秒数、50 账号场景和主线程开销尚未测量。

### F06：CAP 分析必须整体成功

initial、trends、groups、costs 各自保存 loading、snapshot、error 和查询信息，成功区域立即发布。每区显示原始窗口与生成时间，失败保留该区旧结果；单区重试只使用该区失败时的窗口和分页参数。分组翻页不补发其他分析端点，批量重试只处理失败区域。

实现见 [CAPUsageStore.swift](../Sources/CPAQuotaKit/CAPUsageStore.swift)、[CAPUsageCoordinator.swift](../Sources/CPAQuotaUI/CAPUsageCoordinator.swift) 以及 [CAPUsageDetailViews.swift](../Sources/CPAQuotaUI/CAPUsageDetailViews.swift)。[CAPUsageAnalyticsTests.swift](../Tests/CPAQuotaKitTests/CAPUsageAnalyticsTests.swift) 新增每个资源分别 401/403/404/429/503/超时、部分成功即时发布、旧窗口保留、分页重试、取消与迟到响应回归。

详情读取仍顺序执行并复用原客户端限制。匿名失败不自动附加管理密钥，区域重试不清除资源冷却或管理熔断。兼容 `details` 属性只表达最近一组窗口一致的快照，不代表跨端点数据库原子快照。

### F07：交互文字对比度

新增独立 `BrandActionColor`，为浅色、深色及 Increase Contrast 提供交互文字色；装饰填充和图形继续使用原品牌色。各主要工作区和表单将交互 tint 接入该语义颜色。

实现见 [BrandActionColor.swift](../Sources/CPAQuotaUI/BrandActionColor.swift) 和 [LiquidGlassDesignSystem.swift](../Sources/CPAQuotaUI/LiquidGlassDesignSystem.swift)。[BrandContrastTests.swift](../Tests/CPAQuotaKitTests/BrandContrastTests.swift) 对三类不透明内容表面验证普通模式至少 4.5:1、高对比模式至少 7:1；该 Swift 用例尚未执行。

本次另以 Python 读取源码中的 sRGB 数值并计算相对亮度，三种表面的最低比值分别为浅色普通 5.253:1、浅色高对比 7.792:1、深色普通 6.904:1、深色高对比 9.247:1，均达到上述数值门槛。这是已执行的静态颜色计算，未计入 55 项工具回归，也不是 Swift 测试运行结果。计算依据为 [WCAG 对比度说明](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)。

颜色公式不能证明玻璃材质、系统控件叠加、禁用态与真实设备最终像素均符合要求。实际渲染、最大动态字体与辅助功能验收保留在发布门禁中。

### F08：监控配置与授权混淆

新增经过鉴权的只读能力接口，仅返回当前令牌授权的来源和账号。共享合同为 [monitoring-capabilities-v1.json](../Tests/ContractFixtures/monitoring-capabilities-v1.json)，Go 处理器与 Swift 解码使用同一夹具。客户端严格验证版本、时间、资源标识、去重与容量算术。

候选监控连接先验证能力，再提交凭据；失败保留原连接与凭据。新监控在建立本机活动前再次验证确切来源、账号范围和容量。界面区分已配置、待验证、正在验证、授权通过和验证失败。恢复已保存连接先恢复原会话，不等待新增接口；旧服务 404 不能冒充授权成功，但原会话查询与停止仍可用。

候选授权查询与最终凭据切换分开标记。等待候选或显式授权查询时，原会话仍可查询、停止；原会话操作尚未完成时不提交连接切换。实现见 [MonitoringWorkspaceCoordinator.swift](../Sources/CPAQuotaUI/MonitoringWorkspaceCoordinator.swift)。回归见 [capabilities_test.go](../Services/QuotaMonitor/capabilities_test.go)、[MonitoringCapabilitiesTests.swift](../Tests/CPAQuotaKitTests/MonitoringCapabilitiesTests.swift) 及 [MonitoringWorkspaceReliabilityTests.swift](../Tests/CPAQuotaKitTests/MonitoringWorkspaceReliabilityTests.swift)。

该接口不写状态、不创建活动，也不联系 CPA 或 APNs。授权通过只说明本次到达监控服务且令牌获准访问返回的范围，不能证明上游凭据、APNs 配置、真实推送或设备显示成功。升级顺序是先部署支持能力接口的服务端，再使用新客户端创建监控。

### F09：分支保护与发布门禁

新增 [发布与合并门禁](RELEASE_GATES.md) 和 [PR 模板](../.github/pull_request_template.md)，要求准确候选 SHA、必需检查、独立审阅、未运行项及设备证据。缺少必要验证时应保持 Draft。

本次读取的 `main` 元数据显示 `protected=false`；规则集 API 返回 403，当前私有仓库需要支持该功能的账户计划。仓库文档和人工检查不能替代服务端强制规则，也不能证明失败检查已被阻止合并。计划和权限具备后，由管理员设置并验证 PR、必需检查、禁止强推和删除等规则；使用隔离仓库或分支验收，不对生产 `main` 做破坏性试验。本轮未改变套餐、可见性或权限。

### F10：正好 100% 已用的语义

将 `isExhausted`（比例读数至少 1）与 `isExplicitlyLimited`（上游明确 `allowed=false` 或 `limitReached=true`）分开。正好 100% 显示“读数已用完”，不会仅提示余额偏低，也不会据此推断所有请求都失败。上游明确限制优先显示其限制状态；未知比例仍保持未知。

实现见 [QuotaPresentation.swift](../Sources/CPAQuotaUI/QuotaPresentation.swift) 和 [NativeContentComponents.swift](../Sources/CPAQuotaUI/NativeContentComponents.swift)。[IntegrationPresentationRegressionTests.swift](../Tests/CPAQuotaKitTests/IntegrationPresentationRegressionTests.swift) 覆盖 0、0.2、0.999、1、1.01、未知比例和上游标志冲突组合。

## D01–D04 体验建议对照

| 建议 | 本轮实现与对应文件 | 回归及保留边界 |
| --- | --- | --- |
| D01：额度总览 | [QuotasOverviewTabView.swift](../Sources/CPAQuotaUI/QuotasOverviewTabView.swift) 增加账号摘要、搜索、状态筛选和刷新进度；每账号显示最低已知剩余的独立窗口，标明未知窗口数量，完整内容进入账号详情。内置窗口名称中文化，原文保留在诊断中。 | `AuditQuotaPresentationTests` 覆盖最低窗口、未知值和状态统计；不相加独立窗口百分比，不把失败或未知当零。1/10/50 账号首屏和可达性仍需原生验证。 |
| D02：CAP 信息顺序与时间范围 | [CAPUsageTabView.swift](../Sources/CPAQuotaUI/CAPUsageTabView.swift) 统一画布与内容表面，优先展示请求、失败比例、Token、成本和速度；[CAPUsageWindow.swift](../Sources/CPAQuotaKit/CAPUsageWindow.swift) 提供 30 分钟、24 小时、7 天三个范围，使用完整分钟终点和固定 custom 起止值。 | `CAPFrontendPresentationTests` 覆盖范围、保留期、未知失败率和旧窗口。切换范围只取消读取并更新待查询窗口，不自动加载；重试和翻页保持各自原查询。上游固定版本的协议依据、保留范围与预算见 [CAP 合同](CAP_USAGE_BACKEND.md)，不代表用户实例已验证。 |
| D03：分阶段监控配置 | [MonitoringTabView.swift](../Sources/CPAQuotaUI/MonitoringTabView.swift) 按服务验证、授权来源/账号、范围与开始组织内容；从服务授权清单选择安全别名，CPA 清单不被当作监控授权。远端状态、本机显示与最近确认时间分别展示，高级诊断和恢复记录仍可达。 | 能力与工作区回归覆盖无效配置、撤权、容量、旧服务和原会话停止。`lastConfirmedAt` 是客户端最近收到会话或取消确认的时间，不是额度观察时间或设备送达时间。本机关闭和远端停止保持独立。 |
| D04：首次进入与统一入口 | [CPAQuotaRootView.swift](../Sources/CPAQuotaUI/CPAQuotaRootView.swift) 为未配置工作区显示功能说明和统一“连接 CPA 服务”入口，共用一份连接表单；监控保留独立连接。页面名称遵循 [编辑准则](COPY_STYLE.md)，五个原生工作区及各自导航历史保留。 | 会话取消回归与 [原生 UI 用例](../Apple/CPAQuotaAppUITests/CPAQuotaAppUITests.swift) 承担入口、关闭和导航验收。未执行的系统手势、VoiceOver、iPad/横屏与最大动态字体不能由源码审阅替代。 |

## 合并与发布前仍需完成

公开文案、源布局和差异检查已完成；仍须核对新 PR 准确候选提交对应的 Go、Swift、原生 UI 与构建结果。若 CI 没有启动，应保留未执行原因和 Draft 状态，不用历史成功记录补位。

最低 iOS 17、真实设备的系统活动、APNs sandbox/production、令牌轮换、离线/强退/到期、真实 Keychain、签名安装、辅助功能、性能及服务部署兼容性继续按 [发布与合并门禁](RELEASE_GATES.md) 留存证据。用户实例的 CAP 保留范围、Nginx 配置和真实上游读取也需要部署验收。

服务端强制分支保护和将来的历史安全回收是明确保留的外部配置或后续协议工作。本轮源码与文档没有将这些边界写成已启用、已发布或已验收。
