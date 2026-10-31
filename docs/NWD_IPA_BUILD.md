# Rin，iOS 构建和签名

Rin，本仓库提供离线源码准备、显式 Linux 本地构建及 App/Widget 结构检查。新通用入口已在既有 NWD 的 Swift 6.4.1、iPhoneOS27.1 SDK 环境完成一次真实构建，产出未签名的主 App 与扩展，并核对 frontend、linker、SDK 配置和源文件前后摘要；这不等于所有工具版本组合都已兼容。准备、预检和结构检查不会联网、编译、签名、安装或访问设备；只有显式调用 `build` 才会启动本地 xtool 和 Swift。本轮没有使用新入口签名或进行真机验收。

## Rin，准备隔离源码

Rin，使用 Python 3，在源码树之外选择一个尚不存在的输出目录；父目录必须存在。此操作只复制 `Package.swift`、`Sources`、`Tests`、`Apple`，并在副本中配置 xtool 的 App 和 Widget 扩展产品及场景元数据；原始源码不修改。输入必须是可信、静止的源码目录，不支持直接解压外部归档；禁止在复制期间并发修改它。输出已存在、输入含符号链接或敏感文件名时会拒绝。失败时输出目录可能保留部分结果，检查后由操作者决定如何处理，不会自动删除或覆盖。

```powershell
python -I tools/ios_build/nwd.py prepare --source . --output C:/work/cpa-derived
# 或 Windows PowerShell：
./tools/Build-NWD.ps1 -Output C:/work/cpa-derived
```

Rin，原 `Build-NWD.ps1` 的固定远端上传和仅编译 CPAQuotaKit 行为已移除；它现在仅准备源码。此准备结果本身不是 IPA，也不能证明 xtool 的构建链或签名配置可用。

## Rin，离线 SDK 配置预检

```powershell
python -I tools/ios_build/nwd.py sdk-preflight --sdk-root C:/sdk/Developer/iPhoneOS27.1.sdk --swift-sdk-json C:/sdk/swift-sdk.json --sdk-version 27.1
```

Rin，SDK root、Swift SDK 配置和版本都必须明确指定。此预检按 Swift SDK schema 4.0 检查 `arm64-apple-ios` 的相对 `sdkRootPath`、bundle 内 toolset 文件，以及 SDKSettings 的 Version 和 CanonicalName；两个 settings 文件同时存在时均需一致。路径仅是示例，应替换为实际本机路径。检查通过仍返回 `actual_build_inputs_verified: false`：它不启动编译，也不能证明之后的编译进程实际使用了这些输入。

## Rin，检查已有未签名 App

```powershell
python -I tools/ios_build/nwd.py verify --app C:/work/CPAQuota.app --minimum-ios 17.0 --sdk-version 27.1
```

Rin，此命令检查 App 与指定 Widget 扩展的 bundle 标识、扩展点、arm64 iOS Mach-O 类型、最小系统、SDK 版本字段、框架引用、场景元数据和隐私文件存在性。`--sdk-version` 只用于比对产物中的版本字段，**不是 SDK 输入证明**，也不会修改二进制；结果明确标记 `sdk_provenance_verified: false`。该命令不验证签名、profile、图标内容或隐私清单的语义，也不是设备验收。

Rin，Linux 构建入口在启动前核对显式 SDK root 的 `SDKSettings.json` 版本及 CanonicalName、Swift SDK 配置中的目标与路径，在构建日志中要求 App 与扩展分别出现匹配的 frontend `-sdk`、目标 SDK 版本和 linker 参数，并比较 SDK 配置及 toolset 的构建前后摘要；最后检查两个产物。上述检查只是工具输入一致性证据，不是密码学供应链认证；仅检查 Mach-O 的 `LC_BUILD_VERSION` 不能排除其他 SDK 被标记为较新版本。资源须由可信 Apple 工具链编译，不要从未知 IPA 复用图标或私自修改 Mach-O 头。

## Rin，显式 Linux 本地构建

Rin，先使用上面的 `prepare` 生成隔离源码，再在独立目录准备可信编译资源 `Assets.car`、`AppIcon60x60@2x.png`、`AppIcon76x76@2x~ipad.png` 和 `IconInfo.plist`；后者包含 `CFBundleIcons` 与 `CFBundleIcons~ipad` 两个字典。`manifest.json` 的 `source_assets_sha256` 使用下述命令的值，`files` 包含上述四个文件名到 SHA-256 小写十六进制摘要的映射。操作者必须独立确认资源确由对应资产源码可信编译；摘要只能检查一致性，不能证明来源。

