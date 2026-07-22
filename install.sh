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
readonly CHANNEL_FILE="${APP_DIR}/channel"

#=====================================================================
# 工具函数
#=====================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${RED}[WARN]${NC}  $1"; }
log_title() { echo -e "\n${CYAN}=== $1 ===${NC}\n"; }

confirm() {
    local prompt="${1:-确认操作?}"
    read -r -p "$prompt (y/N): " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

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

die() { log_warn "$1"; exit 1; }

#=====================================================================
# 系统依赖
#=====================================================================

install_deps() {
    log_info "检查系统依赖..."
    local pkg_install
    if command -v apt &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        pkg_install="apt-get update -qq && apt-get install -y -qq"
    elif command -v dnf &>/dev/null; then
        pkg_install="dnf install -y"
    elif command -v yum &>/dev/null; then
        pkg_install="yum install -y epel-release && yum install -y"
    else
        die "不支持的包管理器"
    fi
    for pkg in jq openssl python3; do
        command -v "$pkg" &>/dev/null && continue
        log_info "安装 $pkg..."
        bash -c "$pkg_install $pkg" || die "$pkg 安装失败"
    done
}

#=====================================================================
# 网络与校验
#=====================================================================

get_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        *)       die "不支持的架构: $(uname -m)" ;;
    esac
}

get_server_ip() {
    local ip
    ip=$(curl -s4m5 ip.sb -k 2>/dev/null) || ip=$(curl -s4m5 api.ipify.org 2>/dev/null) || ip=$(curl -s4m5 ifconfig.me 2>/dev/null)
    [ -n "$ip" ] && echo "$ip" && return 0
    die "无法获取服务器公网 IP，请检查网络"
}

get_channel() { cat "${CHANNEL_FILE}" 2>/dev/null || echo "stable"; }

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] \
        || die "无效端口: $1"
}

validate_sni() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] \
        || die "无效域名: $1 (需要合法 FQDN)"
}

port_in_use() {
    ss -tlnp 2>/dev/null | grep -q ":${1} " && return 0
    return 1
}

#=====================================================================
# 下载 sing-box
#=====================================================================

