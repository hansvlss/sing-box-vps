#!/usr/bin/env bash
# sbx-dualhost-4in1.sh
# Sing-Box (Trojan/VLESS-Reality/Hy2 + VMess-WS local) + Nginx 443 reverse proxy + sub.txt
# Usage:
#   bash sbx-dualhost-4in1.sh -w WS_HOST -r REAL_HOST [--hy2-obfs on|off]

set -euo pipefail
IFS=$' \n\t'

WS_HOST=""        # 走CDN的域名（橙云）
REAL_HOST=""      # 直连域名（灰云，用于证书 & 非WS协议）
HY2_OBFS_SWITCH="off"  # on/off
SB_VER="v1.12.9"

usage() {
  cat <<USG
用法:
  bash $0 -w cdn.example.com -r direct.example.com [--hy2-obfs on|off]

说明:
  -w  WS/CDN 域名（Cloudflare 橙云）→ 用于 443 上的 VMess-WS
  -r  直连域名（灰云，仅DNS）→ 用于 ACME 证书、Trojan/VLESS-Reality/Hy2
  --hy2-obfs on|off  默认 off
USG
  exit 1
}

# -------- 参数解析 --------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--ws)       WS_HOST="${2:-}"; shift 2;;
    -r|--real)     REAL_HOST="${2:-}"; shift 2;;
    --hy2-obfs)    HY2_OBFS_SWITCH="${2:-off}"; shift 2;;
    -h|--help)     usage;;
    *) echo "未知参数: $1"; usage;;
  esac
done

[[ -z "$WS_HOST" || -z "$REAL_HOST" ]] && { echo "必须同时提供 -w 与 -r"; usage; }
if [[ "$HY2_OBFS_SWITCH" != "on" && "$HY2_OBFS_SWITCH" != "off" ]]; then
  echo "--hy2-obfs 必须为 on 或 off"; exit 1
fi

echo "[START] WS/CDN=$WS_HOST  DIRECT=$REAL_HOST  HY2-OBFS=$HY2_OBFS_SWITCH"

# -------- 基础环境 & apt 锁处理 --------
export DEBIAN_FRONTEND=noninteractive

wait_apt() {
  local tries=30
  while fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    ((tries--)) || { echo "apt 锁等待超时"; exit 1; }
    echo "[INFO] 等待 apt 锁释放…"; sleep 3
  done
}

echo "[STEP] apt update & install deps"
wait_apt
apt-get update -y
apt-get upgrade -y || true
apt-get install -y curl wget jq nginx unzip tar openssl socat ufw python3 || true

install -d /etc/sing-box
WEB_ROOT="/var/www/singbox"; install -d "$WEB_ROOT"

# -------- 安装 sing-box --------
install_singbox() {
  local ARCH="$(uname -m)" SB_ARCH
  case "$ARCH" in
    x86_64|amd64) SB_ARCH="linux-amd64";;
    aarch64|arm64) SB_ARCH="linux-arm64";;
    armv7l) SB_ARCH="linux-armv7";;
    *) SB_ARCH="linux-amd64";;
  esac
  local F="sing-box-${SB_VER#v}-${SB_ARCH}.tar.gz"
  local U1="https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/${F}"
  local U2="https://ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/${F}"

  echo "[STEP] Install sing-box $SB_VER"
  tmp="$(mktemp -d)"
  if ! curl -fsSL4 --connect-timeout 20 -o "$tmp/sb.tgz" "$U1"; then
    curl -fsSL4 --connect-timeout 20 -o "$tmp/sb.tgz" "$U2"
  fi
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  install -m 755 "$(find "$tmp" -type f -name sing-box -print -quit)" /usr/local/bin/sing-box
  rm -rf "$tmp"
  sing-box version || true
}
install_singbox

# -------- ACME 证书（优先 REAL_HOST） --------
CERT_DIR="/etc/sing-box"
CERT="$CERT_DIR/cert.pem"
KEY="$CERT_DIR/key.pem"

