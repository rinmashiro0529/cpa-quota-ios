# AI 对话指南与安全边界

「AI 对话」工作区（`Sources/CPAQuotaChat/` 与 `Sources/CPAQuotaUI/Chat/`）允许在已连接的 CPA 服务上直接与模型对话。与只读查询的额度、CAP 用量和账号诊断不同，**AI 对话会向 CPA 发送对话内容与图片并消耗上游额度**；开启联网搜索时，还会将消息正文发送给所选第三方搜索服务。

## 前置条件与凭据

AI 对话使用 **CPA 客户端 API Key**，与用于额度查询的 **CPA 管理密钥** 相互独立：

1. 在「连接管理」中先完成 CPA 服务连接。
2. 进入「AI 对话 › 对话设置 › API Key」：
   - **自动发现**：若已保存 CPA 管理密钥，应用会通过 `GET /v0/management/api-keys` 读取服务端配置的客户端 API Key 列表；若该接口返回 `404` 或 `501`，自动回退至 `GET /v8/management/config/access/api-keys`，供选择其中一把用于本机对话。
   - **手动填写**：也可直接填写客户端 API Key（不能包含换行等控制字符）。
3. 凭据存储与隔离：
   - 客户端 API Key 与第三方搜索 API Key 保存在设备 Keychain 的 `CPAQuotaKit.ChatCredentials` 服务下（`WhenUnlockedThisDeviceOnly`，不启用 iCloud 同步，不与管理密钥共享存储服务名）。
   - 客户端 API Key 按 CPA 服务标识隔离（账号名 `client-api-key|<server.identifier>`）；第三方搜索 API Key 全局共用（账号名 `search-key|<provider>`），不随 CPA 连接切换而隔离。

## 模型目录、推理路由与思考等级

- **模型目录**：通过 `GET /v1/models` 读取当前 CPA 暴露的模型列表；新对话可在「对话设置」中选择「沿用上次选择」或「固定指定模型」。
- **推理协议与回退**：
  - 针对 Claude / Anthropic 系列模型，应用优先使用 Anthropic Messages 协议请求 `{server}/v1/messages`（鉴权头为 `x-api-key`）；当服务端返回 `401`、`404`、`405` 或 `501` 时，自动回退至 OpenAI 兼容的 `POST /v1/chat/completions`（鉴权头为 `Authorization: Bearer ...`）。不会在 `200` 响应解码失败时盲目回退，以免重复计费。
  - 其他模型默认经 `POST /v1/chat/completions`（OpenAI 兼容、SSE 流式）推理。
  - **反向代理 / ACL 提示**：若反代层按路径放行推理接口，使用 Claude 模型时请同时确认 `/v1/messages`（及 `x-api-key` 头）与 `/v1/chat/completions` 的策略。
- **思考等级与兼容降级**：输入框旁的「思考等级」支持「自动」及多档强度选择，发送时会按目标协议映射为 `output_config.effort`、`thinking.budget_tokens` 或 `reasoning_effort`；若上游返回参数校验拒绝（`400` / `422` 或对应错误事件），会按兼容策略降级或省略并记录实际生效状态。
- **中断与一键续写**：生成被手动停止、网络中断、流异常断开或后台超时中断时，保留已生成内容，可在输入框一键续写并追踪单次回复的多次尝试记录；跨服务器继续既有对话前会要求确认目标服务。

## 规则、记忆与斜杠技能

- **提示词组装顺序**：发送时依次附加「全局规则 → 启用的记忆 → 本对话设定」，再附带受长度边界约束的历史消息、当前消息正文及图片附件（以 base64 Data URL 形式随推理请求发送给 CPA）。
- **记忆**：可在「对话设置」开关「使用记忆」，或长按消息选择「加入记忆」、在「记忆」列表置顶/编辑/删除。全局规则与记忆作用于所有已连接的 CPA 服务；切换服务时如不希望附带，请先关闭「使用记忆」。
- **斜杠技能**：在输入框键入 `/命令名`（如 `/translate 你好`）触发；命令名不含空格，保存时自动转为小写，技能提示词会前置在用户内容之前发送。

## 联网搜索与外发数据边界

联网搜索默认关闭，需在「对话设置 › 联网搜索」中选择服务并保存对应搜索 API Key，随后在对话中按需开启。

- **支持的第三方搜索服务**：Tavily（`https://api.tavily.com/search`）、Brave、Exa、Serper、SerpAPI（`https://serpapi.com/search.json`）。
- **实际外发内容**：开启联网搜索后，**去掉斜杠技能命令后的整条用户消息正文**会作为搜索查询发送给所选第三方搜索服务（最多取 5 条结果注入上下文）。不要在开启联网搜索的消息中输入不希望发往第三方搜索服务商的私密信息。
- **SerpAPI 特别说明**：SerpAPI 接口要求通过 URL 查询参数（`api_key`）传递密钥，该密钥可能出现在中间代理或服务端访问日志中。

## HTML 代码块静态预览隔离边界

当助手回复包含完整 HTML 代码块时，应用提供「HTML 片段」预览页（`Sources/CPAQuotaUI/Chat/IsolatedChatHTMLWebView.swift`）：

- **系统要求**：静态预览需要 **iOS 18.4 及以上**系统；低于 iOS 18.4 时自动回退为仅展示源码与复制按钮。
- **隔离措施**：
  - 使用非持久 `WKWebsiteDataStore.nonPersistent()`；
  - 禁用内容 JavaScript（`allowsContentJavaScript = false`）并禁止脚本自动开窗；
  - 禁用数据探测器（`dataDetectorTypes = []`）；
  - 注入阻止全部 URL 的 `WKContentRuleList`（`{"trigger":{"url-filter":".*"},"action":{"type":"block"}}`）；
  - 注入 CSP `default-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'` 及 `x-dns-prefetch-control: off`，并以 `baseURL: nil` 载入。
- 该隔离仅用于静态预览，不等同于形式化浏览器沙箱审计；如不信任代码内容，可切换到「源码」视图检查。

## 本机持久化、后台继续与清除边界

- **文件存储布局**（`ChatFilePersistence`）：
  - 每段对话单独存为 `Conversations/<UUID>.json`，摘要索引位于 `Conversations/index.json`（按需懒加载，避免启动全量解码）；
  - 图片附件外置存储在 `Attachments/` 目录下，对话 JSON 中仅引用经文件名安全校验的外部文件名；
  - 设置、记忆与技能分别保存于 `settings.json`、`memories.json`、`skills.json`；
  - 写入采用原子落盘，在支持平台上启用文件保护并设置排除备份。
- **后台继续生成与本地通知**：应用退到后台后，系统通常仅允许继续生成约 30 秒；超时会保存已生成内容并标记为中断。若已授权通知且开启「后台完成时通知」，完成后会发送固定脱敏文案（「AI 对话已完成 / 回复已生成，打开应用查看。」），不在锁屏泄露对话标题或消息正文。
- **清除边界（重要）**：
  - 在「连接管理」中执行「忘记连接」只移除当前服务的 CPA 管理密钥和该服务的客户端 API Key，**不会删除本机保存的对话 JSON、图片附件、记忆、技能或第三方搜索 API Key**；
  - 即使登录 CPA 时选择不记住连接，发起对话后对话数据仍会写入本机磁盘；
  - 如需清理对话记录，请在「对话设置」中使用「删除全部对话」（保留记忆与技能），或分别删除记忆、技能与搜索 Key。
