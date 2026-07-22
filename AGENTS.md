# AGENTS.md — vps-proxy

## 项目概述

vps-proxy 是一键部署脚本，在 Linux VPS 上安装 Reality + Hysteria2 代理节点，附带 Clash 订阅 HTTP 服务和状态面板。

- **语言**: Bash
- **入口**: `install.sh`（单文件）
- **安装路径**: `/opt/vps-proxy/`
- **运行权限**: 必须 root

## 代码约定

### Shell 规范

- **第一行必须是** `set -euo pipefail`
- 函数命名: `snake_case`
- 全局变量: `UPPER_CASE`，用 `readonly` 声明
- 局部变量: `local lower_case`
- 字符串用双引号: `"${var}"`（除非确定不需要）
- 条件用 `[[ ]]` 不用 `[ ]`
- heredoc 用 `<< 'EOF'` 防止变量展开（Python 代码中）
- heredoc 用 `<< EOF` 允许变量展开（配置文件中）

### 错误处理

- 致命错误用 `die "消息"`，不要直接 `exit 1`
- systemctl 调用必须加 `2>/dev/null || true`（兼容非 systemd 环境）
- 网络操作必须有超时: `curl -m5`
- 用户输入必须校验（端口: 1-65535，域名: 合法 FQDN）

### 安全

- 敏感文件路径: `/opt/vps-proxy/` 下，root 只读
- 不在 stdout 打印完整 YAML/JSON 配置
- 订阅 token 用 `/dev/urandom` 生成
- 破坏性操作（卸载、重装）必须 `confirm()` 提示
- 配置修改自动备份 + `sing-box check` 校验后才生效

## 目录结构

```
/opt/vps-proxy/         安装目录
├── sing-box            二进制
├── server.json         服务端配置
├── channel             版本频道 (stable/alpha)
├── pubkey              Reality 公钥
├── sub_token           订阅路径 token
├── .hy2_sni_cache      证书 CN 缓存
├── certs/
│   ├── hysteria2.key
│   └── hysteria2.crt
├── sub/
│   ├── clash.yaml      Clash 订阅文件
│   └── sub-server.py   HTTP 订阅服务器
```

## 测试

```bash
# 语法检查
bash -n install.sh

# 完整安装测试
sudo rm -rf /opt/vps-proxy /etc/systemd/system/{sing-box,clash-sub}.service
printf "443\nitunes.apple.com\n8443\nbing.com\n" | sudo bash install.sh

# 订阅端点测试
curl -s http://127.0.0.1:25500/health
```

## 发布

1. `bash -n install.sh` 通过
2. 在干净 VPS 上完整安装测试
3. `git tag vX.Y.Z`
4. 用户通过 `bash <(curl -fsSL https://raw.githubusercontent.com/.../main/install.sh)` 安装
