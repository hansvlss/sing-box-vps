#!/usr/bin/env bash
# ================================================================
# panel-dualhost.sh - 最终稳定版（彻底修复 location 嵌套问题）
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

# 1️⃣ 检查环境
log "检查环境..."
command -v nginx >/dev/null 2>&1 || { echo "❌ nginx 未安装"; exit 1; }

# 2️⃣ 状态脚本
log "生成状态脚本..."
cat >"$REFRESH_BIN" <<"SH"
#!/usr/bin/env bash
set -euo pipefail
STATUS="/var/www/singbox/status.json"
CERT="/etc/sing-box/cert.pem"
DOMAIN=$(awk '/server_name/{for(i=2;i<=NF;i++){gsub(/;|;/,"",$i);if($i!="_")print $i}}' /etc/nginx/sites-enabled/*.conf | head -n1)
[ -z "$DOMAIN" ] && DOMAIN=$(hostname -f)
ISSUER=$(openssl x509 -in "$CERT" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
NOT_AFTER=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
ss -tulpen > /tmp/ss.tmp 2>/dev/null || true
P443=$(grep -q ':443 ' /tmp/ss.tmp && echo up || echo down)
P8444=$(grep -q ':8444' /tmp/ss.tmp && echo up || echo down)
U8447=$(grep -q ':8447' /tmp/ss.tmp && echo up || echo down)
rm -f /tmp/ss.tmp
cat >"$STATUS" <<JSON
{
  "domain": "$DOMAIN",
  "issuer": "$ISSUER",
  "expire": "$NOT_AFTER",
  "ports": { "443":"$P443", "8444":"$P8444", "udp_8447":"$U8447" },
  "generated_at": "$(date -u +%FT%TZ)"
}
JSON
SH
chmod +x "$REFRESH_BIN"
"$REFRESH_BIN" || true
echo '* * * * * root /usr/local/bin/singbox-panel-refresh >/dev/null 2>&1' > "$CRON_FILE"

# 3️⃣ 写入面板 HTML
log "写入前端面板..."
install -d "${PANEL_DIR}/panel"
cat >"${PANEL_DIR}/panel/index.html" <<"HTML"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Sing-box 面板</title>
<style>body{background:#0f141b;color:#d6e2ee;font-family:ui-sans-serif,system-ui;margin:0;padding:20px}
.card{background:#151c24;border-radius:14px;padding:16px;max-width:700px;margin:auto}
.ok{color:#3ad29f}.bad{color:#ff6b6b}</style></head>
<body><div class="card"><h2>Sing-box 状态面板</h2><div id="info">加载中...</div></div>
<script>
async function load(){
 try{
   const r=await fetch("/status.json?"+Date.now()); const s=await r.json();
   let html=`<p>域名：${s.domain}</p><p>证书到期：${s.expire}</p><ul>`;
   for(const [k,v] of Object.entries(s.ports))
     html+=`<li>${k}: <b class="${v==="up"?"ok":"bad"}">${v}</b></li>`;
   html+=`</ul><p>更新时间：${s.generated_at}</p>`;
   document.getElementById("info").innerHTML=html;
 }catch(e){document.getElementById("info").innerHTML="<p style='color:#ff6b6b'>加载失败："+e+"</p>";}
}
load();setInterval(load,15000);
</script></body></html>
HTML

# 4️⃣ 写入独立片段
log "写入 Nginx 片段..."
SNIPPET="/etc/nginx/snippets/panel-locations.conf"
cat >"$SNIPPET" <<"NGX"
# === singbox-panel BEGIN ===
location /panel/ {
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

# 5️⃣ 清理旧配置并追加到 server 块外层
log "挂载面板到主 443 server..."
sed -i '/# === singbox-panel BEGIN ===/,/# === singbox-panel END ===/d' "$SITE_AV" || true

awk -v inc="$(cat "$SNIPPET")" '
  BEGIN{depth=0;in443=0}
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

# 6️⃣ 检查与重载
log "校验并重载 Nginx..."
nginx -t && systemctl reload nginx || systemctl restart nginx

echo
echo "✅ 部署完成"
echo "📊 面板:  https://你的域名/panel/"
echo "🧩 状态:  https://你的域名/status.json"
echo "🔗 订阅:  https://你的域名/sub.txt"
