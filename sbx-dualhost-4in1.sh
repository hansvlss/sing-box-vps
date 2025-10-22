#!/usr/bin/env bash
# sbx-dualhost-4in1.sh v2
# sing-box 4in1 (VMess/WS on 443 via nginx, VLESS/Reality:8448, Trojan:8444, HY2:8447)
# Dual-host:  -w <WS/CDN host>  -r <REAL/DIRECT host>

set -euo pipefail
IFS=$' \n\t'

WS_HOST=""        # -w cdn domain (可橙云)
REAL_HOST=""      # -r 直连域名（灰云）
HY2_OBFS="off"    # on|off

usage(){
  cat <<USG
用法: bash $0 -w cdn.example.com -r real.example.com [--hy2-obfs on|off]
示例: bash $0 -w cdnvpn.example.com -r bbvpn.example.com
说明:
  -w: 提供给 VMess+WS 的域名（可开橙云，经 Nginx 443 反代到本地 12080）
  -r: 直连域名（灰云），用于 ACME 证书签发、Trojan/Reality/HY2
USG
  exit 1
}

# ---------------- 参数解析 ----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--ws-host)   WS_HOST="${2:-}"; shift 2;;
    -r|--real-host) REAL_HOST="${2:-}"; shift 2;;
    --hy2-obfs)     HY2_OBFS="${2:-off}"; shift 2;;
    -h|--help)      usage;;
    *) echo "未知参数: $1"; usage;;
  esac
done

[[ -z "$WS_HOST" || -z "$REAL_HOST" ]] && { echo "必须同时指定 -w 与 -r"; usage; }
[[ "$HY2_OBFS" != "on" && "$HY2_OBFS" != "off" ]] && { echo "--hy2-obfs 必须为 on|off"; exit 1; }

echo "[START] WS/CDN=${WS_HOST}  DIRECT=${REAL_HOST}  HY2-OBFS=${HY2_OBFS}"
[[ $EUID -ne 0 ]] && { echo "请用 root 运行"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

# ---------- APT 防冲突：等待锁 + 暂停 timer ----------
stop_apt_timers(){
  systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
  systemctl stop apt-daily.timer   apt-daily-upgrade.timer   2>/dev/null || true
}
start_apt_timers(){
  systemctl start apt-daily.timer  apt-daily-upgrade.timer   2>/dev/null || true
}
wait_for_apt(){
  echo "[INFO] 等待系统 apt/dpkg 释放锁..."
  for i in {1..100}; do
    if ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
       && ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       && ! fuser /var/cache/apt/archives/lock >/dev/null 2>&1; then
      echo "[OK] apt 锁空闲"
      return 0
    fi
    sleep 3
  done
  echo "[WARN] 等锁超时，继续执行"
}
stop_apt_timers
trap 'start_apt_timers' EXIT
wait_for_apt

# ---------- 安装依赖（带重试） ----------
echo "[STEP] apt update && install deps"
for n in 1 2 3; do
  apt-get update && break || { echo "[WARN] apt update 重试 $n"; sleep 5; }
done
DEPS=(curl wget jq nginx python3 python3-pip ufw unzip tar openssl tmux tcpdump dos2unix socat net-tools sudo)
apt-get install -y "${DEPS[@]}" || {
  dpkg --configure -a || true
  apt-get -f install || true
  apt-get install -y "${DEPS[@]}"
}

install -d /etc/sing-box
WEB_ROOT="/var/www/singbox"; install -d "$WEB_ROOT"

# ---------- 安装 sing-box ----------
install_singbox(){
  echo "[STEP] 安装 sing-box"
  set +e
  case "$(uname -m)" in
    x86_64|amd64) SB_ARCH="linux-amd64" ;;
    aarch64|arm64) SB_ARCH="linux-arm64" ;;
    armv7l) SB_ARCH="linux-armv7" ;;
    *) SB_ARCH="linux-amd64" ;;
  esac
  V="v1.12.9"
  F="sing-box-${V#v}-${SB_ARCH}.tar.gz"
  URLS=(
    "https://github.com/SagerNet/sing-box/releases/download/${V}/${F}"
    "https://ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/${V}/${F}"
    "https://download.fastgit.org/SagerNet/sing-box/releases/download/${V}/${F}"
  )
  T="$(mktemp -d)"; TGZ="$T/sb.tgz"; ok=0
  for u in "${URLS[@]}"; do
    echo "[INFO] 下载: $u"
    if curl -fsSL --connect-timeout 20 -o "$TGZ" "$u"; then
      if head -c 2 "$TGZ" | od -An -tx1 | tr -d ' \n' | grep -q '^1f8b'; then ok=1; break; fi
    fi
  done
  [[ $ok -eq 1 ]] || { echo "[ERROR] sing-box 下载失败"; rm -rf "$T"; exit 1; }
  tar -xzf "$TGZ" -C "$T"
  install -m 755 "$(find "$T" -type f -name sing-box -print -quit)" /usr/local/bin/sing-box
  /usr/local/bin/sing-box version || true
  rm -rf "$T"; set -e
}
install_singbox

