#!/bin/bash
set -euo pipefail

#=============================================================================
# vps-proxy — 一键部署 Reality + Hysteria2 代理节点
# 订阅地址: http://<IP>:25500/sub/<token>
# 状态面板: http://<IP>:25500/status
#=============================================================================

readonly APP_NAME="vps-proxy"
readonly APP_DIR="/opt/${APP_NAME}"
readonly CERT_DIR="${APP_DIR}/certs"
readonly SUB_DIR="${APP_DIR}/sub"
readonly SUB_PORT_DEFAULT=25500
readonly SING_BOX_BIN="${APP_DIR}/sing-box"

# 用户输入
REALITY_PORT=""
REALITY_SNI=""
HY2_PORT=""
HY2_SNI=""

#=====================================================================
# 工具函数
#=====================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${RED}[WARN]${NC}  $1"; }
log_title() { echo -e "\n${CYAN}=== $1 ===${NC}\n"; }

banner() {
    echo ""
    echo "  ██╗   ██╗██████╗ ███████╗   ██████╗ ██████╗  ██████╗ ██╗  ██╗██╗   ██╗"
    echo "  ██║   ██║██╔══██╗██╔════╝   ██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝╚██╗ ██╔╝"
    echo "  ██║   ██║██████╔╝███████╗   ██████╔╝██████╔╝██║   ██║ ╚███╔╝  ╚████╔╝"
    echo "  ╚██╗ ██╔╝██╔═══╝ ╚════██║   ██╔═══╝ ██╔══██╗██║   ██║ ██╔██╗   ╚██╔╝"
    echo "   ╚████╔╝ ██║     ███████║   ██║     ██║  ██║╚██████╔╝██╔╝ ██╗   ██║"
    echo "    ╚═══╝  ╚═╝     ╚══════╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝"
    echo ""
    echo "              Reality + Hysteria2 一键部署脚本"
    echo ""
}

#=====================================================================
# 系统依赖
#=====================================================================

install_deps() {
    log_info "检查系统依赖..."

    local pkg_install
    if command -v apt &>/dev/null; then
        pkg_install="apt-get update -qq && apt-get install -y -qq"
    elif command -v dnf &>/dev/null; then
        pkg_install="dnf install -y"
    elif command -v yum &>/dev/null; then
        pkg_install="yum install -y epel-release && yum install -y"
    else
        log_warn "不支持的包管理器"
        exit 1
    fi

    for pkg in jq openssl python3; do
        if ! command -v "$pkg" &>/dev/null; then
            log_info "安装 $pkg..."
            bash -c "$pkg_install $pkg" || { log_warn "$pkg 安装失败"; exit 1; }
        fi
    done
}
# 下载 sing-box
#=====================================================================

get_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *)       log_warn "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

download_sing_box() {
    local channel="${1:-${SING_BOX_CHANNEL:-stable}}"

    if [ -x "${SING_BOX_BIN}" ] && [ "$channel" = "${SING_BOX_CHANNEL:-stable}" ]; then
        log_info "sing-box 已存在，跳过下载"
        return 0
    fi

    log_info "下载 sing-box (${channel})..."
    local arch
    arch=$(get_arch)

    local version_tag
    if [ "$channel" = "alpha" ]; then
        version_tag=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases" 2>/dev/null \
            | jq -r '[.[] | select(.prerelease==true)][0].tag_name // "v1.14.0-alpha.27"')
    else
        version_tag=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases" 2>/dev/null \
            | jq -r '[.[] | select(.prerelease==false)][0].tag_name // "v1.13.12"')
    fi

    if [ -z "$version_tag" ] || [ "$version_tag" = "null" ]; then
        log_warn "无法获取 sing-box 版本号"
        exit 1
    fi

    local version="${version_tag#v}"
    local package="sing-box-${version}-linux-${arch}"
    local url="https://github.com/SagerNet/sing-box/releases/download/${version_tag}/${package}.tar.gz"

    log_info "版本: ${version} (${arch})"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! curl -fsSLo "${tmp_dir}/${package}.tar.gz" "$url"; then
        log_warn "下载失败: $url"
        rm -rf "$tmp_dir"
        exit 1
    fi

    tar -xzf "${tmp_dir}/${package}.tar.gz" -C "$tmp_dir"
    mkdir -p "$APP_DIR"
    mv "${tmp_dir}/${package}/sing-box" "$SING_BOX_BIN"
    chown root:root "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    rm -rf "$tmp_dir"

    SING_BOX_CHANNEL="$channel"
    log_info "sing-box 安装完成: $("${SING_BOX_BIN}" version 2>/dev/null | head -1 || echo 'ok')"
}

