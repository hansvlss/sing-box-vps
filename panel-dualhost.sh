#!/usr/bin/env bash
# panel-dualhost.sh — 最终修正版，无 location 嵌套风险
set -euo pipefail
IFS=$' \n\t'

PANEL_DIR="/var/www/singbox"
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
REFRESH_BIN="/usr/local/bin/singbox-panel-refresh"
CRON_FILE="/etc/cron.d/singbox-panel-refresh"

SITE_AV="/etc/nginx/sites-available/singbox-site.conf"
SITE_EN="/etc/nginx/sites-enabled/singbox-site.conf"

install -d "$PANEL_DIR" "$STATE_DIR" "$RUN_DIR"

log(){ echo -e "\033[1;36m[STEP]\033[0m $*"; }

log "检查环境..."
command -v nginx >/dev/null 2>&1 || { echo "nginx 未安装"; exit 1; }

# =====================================================================
# 1. 状态刷新脚本
# =====================================================================
log "生成状态脚本..."
cat >"$REFRESH_BIN" <<"SH"
#!/usr/bin/env bash
set -euo pipefail
STATUS="/var/www/singbox/status.json"
CERT="/etc/sing-box/cert.pem"
install -d /var/lib/singbox-panel /var/run/singbox-panel

DOMAIN=$(awk '/server_name/{for(i=2;i<=NF;i++){gsub(/;|;/,"",$i);if($i!="_")print $i}}' /etc/nginx/sites-enabled/*.conf | head -n1)
[ -z "$DOMAIN" ] && DOMAIN=$(hostname -f 2>/dev/null || hostname)

ISSUER=$(openssl x509 -in "$CERT" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
SUBJECT=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed 's/^subject=//')
NOT_AFTER=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2)

ss -tulpen > /tmp/ss.tmp 2>/dev/null || true
P443=$(grep -q ':443 ' /tmp/ss.tmp && echo up || echo down)
P8444=$(grep -q ':8444' /tmp/ss.tmp && echo up || echo down)
P8448=$(grep -q ':8448' /tmp/ss.tmp && echo up || echo down)
U8447=$(grep -q ':8447 ' /tmp/ss.tmp && echo up || echo down)
rm -f /tmp/ss.tmp

cat >"$STATUS" <<JSON
{
  "domain": "$DOMAIN",
  "cert_issuer": "$ISSUER",
  "cert_subject": "$SUBJECT",
  "cert_expire": "$NOT_AFTER",
  "ports": {
    "443": "$P443",
    "8444": "$P8444",
    "8448": "$P8448",
    "udp_8447": "$U8447"
  },
  "generated_at": "$(date -u +%FT%TZ)"
}
JSON
SH
chmod +x "$REFRESH_BIN"
"$REFRESH_BIN" || true

echo '* * * * * root /usr/local/bin/singbox-panel-refresh >/dev/null 2>&1' > "$CRON_FILE"
chmod 644 "$CRON_FILE"

# =====================================================================
# 2. 写入前端 HTML
# =====================================================================
log "写入前端面板..."
install -d "${PANEL_DIR}/panel"
cat >"${PANEL_DIR}/panel/index.html" <<"HTML"
<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Sing-box 面板</title>
<style>
body{background:#0f141b;color:#d6e2ee;font-family:ui-sans-serif,system-ui;margin:0;padding:20px}
.card{background:#151c24;border-radius:14px;padding:16px;max-width:600px;margin:auto}
h2{margin-top:0}pre{background:#0b1117;padding:10px;border-radius:10px;overflow:auto}
.ok{color:#3ad29f}.bad{color:#ff6b6b}
</style></head>
<body>
<div class="card">
<h2>Sing-box 状态面板</h2>
<div id="info">加载中...</div>
</div>
<script>
async function load(){
 try{
   const r=await fetch("/status.json?"+Date.now());
   const s=await r.json();
   let html=`<p>域名：${s.domain}</p>
   <p>证书：${s.cert_issuer||"-"}<br>到期：${s.cert_expire||"-"}</p>
   <p>端口状态：</p><ul>`;
   for(const [k,v] of Object.entries(s.ports)) html+=`<li>${k}: <b class="${v==="up"?"ok":"bad"}">${v}</b></li>`;
   html+=`</ul><p>更新时间：${s.generated_at}</p>`;
   document.getElementById("info").innerHTML=html;
 }catch(e){document.getElementById("info").textContent="加载失败："+e}
}
load();setInterval(load,15000);
</script></body></html>
HTML

# =====================================================================
# 3. Nginx location 片段
# =====================================================================
log "写入 Nginx 配置片段..."
PANEL_LOCATIONS="/etc/nginx/snippets/sbx_panel_locations.conf"
cat >"$PANEL_LOCATIONS" <<"NGX"
# === singbox-panel BEGIN ===
location ^~ /panel/ {
  alias /var/www/singbox/panel/;
  index index.html;
  try_files $uri $uri/ /panel/index.html;
}

location = /status.json {
  default_type application/json;
  add_header Cache-Control "no-store" always;
  alias /var/www/singbox/status.json;
}

location = /sub.txt {
  default_type text/plain;
  add_header Cache-Control "no-store" always;
  alias /var/www/singbox/sub.txt;
}
# === singbox-panel END ===
NGX

# =====================================================================
# 4. 追加到主 443 server 块（尾部前）
# =====================================================================
log "追加到主 443 server..."
if [[ ! -f "$SITE_AV" ]]; then
  echo "❌ 未找到 $SITE_AV，请先执行 4in1 安装。"
  exit 1
fi

# 移除旧片段
sed -i '/# === singbox-panel BEGIN ===/,/# === singbox-panel END ===/d' "$SITE_AV"

# 在 443 server 的最后一个 } 之前追加
awk -v inc="$(cat "$PANEL_LOCATIONS")" '
  BEGIN{in443=0;depth=0}
  {
    line=$0
    if ($0 ~ /^[ \t]*server[ \t]*\{/) {depth=1}
    if ($0 ~ /listen[ \t]+443/) in443=1
    if (in443 && depth==1 && $0 ~ /^[ \t]*}/) {print inc; print $0; in443=0; next}
    print $0
    if ($0 ~ /\{/) depth++
    if ($0 ~ /\}/) depth--
  }
' "$SITE_AV" > "${SITE_AV}.tmp" && mv "${SITE_AV}.tmp" "$SITE_AV"

ln -sf "$SITE_AV" "$SITE_EN"

log "校验并重载 Nginx..."
nginx -t && systemctl reload nginx || systemctl restart nginx

echo
echo "✅ 面板安装完成"
echo "📊 面板:  https://你的域名/panel/"
echo "🧩 状态:  https://你的域名/status.json"
echo "🔗 订阅:  https://你的域名/sub.txt"
