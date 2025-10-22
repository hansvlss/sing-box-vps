#!/usr/bin/env bash
# sing-box 4-in-1 (vmess/ws, vless/reality, trojan, hysteria2) + nginx sub.txt
# Usage: bash /root/install-singbox-4in1.sh -d your.domain.tld [--hy2-obfs on|off]
set -euo pipefail

# make word-splitting safer per user's request
IFS=$' \n\t'

# ---------- 参数解析 ----------
DOMAIN=""
HY2_OBFS="off"   # "on" or "off"

usage(){
  cat <<USG
用法: bash $0 -d your.domain.tld [--hy2-obfs on|off]
示例: bash $0 -d vpn.example.com
USG
  exit 1
}

# basic argument parse
while [[ ${#} -gt 0 ]]; do
  case "$1" in
    -d|--domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --hy2-obfs)
      HY2_OBFS="${2:-off}"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "未知参数: $1"
      usage
      ;;
  esac
done

if [[ -z "${DOMAIN}" ]]; then
  echo "必须指定域名 -d your.domain.tld"
  usage
fi

if [[ "${HY2_OBFS}" != "on" && "${HY2_OBFS}" != "off" ]]; then
  echo "--hy2-obfs must be 'on' or 'off'"
  exit 1
fi

echo "[START] domain=${DOMAIN}  hy2-obfs=${HY2_OBFS}"

# ---------- 环境检查 ----------
if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 用户运行"
  exit 1
fi

# avoid interactive apt prompts
export DEBIAN_FRONTEND=noninteractive

echo "[STEP] apt update && install base deps"
apt-get update -y
DEPS=(curl wget jq nginx python3 python3-pip ufw unzip tar openssl tmux tcpdump dos2unix socat net-tools)
apt-get install -y "${DEPS[@]}"

install -d /etc/sing-box
WEB_ROOT="/var/www/singbox"; install -d "$WEB_ROOT"

# ---------- 安装 sing-box（鲁棒下载） ----------
install_singbox() {
  echo "[STEP] Install sing-box"
  set +e
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) SB_ARCH="linux-amd64" ;;
    aarch64|arm64) SB_ARCH="linux-arm64" ;;
    armv7l) SB_ARCH="linux-armv7" ;;
    *) SB_ARCH="linux-amd64" ;;
  esac

  # 固定已验证版本（可按需修改）
  V="v1.12.9"
  FNAME="sing-box-${V#v}-${SB_ARCH}.tar.gz"
  URLS=(
    "https://github.com/SagerNet/sing-box/releases/download/${V}/${FNAME}"
    "https://ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/${V}/${FNAME}"
    "https://download.fastgit.org/SagerNet/sing-box/releases/download/${V}/${FNAME}"
  )

  TMPDIR="$(mktemp -d)"
  TGZ="$TMPDIR/sb.tgz"
  downloaded=0
  for u in "${URLS[@]}"; do
    echo "[INFO] try download: $u"
    if curl -fsSL4 --connect-timeout 15 -o "$TGZ" "$u"; then
      # quick check: gzip magic
      if head -c 2 "$TGZ" | od -An -tx1 | tr -d ' \n' | grep -q '^1f8b'; then
        downloaded=1
        break
      else
        echo "[WARN] downloaded file is not gzip, maybe HTML error page"
        rm -f "$TGZ"
      fi
    else
      echo "[WARN] download failed for $u"
    fi
  done

  if [[ $downloaded -ne 1 ]]; then
    echo "[ERROR] all downloads failed"
    rm -rf "$TMPDIR"
    exit 1
  fi

  tar -xzf "$TGZ" -C "$TMPDIR"
  SB_BIN=$(find "$TMPDIR" -type f -name sing-box -print -quit)
  if [[ -z "$SB_BIN" ]]; then
    echo "[ERROR] sing-box binary not found in archive"
    rm -rf "$TMPDIR"
    exit 1
  fi
  install -m 755 "$SB_BIN" /usr/local/bin/sing-box
  /usr/local/bin/sing-box version || true
  rm -rf "$TMPDIR"
  set -e
}

install_singbox

# ---------- 证书（ACME 优先，限额或失败则自签） ----------
CERT_DIR="/etc/sing-box"
CERT="$CERT_DIR/cert.pem"
KEY="$CERT_DIR/key.pem"