#=====================================================================
# 生成证书和密钥
#=====================================================================

generate_secrets() {
    log_info "生成密钥和证书..."

    mkdir -p "$CERT_DIR"

    # Reality keypair
    local keypair
    keypair=$("${SING_BOX_BIN}" generate reality-keypair)
    REALITY_PRIVATE_KEY=$(echo "$keypair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    REALITY_PUBLIC_KEY=$(echo  "$keypair" | awk '/PublicKey/ {print $2}'  | tr -d '"')

    # UUID & short ID
    REALITY_UUID=$("${SING_BOX_BIN}" generate uuid)
    REALITY_SHORT_ID=$("${SING_BOX_BIN}" generate rand --hex 8)

    # Hysteria2 password
    HY2_PASSWORD=$("${SING_BOX_BIN}" generate rand --hex 8)

    # Self-signed cert for Hysteria2
    local hy2_cn="${HY2_SNI:-bing.com}"
    openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/hysteria2.key" 2>/dev/null
    openssl req -new -x509 -days 36500 \
        -key "${CERT_DIR}/hysteria2.key" \
        -out "${CERT_DIR}/hysteria2.crt" \
        -subj "/CN=${hy2_cn}" 2>/dev/null

    log_info "密钥生成完成"
}

#=====================================================================
# 生成服务端配置
#=====================================================================

write_server_config() {
    log_info "生成 sing-box 服务端配置..."

    cat > "${APP_DIR}/server.json" << EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "sniff": true,
      "sniff_override_destination": true,
      "users": [
        {
          "uuid": "${REALITY_UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SNI}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": ["${REALITY_SHORT_ID}"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "password": "${HY2_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${CERT_DIR}/hysteria2.crt",
        "key_path": "${CERT_DIR}/hysteria2.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "inbound": ["vless-in", "hy2-in"],
        "action": "direct"
      }
    ],
    "final": "direct"
  }
}
EOF
}

#=====================================================================
# systemd 服务
#=====================================================================

write_systemd_service() {
    log_info "安装 systemd 服务..."

    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=Sing-box Proxy Service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${APP_DIR}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${SING_BOX_BIN} run -c ${APP_DIR}/server.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable sing-box >/dev/null 2>&1 || true
}

#=====================================================================
# 生成 Clash 订阅文件
#=====================================================================

get_server_ip() {
    curl -s4m5 ip.sb -k 2>/dev/null || curl -s4m5 api.ipify.org 2>/dev/null || curl -s4m5 ifconfig.me 2>/dev/null || echo "未知"
}

generate_sub_token() {
    if [ ! -f "${APP_DIR}/sub_token" ]; then
        mkdir -p "$SUB_DIR"
        "${SING_BOX_BIN}" generate rand --hex 8 > "${APP_DIR}/sub_token" 2>/dev/null || \
            openssl rand -hex 8 > "${APP_DIR}/sub_token" 2>/dev/null || \
            date +%s | sha256sum | head -c 16 > "${APP_DIR}/sub_token"
    fi
}


# 从 server.json 加载所有配置变量（write_clash_sub 和 show_config 共用）
load_config_vars() {
    local cfg="${APP_DIR}/server.json"
    CFG_SERVER_IP=$(get_server_ip)
    CFG_REALITY_PORT=$(jq -r '.inbounds[0].listen_port' "$cfg" 2>/dev/null || echo "$REALITY_PORT")
    CFG_HY2_PORT=$(jq -r '.inbounds[1].listen_port' "$cfg" 2>/dev/null || echo "$HY2_PORT")
    CFG_UUID=$(jq -r '.inbounds[0].users[0].uuid' "$cfg")
    CFG_PUBKEY=$(cat "${APP_DIR}/pubkey" 2>/dev/null)
    CFG_SHORT_ID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$cfg")
    CFG_HY2_PASS=$(jq -r '.inbounds[1].users[0].password' "$cfg")
    # 缓存证书 CN（首次读取后缓存到文件）
    if [ ! -f "${APP_DIR}/hy2_sni" ]; then
        openssl x509 -in "${CERT_DIR}/hysteria2.crt" -noout -subject -nameopt RFC2253 2>/dev/null \
            | awk -F'=' '{print $NF}' > "${APP_DIR}/hy2_sni"
    fi
    CFG_HY2_SNI=$(cat "${APP_DIR}/hy2_sni" 2>/dev/null || echo "bing.com")
    CFG_SUB_TOKEN=$(cat "${APP_DIR}/sub_token" 2>/dev/null || echo "")
    CFG_SUB_PORT="${SUB_PORT:-$SUB_PORT_DEFAULT}"
}