# ---------- 证书：REAL_HOST 申请 ACME (Let’s Encrypt)，失败则自签 ----------
CERT_DIR="/etc/sing-box"; CERT="$CERT_DIR/cert.pem"; KEY="$CERT_DIR/key.pem"
issue_cert(){
  echo "[STEP] 签发证书 for ${REAL_HOST}"
  systemctl stop nginx >/dev/null 2>&1 || true
  ufw allow 80/tcp || true
  if [[ ! -x "${HOME}/.acme.sh/acme.sh" ]]; then
    curl -fsSL https://get.acme.sh | sh -s email=admin@"${REAL_HOST}" || true
  fi
  "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  command -v socat >/dev/null || apt-get install -y socat
  set +e
  "${HOME}/.acme.sh/acme.sh" --issue -d "${REAL_HOST}" --standalone -k ec-256 --force
  r=$?; set -e
  if [[ $r -eq 0 ]]; then
    D="${HOME}/.acme.sh/${REAL_HOST}_ecc"
    install -m 600 "${D}/${REAL_HOST}.key" "$KEY"
    install -m 644 "${D}/fullchain.cer" "$CERT"
    echo "[OK] ACME 成功"
  else
    echo "[WARN] ACME 失败，生成自签证书"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -days 365 \
      -subj "/CN=${REAL_HOST}" -nodes -keyout "$KEY" -out "$CERT"
    chmod 600 "$KEY"; chmod 644 "$CERT"
  fi
}
issue_cert

# ---------- 生成凭据 ----------
echo "[STEP] 生成凭据"
UUID=$(/usr/local/bin/sing-box generate uuid)
TROJAN_PWD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 18 || true)
WS_PATH="ws-$(tr -dc a-z0-9 </dev/urandom | head -c 6 || true)"
HY2_PWD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 18 || true)
HY2_OBFS_STR=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16 || true)

TMP_R="$(mktemp)"
if /usr/local/bin/sing-box generate reality-keypair >"$TMP_R" 2>/dev/null; then
  REALITY_PRIVATE=$(awk -F': +' '/[Pp]rivate/{print $2;exit}' "$TMP_R")
  REALITY_PUBLIC=$(awk -F': +' '/[Pp]ublic/{print $2;exit}'  "$TMP_R")
fi
rm -f "$TMP_R"
REALITY_SHORTID=$(tr -dc 'a-f0-9' </dev/urandom | head -c 8 || true)

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
export HY2_OBFS="${HY2_OBFS_STR}"
export HY2_OBFS_SWITCH="${HY2_OBFS}"
ENV
chmod 600 /root/sb.env

# ---------- 写入 sing-box 配置 ----------
echo "[STEP] 写入 /etc/sing-box/config.json"
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
      "tls": { "enabled": true, "certificate_path": "${CERT}", "key_path": "${KEY}", "alpn": ["h3"] }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": { "final": "direct" }
}
JSON

# HY2 混淆
if [[ "${HY2_OBFS}" == "on" && -n "${HY2_OBFS_STR}" ]]; then
  tmpf="$(mktemp)"
  jq --arg ob "${HY2_OBFS_STR}" '(.inbounds[] | select(.type=="hysteria2")) += { "obfs": {"type":"salamander", "password": $ob} }' \
     /etc/sing-box/config.json >"$tmpf" && mv "$tmpf" /etc/sing-box/config.json
fi
/usr/local/bin/sing-box check -c /etc/sing-box/config.json || true

# ---------- systemd ----------
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

