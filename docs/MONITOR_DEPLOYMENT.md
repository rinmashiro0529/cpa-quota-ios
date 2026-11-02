# 监控服务离线构建与部署模板

本目录提供独立监控服务的构建入口与手动安装模板；默认不连接网络、不读取实际秘密、不安装、不启动服务。真实部署、反代修改和服务启动需要独立授权；本说明不表示已经部署或完成端到端验收。

## 离线构建

```powershell
python -I -B tools/monitor_ops/build.py --output <仓库外的新目录>
```

安装 Go 1.26 或兼容版本及 gofmt 后执行。入口设置 `GOTOOLCHAIN=local`、`GOWORK=off`、`GOPROXY=off`、`GOSUMDB=off`、`-mod=readonly` 和最多两个 Go 并发，不自动下载；构建静态 Linux amd64 文件 `quota-monitor` 与 `result.json`。目标目录必须不存在或为空，不覆盖原有内容；Go 缓存、模块缓存和临时文件均放在输出目录内。操作者须确保该目录及其父目录的权限或 Windows ACL 不允许其他用户读取或写入；新建目录在支持 POSIX 权限的系统上使用 0700。失败回执也会保留在该目录，须另选新目录。回执包括源文件和二进制 SHA-256、ELF64 小端 amd64 文件头检查、版本与格式检查结果；构建不运行二进制。`gofmt -l` 的原始结果保留，`original_format_gate_passed` 根据退出码和未格式化列表分别记录门禁结果；只有所有 Go 文件的 gofmt 输出与原内容仅将 CRLF 换成 LF 后逐字节一致，才记录 `eol_only=true` 并允许构建；不会修改源码或将原检查描述为通过。完整 vet、测试和 race 验证另见 `tools/test_monitor_backend.py`，构建成功不能替代它们。

## 安装前核对

模板位于 `Services/QuotaMonitor/deploy/`。它们是相互匹配的固定路径示例，不自动渲染或安装；请先检查目标系统的 systemd 版本是否支持 `DynamicUser`、`LoadCredential`、`StateDirectoryMode`、`ProtectProc` 和对应资源限制，检查目标路径是否空闲、现有反代配置与端口是否冲突。禁止覆盖其他服务的文件、密钥或配置，先制定可恢复的备份与回退方案。资源限制需结合实际负载评估。

获得部署授权后，由具有 root 权限的操作者手动完成以下步骤，不要将实际秘密或配置写入仓库、命令历史、终端输出或日志。

1. 将构建产物放到 `/usr/local/bin/quota-monitor`，将 `quota-monitor-start` 放到 `/usr/local/libexec/quota-monitor-start` 并赋予 root 所有、不可由其他用户写入的可执行权限；先核对二进制 SHA-256 与回执一致。包装器把 systemd 凭据读入进程环境，注意有权限检查进程环境的管理员仍可能读取秘密。
2. 创建 root 所有的 `/etc/quota-monitor` 及 `credentials`，权限分别为 0700；将 `config.placeholder.json` 复制为其中 `config.json`，设为 root 所有 0600，按 `docs/MONITOR_SERVICE.md` 填写实际授权来源、账号、principal 和 APNs 字段，保持监听 `127.0.0.1:8787` 及状态路径 `/var/lib/quota-monitor/state.enc`。该配置只存环境变量名称，不存秘密；systemd 将其作为 `config` 凭据复制给动态用户，包装器从凭据目录读取它，而不直接读取 root 私有配置目录。模板不包含可用生产账号。
3. 创建 root 所有 0600 的 `/etc/quota-monitor/monitor.env`，可为空；它是 systemd EnvironmentFile，只供非秘密的环境设置，不要用它存秘密或覆盖包装器约定的变量。分别由操作者安全提供 root 所有 0600 的 `credentials/state-key`、`credentials/cpa-key`、`credentials/bridge-token`、`credentials/apns-key`，即使 dry-run 也须存在 `apns-key` 文件，可为空。state-key 是标准 Base64 编码的 32 字节密钥；APNs 文件是 PEM 内容而非路径。其他秘密长度与格式见服务文档；不要以示例值当作生产秘密。
4. 审阅 `quota-monitor.service` 并手动安装到 systemd 单元目录；`StateDirectory=quota-monitor` 由 systemd 创建并管控 0700 状态目录。确认状态密钥稳定且有受保护的备份；现有状态不得删除以绕过解密或容量问题。
5. 反代模板二选一，不要同时启用：共享 TLS 站点优先审阅 `nginx-prefix-location.conf`，在确认 `/quota-monitor/` 尚未被占用后加入既有 server；`proxy_pass` 的尾部斜杠将此前缀剥离后再交给服务，客户端基础地址须包含 `/quota-monitor`。或者仅在独立专用站点审阅 `nginx-location.conf`，其 `location /` 接管该站点的根路由，绝不可直接放进共享 CPA 站点。确认其他精确或正则 location 不改变预期路由，不覆盖现有 CPA 路由。域名、TLS、网络访问控制和上游端口由操作者配置；不要暴露 loopback 服务端口。
6. 安装和启动前由操作者分别检查 systemd 和 Nginx 配置，再按目标系统的受控变更流程加载并启用；任何失败先停止，检查日志时不得泄露秘密。不要假定这些步骤可在未获授权的生产环境执行。

凭据文件使用 UTF-8、无 BOM。state-key、cpa-key 和 bridge-token 各为一行，不包含 CR 或额外空白；APNs 私钥使用正常 LF 换行的 PEM。包装器不猜测编码或修改密钥，格式错误应修正输入后受控重启，不得通过重置上游凭据绕过。

## 运行后验收与回退

确认服务就绪后，通过可信 HTTPS 路径检查 `/healthz` 为 200；不带 Bearer 请求受保护资源应为 401；使用有权访问的 principal 查询尚无缓存的 source quota 应为 404；该 principal 查询未获授权的其他来源应为 403。这里的跨来源是授权范围检查，不是浏览器 CORS 检查。检查时不要在命令行、历史、日志或报告中暴露 token，也不要制造 ActivityKit push token。已有缓存或授权配置不同会改变预期，应先确认前置条件。

反代配置热加载后应等待并轮询健康检查直到就绪或超时，不要立即断言成功；服务配置或凭据更改需受控重启，不支持假设热更新。`dry_run=true` 只禁止 APNs 投递，存在有效活动时仍可能采集 CPA；不要通过注册伪造活动验证。真实设备、CPA、APNs、Linux 实机及热加载行为均需另行授权和实际验收。

回退应恢复事先验证的原反代与单元配置，按受控流程重新加载并检查健康；保留加密状态与密钥，不擅自删除数据。状态格式升级与回退兼容性见 `docs/MONITOR_SERVICE.md`，不要将旧二进制直接指向不兼容的新状态。