write_clash_sub() {
    load_config_vars
    mkdir -p "$SUB_DIR"

    cat > "${SUB_DIR}/clash.yaml" << YAMLEOF
port: 7890
allow-lan: true
mode: rule
log-level: info
unified-delay: true
global-client-fingerprint: chrome
dns:
  enable: true
  listen: :53
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 223.5.5.5
    - 8.8.8.8
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  fallback:
    - https://1.0.0.1/dns-query
    - tls://dns.google
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4

proxies:
  - name: Reality
    type: vless
    server: ${CFG_SERVER_IP}
    port: ${CFG_REALITY_PORT}
    uuid: ${CFG_UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${CFG_PUBKEY}
      short-id: ${CFG_SHORT_ID}

  - name: Hysteria2
    type: hysteria2
    server: ${CFG_SERVER_IP}
    port: ${CFG_HY2_PORT}
    password: ${CFG_HY2_PASS}
    sni: ${CFG_HY2_SNI}
    skip-cert-verify: true
    alpn:
      - h3

proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - 自动选择
      - Reality
      - Hysteria2
      - DIRECT

  - name: 自动选择
    type: url-test
    proxies:
      - Reality
      - Hysteria2
    url: "http://www.gstatic.com/generate_204"
    interval: 300
    tolerance: 50

rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
YAMLEOF
}

#=====================================================================
# 订阅服务器
#=====================================================================

write_sub_server() {
    log_info "部署订阅服务器..."

    local sub_port="${SUB_PORT:-$SUB_PORT_DEFAULT}"

    cat > "${APP_DIR}/sub-server.py" << 'PYEOF'
import http.server
import os
import sys
import subprocess
import time

APP_DIR = '/opt/vps-proxy'
SUB_FILE = os.path.join(APP_DIR, 'sub', 'clash.yaml')
TOKEN_FILE = os.path.join(APP_DIR, 'sub_token')
START_TIME = time.time()

def get_token():
    try:
        with open(TOKEN_FILE) as f:
            return f.read().strip()
    except:
        return None

def get_uptime():
    delta = int(time.time() - START_TIME)
    d, h, m = delta // 86400, (delta % 86400) // 3600, (delta % 3600) // 60
    parts = []
    if d: parts.append(f'{d}天')
    if h: parts.append(f'{h}时')
    parts.append(f'{m}分')
    return ' '.join(parts)

def get_svc_status():
    try:
        r = subprocess.run(['systemctl', 'is-active', 'sing-box'], capture_output=True, text=True, timeout=3)
        return r.stdout.strip()
    except:
        return 'unknown'

_ip_cache = ('', 0.0)

def get_server_ip():
    global _ip_cache
    now = time.time()
    if _ip_cache[0] and (now - _ip_cache[1]) < 60:
        return _ip_cache[0]
    try:
        r = subprocess.run(['curl', '-s4m3', 'ip.sb', '-k'], capture_output=True, text=True, timeout=5)
        ip = r.stdout.strip() or 'N/A'
    except:
        ip = 'N/A'
    _ip_cache = (ip, now)
    return ip

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if token and self.path == f'/sub/{token}':
            try:
                with open(SUB_FILE, 'rb') as f:
                    data = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'text/yaml; charset=utf-8')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                self.wfile.write(data)
            except FileNotFoundError:
                self.send_response(503)
                self.end_headers()
                self.wfile.write(b'Config not ready. Run: bash install.sh')
        elif self.path == '/health':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'ok')
        elif self.path == '/status':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            ip = get_server_ip()
            svc = get_svc_status()
            up = get_uptime()
            css = 'ok' if svc == 'active' else 'warn'
            html = f'''<!DOCTYPE html>
<html lang="zh">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>vps-proxy 状态</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{font-family:ui-monospace,monospace;background:#0f0f1a;color:#c0c0d0;min-height:100vh;display:flex;align-items:center;justify-content:center}}
.card{{background:#1a1a2e;border-radius:12px;padding:2em;max-width:420px;width:90%;box-shadow:0 0 30px rgba(0,212,255,0.08)}}
h1{{color:#00d4ff;font-size:1.2em;margin-bottom:1.2em;text-align:center}}
.row{{display:flex;justify-content:space-between;padding:0.6em 0;border-bottom:1px solid #2a2a3e}}
.row:last-child{{border-bottom:none}}
.label{{opacity:0.6}}
.value{{color:#fff;font-weight:600}}
.ok{{color:#00ff88}}.warn{{color:#ffaa00}}
.foot{{text-align:center;margin-top:1.5em;opacity:0.4;font-size:0.8em}}
</style></head>
<body>
<div class="card">
<h1>代理节点状态</h1>
<div class="row"><span class="label">IP 地址</span><span class="value">{ip}</span></div>
<div class="row"><span class="label">服务状态</span><span class="value {css}">{svc}</span></div>
<div class="row"><span class="label">运行时间</span><span class="value">{up}</span></div>
<div class="row"><span class="label">订阅端口</span><span class="value">{port}</span></div>
<div class="foot">vps-proxy</div>
</div></body></html>'''
            self.wfile.write(html.encode())
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not Found')

    def log_message(self, *args):
        pass

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 25500
    httpd = http.server.HTTPServer(('0.0.0.0', port), Handler)
    httpd.serve_forever()
