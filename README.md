# vps-proxy

一键部署 Reality + Hysteria2 代理节点，附带 Clash 订阅服务和状态面板。

支持 Debian / Ubuntu / CentOS / Fedora / Arch。

## 特性

默认：

- **Token 鉴权**：订阅与状态面板均有 token 保护
- **限流保护**：30 次/10 秒防暴力破解
- **Hysteria2 Salamander 混淆**：默认开启，隐藏 QUIC 指纹与 SNI，防被动识别
- **多发行版支持**：Debian / Ubuntu / CentOS / Fedora / Arch
- **非交互模式**：管道/AI 调用时自动跳过所有提示，安全拒绝确认操作，零阻塞

可选：

- **零域名 HTTPS**：Caddy + nip.io，自动 Let's Encrypt 证书
- **Web 管理面板**：s-ui-x，流量统计与多用户管理
- **综合检测**：[XY 系列脚本](https://github.com/xykt/ScriptMenu) 集成（IP 质量 / 网络延迟 / 流媒体解锁 / 硬件测试）

## 准备工作

> 还没有 VPS？参考 [DigVPS](https://digvps.com/) 选购适合的服务器。

SSH 登录 VPS 后，先更新系统并安装 curl：

```bash
# Debian / Ubuntu
apt update && apt upgrade -y && apt install -y curl

# CentOS / RHEL
yum update -y && yum install -y curl

# Fedora
dnf update -y && dnf install -y curl

# Arch
pacman -Syu --noconfirm curl
```

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ExLei/vps-proxy/main/install.sh)
```

## 使用教程

### 1. 运行安装脚本

```bash
sudo bash install.sh
```

交互输入（仅 TTY 环境下显示，管道/AI 调用时自动使用默认值）：

```
Reality 端口 (默认 443):           # 建议 443 或自定义
Reality SNI (默认 itunes.apple.com):  # 伪装域名，回车默认
Hysteria2 端口 (默认 8443):        # 建议 8443 或自定义
Hysteria2 证书域名 (默认 bing.com):    # 自签证书域名，回车默认
是否启用 HTTPS (需要开放 80 端口)？     # 建议 y，自动获取免费证书
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
hysteria2://...@1.2.3.4:8443?...&sni=bing.com&obfs=salamander&obfs-password=...#vps-proxy-hy2

=== Clash 订阅地址 ===

  http://1.2.3.4:25500/sub/a1b2c3d4e5f6g7h8/vps-proxy
  https://1.2.3.4.nip.io/sub/a1b2c3d4e5f6g7h8/vps-proxy  (启用 HTTPS 后)

状态面板: http://1.2.3.4:25500/status?token=a1b2c3d4e5f6g7h8
          https://1.2.3.4.nip.io/status?token=a1b2c3d4e5f6g7h8  (启用 HTTPS 后)
```

### 3. 导入 Clash Verge

1. 打开 Clash Verge → **订阅** → **新建**
2. 类型选择 **Remote**
3. 粘贴订阅链接
4. 点击保存，自动更新节点

### 4. 管理节点

```bash
sudo bash install.sh   # 进入管理菜单
```

菜单选项：

| 选项 | 功能 | 等效 CLI |
|------|------|----------|
| 1 | 重新安装 | `sudo bash install.sh reinstall` |
| 2 | 修改 Reality 端口/域名 | — |
| 3 | 修改 Hysteria2 端口/域名 | — |
| 4 | 显示客户端配置 | `sudo bash install.sh config` |
| 5 | 重启订阅服务器 | `sudo bash install.sh restart-sub` |
| 6 | 切换 Stable / Alpha 版本 | `sudo bash install.sh toggle` |
| 7 | 卸载 | `sudo bash install.sh uninstall` |
| 8 | 安装 Web 管理面板 (s-ui-x) | `sudo bash install.sh panel` |
| 9 | XY 综合检测 (IP/网络/硬件) | `sudo bash install.sh check` |

### 5. 综合检测

集成 [XY 系列脚本](https://github.com/xykt/ScriptMenu)，一键触发 VPS 全方位体检：

```bash
sudo bash install.sh check
```

检测内容：

| 模块 | 检测项 |
|------|--------|
| IP 质量 | 黑名单扫描、代理/VPN 识别、欺诈评分、IP 类型（家宽/机房/移动） |
| 网络质量 | 三网延迟、丢包率、抖动、回程路由 |
| 流媒体解锁 | Netflix、Disney+、YouTube、B站等区域限制 |
| 硬件质量 | CPU 跑分、内存带宽、磁盘 IOPS、网络吞吐 |

### 6. 放行端口

在 VPS 后台安全组/防火墙中放行以下端口：

| 端口 | 协议 | 用途 |
|------|------|------|
| 80 | TCP | Let's Encrypt 证书验证（启用 HTTPS 时需要） |
| 443 | TCP | Caddy HTTPS |
| 你的 Reality 端口 | TCP | VLESS 入站 |
| 你的 Hysteria2 端口 | UDP | Hysteria2 入站 |

也可用命令行放行（如有 ufw）：

```bash
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 你的Reality端口/tcp
ufw allow 你的Hysteria2端口/udp
```

### 7. 非交互模式

脚本检测到非 TTY 环境（管道、AI 调用、cron 等）时自动适配：

- `confirm` 类提示 → 安全拒绝
- 安装端口/SNI → 使用默认值（443 / itunes.apple.com / 8443 / bing.com）
- 管理菜单 → 直接显示配置
- `check` 命令 → 不受影响，直接启动 XY 检测

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

## 开发

```bash
# 四发行版回归测试
podman build -f Dockerfile.debian -t vps-proxy-deb  .
podman build -f Dockerfile.fedora -t vps-proxy-fedora .
podman build -f Dockerfile.arch   -t vps-proxy-arch  .
podman build -f Dockerfile.centos -t vps-proxy-centos .
```

## 致谢

- [sing-box](https://github.com/SagerNet/sing-box) — 核心代理引擎
- [sing-REALITY-Box](https://github.com/deathline94/sing-REALITY-Box) — 上游 Reality 一键安装脚本
- [s-ui-x](https://github.com/deposist/s-ui-x) — Web 管理面板
- [XY 系列脚本](https://github.com/xykt/ScriptMenu) — VPS 综合检测

## License

AGPL-3.0