issue_cert() {
  echo "[STEP] Issue cert: ACME preferred, fallback self-signed"
  # ensure port 80 free for standalone
  systemctl stop nginx >/dev/null 2>&1 || true
  ufw allow 80/tcp || true

  if [[ ! -x "${HOME}/.acme.sh/acme.sh" ]]; then
    echo "[INFO] install acme.sh"
    curl -fsSL https://get.acme.sh | sh -s email=admin@"${DOMAIN}" || true
  fi

  # set LE
  "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

  # ensure socat present for acme standalone if needed
  if ! command -v socat >/dev/null 2>&1; then
    apt-get install -y socat
  fi

  set +e
  "${HOME}/.acme.sh/acme.sh" --issue -d "${DOMAIN}" --standalone -k ec-256 --force
  ret=$?
  set -e

  if [[ $ret -eq 0 ]]; then
    ACMEDIR="${HOME}/.acme.sh/${DOMAIN}_ecc"
    if [[ -f "${ACMEDIR}/${DOMAIN}.key" && -f "${ACMEDIR}/fullchain.cer" ]]; then
      install -m 600 "${ACMEDIR}/${DOMAIN}.key" "$KEY"
      install -m 644 "${ACMEDIR}/fullchain.cer" "$CERT"
      echo "[OK] ACME 成功"
      return 0
    else
      echo "[WARN] acme issued but files missing, fallback to self-signed"
    fi
  else
    echo "[WARN] ACME failed or rate-limited, fallback to self-signed"
  fi

  # fallback self-signed 1 year
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -days 365 \
    -subj "/CN=${DOMAIN}" -nodes -keyout "$KEY" -out "$CERT"
  chmod 600 "$KEY"; chmod 644 "$CERT"
  echo "[OK] self-signed cert generated"
}

issue_cert

# ---------- 生成凭据并写入 /root/sb.env ----------
echo "[STEP] Generate credentials"
UUID=$(/usr/local/bin/sing-box generate uuid)
TROJAN_PWD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 18 || true)
WS_PATH="ws-$(tr -dc a-z0-9 </dev/urandom | head -c 6 || true)"
HY2_PWD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 18 || true)
HY2_OBFS_STR=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16 || true)

# Reality keypair: avoid SIGPIPE by writing to temp file then reading
TMP_REALITY="$(mktemp)"
if /usr/local/bin/sing-box generate reality-keypair >"$TMP_REALITY" 2>/dev/null; then
  REALITY_PRIVATE=$(awk -F': +' '/[Pp]rivate/ {print $2; exit}' "$TMP_REALITY" || true)
  REALITY_PUBLIC=$(awk -F': +' '/[Pp]ublic/ {print $2; exit}' "$TMP_REALITY" || true)
else
  REALITY_PRIVATE=""
  REALITY_PUBLIC=""
fi
rm -f "$TMP_REALITY"

REALITY_SHORTID=$(tr -dc 'a-f0-9' </dev/urandom | head -c 8 || true)

umask 177
cat > /root/sb.env <<ENV
export DOMAIN="${DOMAIN}"
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

# ---------- 写入 sing-box 配置（4 协议） ----------
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
        "server_name": "${DOMAIN}",
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
 "transport": {
  "type": "ws",
  "path": "/${WS_PATH}"
}
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

# 如果开启 HY2 obfs，则用 jq 在 config 中插入 obfs 字段（不破坏原文件）
if [[ "${HY2_OBFS}" == "on" && -n "${HY2_OBFS_STR}" ]]; then
  tmpf="$(mktemp)"
  jq --arg ob "${HY2_OBFS_STR}" '(.inbounds[] | select(.type=="hysteria2")) += { "obfs": {"type":"salamander", "password": $ob} }' /etc/sing-box/config.json >"$tmpf" && mv "$tmpf" /etc/sing-box/config.json
fi

# 校验 sing-box 配置（非阻塞）
if command -v /usr/local/bin/sing-box >/dev/null 2>&1; then
  /usr/local/bin/sing-box check -c /etc/sing-box/config.json || true
fi

# ---------- systemd 单元 ----------
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

# ---------- 生成订阅 sub.txt（从 /root/sb.env 读取，避免 KeyError） ----------
echo "[STEP] build sub.txt"
python3 - <<'PY' > "${WEB_ROOT}/sub.txt"
import json, base64, re
d={}
with open('/root/sb.env') as f:
    for line in f:
        line=line.strip()
        if line.startswith('export '):
            k,v=line[7:].split('=',1)
            d[k]=v.strip().strip('"')