download_sing_box() {
    local channel="${1:-$(get_channel)}"
    local arch; arch=$(get_arch)

    log_info "下载 sing-box (${channel})..."
    local version_tag
    if [ "$channel" = "alpha" ]; then
        version_tag=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases" 2>/dev/null \
            | jq -r '[.[] | select(.prerelease==true)][0].tag_name // "v1.14.0-alpha.27"')
    else
        version_tag=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases" 2>/dev/null \
            | jq -r '[.[] | select(.prerelease==false)][0].tag_name // "v1.13.12"')
    fi
    [ -n "$version_tag" ] && [ "$version_tag" != "null" ] || die "无法获取 sing-box 版本号"

    local version="${version_tag#v}"
    local pkg="sing-box-${version}-linux-${arch}"
    local url="https://github.com/SagerNet/sing-box/releases/download/${version_tag}/${pkg}.tar.gz"
    local sha_url="${url}.sha256sum"

    log_info "版本: ${version} (${arch})"

    local tmp; tmp=$(mktemp -d)
    echo -n "  下载中... "
    if ! curl -fsSL#o "${tmp}/${pkg}.tar.gz" "$url"; then
        rm -rf "$tmp"; die "下载失败"
    fi

    # Try checksum verification (non-fatal if missing)
    local expected_hash
    expected_hash=$(curl -fsSL "$sha_url" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$expected_hash" ]; then
        local actual_hash
        actual_hash=$(sha256sum "${tmp}/${pkg}.tar.gz" | awk '{print $1}')
        [ "$expected_hash" = "$actual_hash" ] || { rm -rf "$tmp"; die "SHA-256 校验失败！"; }
        echo "校验通过"
    else
        echo "完成 (无校验文件)"
    fi

    tar -xzf "${tmp}/${pkg}.tar.gz" -C "$tmp"
    mkdir -p "$APP_DIR"
    mv "${tmp}/${pkg}/sing-box" "$SING_BOX_BIN"
    chown root:root "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    rm -rf "$tmp"

    echo "$channel" > "$CHANNEL_FILE"
    log_info "sing-box 安装完成"
}

#=====================================================================
# 配置读取（纯读取，无副作用）
#=====================================================================

# 确保 cert CN 已缓存
ensure_hy2_sni_cached() {
    local cache="${APP_DIR}/.hy2_sni_cache"
    if [ ! -f "$cache" ]; then
        openssl x509 -in "${CERT_DIR}/hysteria2.crt" -noout -subject -nameopt RFC2253 2>/dev/null \
            | awk -F'=' '{print $NF}' > "$cache"
    fi
    cat "$cache"
}

# 从 server.json 读取所有运行时变量
load_config_vars() {
    local cfg="${APP_DIR}/server.json"
    [ -f "$cfg" ] || die "配置文件不存在: $cfg"

    CFG_SERVER_IP=$(get_server_ip)
    CFG_REALITY_PORT=$(jq -r '.inbounds[0].listen_port' "$cfg")
    CFG_HY2_PORT=$(jq -r '.inbounds[1].listen_port' "$cfg")
    CFG_UUID=$(jq -r '.inbounds[0].users[0].uuid' "$cfg")
    CFG_PUBKEY=$(cat "${APP_DIR}/pubkey" 2>/dev/null || echo "")
    CFG_SHORT_ID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$cfg")
    CFG_REALITY_SNI=$(jq -r '.inbounds[0].tls.server_name' "$cfg")
    CFG_HY2_PASS=$(jq -r '.inbounds[1].users[0].password' "$cfg")
    CFG_HY2_SNI=$(ensure_hy2_sni_cached)
    CFG_SUB_TOKEN=$(cat "${APP_DIR}/sub_token" 2>/dev/null || echo "")
    CFG_SUB_PORT="${SUB_PORT:-$SUB_PORT_DEFAULT}"
}

#=====================================================================
# 生成密钥
#=====================================================================

generate_secrets() {
    log_info "生成密钥和证书..."
    mkdir -p "$CERT_DIR"

    local keypair
    keypair=$("${SING_BOX_BIN}" generate reality-keypair)
    REALITY_PRIVATE_KEY=$(echo "$keypair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    REALITY_PUBLIC_KEY=$(echo  "$keypair" | awk '/PublicKey/ {print $2}'  | tr -d '"')

    REALITY_UUID=$("${SING_BOX_BIN}" generate uuid)
    REALITY_SHORT_ID=$("${SING_BOX_BIN}" generate rand --hex 8)
    HY2_PASSWORD=$("${SING_BOX_BIN}" generate rand --hex 8)

    openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/hysteria2.key" 2>/dev/null
    openssl req -new -x509 -days 36500 \
        -key "${CERT_DIR}/hysteria2.key" \
        -out "${CERT_DIR}/hysteria2.crt" \
        -subj "/CN=${HY2_SNI}" 2>/dev/null

    # 清理旧缓存（证书换了）
    rm -f "${APP_DIR}/.hy2_sni_cache"
    log_info "密钥生成完成"
}

#=====================================================================
# 服务端配置
#=====================================================================

write_server_config() {
    log_info "生成 sing-box 服务端配置..."
    cat > "${APP_DIR}/server.json" << EOF
{
  "log": {"level": "warn", "timestamp": true},
  "inbounds": [
    {
      "type": "vless", "tag": "vless-in", "listen": "::",
      "listen_port": ${REALITY_PORT},
      "sniff": true, "sniff_override_destination": true,
      "users": [{"uuid": "${REALITY_UUID}", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {"server": "${REALITY_SNI}", "server_port": 443},
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": ["${REALITY_SHORT_ID}"]
        }
      }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [{"password": "${HY2_PASSWORD}"}],
      "tls": {
        "enabled": true, "alpn": ["h3"],
        "certificate_path": "${CERT_DIR}/hysteria2.crt",
        "key_path": "${CERT_DIR}/hysteria2.key"
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {
    "rules": [
      {"protocol": "dns", "action": "hijack-dns"},
      {"inbound": ["vless-in", "hy2-in"], "action": "direct"}
    ],
    "final": "direct"
  }
}
EOF
}

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
# 端口碰撞检测
#=====================================================================

check_port_conflicts() {
    local conflicts=""
    for p in "$REALITY_PORT" "$HY2_PORT"; do
        if port_in_use "$p"; then
            conflicts="$conflicts  $p"
        fi
    done
    if [ -n "$conflicts" ]; then
        log_warn "以下端口已被占用:$conflicts"
        log_warn "请修改端口或停止占用进程"
        return 1
    fi
}

#=====================================================================
# 订阅文件
#=====================================================================

generate_sub_token() {
    if [ ! -f "${APP_DIR}/sub_token" ]; then
        mkdir -p "$SUB_DIR"
        "${SING_BOX_BIN}" generate rand --hex 8 > "${APP_DIR}/sub_token" 2>/dev/null || \
            od -An -N8 -tx1 /dev/urandom | tr -d ' \n' > "${APP_DIR}/sub_token" 2>/dev/null || \
            date +%s | sha256sum | head -c 16 > "${APP_DIR}/sub_token"
    fi
}

write_clash_sub() {
    load_config_vars
    mkdir -p "$SUB_DIR"

    # 从 server.json 读取 SNI（确保与运行中配置一致）
    local reality_sni
    reality_sni=$(jq -r '.inbounds[0].tls.server_name' "${APP_DIR}/server.json")

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
    servername: ${reality_sni}
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
import http.server, os, sys, subprocess, time, threading

APP_DIR = '/opt/vps-proxy'
SUB_FILE = os.path.join(APP_DIR, 'sub', 'clash.yaml')
TOKEN_FILE = os.path.join(APP_DIR, 'sub_token')
START_TIME = time.time()

_ip_cache = ('', 0.0)
_req_counts = {}  # simple IP-based rate limit

def get_token():
    try:
        with open(TOKEN_FILE) as f: return f.read().strip()
    except: return None

def get_uptime():
    delta = int(time.time() - START_TIME)
    d, h, m = delta // 86400, (delta % 86400) // 3600, (delta % 3600) // 60
    parts = []
    if d: parts.append(f'{d}d')
    if h: parts.append(f'{h}h')
    parts.append(f'{m}m')
    return ' '.join(parts)

def get_svc_status():
    try:
        r = subprocess.run(['systemctl', 'is-active', 'sing-box'], capture_output=True, text=True, timeout=3)
        return r.stdout.strip()
    except: return 'unknown'

def get_server_ip():
    global _ip_cache
    now = time.time()
    if _ip_cache[0] and (now - _ip_cache[1]) < 60: return _ip_cache[0]
    for cmd in (['curl', '-s4m3', 'ip.sb', '-k'], ['curl', '-s4m3', 'api.ipify.org']):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            ip = r.stdout.strip()
            if ip: _ip_cache = (ip, now); return ip
        except: pass
    _ip_cache = ('N/A', now); return 'N/A'

def check_rate(client_ip):
    now = time.time()
    window = [t for t in _req_counts.get(client_ip, []) if now - t < 10]
    if len(window) >= 30: return False
    window.append(now)
    _req_counts[client_ip] = window
    return True

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        client = self.client_address[0]
        if self.path.startswith('/status') and not check_rate(client):
            self.send_response(429); self.end_headers(); return

        token = get_token()
        if token and self.path == f'/sub/{token}':
            try:
                with open(SUB_FILE, 'rb') as f: data = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'text/yaml; charset=utf-8')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                self.wfile.write(data)
            except FileNotFoundError:
                self.send_response(503); self.end_headers()
                self.wfile.write(b'Config not ready')
        elif self.path == '/health':
            self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
        elif self.path == '/status':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            ip = get_server_ip(); svc = get_svc_status(); up = get_uptime()
            css = 'ok' if svc == 'active' else 'warn'
            self.wfile.write(f'''<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>vps-proxy</title><style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{font-family:ui-monospace,monospace;background:#0f0f1a;color:#c0c0d0;min-height:100vh;display:flex;align-items:center;justify-content:center}}
.card{{background:#1a1a2e;border-radius:12px;padding:2em;max-width:420px;width:90%;box-shadow:0 0 30px rgba(0,212,255,0.08)}}
h1{{color:#00d4ff;font-size:1.2em;margin-bottom:1.2em;text-align:center}}
.row{{display:flex;justify-content:space-between;padding:0.6em 0;border-bottom:1px solid #2a2a3e}}
.row:last-child{{border-bottom:none}}
.label{{opacity:0.6}}.value{{color:#fff;font-weight:600}}
.ok{{color:#00ff88}}.warn{{color:#ffaa00}}
.foot{{text-align:center;margin-top:1.5em;opacity:0.4;font-size:0.8em}}
</style></head><body><div class="card">
<h1>代理节点状态</h1>
<div class="row"><span class="label">IP 地址</span><span class="value">{ip}</span></div>
<div class="row"><span class="label">服务状态</span><span class="value {css}">{svc}</span></div>
<div class="row"><span class="label">运行时间</span><span class="value">{up}</span></div>
<div class="row"><span class="label">订阅端口</span><span class="value">{port}</span></div>
<div class="foot">vps-proxy</div>
</div></body></html>'''.encode())
        else:
            self.send_response(404); self.end_headers()
            self.wfile.write(b'Not Found')

    def log_message(self, *args): pass

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 25500
    httpd = http.server.HTTPServer(('0.0.0.0', port), Handler)
    httpd.serve_forever()
PYEOF

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

#=====================================================================
# 显示客户端配置
#=====================================================================

show_config() {
    load_config_vars

    log_title "Reality 节点"
    echo "vless://${CFG_UUID}@${CFG_SERVER_IP}:${CFG_REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${CFG_REALITY_SNI}&fp=chrome&pbk=${CFG_PUBKEY}&sid=${CFG_SHORT_ID}&type=tcp&headerType=none#vps-proxy-reality"

    log_title "Hysteria2 节点"
    echo "hysteria2://${CFG_HY2_PASS}@${CFG_SERVER_IP}:${CFG_HY2_PORT}?insecure=1&sni=${CFG_HY2_SNI}#vps-proxy-hy2"

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
# 服务管理
#=====================================================================

start_services() {
    log_info "检查配置..."
    "${SING_BOX_BIN}" check -c "${APP_DIR}/server.json" || die "配置校验失败"

    log_info "启动 sing-box..."
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart sing-box 2>/dev/null || true
    systemctl is-active --quiet sing-box 2>/dev/null \
        && log_info "sing-box 运行中" \
        || log_warn "sing-box 启动失败，检查: journalctl -u sing-box -n 20"

    log_info "启动订阅服务器..."
    systemctl restart clash-sub 2>/dev/null || true
    systemctl is-active --quiet clash-sub 2>/dev/null \
        && log_info "订阅服务器运行中" \
        || log_warn "订阅服务器启动失败"
}

#=====================================================================
# 卸载
#=====================================================================

uninstall() {
    if ! confirm "确认卸载 ${APP_NAME}？这将删除所有配置和密钥"; then
        echo "已取消"
        return
    fi
    log_info "卸载 ${APP_NAME}..."
    for svc in sing-box clash-sub; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/clash-sub.service
    rm -rf "$APP_DIR"
    systemctl daemon-reload 2>/dev/null || true
    log_info "卸载完成"
}

#=====================================================================
# 版本切换
#=====================================================================

toggle_version() {
    local current; current=$(get_channel)
    local target
    if [ "$current" = "stable" ]; then target="alpha"; else target="stable"; fi

    log_info "切换 ${current} → ${target} ..."
    local new_bin="${SING_BOX_BIN}.new"

    # 下载新版本到临时位置
    local channel_bak
    channel_bak=$(cat "${CHANNEL_FILE}" 2>/dev/null || echo "stable")
    echo "$target" > "$CHANNEL_FILE"

    local arch; arch=$(get_arch)
    local version_tag
    if [ "$target" = "alpha" ]; then
        version_tag=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases" 2>/dev/null \
            | jq -r '[.[] | select(.prerelease==true)][0].tag_name // "v1.14.0-alpha.27"')
    else
        version_tag=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases" 2>/dev/null \
            | jq -r '[.[] | select(.prerelease==false)][0].tag_name // "v1.13.12"')
    fi

    if [ -z "$version_tag" ] || [ "$version_tag" = "null" ]; then
        echo "$channel_bak" > "$CHANNEL_FILE"
        die "无法获取版本号"
    fi

    local version="${version_tag#v}"
    local pkg="sing-box-${version}-linux-${arch}"
    local url="https://github.com/SagerNet/sing-box/releases/download/${version_tag}/${pkg}.tar.gz"

    local tmp; tmp=$(mktemp -d)
    if ! curl -fsSLo "${tmp}/${pkg}.tar.gz" "$url"; then
        echo "$channel_bak" > "$CHANNEL_FILE"; rm -rf "$tmp"
        die "下载失败"
    fi

    tar -xzf "${tmp}/${pkg}.tar.gz" -C "$tmp"
    mv "${tmp}/${pkg}/sing-box" "$new_bin"
    chown root:root "$new_bin"; chmod +x "$new_bin"
    rm -rf "$tmp"

    # 原子替换
    mv "$new_bin" "$SING_BOX_BIN"

    systemctl restart sing-box 2>/dev/null || true
    log_info "已切换到 ${target}"
}

#=====================================================================
# 修改配置
#=====================================================================

backup_config() {
    local bak="${APP_DIR}/server.json.bak.$(date +%s)"
    cp "${APP_DIR}/server.json" "$bak"
    echo "$bak"
}

modify_reality() {
    local cfg="${APP_DIR}/server.json"
    local current_port current_sni
    current_port=$(jq -r '.inbounds[0].listen_port' "$cfg")
    current_sni=$(jq -r '.inbounds[0].tls.server_name' "$cfg")

    read -r -p "Reality 端口 (当前: ${current_port}): " new_port
    new_port="${new_port:-$current_port}"
    validate_port "$new_port"
    read -r -p "Reality SNI (当前: ${current_sni}): " new_sni
    new_sni="${new_sni:-$current_sni}"
    validate_sni "$new_sni"

    local bak; bak=$(backup_config)
    local tmp; tmp=$(mktemp)
    jq --arg p "$new_port" --arg sni "$new_sni" \
        '.inbounds[0].listen_port = ($p | tonumber) | .inbounds[0].tls.server_name = $sni | .inbounds[0].tls.reality.handshake.server = $sni' \
        "$cfg" > "$tmp"

    # 校验新配置
    if ! "${SING_BOX_BIN}" check -c "$tmp" 2>/dev/null; then
        log_warn "新配置校验失败，已回滚 (备份: $bak)"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$cfg"
    systemctl restart sing-box 2>/dev/null || true
    write_clash_sub
    log_info "Reality 配置已更新"
    show_config
}

modify_hysteria2() {
    local cfg="${APP_DIR}/server.json"
    local current_port current_sni
    current_port=$(jq -r '.inbounds[1].listen_port' "$cfg")
    current_sni=$(ensure_hy2_sni_cached)

    read -r -p "Hysteria2 端口 (当前: ${current_port}): " new_port
    new_port="${new_port:-$current_port}"
    validate_port "$new_port"
    read -r -p "Hysteria2 证书域名 (当前: ${current_sni}): " new_sni
    new_sni="${new_sni:-$current_sni}"
    validate_sni "$new_sni"

    local bak; bak=$(backup_config)

    # 更新服务端配置
    local tmp; tmp=$(mktemp)
    jq --arg p "$new_port" '.inbounds[1].listen_port = ($p | tonumber)' "$cfg" > "$tmp"
    if ! "${SING_BOX_BIN}" check -c "$tmp" 2>/dev/null; then
        log_warn "新配置校验失败，已回滚 (备份: $bak)"
        rm -f "$tmp"; return 1
    fi
    mv "$tmp" "$cfg"

    # 重新生成自签证书
    openssl ecparam -genkey -name prime256v1 -out "${CERT_DIR}/hysteria2.key" 2>/dev/null
    openssl req -new -x509 -days 36500 \
        -key "${CERT_DIR}/hysteria2.key" \
        -out "${CERT_DIR}/hysteria2.crt" \
        -subj "/CN=${new_sni}" 2>/dev/null
    rm -f "${APP_DIR}/.hy2_sni_cache"

    systemctl restart sing-box 2>/dev/null || true
    write_clash_sub
    log_info "Hysteria2 配置已更新"
    show_config
}

#=====================================================================
# 菜单
#=====================================================================

show_menu() {
    echo ""
    echo "  ${APP_NAME} 已安装"
    echo ""
    echo "  1. 重新安装"
    echo "  2. 修改 Reality 配置"
    echo "  3. 修改 Hysteria2 配置"
    echo "  4. 显示客户端配置"
    echo "  5. 重启订阅服务器"
    echo "  6. 切换版本 (Stable ⇄ Alpha)"
    echo "  7. 卸载"
    echo ""
    read -r -p "  请选择 (1-7): " choice

    case $choice in
        1) confirm "确认重新安装？这将删除所有配置" || return; uninstall; main_install ;;
        2) modify_reality ;;
        3) modify_hysteria2 ;;
        4) show_config ;;
        5) systemctl restart clash-sub 2>/dev/null || true; show_config ;;
        6) toggle_version; show_config ;;
        7) uninstall ;;
        *) echo "无效选项" ;;
    esac
}