# ---------- 订阅 sub.txt ----------
echo "[STEP] 生成订阅 sub.txt"
python3 - <<'PY' > "/var/www/singbox/sub.txt"
import json, base64
d={}
with open('/root/sb.env') as f:
    for line in f:
        line=line.strip()
        if line.startswith('export '):
            k,v=line[7:].split('=',1); d[k]=v.strip().strip('"')
dom_ws=d.get('WS_HOST',''); dom_real=d.get('REAL_HOST','')
uuid=d.get('UUID',''); ws=d.get('WS_PATH','')
pbk=d.get('REALITY_PUBLIC',''); sid=d.get('REALITY_SHORTID','')
tro=d.get('TROJAN_PWD',''); hy2pwd=d.get('HY2_PWD','')
hy2switch=d.get('HY2_OBFS_SWITCH','off'); hy2obfs=d.get('HY2_OBFS','')

vm={"v":"2","ps":"VMESS-WS","add":dom_ws,"port":"443","id":uuid,"aid":"0",
    "net":"ws","type":"none","host":dom_ws,"path":"/"+ws,"tls":"tls","sni":dom_ws}
print("vmess://"+base64.b64encode(json.dumps(vm,separators=(',',':')).encode()).decode())
print()
print(f"vless://{uuid}@{dom_real}:8448?encryption=none&flow=xtls-rprx-vision&security=reality"
      f"&sni=www.cloudflare.com&pbk={pbk}&sid={sid}#VLESS-Reality")
print()
print(f"trojan://{tro}@{dom_real}:8444?security=tls&sni={dom_real}#Trojan-TLS")
print()
if hy2switch=='on':
    print(f"hysteria2://{hy2pwd}@{dom_real}:8447?obfs=salamander:{hy2obfs}&alpn=h3&sni={dom_real}&insecure=0#Hysteria2")
else:
    print(f"hysteria2://{hy2pwd}@{dom_real}:8447?alpn=h3&sni={dom_real}&insecure=0#Hysteria2")
PY
chmod 644 "${WEB_ROOT}/sub.txt"

# ---------- Nginx: 443 反代 WS + sub.txt ----------
echo "[STEP] 配置 nginx (443 WS 反代 + /sub.txt)"
cat > /etc/nginx/sites-available/singbox-site.conf <<NGX
server {
  listen 80;
  server_name ${WS_HOST} ${REAL_HOST};
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl http2;
  server_name ${WS_HOST} ${REAL_HOST};

  ssl_certificate     ${CERT};
  ssl_certificate_key ${KEY};

  # 订阅
  location = /sub.txt { root ${WEB_ROOT}; default_type text/plain; }

  # VMess WebSocket (仅 WS_HOST 会使用到)
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

  # 其他路径可 404 或挂伪装站点
  location / { return 404; }
}
NGX
ln -sf /etc/nginx/sites-available/singbox-site.conf /etc/nginx/sites-enabled/singbox-site.conf
nginx -t && systemctl restart nginx || true

# ---------- UFW ----------
echo "[STEP] 配置 UFW"
ufw limit 22/tcp comment 'SSH' || true
ufw allow 80/tcp  || true
ufw allow 443/tcp || true
ufw allow 8444/tcp || true
ufw allow 8448/tcp || true
ufw allow 8447/udp || true
ufw --force enable || true

# ---------- 自检与输出 ----------
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
echo "== subscription preview (first 80 lines) =="
curl -sS --max-time 8 https://${WS_HOST}/sub.txt | sed -n '1,80p' || \
echo "[WARN] 通过 WS_HOST 拉取 sub.txt 失败（若 WS_HOST 橙云且缓存，请稍后再试）"

echo
echo "==== DONE ===="
echo "Subscription (WS/CDN): https://${WS_HOST}/sub.txt"
echo "VMess WS : ${WS_HOST}:443   path /${WS_PATH}   UUID ${UUID}"
echo "VLESS RLT: ${REAL_HOST}:8448 UUID ${UUID}  PBK ${REALITY_PUBLIC}  SID ${REALITY_SHORTID}"
echo "Trojan TLS: ${REAL_HOST}:8444  password ${TROJAN_PWD}"
echo "HY2      : ${REAL_HOST}:8447  password ${HY2_PWD}  obfs-switch ${HY2_OBFS}"
