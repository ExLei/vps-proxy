# 贡献指南

## 快速开始

```bash
git clone <repo-url>
cd vps-proxy

# 语法检查
bash -n install.sh

# 测试安装
sudo rm -rf /opt/vps-proxy
printf "443\nitunes.apple.com\n8443\nbing.com\n" | sudo bash install.sh
```

## 代码风格

遵循 [AGENTS.md](AGENTS.md) 中的约定。核心：

- `set -euo pipefail` 全局开启
- 函数 `snake_case`，变量 `UPPER_CASE`（全局） / `lower_case`（局部）
- 错误: `die "消息"`
- 校验: `validate_port` / `validate_sni`
- 确认: `confirm "提示"`

## 提交规范

使用 Conventional Commits:

```
category: 简短描述

详细说明（可选）
```

类别:
- `fix:` — Bug 修复
- `feat:` — 新功能
- `refactor:` — 重构
- `audit:` — 安全审查
- `adopt:` — 从上游纳进特性
- `docs:` — 文档

## 测试清单

- [ ] `bash -n install.sh` 通过
- [ ] 全新安装不报错
- [ ] `config` 子命令输出正确链接
- [ ] `toggle` 切换版本正常
- [ ] `modify_reality` 修改后配置校验通过
- [ ] `modify_hysteria2` 修改后证书更新
- [ ] `uninstall` 有确认提示
- [ ] 订阅 URL 可访问
- [ ] `/status` 页面正常显示

## 发布

```bash
git tag v1.0.0
git push origin main --tags
```
