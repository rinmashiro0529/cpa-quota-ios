# 后端交付与验证记录

本文已泛化环境标识；原始日志与归档仅存原验证环境，表中日志名不是公开下载入口。

验证日期为 **2026-10-25**。本轮交付是 `CPAQuotaKit` 原生后端包与 SwiftUI 可观察状态层，不是完整 App 或新服务器；没有 View、IPA 或生产部署。

GitHub 仓库随源码提供经过检查的脱敏 JSON 验证摘要；下文引用的原始 `.log` 日志与 `.tar` 构建源归档保留在原开发环境，不随仓库上传。后续 `.md` 与 Git 配置变更没有改变下述 Swift 编译输入。

## 当前验证结果

| 项目 | 实际结果 | 证据 |
| --- | --- | --- |
| 历史 Linux 构建环境 Swift 6 严格编译 | 通过，源码启用 warnings-as-errors | `artifacts/native-tests.log` |
| 原生单元测试 | **106 项，15 个 suite，全部通过** | 同上；Swift Testing 的最终汇总，不是前面 XCTest 兼容 runner 的 0 项统计 |
| 编排/取消回归重复验证 | 14 项、2 个 suite，连续运行 20 轮，全部通过；未重新编译或降低断言 | `artifacts/review-repeat.log` |
| public Interface 接入 | 普通 `import CPAQuotaKit` 构造连接、凭据流和 MainActor store 的测试通过 | `Tests/CPAQuotaKitTests/PublicInterfaceTests.swift` |
| Linux 验证 CLI 构建 | 通过 | `artifacts/probe-build.log` |
| iOS arm64 library | 通过，release、最低 iOS 17、iPhoneOS27.1 SDK | `artifacts/ios-device-build.log` |
| iOS arm64 Simulator library | 通过，release、最低 iOS 17、iPhoneSimulator27.1 SDK | `artifacts/ios-simulator-build.log` |
| Mach-O 独立检查 | 两种产物均为 arm64；LC_BUILD_VERSION 平台分别为 2（iOS）和 7（模拟器），SDK 27.1，最低系统 17.0 | `artifacts/build-verification.json` |
| 真实 CPA 的 Swift 查询 | 4 个账号，3 个启用账号全部成功，0 个启用账号失败 | `artifacts/live-verification.json` |
| 本机/编译副本一致性 | 21 个 Swift 文件在本机、历史 Linux 构建环境与最终构建源归档中的哈希全部一致 | `artifacts/source-audit.json` |
| 凭据/签名材料检查 | 生成目录及日志/源代码归档未发现实际管理密钥；没有 p12、mobileprovision、IPA、key.txt 或 .env 文件 | 同上 |

最终 Swift 源码集合的校验摘要为 `5464461e8c1524db795cf476deafb2f3be22c02458e32915e37bd2b0a39a2443`，对应成功构建源归档 `source-20261025-221119.tar`，归档 SHA256 为 `8a27db32bf8728cf1b1db12d63e7eef4bf58fcb5937f5e5e8816da91a9add094`。校验范围是 Package.swift 与 Sources/Tests 的 Swift 文件；本验证说明等后续文档不属于编译输入。完整逐文件 manifest 与摘要算法保存在 `artifacts/source-audit.json`。

完整验收通过本机 `tools/Build-NWD.ps1 -Mode All`（历史命令，当前脚本行为已变化）执行。实际远端命令如下，所有编译和 Swift 测试均在历史 Linux 构建环境的既有容器内完成：

```text
swift test -j 2 --scratch-path .build/linux -Xswiftc -warnings-as-errors
swift build -j 2 --scratch-path .build/linux --product cpa-quota-probe -Xswiftc -warnings-as-errors
swift build --build-system native -j 2 --swift-sdk darwin --triple arm64-apple-ios --scratch-path .build/ios-device -c release --target CPAQuotaKit -Xswiftc -warnings-as-errors
swift build --build-system native -j 2 --swift-sdk darwin --triple arm64-apple-ios-simulator --scratch-path .build/ios-simulator -c release --target CPAQuotaKit -Xswiftc -warnings-as-errors
```