```sh
python3 -I tools/ios_build/nwd.py assets-digest --assets /work/derived/Apple/Assets.xcassets
sha256sum /work/resources/Assets.car /work/resources/AppIcon60x60@2x.png /work/resources/AppIcon76x76@2x~ipad.png /work/resources/IconInfo.plist
python3 -I tools/ios_build/nwd.py build --derived /work/derived --output /work/new-output --resources /work/resources --sdk-root /path/to/iPhoneOS27.1.sdk --swift-sdk-json /path/to/darwin.artifactbundle/swift-sdk.json --swift-sdk darwin --minimum-ios 17.0 --sdk-version 27.1 --swift /usr/bin/swift --xtool /usr/bin/xtool
```

Rin，示例路径必须替换为当前环境实际路径；输出目录必须不存在，且不得与输入目录重叠。构建失败保留日志及部分输出，重试前需检查并选择新的目录；工具不会删除目录。构建会在派生树生成 `.build` 与 `xtool`，不可在包含旧构建输出的派生树上重试。Swift SDK 选择器必须由实际编译日志证明与显式 SDK root 一致；SDK 27 及以上要求 Swift 6.4 或更新版本。工具保留指定的 Swift 路径用于执行，并分别记录其真实路径和版本；构建前后比对业务源码清单，默认超时 1800 秒，可用 `--timeout` 修改，超时只结束本次构建进程组。`build.log`、`shim.json`、`result.json` 及未签名 IPA 保存在输出目录；日志可能包含本机路径，公开前应检查。输出不包含签名或设备验收结论。

Rin，`manifest.json` 结构示例如下，实际摘要须自行填入；不能直接使用占位内容。

```json
{
  "source_assets_sha256": "<资产源码清单摘要>",
  "files": {
    "Assets.car": "<sha256>",
    "AppIcon60x60@2x.png": "<sha256>",
    "AppIcon76x76@2x~ipad.png": "<sha256>",
    "IconInfo.plist": "<sha256>"
  }
}
```

Rin，实测环境为 xtool1.23.0；现有 LLD 输出了 iOS 平台支持警告，SwiftPM native 后端也有弃用提示。构建及输入一致性检查通过不消除这些风险，日志保留警告，没有升级共享工具、抑制错误或修改二进制头；签名、设备安装和实际运行仍需单独验收。

## Rin，Xcode 双 bundle 签名与导出

Rin，在 macOS 上使用已安装且支持目标 SDK 的 Xcode，打开 `Apple/CPAQuota.xcodeproj`，选择共享 scheme `CPAQuota` 和 Generic iOS Device。项目包含主 App `icu.nahida.cpaquota` 和嵌入的 Widget `icu.nahida.cpaquota.activity`。在 Apple Developer 账户中为两个 identifier 分别配置所需 capability、证书和 provisioning profile；在 Xcode 的两个 target 的 Signing & Capabilities 中选择团队及匹配的签名方式。Profile、证书、私钥和导出选项必须保存在仓库外，且不得提交。

Rin，使用 Xcode 的 Product > Archive 构建，再在 Organizer 中按目标分发方式导出，确认两个 bundle 的签名和 profile 均匹配。也可使用本机 Xcode 的 `xcodebuild archive` 和 `xcodebuild -exportArchive`：分别传入项目、scheme、独立 archive 路径，以及仓库外的导出选项 plist；手动签名时该 plist 的 `provisioningProfiles` 必须分别映射两个 bundle identifier。可用导出方法和键以本机 `xcodebuild -help` 为准。不要将私钥、profile 或账户数据放进命令日志、报告或仓库。

Rin，Linux 自定义签名及嵌套签名独立验证不由本仓库提供。旧流程依赖额外加密库、专用签名/验签实现与具体环境，不能当成自包含入口；若未来实现，必须分别校验证书链、两个 profile 与 entitlement 匹配、嵌套签名及最终包完整性，再进行授权设备验证。Xcode 流程本次未在此环境运行，签名、安装、Widget、Live Activities 和 APNs 均未在真机验收。
