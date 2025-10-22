#!/usr/bin/env bash
# sbx-dualhost-4in1.sh
# sing-box 4 协议 + 双域名：VMess(WS+TLS) 经 CDN；Trojan/Hysteria2/Reality 直连
set -euo pipefail
IFS=$' \n\t'

# ---------- 参数 ----------
DOMAIN_WS=""   # 用于 VMess(WS+TLS) + /sub.txt + 面板（建议橙云）
DOMAIN_DIR=""  # 用于 Trojan/Hysteria2/Reality（必须灰云）
HY2_OBFS="off" # on/off

usage(){
  cat <<USG
用法:
  bash $0 -w domain_ws -r domain_dir [--hy2-obfs on|off]

示例:
  bash $0 -w aavpn.100998.xyz -r direct.100998.xyz --hy2-obfs on
USG
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--ws)    DOMAIN_WS="${2:-}"; shift 2;;
    -r|--direct)DOMAIN_DIR="${2:-}"; shift 2;;
    --hy2-obfs) HY2_OBFS="${2:-off}"; shift 2;;
    -h|--help)  usage;;
    *) echo "未知参数: $1"; usage;;
  esac
done

[[ -z "$DOMAIN_WS"  || -z "$DOMAIN_DIR" ]] && { echo "必须同时指定 -w 与 -r 域名"; usage; }
[[ "$HY2_OBFS" != "on" && "$HY2_OBFS" != "off" ]] && { echo "--hy2-obfs 仅支持 on/off"; exit 1; }
[[ $EUID -ne 0 ]] && { echo "请用 root 运行"; exit 1; }

echo "[START] WS/CDN=${DOMAIN_WS}  DIRECT=${DOMAIN_DIR}  HY2-OBFS=${HY2_OBFS}"
export DEBIAN_FRONTEND=noninteractive

# ---------- 依赖 ----------
apt-get update -y
apt-get install -y curl wget jq nginx python3 python3-pip ufw unzip tar openssl tmux tcpdump dos2unix socat net-tools

install -d /etc/sing-box
WEB_ROOT="/var/www/singbox"; install -d "$WEB_ROOT"

# ---------- 安装 sing-box ----------
install_singbox() {
  set +e
  case "$(uname -m)" in
    x86_64|amd64) SB_ARCH="linux-amd64";;
    aarch64|arm64) SB_ARCH="linux-arm64";;
    armv7l)        SB_ARCH="linux-armv7";;
    *)             SB_ARCH="linux-amd64";;
  esac
  V="v1.12.9"; F="sing-box-${V#v}-${SB_ARCH}.tar.gz"
  for U in \
    "https://github.com/SagerNet/sing-box/releases/download/${V}/${F}" \
    "https://ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/${V}/${F}"
  do
    TMP="$(mktemp -d)"; if curl -fsSL --connect-timeout 15 -o "$TMP/sb.tgz" "$U"; then
      if head -c2 "$TMP/sb.tgz" | od -An -tx1 | tr -d ' \n' | grep -q '^1f8b'; then
        tar -xzf "$TMP/sb.tgz" -C "$TMP"
        install -m755 "$(find "$TMP" -type f -name sing-box -print -quit)" /usr/local/bin/sing-box
        rm -rf "$TMP"; set -e; return
      fi
    fi
    rm -rf "$TMP"
  done
  echo "[ERR] sing-box 下载失败"; exit 1
}
install_singbox

# ---------- 证书：为两个域名各签一套 ----------
CERT_DIR="/etc/sing-box"; install -d "$CERT_DIR"
CERT_WS="${CERT_DIR}/ws_cert.pem"; KEY_WS="${CERT_DIR}/ws_key.pem"
CERT_DIRCT="${CERT_DIR}/dir_cert.pem"; KEY_DIRCT="${CERT_DIR}/dir_key.pem"

issue_one_cert(){
  local dn="$1" cert="$2" key="$3"
  systemctl stop nginx >/dev/null 2>&1 || true
  ufw allow 80/tcp || true
  if [[ ! -x "${HOME}/.acme.sh/acme.sh" ]]; then
    curl -fsSL https://get.acme.sh | sh -s email=admin@"${dn}" || true
  fi
  "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

  set +e
  "${HOME}/.acme.sh/acme.sh" --issue -d "${dn}" --standalone -k ec-256 --force
  r=$?; set -e
  if [[ $r -eq 0 ]]; then
    d="${HOME}/.acme.sh/${dn}_ecc"
    install -m600 "${d}/${dn}.key" "$key"
    install -m644 "${d}/fullchain.cer" "$cert"
    echo "[OK] ACME 证书: $dn"
  else
    echo "[WARN] ACME 失败: ${dn}，回落自签"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -days 365 \
      -subj "/CN=${dn}" -nodes -keyout "$key" -out "$cert"
    chmod 600 "$key"; chmod 644 "$cert"
  fi
}

issue_one_cert "$DOMAIN_WS"  "$CERT_WS"   "$KEY_WS"
issue_one_cert "$DOMAIN_DIR" "$CERT_DIRCT" "$KEY_DIRCT"

# ---------- 凭据 ----------
UUID=$(/usr/local/bin/sing-box generate uuid)
TROJAN_PWD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 18)
WS_PATH="ws-$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
HY2_PWD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 18)
HY2_OBFS_STR=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

