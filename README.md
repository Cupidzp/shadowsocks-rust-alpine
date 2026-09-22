# shadowsocks-rust Alpine 一键部署

这是一个面向 Alpine Linux 的交互式部署脚本，基于官方
[`shadowsocks-rust`](https://github.com/shadowsocks/shadowsocks-rust) 软件包。

默认行为：

- 监听地址固定为 `::`
- 默认端口为 `12345`，也可以交互输入 `1-65535` 的端口
- 加密方式固定为 `2022-blake3-aes-256-gcm`
- 自定义 PSK 必须是解码后正好 32 字节的标准 Base64
- PSK 留空时调用 `ssservice genkey` 自动生成
- 配置文件：`/etc/shadowsocks-rust/config.json`
- OpenRC 服务：`ss-rust`
- 运行用户：`nobody:nobody`
- 监听 TCP 和 UDP
- 配置使用 `server: "::"`，并请求关闭 `IPV6_V6ONLY` 以兼容 IPv4-mapped 连接

## Alpine 上执行

建议先检查远程脚本内容，再执行。直接运行需要 root 权限和可用的 `curl`：

```sh
curl -fsSL https://raw.githubusercontent.com/Cupidzp/shadowsocks-rust-alpine/main/install.sh | sh
```

如果系统没有 curl：

```sh
apk add --no-cache curl
curl -fsSL https://raw.githubusercontent.com/Cupidzp/shadowsocks-rust-alpine/main/install.sh | sh
```

脚本会自动安装：

```text
shadowsocks-rust-ssserver
shadowsocks-rust-ssservice
iproute2-ss
curl
```

`shadowsocks-rust-ssservice` 和 `shadowsocks-rust-ssserver` 需要 Alpine 的
`community` 仓库可用。

## 客户端信息

脚本完成后会显示：

- 服务器 IPv6 地址或域名
- 端口
- 加密方式
- PSK
- Shadowsocks `ss://` URI

如果自动获取公网 IPv6 失败，使用服务器公网 IPv6 地址手动填写节点。IPv6 地址在
URI 中必须带方括号，例如 `[2001:db8::1]`。

客户端必须支持 Shadowsocks 2022 和
`2022-blake3-aes-256-gcm`。同时在 VPS 安全组或云防火墙放行脚本选择的 TCP/UDP
端口。

## 服务管理

```sh
rc-service ss-rust status
rc-service ss-rust restart
rc-service ss-rust stop
tail -f /var/log/shadowsocks-rust.log /var/log/shadowsocks-rust.err
cat /root/ss2022-key.txt
```

重复运行脚本前，已有配置、服务文件和密钥会备份到 `/root/shadowsocks-rust-backup.*`。

选择 `1-1023` 端口时，OpenRC 服务仅额外使用 `CAP_NET_BIND_SERVICE`；普通高端口不添加
额外能力。

## 上传到 GitHub

仓库地址：

```text
https://github.com/Cupidzp/shadowsocks-rust-alpine
```

在本地 PowerShell 中执行：

```powershell
Set-Location -LiteralPath 'D:\aiwork\shadowsocks-rust-alpine'

git init
git branch -M main
git add install.sh README.md
git update-index --chmod=+x install.sh
git commit -m "Add Alpine Shadowsocks 2022 installer"
git remote add origin https://github.com/Cupidzp/shadowsocks-rust-alpine.git
git push -u origin main
```

使用 HTTPS 推送时，GitHub 要求使用 Personal Access Token 作为密码；也可以配置 SSH 远程地址：

```powershell
git remote set-url origin git@github.com:Cupidzp/shadowsocks-rust-alpine.git
git push -u origin main
```

其他 Alpine 服务器可以执行：

```sh
apk add --no-cache curl && curl -fsSL https://raw.githubusercontent.com/Cupidzp/shadowsocks-rust-alpine/main/install.sh | sh
```

远程执行脚本会随着仓库内容变化而变化。正式长期使用时，建议固定到某个 Git commit
或先下载后审查：

```sh
curl -fsSLo /root/install-shadowsocks-rust.sh https://raw.githubusercontent.com/Cupidzp/shadowsocks-rust-alpine/main/install.sh
less /root/install-shadowsocks-rust.sh
sh /root/install-shadowsocks-rust.sh
```