#=====================================================================
# 主安装
#=====================================================================

main_install() {
    banner
    install_deps

    # 交互输入
    echo ""
    read -r -p "Reality 端口 (默认 443): " REALITY_PORT; REALITY_PORT="${REALITY_PORT:-443}"
    validate_port "$REALITY_PORT"
    read -r -p "Reality SNI (默认 itunes.apple.com): " REALITY_SNI; REALITY_SNI="${REALITY_SNI:-itunes.apple.com}"
    validate_sni "$REALITY_SNI"

    echo ""
    read -r -p "Hysteria2 端口 (默认 8443): " HY2_PORT; HY2_PORT="${HY2_PORT:-8443}"
    validate_port "$HY2_PORT"
    read -r -p "Hysteria2 证书域名 (默认 bing.com): " HY2_SNI; HY2_SNI="${HY2_SNI:-bing.com}"
    validate_sni "$HY2_SNI"

    # 端口冲突检测
    check_port_conflicts || {
        if ! confirm "端口冲突，是否继续？"; then
            die "安装取消"
        fi
    }

    download_sing_box
    generate_secrets

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

[ "$(id -u)" -eq 0 ] || die "请用 root 运行: sudo bash install.sh"

if [ -f "${APP_DIR}/server.json" ] && [ -x "$SING_BOX_BIN" ] && [ -f /etc/systemd/system/sing-box.service ]; then
    case "${1:-}" in
        config|show)  show_config; exit 0 ;;
        toggle)       toggle_version; show_config; exit 0 ;;
        restart-sub)  systemctl restart clash-sub 2>/dev/null; show_config; exit 0 ;;
        uninstall)    uninstall; exit 0 ;;
        reinstall)    uninstall; main_install; exit 0 ;;
        *)            show_menu; exit 0 ;;
    esac
fi

main_install
