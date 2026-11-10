# SOCKS5 for OHOS

无认证、IPv4-only SOCKS5 客户端。填写服务器 IPv4 地址/域名和端口，点击连接并接受系统 VPN 授权。

## 实现

ArkTS 页面 → VpnExtensionAbility 创建 TUN → C++ NAPI (`libentry.so`) → Go (`libtungo.so`) → `tun2socks.StartFromIO` → 远程 SOCKS5。

复用 shadowsocks_ohos 的 VPN 配置、进程网络保护和动态库加载方式，不包含 Shadowsocks 引擎、本地 SOCKS5 服务器或自定义认证协议。服务器配置保存在应用偏好设置中。

## 当前范围

- 仅无认证 SOCKS5，不支持用户名/密码。
- arm64 OHOS/HarmonyOS 设备，仅转发 IPv4 流量。
- 本地 DNS 固定对 AAAA 查询返回 NOERROR/NODATA，对 A 查询正常转发。TUN 入口只把 IPv4 包交给转发栈，其他地址族丢弃。保留 IPv6 TUN 地址和默认路由仅用于截获流量，避免受 VPN 管理的应用绕行系统 IPv6 网络；这不表示支持 IPv6 转发。
- TCP 和 UDP 使用 go-tun2socks。VPN DNS 地址为 8.8.8.8 / 8.8.4.4，TUN 内 UDP/53 通过其现有 tunDNS 钩子进入本地 DNS 转接器，再经 SOCKS5 CONNECT 查询 8.8.8.8:53/TCP，不直接向公网发送 DNS。
- DNS 不再依赖代理的 UDP 数据转发。普通 IPv4 UDP（包括 QUIC）仍需服务器支持 UDP ASSOCIATE 及可用中继端口。
- “VPN 已启动”表示 TUN 和转发引擎启动成功，不是远端连通性检测结果。连接日志显示 Go 转发错误。
- SOCKS5 本身不提供加密，请使用可信网络和 HTTPS。无认证服务器应限制允许连接的来源。

## 构建

依赖本机相邻源码仓库 ``；路径由 `native/tunengine/go.mod` 的相对 `replace` 指定。构建必须保留本次对该仓库 `tun2socks/tun2socks.go` 的修复及对应测试；shadowsocks_ohos 参考项目未修改。

先构建 Go 动态库，必须使用支持 `openharmony/arm64` 的 Go 工具链，不能用普通 Linux Go 动态库替代：

```sh
OHOS_GO=/tmp/shadowsocks-ohos-go-2417e08/bin/go \
  zsh native/tunengine/build.sh
```

可通过 `OHOS_NDK` 指定 native SDK，默认使用 DevEco Studio 内置 SDK。首次下载依赖需要可访问的 Go 模块代理；本机验证使用 `GOPROXY=https://goproxy.cn`。

```sh
cd native/tunengine
go test ./...
```

然后在 DevEco Studio 构建/运行 entry 模块，或从工程根目录执行：

```sh
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
PATH=/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

产物位于 `entry/build/default/outputs/default/`。安装到设备需要可用的开发签名。

## 验证

2026-09-25：此前的 `ipv4-dns-eof-4` 已在鸿蒙平板的 IPv4 模式下验证 Google 可正常访问，百度出口 IP 也确认经过代理。当前清理版 `ipv4-only-5` 已完成构建，尚未覆盖安装到平板或重新验证联网。

已验证的故障与修复：

- 代理接受 UDP ASSOCIATE，但实际 UDP DNS 查询超时；TCP DNS 查询成功。增加本地 DNS-over-SOCKS5-TCP 转接。
- 上游 dnsReq 仅处理首个数据报，后续查询无回复。内存 TUN 回归测试在修复前稳定失败，加入循环和连接释放后通过。
- 对同一代理强制访问 Google IPv4 得到 HTTP 200，强制 Google IPv6 则 TLS 失败。当前固定不返回 AAAA，也不向代理转发 IPv6 包。
- 上游 TCP 转发未向应用传递代理 EOF，且上传结束就关闭下行。半关闭回归测试在修复前超时，修复后通过。
- IP 地址中的非 ASCII 中点曾被误当成域名接受，现在由 ArkTS 和 Go 校验拒绝并提示。

Go race 回归测试（含 AAAA 空答案、非 IPv4 包丢弃、IPv4 包原样传递及连续 DNS 查询）、OHOS arm64 动态库、NAPI 与 HAP 构建均通过，已检查删除的选项无残留引用。ArkTS 单测已添加，但当前 VS Code 测试运行器未发现它；hvigor 构建仍有由外层捕获的异常处理提示。网络切换和普通 UDP 应用尚未完成设备验收。

## 诊断日志

“连接日志”自动刷新并支持整段复制，包含 VPN 启动阶段、SOCKS5/TCP DNS/HTTPS 探针、TUN 计数及 TCP 转发记录。探针绕过 TUN，仅用于对照，不能单独证明浏览器流量已转发。

本版为诊断构建，日志含服务器地址、目标 IP 和 DNS 域名，不含网页内容或凭据。复制分享前应检查隐私信息。日志文件保存在应用私有目录；界面仅显示每个文件的末尾部分，长期运行前应考虑降低日志量或增加文件轮换。

早先手机关闭 VPN 后独立 socket 探针仍报 `errno=113` 的情况，是该手机测试环境的另一个现象，不能据此推断平板故障。平板本次问题以上述分阶段日志与真机复测为准。