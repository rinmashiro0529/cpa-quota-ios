# CPA Quota

CPA Quota 是连接个人 CPA 服务、只读查看账号额度的原生 iOS 客户端，并提供可选的独立 Go 监控服务。

## 功能

- 查看 CPA 已有账号及额度窗口、重置时间和最近查询结果；读取失败时保留并标注上次成功结果。
- 查看 CAP 用量和账号诊断，管理连接与本机偏好。
- 使用系统小组件和实时活动；小组件共享默认关闭，系统活动显示首个账号和其他账号数量，不承诺后台自动轮播。
- 可选地连接独立监控服务；服务需要另行配置、运行与授权。

当前界面为中文。应用只读查询，不登录上游 OAuth，也不修改账号、配置或重置额度。

## 要求

- iOS 17 或更高版本；macOS 14 或更高版本可用于支持的 Swift 包开发。最低系统真机兼容性尚未验收。
- 使用 Swift 6 和 Xcode 构建原生 App；独立监控服务需要 Go 1.26 或兼容工具链。
- 已获授权的 CPA HTTPS 地址及管理密钥；管理密钥不同于普通推理 API Key。

## 构建与连接

1. 克隆仓库，在 macOS 上用 Xcode 打开 `Apple/CPAQuota.xcodeproj`。
2. 选择共享方案 `CPAQuota` 和 iPhone 模拟器，然后运行。模拟器运行不等于真实设备、Keychain 或 APNs 验收。
3. 如需在真机安装，参照 [iOS 构建和签名指南](docs/NWD_IPA_BUILD.md) 为 App 与扩展配置团队、签名和所需能力。Linux/Darwin SDK 交叉编译的未签名 IPA 不是可直接安装的已签名版本。
4. 在连接管理中填写 CPA HTTPS 地址和管理密钥，验证连接后查看服务中已有账号及额度。管理凭据保存在设备 Keychain；不要提交真实凭据或生产配置。
5. 可按需开启小组件共享；实时活动的能力配置、账号选择和排障参见 [实时活动指南](docs/LIVE_ACTIVITY_SETUP.md)。签名、真实设备及 APNs 送达仍须独立验收。

## 可选监控服务

[部署指南](docs/MONITOR_DEPLOYMENT.md) 说明独立 Go 服务的离线构建、配置与受控部署；[服务合同](docs/MONITOR_SERVICE.md) 描述授权、容量、取消和持久化。监控访问令牌与 CPA 管理密钥分别配置。`dry_run=true` 禁止 APNs 发送，但有活动时仍可能采集 CPA，不能视为完全离线。结束本机显示不等于服务端监控已停止。

## 项目结构

| 路径 | 用途 |
| --- | --- |
| `Sources/CPAQuotaKit/` | 只读网络、额度、CAP、凭据与状态 |
| `Sources/CPAQuotaUI/` | 会话与 SwiftUI 界面 |
| `Sources/CPAQuotaActivity/`、`Apple/CPAQuotaActivityExtension/` | 实时活动与小组件 |
| `Sources/CPAQuotaApp/`、`Apple/CPAQuota.xcodeproj` | App 入口与原生工程 |
| `Services/QuotaMonitor/` | 可选的独立 Go 监控服务 |
| `Tests/`、`Apple/CPAQuotaAppUITests/`、`tools/tests/` | 合同、模型、原生 UI 与工具回归 |

## 测试与已知限制

```powershell
python -I -X utf8 -B ci/validate_source_layout.py --root .
python -I -X utf8 -B ci/test_source_layout.py
python -I -X utf8 -B ci/test_activity_extension.py
python -I -B -m unittest discover -s tools/tests -p "test_*.py"
go -C Services/QuotaMonitor test ./...
go -C Services/QuotaMonitor vet ./...
```

当前提交的 CI 结果以对应 [GitHub Actions](https://github.com/rinmashiro0529/cpa-quota-ios/actions) 运行记录为准。历史成功不代表当前提交通过；main `1f782ca` 的 Go 检查曾失败及重跑后 race 阶段失败。模拟器和离线测试不能代替真实 CPA、签名、Keychain、真机与 APNs 验收。截图须来自真实运行并经隐私核验，当前尚待提供。

## 安全、贡献与许可

请阅读 [安全政策](SECURITY.md)、[贡献指南](CONTRIBUTING.md) 和 [MIT 许可证](LICENSE)。公开前未完成的私密报告渠道、扫描、附件和素材权属等门禁见 [公开准备检查表](docs/OPEN_SOURCE_READINESS.md)。

## 文档

**当前指南**：[状态与验证](docs/MAIN_INTEGRATION_STATUS.md) · [构建和签名](docs/NWD_IPA_BUILD.md) · [实时活动](docs/LIVE_ACTIVITY_SETUP.md) · [监控部署](docs/MONITOR_DEPLOYMENT.md) · [前端接入](docs/FRONTEND_INTEGRATION.md) · [CAP 用量](docs/CAP_USAGE_BACKEND.md) · [Swift 监控](docs/MONITORING_SWIFT_BACKEND.md) · [桥接凭据](docs/MONITOR_BRIDGE_CREDENTIALS.md) · [监控服务](docs/MONITOR_SERVICE.md) · [文案准则](docs/COPY_STYLE.md)。

**历史开发记录**：以下文件记录特定时期的需求和验证，不代表当前提交的测试结果：[前端需求](FRONTEND_PROMPT.md) · [后端上下文](docs/BACKEND_CONTEXT.md) · [后端可靠性](docs/BACKEND_RELIABILITY_PR.md) · [后端验证](docs/BACKEND_VERIFICATION.md) · [前端审计](docs/FRONTEND_PR3_AUDIT.md) · [集成验证](docs/INTEGRATION_VERIFICATION.md) · [前端实现](docs/NATIVE_FRONTEND_IMPLEMENTATION.md) · [早期验证](docs/VERIFICATION.md)。