issue_cert() {
  echo "[STEP] Issue cert for $REAL_HOST"
  systemctl stop nginx >/dev/null 2>&1 || true
  ufw allow 80/tcp || true

  if [[ ! -x "${HOME}/.acme.sh/acme.sh" ]]; then
    curl -fsSL https://get.acme.sh | sh -s email=admin@"${REAL_HOST}" || true
  fi
  "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  command -v socat >/dev/null || apt-get install -y socat

  set +e
  "${HOME}/.acme.sh/acme.sh" --issue -d "${REAL_HOST}" --standalone -k ec-256 --force
  ret=$?
  set -e

  if [[ $ret -eq 0 ]]; then
    ACMED="${HOME}/.acme.sh/${REAL_HOST}_ecc"
    install -m 600 "${ACMED}/${REAL_HOST}.key" "$KEY"
    install -m 644 "${ACMED}/fullchain.cer" "$CERT"
    echo "[OK] ACME 成功"
  else
    echo "[WARN] ACME 失败，回退自签"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -days 365 \
      -subj "/CN=${REAL_HOST}" -nodes -keyout "$KEY" -out "$CERT"
    chmod 600 "$KEY"; chmod 644 "$CERT"
  fi
}
issue_cert

# -------- 生成凭据 --------
echo "[STEP] Generate credentials"
UUID="$(sing-box generate uuid)"
TROJAN_PWD="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 18)"
WS_PATH="ws-$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
HY2_PWD="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 18)"
HY2_OBFS="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)"

TMPR="$(mktemp)"
if sing-box generate reality-keypair >"$TMPR" 2>/dev/null; then
  REALITY_PRIVATE="$(awk -F': +' '/[Pp]rivate/{print $2}' "$TMPR")"
  REALITY_PUBLIC="$(awk -F': +' '/[Pp]ublic/{print $2}' "$TMPR")"
fi
rm -f "$TMPR"
REALITY_SHORTID="$(tr -dc 'a-f0-9' </dev/urandom | head -c 8)"

umask 177
cat > /root/sb.env <<ENV
export WS_HOST="${WS_HOST}"
export REAL_HOST="${REAL_HOST}"
export UUID="${UUID}"
export TROJAN_PWD="${TROJAN_PWD}"
export REALITY_PRIVATE="${REALITY_PRIVATE}"
export REALITY_PUBLIC="${REALITY_PUBLIC}"
export REALITY_SHORTID="${REALITY_SHORTID}"
export WS_PATH="${WS_PATH}"
export HY2_PWD="${HY2_PWD}"
export HY2_OBFS="${HY2_OBFS}"
export HY2_OBFS_SWITCH="${HY2_OBFS_SWITCH}"
ENV
chmod 600 /root/sb.env

# -------- 写入 sing-box 配置 --------
echo "[STEP] write /etc/sing-box/config.json"
cat > /etc/sing-box/config.json <<JSON
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "trojan",
      "listen": "::",
      "listen_port": 8444,
      "users": [{ "password": "${TROJAN_PWD}" }],
      "tls": {
        "enabled": true,
        "server_name": "${REAL_HOST}",
        "alpn": ["h2","http/1.1"],
        "certificate_path": "${CERT}",
        "key_path": "${KEY}"
      }
    },
    {
      "type": "vmess",
      "listen": "127.0.0.1",
      "listen_port": 12080,
      "users": [{ "uuid": "${UUID}" }],
      "transport": { "type": "ws", "path": "/${WS_PATH}" }
    },
    {
      "type": "vless",
      "listen": "::",
      "listen_port": 8448,
      "users": [{ "uuid": "${UUID}", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "www.cloudflare.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "www.cloudflare.com", "server_port": 443 },
          "private_key": "${REALITY_PRIVATE}",
          "short_id": ["${REALITY_SHORTID}"]
        },
        "alpn": ["h2","http/1.1"]
      }
    },
    {
      "type": "hysteria2",
      "listen": "::",
      "listen_port": 8447,
      "up_mbps": 100,
      "down_mbps": 100,
      "users": [{ "password": "${HY2_PWD}" }],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT}",
        "key_path": "${KEY}",
        "alpn": ["h3"]
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": { "final": "direct" }
}
JSON

# 若开启 Hy2 混淆，补写 obfs 字段
if [[ "$HY2_OBFS_SWITCH" == "on" ]]; then
  tmpf="$(mktemp)"
  jq --arg ob "$HY2_OBFS" '(.inbounds[] | select(.type=="hysteria2")) += { "obfs": {"type":"salamander","password": $ob} }' \
     /etc/sing-box/config.json >"$tmpf" && mv "$tmpf" /etc/sing-box/config.json
fi

# 配置 systemd
cat > /etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now sing-box || true
sing-box check -c /etc/sing-box/config.json || true

