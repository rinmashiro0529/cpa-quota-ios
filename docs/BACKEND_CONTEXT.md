# 后端开发上下文

> **历史记录**：首次提交 2026-10-25（`fd9c6c2`）；本文可能包含后续补充，仅反映所述时期及版本，测试结果不代表当前提交。当前入口见 [README](../README.md)。

本文为公开资料泛化版本；原始私有路径、主机标识和记录仅存原验证环境，历史结论和验证边界不变。

本资料在开始 Swift 实现前收集，日期为 2026-10-25。原始完整 CPA 调研仅存于原验证环境；本工程不复制其中的账号身份或任何凭据。

## CPA 第一手合同

| 项目 | 已确认事实 |
| --- | --- |
| 实例 | 历史实例，CLIProxyAPIPlus `v7.3.12-3-plus`，commit `8f22abcb` |
| 来源 | 历史实例源码 HEAD `8f22abcbc089051073167882157556a90a753c0a`、部署 `management.html`、实际 HTTP 观察 |
| 账号 | 调研时两个启用 Codex、一个停用 xAI、一个启用 freetier 插件账号 |
| 鉴权 | 管理 Bearer key，不是普通推理 API Key；同 IP 5 次失败可能封禁约 30 分钟 |
| 列表 | `GET /v0/management/auth-files`，根对象 `files` + `observed_at` |
| 插件能力 | `GET /v0/management/quota/providers`；不是所有内置额度读取器的完整目录 |
| 插件查询 | `POST /v0/management/quota/fetch`，请求 `auth_index`，可返回仅 summary、没有 groups 的合法结果 |
| Codex 查询 | `POST /v0/management/api-call` 代理固定 GET `https://chatgpt.com/backend-api/wham/usage`，内层 `$TOKEN$` 在 CPA 替换 |
| Codex 包装 | 外层 HTTP 200 不代表上游成功；检查 status_code，再解码字符串 body |
| xAI | 部署管理页固定 GET `https://cli-chat-proxy.grok.com/v1/billing`，config 金额使用 cents；账号停用，不能声称线上通过 |

来源代码为 `internal/api/server_management.go`、`internal/api/handlers/management/{auth_files.go,api_tools.go,plugin_quota.go}`、`sdk/pluginapi/types.go`，以及独立挂载的管理页面。已有调研把源码行号、私有部署细节和脱敏实测分开记录。

必须保留的差异包括：被动观察时间与列表时间不同；信号可能是字符串、真实响应可能是数值/布尔；Codex 返回已用百分比和窗口秒数；插件返回剩余 fraction 与自定义指标；nullable credits 不等于零。Codex 计划名不能决定窗口长度，quota/provider 标记缺省也不能直接判定 Codex 不支持。

## 本机与 nwd 编译约定

| 项目 | 证据/结果 |
| --- | --- |
| 参考工程 | 原验证环境中的参考工程 |
| 本轮参考计划 | 参考工程的历史计划，Package.swift、xtool.yml 及相关开发记录 |
| 状态模式 | 参考工程的对应源码第 6–7 行使用 `@MainActor @Observable` |
| SSH | 本机 SSH 配置指向已有开发主机；未改 SSH 配置 |
| 容器 | 历史构建容器，`swift:6.4.1-noble`；实际执行 `swift --version` 为 6.4.1 |
| 资源 | 现有容器 3 GiB、2 CPU；构建脚本进一步 `-j 2` |
| 挂载 | 使用工作目录、home 和 Xcode 资源的独立挂载 |
| SDK | `swift sdk list` 返回 darwin，配置包含 iPhoneOS27.1.sdk 与 iPhoneSimulator27.1.sdk |
| 现有工具 | xtool 1.23.0；本轮库编译不需要调用其 App 打包流程 |
| 新工程 | 本机和构建主机使用独立工程目录，不复用/覆盖参考 App |

参考项目使用过 `xtool dev build -c release --ipa` 与后续独立 ad hoc 签名，但本轮只交付库。因此采用 `swift test` 和 `swift build --build-system native --swift-sdk darwin --triple ... --target CPAQuotaKit`，不新增无意义的 App 壳来制造 IPA。SwiftPM 6.4 默认 Swift Build 后端在这套 slim SDK 上无法发现 iphoneos；native 后端可进入真实 SDK 编译，但带工具链弃用提示，已记录且未修改系统 SDK。

Keychain 属性还直接核查了已安装 iPhoneOS27.1 SDK 的 `Security.framework/Headers/SecItem.h:179-189,219-246,1231-1245`：非同步是省略 synchronizable 键时的默认行为；ThisDeviceOnly 与同步属性存在组合限制；更新只允许真实属性，未得到“iOS 一律禁止更新 accessible”的证据。实现不采用跳过保护等级的 errSecParam 静默兼容分支。

原验证环境中的签名材料目录仅检查到 p12、mobileprovision 和 key.txt 存在，没有读取密码、私钥或描述文件内容，没有复制到本项目或构建主机。iOS Keychain 默认使用未来宿主 App 的签名隔离，不设置额外 access group，也不修改现有 Keychain。

参考工程配置之外，还从仅存原验证环境的历史会话记录中提取了构建命令，未复制完整会话或秘密值；参考计划的环境段为第 15–18 行、容器段为第 29–30 行，Package.swift 的平台段为第 7–10 行。历史记录只作为线索，当前工具版本、容器挂载和 SDK 配置均经实际只读核查。

资料收集时曾误读参考工程 `signing/adhoc-entitlements.plist`，超出当时规定的目录限制。它是 App 标识与 entitlement 元数据，不是私钥或密码；未记录其字段值、未复制到新工程，也未读取同目录 p12、密码或 mobileprovision。该越界读取已如实记录，不能将其当作额外权限授权。

## 文档核查

| 来源 | 结果 |
| --- | --- |
| [SwiftPM PackageDescription](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html) | 已查阅，核查 library、executable/test target、平台与资源约定 |
| [Apple Keychain data protection](https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web) | 前序调研已核查；本轮默认解锁可用且 ThisDeviceOnly，不承诺锁屏后台读取 |
| Apple Observation 文档页 | 当时未获取可用正文；以现有源码模式与真实 SDK 构建核实 |
| [Codex usage/pricing](https://developers.openai.com/codex/pricing/) | 前序已核查订阅额度与 API token 费用不同，不能据本地 token 统计计算订阅余额 |

## 实现范围

生产实现全部为 Swift，单元测试也为 Swift；PowerShell/Python 仅用于同步、构建编排和安全启动只读验证，不承担 App 运行时逻辑。本轮支持当前启用账号所需的 Codex/插件合同，并提供 xAI 的结构归一化；其他平台不会被假装成已支持。

没有服务器部署、CPA 配置写入、OAuth 登录、强制 token 刷新、额度重置、推理测试或前端 View。平台 API 漂移、真实 iPhone/Keychain 运行和后台调度是后续集成仍须验证的边界。
