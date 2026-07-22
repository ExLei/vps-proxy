# GitHub Copilot Instructions — vps-proxy

本项目是 Bash 部署脚本，运行在 Linux VPS 上，需要 root 权限。

## 关键规则

- **必须在函数第一行使用** `set -euo pipefail`（文件顶部已设置）
- **所有变量引用加双引号**: `"${var}"`
- **systemctl 调用必须容错**: `2>/dev/null || true`
- **heredoc 中 Python 代码用** `<< 'PYEOF'`（单引号防展开）
- **heredoc 中 Bash 变量用** `<< EOF`（双引号允许展开）
- **字符串比较用** `[[ ]]` 不用 `[ ]`
- **不写** `function` 关键字，直接 `func_name() { }`
- **全局常量用** `readonly`
- **错误退出用** `die "消息"` 不用裸 `exit 1`

## 安全约束

- 不在 stdout 打印完整 YAML/JSON
- 用户输入必须校验（端口范围、域名格式）
- 破坏性操作必须 `confirm()` 提示
- 订阅 token 用 `/dev/urandom` 或 sing-box 生成
- 配置文件只 root 可读

## 网络操作

- `curl` 必须加超时: `-m5`
- IP 检测用三重回退: `ip.sb → ipify.org → ifconfig.me`
- GitHub API 调用用 `jq` 解析
- sing-box 下载后校验 SHA-256（非致命）

## 常见反模式

- ❌ `echo $VAR` — 缺引号
- ❌ `[ "$a" == "$b" ]` — 应该用 `[[ ]]`
- ❌ `cat file | grep pattern` — 直接 `grep pattern file`
- ❌ `systemctl restart` 无容错 — 加 `2>/dev/null || true`
- ❌ 直接 exit 1 — 用 `die "消息"`
