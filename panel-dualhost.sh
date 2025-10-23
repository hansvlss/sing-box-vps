#!/usr/bin/env bash
# ================================================================
# panel-dualhost.sh - Sing-box 4in1 面板部署脚本（DualHost 版本）
# 作者：Hans 版本：2025.10.23
# 支持 sbx-dualhost-4in1.sh 已部署环境
# ================================================================
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

# ================================================================
# 1️⃣ 检查依赖环境
# ================================================================
log "检查环境..."
command -v nginx >/dev/null 2>&1 || { echo "❌ nginx 未安装，请先运行 4in1 安装"; exit 1; }

# ================================================================
# 2️⃣ 生成状态采集脚本（每分钟更新 status.json）
# ================================================================
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
P8443=$(grep -q ':8443' /tmp/ss.tmp && echo up || echo down)
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
    "8443": "$P8443",
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

# ================================================================
# 3️⃣ 写入前端面板 HTML
# ================================================================
log "写入前端面板..."
install -d "${PANEL_DIR}/panel"
cat >"${PANEL_DIR}/panel/index.html" <<"HTML"
<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Sing-box 面板</title>
<style>
body{background:#0f141b;color:#d6e2ee;font-family:ui-sans-serif,system-ui;margin:0;padding:20px}
.card{background:#151c24;border-radius:14px;padding:16px;max-width:700px;margin:auto}
h2{margin-top:0;text-align:center}pre{background:#0b1117;padding:10px;border-radius:10px;overflow:auto}
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

# ================================================================
# 4️⃣ 写入独立 Nginx 片段并挂载到主站
# ================================================================
log "写入 Nginx 配置片段..."
SNIPPET="/etc/nginx/snippets/panel-locations.conf"
cat >"$SNIPPET" <<"NGX"
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

# ================================================================
# 5️⃣ 自动追加到主 443 server（尾部）
# ================================================================
log "挂载面板到主 443 server..."
if [[ ! -f "$SITE_AV" ]]; then
  echo "❌ 未检测到主配置：$SITE_AV"
  exit 1
fi

# 清除旧标记段
sed -i '/# === singbox-panel BEGIN ===/,/# === singbox-panel END ===/d' "$SITE_AV"

# 在 443 server 结束花括号前追加
awk -v inc="$(cat "$SNIPPET")" '
  BEGIN{in443=0; depth=0}
  {
    if ($0 ~ /^[ \t]*server[ \t]*\{/) depth=1
    if ($0 ~ /listen[ \t]+443/) in443=1
    if (in443 && depth==1 && $0 ~ /^[ \t]*}/) {print inc; print $0; in443=0; next}
    print $0
    if ($0 ~ /\{/) depth++
    if ($0 ~ /\}/) depth--
  }
' "$SITE_AV" > "${SITE_AV}.tmp" && mv "${SITE_AV}.tmp" "$SITE_AV"

ln -sf "$SITE_AV" "$SITE_EN"

# ================================================================
# 6️⃣ 测试并重载 Nginx
# ================================================================
log "校验并重载 Nginx..."
nginx -t && systemctl reload nginx || systemctl restart nginx

echo
echo "✅ 面板安装完成"
echo "📊 面板:  https://你的域名/panel/"
echo "🧩 状态:  https://你的域名/status.json"
echo "🔗 订阅:  https://你的域名/sub.txt"
echo "------------------------------------------"
echo "若访问 404，请执行："
echo "nginx -t && systemctl reload nginx"