PYEOF

    # systemd 服务
    cat > /etc/systemd/system/clash-sub.service << EOF
[Unit]
Description=vps-proxy Subscription Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
ExecStart=python3 ${APP_DIR}/sub-server.py ${sub_port}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable clash-sub >/dev/null 2>&1 || true
}

show_config() {
    load_config_vars

    # === Reality ===
    log_title "Reality 节点"
    echo "vless://${CFG_UUID}@${CFG_SERVER_IP}:${CFG_REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${CFG_PUBKEY}&sid=${CFG_SHORT_ID}&type=tcp&headerType=none#vps-proxy-reality"

    # === Hysteria2 ===
    log_title "Hysteria2 节点"
    echo "hysteria2://${CFG_HY2_PASS}@${CFG_SERVER_IP}:${CFG_HY2_PORT}?insecure=1&sni=${CFG_HY2_SNI}#vps-proxy-hy2"

    # === 订阅地址 ===
    if [ -n "$CFG_SUB_TOKEN" ]; then
        log_title "Clash 订阅地址"
        echo "在 Clash Verge 中选择 [订阅] → [新建] → [Remote]"
        echo ""
        echo "  http://${CFG_SERVER_IP}:${CFG_SUB_PORT}/sub/${CFG_SUB_TOKEN}"
        echo ""
        echo "状态面板: http://${CFG_SERVER_IP}:${CFG_SUB_PORT}/status"
        echo ""
        echo "(确保 VPS 防火墙放行端口 ${CFG_SUB_PORT})"
    fi
}

#=====================================================================
# 启动
#=====================================================================

start_services() {
    log_info "检查配置..."
    if ! "${SING_BOX_BIN}" check -c "${APP_DIR}/server.json"; then
        log_warn "配置校验失败"
        exit 1
    fi

    log_info "启动 sing-box..."
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart sing-box 2>/dev/null || true

    if systemctl is-active --quiet sing-box 2>/dev/null; then
        log_info "sing-box 运行中"
    else
        log_warn "sing-box 启动失败，检查: journalctl -u sing-box -n 20"
    fi

    log_info "启动订阅服务器..."
    systemctl restart clash-sub 2>/dev/null || true
    if systemctl is-active --quiet clash-sub 2>/dev/null; then
        log_info "订阅服务器运行中"
    else
        log_warn "订阅服务器启动失败（python3 未安装或端口冲突）"
    fi
}

#=====================================================================
# 卸载
#=====================================================================

uninstall() {
    log_info "卸载 ${APP_NAME}..."

    systemctl stop sing-box 2>/dev/null || true
    systemctl stop clash-sub 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    systemctl disable clash-sub 2>/dev/null || true

    rm -f /etc/systemd/system/sing-box.service
    rm -f /etc/systemd/system/clash-sub.service
    rm -rf "$APP_DIR"

    systemctl daemon-reload 2>/dev/null || true
    log_info "卸载完成"
}

#=====================================================================
# 更新 sing-box 内核
#=====================================================================

toggle_version() {
    local current="${SING_BOX_CHANNEL:-stable}"
    if [ "$current" = "stable" ]; then
        log_info "切换到 Alpha 版本..."
        rm -f "$SING_BOX_BIN"
        download_sing_box "alpha"
    else
        log_info "切换到 Stable 版本..."
        rm -f "$SING_BOX_BIN"
        download_sing_box "stable"
    fi
    systemctl restart sing-box 2>/dev/null || true
    log_info "切换完成"
}

#=====================================================================
# 交互菜单
#=====================================================================