完整矩阵通过后，另将 `swift test -j 2 --scratch-path .build/linux --skip-build --filter Review` 重复执行 20 次。日志中有 20 条“14 tests in 2 suites passed”汇总，覆盖旧管理错误恢复、可选能力故障、未来 Retry-After、在途删除、显式取消及取消后立即重载；重复执行不是额外增加 280 种测试，也不等于穷尽所有并发时序。

## 实服验收

| Provider | 账号数 | 启用 | 成功 | 归一化结果 |
| --- | ---: | ---: | ---: | --- |
| Codex | 2 | 2 | 2 | 合计 4 个额度窗口 |
| freetier | 1 | 1 | 1 | 4 个摘要指标，正确支持没有窗口的响应 |
| xAI | 1 | 0 | 0 | 正确返回 accountDisabled，未向上游查询 |

实服验收运行的是历史 Linux 构建环境中实际编译的 `cpa-quota-probe`，不是前序 Python 调研探针。管理密钥通过加密 SSH 标准输入传递，未进入 argv、环境变量或远端凭据文件，并为该探针进程禁用了 core dump。输出与证据仅保留 provider、计数和错误类别，没有记录真实账号 ID、邮箱、token、额度余额或完整响应。

实服验收只调用账号读取、额度能力发现、Codex 固定 GET 代理和插件额度 fetch；未做推理探针、OAuth 新登录、强制凭据刷新、额度重置、账号启停或生产配置修改。

## 关键测试覆盖

| 范围 | 已覆盖的行为 |
| --- | --- |
| 地址与密钥 | HTTPS 限制、无 URL 内凭据/query/fragment、反代前缀规范化、非法端口/路径、密钥控制字符与脱敏 |
| 解析与单位 | 双层 api-call JSON、内层 401/429、百分比与剩余 fraction 区分、窗口实际长度、null credits、summary-only、snake/camel、xAI cents |
| 日期 | 纳秒 RFC3339、Z/+08:00、缺失时区拒绝、HTTP-date GMT/UTC 与非法尾部拒绝、Unix 秒、极大值安全、Retry-After |
| 数据身份 | 缺 auth_index 仍可展示、重复账号 ID 拒绝、窗口/指标 ID 唯一、未知 provider 不伪造额度 |
| 网络 | 无共享 cookies/缓存/凭据存储、拒绝重定向、声明长度与流式长度上限、请求前/请求中取消、真实 URLProtocol 错误路径的 timeout/network/cancel 分类及敏感错误描述抑制 |
| 调度 | 同账号请求合并、客户端全局额度请求并发上限 3、实时缓存、force、Retry-After、管理鉴权错误阻止排队请求继续发送、成功重载不清除未来的全局 Retry-After |
| 状态 | 单账号失败隔离、保留最后成功结果、账号删除/凭据替换清理、禁用账号跳过、迟到响应不覆盖新状态、逐账号进度、单行取消/删除不误终止整批、可观察的能力发现 warning、取消后立即新 load |
| 存储 | Memory 凭据更新/移除/按服务器隔离；Linux Keychain 明确不可用而不落盘降级；Apple Keychain 分支经真实 SDK 编译 |

## 实施中出现并解决的问题

首轮原生编译成功，但 79 项测试中 1 项失败。主会话对比了历史 Linux 构建环境的首轮归档与本机 fixture，确认样本漏填 secondary reset 信号而测试仍期待重置时间。已补齐真实合同中存在的信号，原断言未降低。此后测试通过；失败记录保留在 `artifacts/first-native-run.json`，没有将首次失败隐藏成一次通过。

独立源码验收发现有限但极大的 `1e100` 时间数值可能触发 Int 转换 trap，已改为可失败转换并对日期范围做检查。另补充缺失时区、HTTP-date 非 GMT 时区及多余字段拒绝测试，避免把不明时间解释成当前可用数据。