# -------- 订阅 sub.txt --------
python3 - <<'PY' > "${WEB_ROOT}/sub.txt"
import json, base64, os
env={}
with open('/root/sb.env') as f:
  for ln in f:
    if ln.startswith('export '):
      k,v=ln[7:].split('=',1); env[k]=v.strip().strip('"')
dom_ws  = env.get('WS_HOST','')
dom_real= env.get('REAL_HOST','')
uuid    = env.get('UUID','')
ws      = env.get('WS_PATH','')
pbk     = env.get('REALITY_PUBLIC','')
sid     = env.get('REALITY_SHORTID','')
tro     = env.get('TROJAN_PWD','')
hy2pwd  = env.get('HY2_PWD','')
hy2sw   = env.get('HY2_OBFS_SWITCH','off')
hy2obfs = env.get('HY2_OBFS','')

# VMess via CDN 443
vm={"v":"2","ps":"VMESS-WS","add":dom_ws,"port":"443","id":uuid,"aid":"0",
    "net":"ws","type":"none","host":dom_ws,"path":"/"+ws,"tls":"tls","sni":dom_ws}
print("vmess://"+base64.b64encode(json.dumps(vm,separators=(',',':')).encode()).decode())
print()
print(f"vless://{uuid}@{dom_real}:8448?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.cloudflare.com&pbk={pbk}&sid={sid}#VLESS-Reality")
print()
print(f"trojan://{tro}@{dom_real}:8444?security=tls&sni={dom_real}#Trojan-TLS")
print()
if hy2sw=='on':
  print(f"hysteria2://{hy2pwd}@{dom_real}:8447?obfs=salamander:{hy2obfs}&alpn=h3&sni={dom_real}&insecure=0#Hysteria2")
else:
  print(f"hysteria2://{hy2pwd}@{dom_real}:8447?alpn=h3&sni={dom_real}&insecure=0#Hysteria2")
PY
chmod 644 "${WEB_ROOT}/sub.txt"

# -------- Nginx：443 反代 WS + 暴露 sub.txt --------
echo "[STEP] configure nginx 443 reverse proxy"
cat > /etc/nginx/sites-available/singbox-site.conf <<NGX
server {
  listen 80;
  server_name ${WS_HOST} ${REAL_HOST};
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl http2;
  server_name ${WS_HOST} ${REAL_HOST};
  ssl_certificate ${CERT};
  ssl_certificate_key ${KEY};

  # 订阅文件
  location = /sub.txt {
    root ${WEB_ROOT};
    default_type text/plain;
  }

  # 反代到本地 WS
  location /${WS_PATH} {
    proxy_pass http://127.0.0.1:12080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_read_timeout 86400;
  }

  # 其余返回 404
  location / { return 404; }
}
NGX
ln -sf /etc/nginx/sites-available/singbox-site.conf /etc/nginx/sites-enabled/singbox-site.conf
nginx -t && systemctl restart nginx || true

# -------- UFW --------
echo "[STEP] configure ufw"
ufw limit 22/tcp comment 'SSH' || true
ufw allow 80/tcp  || true
ufw allow 443/tcp || true
ufw allow 8444/tcp || true
ufw allow 8448/tcp || true
ufw allow 8447/udp || true
ufw --force enable || true

# -------- 自检输出 --------
echo
echo "== listen ports =="
ss -tulpen | egrep '(:443 |:8444|:8448)' || true
ss -ulpen | grep ':8447' || true

echo
echo "== cert issuer (443 / 8444) =="
for p in 443 8444; do
  echo --- $p ---
  timeout 6 openssl s_client -connect ${REAL_HOST}:$p -servername ${REAL_HOST} -alpn h2 </dev/null 2>/dev/null \
    | openssl x509 -noout -issuer -subject -dates || true
done

echo
echo "==== DONE ===="
echo "Subscribe : https://${WS_HOST}/sub.txt"
echo "VMess WS  : ${WS_HOST}:443   path /${WS_PATH}   UUID ${UUID}"
echo "VLESS RLT : ${REAL_HOST}:8448   UUID ${UUID}  PBK ${REALITY_PUBLIC}  SID ${REALITY_SHORTID}"
echo "Trojan TLS: ${REAL_HOST}:8444   password ${TROJAN_PWD}"
echo "HY2       : ${REAL_HOST}:8447   password ${HY2_PWD}   obfs-switch ${HY2_OBFS_SWITCH}"