show_menu() {
    echo ""
    echo "  ${APP_NAME} 已安装"
    echo ""
    echo "  1. 重新安装"
    echo "  2. 修改 Reality 端口/域名"
    echo "  3. 显示客户端配置"
    echo "  4. 重启订阅服务器"
    echo "  5. 切换版本 (Stable ⇄ Alpha)"
    echo "  6. 卸载"
    echo ""
    read -r -p "  请选择 (1-6): " choice

    case $choice in
        1)
            uninstall
            main_install
            ;;
        2)
            modify_reality
            ;;
        3)
            show_config
            ;;
        4)
            systemctl restart clash-sub 2>/dev/null || true
            show_config
            ;;
        5)
            toggle_version
            show_config
            ;;
        6)
            uninstall
            ;;
        *)
            echo "无效选项"
            ;;
    esac
}

modify_reality() {
    local current_port current_sni
    current_port=$(jq -r '.inbounds[0].listen_port' "${APP_DIR}/server.json")
    current_sni=$(jq -r '.inbounds[0].tls.server_name' "${APP_DIR}/server.json")

    read -r -p "Reality 端口 (当前: ${current_port}): " new_port
    new_port="${new_port:-$current_port}"
    read -r -p "Reality SNI 域名 (当前: ${current_sni}): " new_sni
    new_sni="${new_sni:-$current_sni}"

    local tmp
    tmp=$(mktemp)
    jq --arg p "$new_port" --arg sni "$new_sni" \
        '.inbounds[0].listen_port = ($p | tonumber) | .inbounds[0].tls.server_name = $sni | .inbounds[0].tls.reality.handshake.server = $sni' \
        "${APP_DIR}/server.json" > "$tmp"
    mv "$tmp" "${APP_DIR}/server.json"

    REALITY_SNI="$new_sni"
    write_clash_sub
    systemctl restart sing-box 2>/dev/null || true
    show_config
}

#=====================================================================
# 主安装流程
#=====================================================================

main_install() {
    banner
    install_deps
    download_sing_box

    # 交互输入
    echo ""
    read -r -p "Reality 端口 (默认 443): " REALITY_PORT
    REALITY_PORT="${REALITY_PORT:-443}"
    [[ "$REALITY_PORT" =~ ^[0-9]+$ ]] && [ "$REALITY_PORT" -ge 1 ] && [ "$REALITY_PORT" -le 65535 ] || { log_warn "无效端口: $REALITY_PORT"; exit 1; }
    read -r -p "Reality SNI 域名 (默认 itunes.apple.com): " REALITY_SNI
    REALITY_SNI="${REALITY_SNI:-itunes.apple.com}"
    [[ "$REALITY_SNI" =~ ^[a-zA-Z0-9.-]+$ ]] || { log_warn "无效域名: $REALITY_SNI"; exit 1; }

    echo ""
    read -r -p "Hysteria2 端口 (默认 8443): " HY2_PORT
    HY2_PORT="${HY2_PORT:-8443}"
    [[ "$HY2_PORT" =~ ^[0-9]+$ ]] && [ "$HY2_PORT" -ge 1 ] && [ "$HY2_PORT" -le 65535 ] || { log_warn "无效端口: $HY2_PORT"; exit 1; }
    read -r -p "Hysteria2 自签证书域名 (默认 bing.com): " HY2_SNI
    HY2_SNI="${HY2_SNI:-bing.com}"
    [[ "$HY2_SNI" =~ ^[a-zA-Z0-9.-]+$ ]] || { log_warn "无效域名: $HY2_SNI"; exit 1; }

    generate_secrets

    # 持久化公钥
    echo "$REALITY_PUBLIC_KEY" > "${APP_DIR}/pubkey"

    write_server_config
    write_systemd_service

    generate_sub_token
    write_clash_sub
    write_sub_server

    start_services
    show_config
}

#=====================================================================
# 入口
#=====================================================================

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    log_warn "请用 root 运行: sudo bash install.sh"
    exit 1
fi

# 检测是否已安装
if [ -f "${APP_DIR}/server.json" ] && [ -x "$SING_BOX_BIN" ] && [ -f /etc/systemd/system/sing-box.service ]; then
    # 已安装的场景：如果有子命令参数，直接执行；否则显示菜单
    case "${1:-}" in
        config|show)  show_config; exit 0 ;;
        status)       show_config; exit 0 ;;
        restart-sub)  systemctl restart clash-sub 2>/dev/null; show_config; exit 0 ;;
        uninstall)    uninstall; exit 0 ;;
        toggle)       toggle_version; show_config; exit 0 ;;
        reinstall)    uninstall; main_install; exit 0 ;;
        *)           show_menu; exit 0 ;;
    esac
fi

# 全新安装
main_install