直接使用 SwiftPM 6.4 默认 Swift Build 后端的第一次交叉编译停在 `unable to find platform for 'iphoneos'`，未进入业务源码编译。确认 SDK 已安装后，本项目交叉编译命令明确选择现有 `--build-system native`，没有安装工具或修改 SDK。随后真实 iOS 分支暴露 `CFBoolean?` 隐式转换问题；实现去除了不必要的同步属性与可选 CFBoolean 常量，并按 SDK 明确的非同步默认行为处理。最终两种 Apple 目标均通过。

Keychain 实现也去除了未经证实的 `errSecParam` 静默跳过保护等级路径。更新与重复创建竞争只执行限定的更新/添加流程，其他系统错误明确返回；不通过明文存储或忽略访问保护来伪造保存成功。

补修后的验证过程中还出现两次测试代码编译失败：HTTP 错误夹具使用了可失败的 `URLError.Code(rawValue:)` 构造，以及两处回归断言跨 actor 读取 `capabilityWarning` 时漏写 await。前者改为保留相同 domain/code 的 NSError，后者先 await 到局部值；均未修改生产实现或降低原断言。两次失败均未进入测试执行，最终完整矩阵通过；各阶段实际结果记录在 `artifacts/build-history.json`。

## 已知限制与未执行项

交叉编译的 `--build-system native` 在当前 SwiftPM 中有弃用提示，日志已保留。本轮只用它绕过现有 slim SDK 的默认平台发现问题，没有关闭 Swift 源码 warnings-as-errors。它是构建工具链兼容事项，不是被隐藏的编译错误；未来更换工具链时需重新核对这项命令。

未运行真实 iPhone、iOS Simulator 运行时或 Keychain 实机读写；仅验证了实际 Apple SDK 的编译与目标文件平台。没有签名、安装 App、读取证书密码或使用 p12/mobileprovision。原验证环境中的签名材料目录仅做过文件元数据核查。

xAI 目前只有结构 fixture 测试，没有停用账号的实服额度请求；其他未实现平台明确返回 unsupportedProvider。Codex 使用产品内部 usage 接口，未来字段漂移仍需维护，不宣称所有 CPA 版本/所有 OAuth 平台已经验证。

额度缓存仅在进程内。后台定时刷新、通知、Widget、多设备同步、服务器只读权限隔离、完整 SwiftUI 界面与 App 签名均不在本次实现范围内。CPA 管理密钥仍具有服务器原来的管理权限，本包的只读 Interface 不替代服务器端授权隔离。

## 独立交叉审查

主会话已对传输、凭据和解析的关键约束进行源码验收，并据此补齐边界回归。独立客户端交叉审查随后确认三处边界：缓存中的旧管理错误阻止恢复、可选能力发现的非鉴权故障阻塞账号列表、单账号取消/删除中止整批。历史 Linux 构建环境已在 99 项测试中复现对应 4 个失败用例，记录见 `artifacts/review-regressions-red.json`。

三类缺陷现已完成范围内补修：旧管理阻断错误会绕过缓存重新证明恢复；可选能力发现的非鉴权失败保留有效账号并通过 capabilityWarning 暴露；单行取消/删除只跳过对应行，调用者/全局取消仍取消整批。Store 以自己持有的操作 Task、发布 token 和同步取消注册避免旧请求覆盖立即启动的新读取；实现与回归测试均没有用 sleep/yield 调度让步掩盖问题。

最终 106 项、15 个 suite 的全量测试已包含这些回归和管理 401/403/429、未来 Retry-After、显式整批取消的保护测试，并通过了 20 轮限定回归重复运行。修复后两个 Apple 目标、最终 Swift 实服探针及本机/历史 Linux 构建环境/归档源码一致性也已重新验收通过；上表为最终结果，不再引用旧的 88 项绿色基线。
