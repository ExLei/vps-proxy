# vps-proxy

一键部署 Reality + Hysteria2 代理节点，附带 Clash 订阅服务和状态面板。

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/vps-proxy/main/install.sh)
```

## 协议

| 协议 | 传输 | 伪装 | 需要域名 |
|------|------|------|---------|
| VLESS + Reality | TCP | 伪装 itunes.apple.com 等 | 否 |
| Hysteria2 | QUIC/UDP | 自签证书 | 否 |

## 功能

- **一键安装**：全程交互式，回车几次即可
- **订阅链接**：`http://<VPS_IP>:25500/sub/<token>` → Clash Verge URL 导入
- **状态面板**：`http://<VPS_IP>:25500/status` → 浏览器查看节点状态
- **零依赖**：自动安装 jq / openssl / python3
- **自动适配**：x86_64 / ARM / ARMv7

## 管理命令

```bash
# 查看配置和订阅地址
sudo bash install.sh config

# 更新 sing-box 内核
sudo bash install.sh update

# 重启订阅服务器
sudo bash install.sh restart-sub

# 卸载
sudo bash install.sh uninstall
```

## 客户端

- **Clash Verge** (Windows/macOS/Linux) — 通过订阅 URL 导入
- **sing-box** 客户端 — 复制 vless:// 和 hysteria2:// 链接
- **v2rayN / Nekoray** — 支持 Reality 协议

## 目录结构

```
/opt/vps-proxy/
├── sing-box          # sing-box 二进制
├── server.json       # 服务端配置
├── certs/            # TLS 证书
│   ├── hysteria2.key
│   └── hysteria2.crt
├── sub/              # 订阅文件
│   └── clash.yaml
├── pubkey            # Reality 公钥
├── sub_token         # 订阅路径 token
└── sub-server.py     # 订阅 HTTP 服务器
```

## 防火墙

确保以下端口在 VPS 安全组中放行：

| 端口 | 用途 |
|------|------|
| 你的 Reality 端口 (默认 443) | VLESS 入站 |
| 你的 Hysteria2 端口 (默认 8443) | Hysteria2 入站 |
| 25500 | 订阅服务器 |

## License

Apache 2.0