TMP_REALITY="$(mktemp)"
/usr/local/bin/sing-box generate reality-keypair >"$TMP_REALITY" 2>/dev/null || true
REALITY_PRIVATE=$(awk -F': +' '/[Pp]rivate/{print $2;exit}' "$TMP_REALITY" || true)
REALITY_PUBLIC=$(awk -F': +' '/[Pp]ublic/{print $2;exit}' "$TMP_REALITY" || true)
rm -f "$TMP_REALITY"
REALITY_SHORTID=$(tr -dc 'a-f0-9' </dev/urandom | head -c 8)

umask 177
cat > /root/sb.env <<ENV
export DOMAIN_WS="${DOMAIN_WS}"
export DOMAIN_DIR="${DOMAIN_DIR}"
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

# ---------- sing-box 配置（四协议） ----------
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
        "server_name": "${DOMAIN_DIR}",
        "alpn": ["h2", "http/1.1"],
        "certificate_path": "${CERT_DIRCT}",
        "key_path": "${KEY_DIRCT}"
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
        "server_name": "${DOMAIN_DIR}",
        "certificate_path": "${CERT_DIRCT}",
        "key_path": "${KEY_DIRCT}",
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

# 可选：HY2 混淆
if [[ "${HY2_OBFS}" == "on" ]]; then
  tmpf="$(mktemp)"
  jq --arg ob "${HY2_OBFS_STR}" '(.inbounds[] | select(.type=="hysteria2")) += { "obfs": {"type":"salamander","password":$ob} }' \
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
python3 - <<'PY' > "${WEB_ROOT}/sub.txt"
import json, base64, os
def env(k, d=""): return os.environ.get(k, d)
dom_ws = env('DOMAIN_WS'); dom_dir = env('DOMAIN_DIR')
uuid = env('UUID'); ws = env('WS_PATH')
pbk = env('REALITY_PUBLIC'); sid = env('REALITY_SHORTID')
tro = env('TROJAN_PWD'); hy2 = env('HY2_PWD')
hy2sw = env('HY2_OBFS_SWITCH','off'); ob = env('HY2_OBFS','')

vm = {"v":"2","ps":"VMESS-WS(CDN)","add":dom_ws,"port":"443","id":uuid,"aid":"0",
      "net":"ws","type":"none","host":dom_ws,"path":"/"+ws,"tls":"tls","sni":dom_ws}
print("vmess://"+base64.b64encode(json.dumps(vm,separators=(',',':')).encode()).decode())
print()
print(f"vless://{uuid}@{dom_dir}:8448?encryption=none&flow=xtls-rprx-vision&security=reality"
      f"&sni=www.cloudflare.com&pbk={pbk}&sid={sid}#VLESS-Reality(DIRECT)")
print()
print(f"trojan://{tro}@{dom_dir}:8444?security=tls&sni={dom_dir}#Trojan-TLS(DIRECT)")
print()
if hy2sw=='on':
    print(f"hysteria2://{hy2}@{dom_dir}:8447?obfs=salamander:{ob}&alpn=h3&sni={dom_dir}&insecure=0#Hysteria2(DIRECT)")
else:
    print(f"hysteria2://{hy2}@{dom_dir}:8447?alpn=h3&sni={dom_dir}&insecure=0#Hysteria2(DIRECT)")
PY
chmod 644 "${WEB_ROOT}/sub.txt"

# ---------- Nginx：仅为 DOMAIN_WS 提供 443 WS 反代 + sub.txt ----------
cat > /etc/nginx/sites-available/singbox-site.conf <<NGX
server {
  listen 80;
  server_name ${DOMAIN_WS};
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl http2;
  server_name ${DOMAIN_WS};
  ssl_certificate     ${CERT_WS};
  ssl_certificate_key ${KEY_WS};

  # 订阅文件
  location = /sub.txt { root ${WEB_ROOT}; default_type text/plain; }

  # WebSocket 反代 -> 本地 12080
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

  location / { return 404; }
}
NGX
ln -sf /etc/nginx/sites-available/singbox-site.conf /etc/nginx/sites-enabled/singbox-site.conf
nginx -t && systemctl restart nginx || true

# ---------- 防火墙 ----------
ufw limit 22/tcp comment 'SSH' || true
ufw allow 80/tcp  || true
ufw allow 443/tcp || true
ufw allow 8444/tcp || true
ufw allow 8448/tcp || true
ufw allow 8447/udp || true
ufw --force enable || true

# ---------- 输出 ----------
echo
echo "== listen ports =="
ss -tulpen | egrep '(:443 |:8444|:8448)' || true
ss -ulpen | grep ':8447' || true

echo
echo "== cert issuer check =="
for host in "$DOMAIN_WS:443" "$DOMAIN_DIR:8444"; do
  echo --- "$host" ---
  timeout 6 openssl s_client -connect $host -servername ${host%%:*} -alpn h2 </dev/null 2>/dev/null \
   | openssl x509 -noout -issuer -subject -dates || true
done

echo
echo "==== DONE ===="
echo "Subscription: https://${DOMAIN_WS}/sub.txt"
echo "VMess(WS+TLS+CDN): ${DOMAIN_WS} 443  path /${WS_PATH}  UUID ${UUID}"
echo "Trojan(TLS DIRECT): ${DOMAIN_DIR}:8444  password ${TROJAN_PWD}"
echo "VLESS Reality    : ${DOMAIN_DIR}:8448  UUID ${UUID}  PBK ${REALITY_PUBLIC}  SID ${REALITY_SHORTID}"
echo "HY2 (DIRECT)     : ${DOMAIN_DIR}:8447  password ${HY2_PWD}  obfs=${HY2_OBFS} (${HY2_OBFS_STR})"
