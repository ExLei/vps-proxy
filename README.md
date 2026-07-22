# vps-proxy

一键部署 Reality + Hysteria2 代理节点，附带 Clash 订阅服务和状态面板。

## 准备工作

SSH 登录 VPS 后，先更新系统并安装 curl：

```bash
# Debian / Ubuntu
apt update && apt upgrade -y && apt install -y curl

# CentOS / RHEL
yum update -y && yum install -y curl

# Arch
pacman -Syu --noconfirm curl
```

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/vps-proxy/main/install.sh)
```

## 使用教程

### 1. 运行安装脚本

```bash
sudo bash install.sh
```

交互输入：
```
Reality 端口 (默认 443):        # 建议 443 或自定义
Reality SNI (默认 itunes.apple.com):  # 伪装域名，回车默认
Hysteria2 端口 (默认 8443):     # 建议 8443 或自定义
Hysteria2 证书域名 (默认 bing.com):   # 自签证书域名，回车默认
```

### 2. 获取订阅链接

安装完成后自动显示，也可随时查看：

```bash
sudo bash install.sh config
```

输出示例：
```
=== Reality 节点 ===
vless://...@1.2.3.4:443?...&sni=itunes.apple.com...#vps-proxy-reality

=== Hysteria2 节点 ===
hysteria2://...@1.2.3.4:8443?...&sni=bing.com#vps-proxy-hy2

=== Clash 订阅地址 ===
  http://1.2.3.4:25500/sub/a1b2c3d4e5f6g7h8

状态面板: http://1.2.3.4:25500/status
```

### 3. 导入 Clash Verge

1. 打开 Clash Verge → **订阅** → **新建**
2. 类型选择 **Remote**
3. 粘贴订阅地址 `http://<你的IP>:25500/sub/<token>`
4. 点击保存，自动更新节点

### 4. 管理节点

```bash
# 修改 Reality 端口或域名
sudo bash install.sh      # 菜单选 2

# 修改 Hysteria2 端口或域名
sudo bash install.sh      # 菜单选 3

# 切换 Stable / Alpha 版本
sudo bash install.sh toggle
```

### 5. 放行端口

在 VPS 后台安全组/防火墙中放行以下端口：

| 端口 | 协议 | 用途 |
|------|------|------|
| 你的 Reality 端口 | TCP | VLESS 入站 |
| 你的 Hysteria2 端口 | UDP | Hysteria2 入站 |
| 25500 | TCP | 订阅服务器 |

也可用命令行放行（如有 ufw）：

```bash
ufw allow 443/tcp
ufw allow 8443/udp
ufw allow 25500/tcp
```

## 目录结构

```
/opt/vps-proxy/
├── sing-box          # sing-box 二进制
├── server.json       # 服务端配置
├── channel           # 版本频道
├── certs/
│   ├── hysteria2.key
│   └── hysteria2.crt
├── sub/
│   ├── clash.yaml    # Clash 订阅文件
│   └── sub-server.py # 订阅 HTTP 服务器
├── pubkey            # Reality 公钥
└── sub_token         # 订阅路径 token
```

## License

Apache 2.0
