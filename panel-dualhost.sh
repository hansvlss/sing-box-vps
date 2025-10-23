#!/usr/bin/env bash
# ============================================================
# panel-dualhost.sh — 兼容 sbx-dualhost-4in1.sh 的面板脚本
# 支持 -w (CDN域名) 与 -r (直连域名)
# ============================================================

set -euo pipefail
IFS=$' \n\t'

PANEL_DIR="/var/www/singbox"
CERT_DIR="/etc/sing-box"
SITE_AV="/etc/nginx/sites-available/singbox-panel.conf"
SITE_EN="/etc/nginx/sites-enabled/singbox-panel.conf"
REFRESH_BIN="/usr/local/bin/singbox-panel-refresh"
CRON_FILE="/etc/cron.d/singbox-panel-refresh"
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"

mkdir -p "$PANEL_DIR" "$CERT_DIR" "$STATE_DIR" "$RUN_DIR"

# ===================== 参数解析 =====================
PANEL_DOMAIN=""
REAL_DOMAIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--web) PANEL_DOMAIN="$2"; shift 2 ;;
    -r|--real) REAL_DOMAIN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "${PANEL_DOMAIN}" ]]; then
  echo "[❌] 缺少 -w 面板域名参数"
  exit 1
fi

if [[ -z "${REAL_DOMAIN}" ]]; then
  echo "[⚙️] 未提供 -r 直连域名，将使用相同域名"
  REAL_DOMAIN="$PANEL_DOMAIN"
fi

CERT="${CERT_DIR}/cert.pem"
KEY="${CERT_DIR}/key.pem"
WS_PATH="ws"

# ===================== 生成状态刷新脚本 =====================
echo "[STEP] 生成状态刷新脚本..."
cat > "$REFRESH_BIN" <<"SH"
#!/usr/bin/env bash
set -euo pipefail
IFS=$' \n\t'
PANEL_DIR="/var/www/singbox"
STATUS="${PANEL_DIR}/status.json"
CERT="/etc/sing-box/cert.pem"
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
install -d "$STATE_DIR" "$RUN_DIR"

get_domain(){
  local d=""
  [[ -f /root/sb.env ]] && . /root/sb.env && d="${DOMAIN:-}"
  [[ -z "$d" ]] && d=$(hostname -f 2>/dev/null || hostname)
  echo "$d"
}

DOMAIN=$(get_domain)
ISSUER=$(openssl x509 -in "$CERT" -noout -issuer 2>/dev/null | cut -d= -f2- || echo "N/A")
SUBJECT=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | cut -d= -f2- || echo "N/A")
NOT_BEFORE=$(openssl x509 -in "$CERT" -noout -startdate 2>/dev/null | cut -d= -f2- || echo "")
NOT_AFTER=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2- || echo "")

LISTEN=$(ss -tulpen 2>/dev/null | awk '/:443 /{a["443"]=1}/:8444/{a["8444"]=1}/:8448/{a["8448"]=1}END{for(p in a)printf p" "}')

read -r total avail < <(awk '/MemTotal:/{t=$2}/MemAvailable:/{a=$2}END{print t,a}' /proc/meminfo)
mem_use=$(( (total - avail) / 1024 ))
mem_total=$(( total / 1024 ))
cpu=$(awk -v p="$(grep 'cpu ' /proc/stat)" 'BEGIN{split(p,a);t1=a[2]+a[3]+a[4]+a[5]+a[6]+a[7]+a[8];i1=a[5];}{getline p < "/proc/stat";split(p,b);t2=b[2]+b[3]+b[4]+b[5]+b[6]+b[7]+b[8];i2=b[5];print int((1-(i2-i1)/(t2-t1))*100)}')

cat >"$STATUS" <<JSON
{
  "domain": "$DOMAIN",
  "cert": {"issuer": "$ISSUER","subject": "$SUBJECT","not_before": "$NOT_BEFORE","not_after": "$NOT_AFTER"},
  "listen": "$LISTEN",
  "mem_used_mb": $mem_use,
  "mem_total_mb": $mem_total,
  "cpu_pct": $cpu,
  "generated_at": "$(date -u +%FT%TZ)"
}
JSON
SH
chmod +x "$REFRESH_BIN"
"$REFRESH_BIN" || true

# ===================== 写入前端面板 =====================
echo "[STEP] 写入前端文件..."
cat > "${PANEL_DIR}/index.html" <<"HTML"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>sing-box 面板</title><style>body{background:#0f141b;color:#e8f0f7;font-family:system-ui;margin:0;padding:16px}pre{background:#151c24;padding:10px;border-radius:8px;overflow:auto}</style></head><body><h2>sing-box 4in1 面板</h2><div id="info">加载中...</div><script>async function load(){try{const s=await fetch('/status.json?ts='+Date.now(),{cache:'no-store'}).then(r=>r.json());document.getElementById('info').innerHTML='<pre>'+JSON.stringify(s,null,2)+'</pre>'}catch(e){document.getElementById('info').textContent='加载失败: '+e}}load();setInterval(load,15000);</script></body></html>
HTML

chmod 644 "${PANEL_DIR}/index.html"

# ===================== 写入 nginx 配置 =====================
echo "[STEP] 写入 nginx 配置..."
cat > "$SITE_AV" <<NGX
server {
  listen 80;
  server_name ${PANEL_DOMAIN};
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name ${PANEL_DOMAIN};

  ssl_certificate     ${CERT};
  ssl_certificate_key ${KEY};

  root ${PANEL_DIR};
  index index.html;

  location = /status.json {
    default_type application/json;
    add_header Cache-Control "no-store" always;
    try_files /status.json =404;
  }

  location = /sub.txt {
    default_type text/plain;
    add_header Cache-Control "no-store" always;
    try_files /sub.txt =404;
  }

  location /${WS_PATH} {
    proxy_pass http://127.0.0.1:12080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_read_timeout 86400;
  }

  location / {
    try_files \$uri /index.html =404;
  }
}
NGX

ln -sf "$SITE_AV" "$SITE_EN"
nginx -t && systemctl reload nginx || echo "[WARN] Nginx 配置检测失败，请检查。"

# ===================== 写入定时任务 =====================
echo "* * * * * root ${REFRESH_BIN} >/dev/null 2>&1" > "$CRON_FILE"
chmod 644 "$CRON_FILE"

# ===================== 输出结果 =====================
echo
echo "✅ 面板部署完成！"
echo "------------------------------------------"
echo "📊 面板:      https://${PANEL_DOMAIN}/"
echo "🧩 状态JSON:  https://${PANEL_DOMAIN}/status.json"
echo "🔗 订阅链接:  https://${PANEL_DOMAIN}/sub.txt"
echo "------------------------------------------"
echo "⚙️ 若 404，请执行:"
echo "   nginx -t && systemctl reload nginx"
echo