dom=d.get('DOMAIN','')
uuid=d.get('UUID','')
ws=d.get('WS_PATH','')
pbk=d.get('REALITY_PUBLIC','')
sid=d.get('REALITY_SHORTID','')
tro=d.get('TROJAN_PWD','')
hy2pwd=d.get('HY2_PWD','')
hy2switch=d.get('HY2_OBFS_SWITCH','off')
hy2obfs=d.get('HY2_OBFS','')

vm={"v":"2","ps":"VMESS-WS","add":dom,"port":"443","id":uuid,"aid":"0",
    "net":"ws","type":"none","host":dom,"path":"/"+ws,"tls":"tls","sni":dom}
print("vmess://"+base64.b64encode(json.dumps(vm,separators=(',',':')).encode()).decode())
print()
print(f"vless://{uuid}@{dom}:8448?encryption=none&flow=xtls-rprx-vision&security=reality"
      f"&sni=www.cloudflare.com&pbk={pbk}&sid={sid}#VLESS-Reality")
print()
print(f"trojan://{tro}@{dom}:8444?security=tls&sni={dom}#Trojan-TLS")
print()
if hy2switch=='on':
    print(f"hysteria2://{hy2pwd}@{dom}:8447?obfs=salamander:{hy2obfs}&alpn=h3&sni={dom}&insecure=0#Hysteria2")
else:
    print(f"hysteria2://{hy2pwd}@{dom}:8447?alpn=h3&sni={dom}&insecure=0#Hysteria2")
PY

chmod 644 "${WEB_ROOT}/sub.txt"

# ---------- 配置 nginx (443 proxy for WS + /sub.txt) ----------
echo "[STEP] configure nginx (443 proxy for WS + /sub.txt)"
cat > /etc/nginx/sites-available/singbox-site.conf <<NGX
server {
  listen 80;
  server_name ${DOMAIN};
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name ${DOMAIN};

  ssl_certificate     ${CERT};
  ssl_certificate_key ${KEY};

  # 订阅文件
  location = /sub.txt {
    root ${WEB_ROOT};
    default_type text/plain;
  }

  # 反代到 sing-box 的本地 WS (VMess)
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

  # 默认返回404，可改成伪装站点
  location / {
    return 404;
  }
}
NGX

ln -sf /etc/nginx/sites-available/singbox-site.conf /etc/nginx/sites-enabled/singbox-site.conf
nginx -t && systemctl restart nginx || true

# ---------- UFW 放行（非交互） ----------
echo "[STEP] configure ufw"
ufw limit 22/tcp comment 'SSH' || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
ufw allow 8443/tcp || true
ufw allow 8444/tcp || true
ufw allow 8448/tcp || true
ufw allow 8447/udp || true
ufw --force enable || true

# ---------- 最终自检与输出 ----------
echo
echo "== listen ports =="
ss -tulpen | egrep '(:443 |:8443|:8444|:8448)' || true
ss -ulpen | grep ':8447' || true

echo
echo "== cert issuer (443 / 8444) =="
for p in 443 8444; do
  echo --- $p ---
  openssl s_client -connect ${DOMAIN}:$p -servername ${DOMAIN} -alpn h2 </dev/null 2>/dev/null \
    | openssl x509 -noout -issuer -subject -dates || true
done

echo
echo "== subscription preview (first 80 lines) =="
curl -sS --max-time 8 https://${DOMAIN}/sub.txt | sed -n '1,80p' || echo "[WARN] cannot fetch subscription via https (curl exit)"

echo
echo "==== DONE ===="
echo "Subscription: https://${DOMAIN}/sub.txt"
echo "VMess WS : ${DOMAIN}:8443   path /${WS_PATH}   UUID ${UUID}"
echo "VLESS RLT: ${DOMAIN}:8448   UUID ${UUID}  PBK ${REALITY_PUBLIC}  SID ${REALITY_SHORTID}"
echo "Trojan TLS: ${DOMAIN}:8444  password ${TROJAN_PWD}"
echo "HY2      : ${DOMAIN}:8447   password ${HY2_PWD}  obfs-switch ${HY2_OBFS}"
