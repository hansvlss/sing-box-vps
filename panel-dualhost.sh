#!/usr/bin/env bash
# panel-dualhost.sh (alias 修正版)
# 为 sbx-dualhost-4in1.sh 添加可视化面板与状态监控（不会签发证书，不改节点）
# 访问路径：https://直连域名/panel/ 与 /status.json

set -euo pipefail
IFS=$' \n\t'

# -------------------- 基础路径 --------------------
PANEL_DIR="/var/www/singbox"
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
REFRESH_BIN="/usr/local/bin/singbox-panel-refresh"
CRON_FILE="/etc/cron.d/singbox-panel-refresh"

CERT="/etc/sing-box/cert.pem"
KEY="/etc/sing-box/key.pem"
SITE_AV="/etc/nginx/sites-available/singbox-site.conf"
SITE_EN="/etc/nginx/sites-enabled/singbox-site.conf"
SNIPPET="/etc/nginx/snippets/singbox-panel-locations.conf"

install -d "$PANEL_DIR" "$STATE_DIR" "$RUN_DIR" /etc/nginx/snippets

echo "[STEP] 检查环境..."
command -v nginx >/dev/null 2>&1 || { echo "❌ Nginx 未安装，请先执行 4in1 部署脚本"; exit 1; }

# -------------------- 域名推断 --------------------
DOMAIN=""
if [[ -f /root/sb.env ]]; then
  . /root/sb.env || true
  DOMAIN="${DOMAIN_DIR:-${DOMAIN_WS:-${DOMAIN:-}}}"
fi
[[ -z "$DOMAIN" ]] && DOMAIN=$(hostname -f 2>/dev/null || hostname)

# -------------------- 生成状态刷新脚本 --------------------
echo "[STEP] 生成状态脚本..."
cat >"$REFRESH_BIN" <<"SH"
#!/usr/bin/env bash
set -euo pipefail
IFS=$' \n\t'
PANEL_DIR="/var/www/singbox"
STATUS="${PANEL_DIR}/status.json"
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
CERT="/etc/sing-box/cert.pem"
install -d "$STATE_DIR" "$RUN_DIR" "$PANEL_DIR"

get_domain(){
  awk '$0~/listen 443/{in443=1} in443&&/server_name/{for(i=2;i<=NF;i++){gsub(/[;|,]/,"",$i);if($i!="_")print $i}} $0~/}/{in443=0}' \
  /etc/nginx/sites-enabled/*.conf 2>/dev/null | head -n1 || hostname -f
}
DOMAIN=$(get_domain)
RAW=$(openssl x509 -in "$CERT" -noout -issuer -subject -dates -text 2>/dev/null || true)
ISSUER=$(echo "$RAW"|awk -F'issuer=' '/issuer=/{print $2}')
SUBJECT=$(echo "$RAW"|awk -F'subject=' '/subject=/{print $2}')
NOT_BEFORE=$(echo "$RAW"|awk -F'notBefore=' '/notBefore=/{print $2}')
NOT_AFTER=$(echo "$RAW"|awk -F'notAfter=' '/notAfter=/{print $2}')
SIGALG=$(echo "$RAW"|awk -F': ' '/Signature Algorithm:/{print $2;exit}')

LISTEN=$(ss -tulpen 2>/dev/null | awk '/:443 /{a["443"]=1}/:8444/{a["8444"]=1}/:8448/{a["8448"]=1} END{for(i in a)printf i"=up "}'); UDP8447=$(ss -ulpen 2>/dev/null|grep -q ':8447 '&&echo up||echo down)
is_active(){ systemctl is-active --quiet "$1"&&echo active||echo inactive; }
NGINX_STATE=$(is_active nginx); SING_STATE=$(is_active sing-box)
HOST=$(hostname -f); IPV4=$(hostname -I|awk '{print $1}'); LOADAVG=$(cut -d' ' -f1-3 /proc/loadavg); UPTIME=$(uptime -p)

read MT MA < <(awk '/MemTotal:|MemAvailable:/{gsub(/[^0-9]/,"",$2);print $2}' /proc/meminfo|xargs)
MU=$(( (MT-MA)/1024 )); MT_MB=$((MT/1024))
read -r I1 T1 < <(awk '/^cpu /{i=$5;t=0;for(j=2;j<=NF;j++)t+=$j;print i,t}' /proc/stat); sleep 0.2
read -r I2 T2 < <(awk '/^cpu /{i=$5;t=0;for(j=2;j<=NF;j++)t+=$j;print i,t}' /proc/stat)
DT=$((T2-T1)); DI=$((I2-I1)); CPU=$((100*(DT-DI)/DT))
read -r DU DTOT < <(df -B1 -P /|awk 'NR==2{print $3,$2}'); D_PCT=$((100*DU/DTOT)); DU_GB=$((DU/1024/1024/1024)); DT_GB=$((DTOT/1024/1024/1024))

now=$(date +%s); rx=$(awk -F'[: ]+' 'NR>2&&$1!="lo"{s+=$3}END{print s}'/proc/net/dev); tx=$(awk -F'[: ]+' 'NR>2&&$1!="lo"{s+=$11}END{print s}'/proc/net/dev)
rfile="$RUN_DIR/rate.prev"; old_ts=$now; old_rx=$rx; old_tx=$tx
[[ -s $rfile ]] && read -r old_ts old_rx old_tx < $rfile || true
echo "$now $rx $tx">$rfile; dt=$((now-old_ts)); rxk=$(( ((rx-old_rx)*8)/1024/dt )); txk=$(( ((tx-old_tx)*8)/1024/dt ))
[[ $rxk -lt 0 ]]&&rxk=0; [[ $txk -lt 0 ]]&&txk=0
tag=$(date +%Y%m%d); base="$STATE_DIR/traffic-$tag.base"; [[ ! -s $base ]]&&echo "$now $rx $tx">$base
read -r bts brx btx < $base; rmb=$(( (rx-brx)/1024/1024 )); tmb=$(( (tx-btx)/1024/1024 ))

cat >"$STATUS"<<JSON
{"domain":"$DOMAIN","cert":{"issuer":"$ISSUER","subject":"$SUBJECT","sigalg":"$SIGALG","not_before":"$NOT_BEFORE","not_after":"$NOT_AFTER"},
 "ports":{"tcp_443":"$(echo "$LISTEN"|grep -q '443=up'&&echo up||echo down)","tcp_8444":"$(echo "$LISTEN"|grep -q '8444=up'&&echo up||echo down)",
 "tcp_8448":"$(echo "$LISTEN"|grep -q '8448=up'&&echo up||echo down)","udp_8447":"$UDP8447"},
 "services":{"nginx":"$NGINX_STATE","singbox":"$SING_STATE"},
 "host":{"name":"$HOST","ipv4":"$IPV4","loadavg":"$LOADAVG","uptime":"$UPTIME","mem_total_mb":$MT_MB,"mem_used_mb":$MU,
 "cpu_pct":$CPU,"disk_total_gb":$DT_GB,"disk_used_gb":$DU_GB,"disk_used_pct":$D_PCT,"rx_rate_kbps":$rxk,"tx_rate_kbps":$txk,
 "rx_today_mb":$rmb,"tx_today_mb":$tmb},"generated_at":"$(date -u +%FT%TZ)"} 
JSON
chmod 644 "$STATUS"
SH
chmod +x "$REFRESH_BIN"
"$REFRESH_BIN" || true

# -------------------- 前端 HTML --------------------
echo "[STEP] 写入前端面板..."
cat >"${PANEL_DIR}/index.html" <<'HTML'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>sing-box 4in1 面板</title><style>
:root{--bg:#0f141b;--card:#151c24;--muted:#8aa1b4;--fg:#d6e2ee;--ok:#3ad29f;--bad:#ff6b6b;--btn:#1f2a36}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial}
.wrap{max-width:1100px;margin:24px auto;padding:0 16px}.h{display:flex;align-items:center;gap:10px;margin:8px 0 16px}
.tag{font-size:12px;padding:2px 8px;border-radius:999px;background:#1c2732;color:var(--muted)}.grid{display:grid;gap:16px}
@media(min-width:900px){.grid{grid-template-columns:1.1fr 1.4fr}}
.card{background:var(--card);border-radius:14px;padding:16px;box-shadow:0 1px 0 rgba(255,255,255,.03) inset,0 6px 24px rgba(0,0,0,.28)}
.kv{display:grid;grid-template-columns:120px 1fr;gap:6px 12px}.kv div{padding:2px 0;color:var(--muted)}.kv b{color:var(--fg);font-weight:600}
.row{display:flex;gap:8px;flex-wrap:wrap}.btn{background:var(--btn);color:#e8f0f7;border:none;border-radius:10px;padding:8px 12px;cursor:pointer}
.btn:hover{filter:brightness(1.1)}.badge{padding:2px 8px;border-radius:999px;border:1px solid #263342;color:var(--muted);font-size:12px}
.badge.ok{border-color:rgba(58,210,159,.3);color:var(--ok)}.badge.bad{border-color:rgba(255,107,107,.3);color:var(--bad)}
.footer{margin-top:12px;color:var(--muted);font-size:12px}
hr{border:0;border-top:1px solid #213041;margin:16px 0}
.bar{height:10px;border-radius:999px;background:#0b1117;border:1px solid #263342;overflow:hidden}.bar>i{display:block;height:100%;background:#2b7fff30}
</style></head><body><div class="wrap"><div class="h"><h2>sing-box 面板</h2><span class="tag" id="stamp">加载中…</span></div>
<div class="grid"><div class="card"><h3>基础信息</h3><div class="kv"><div>域名</div><b id="d">-</b><div>证书颁发者</div><b id="i">-</b>
<div>到期</div><b id="n">-</b><div>端口</div><b><span class="badge" id="p443">443</span><span class="badge" id="p8444">8444</span>
<span class="badge" id="p8448">8448</span><span class="badge" id="p8447">8447/udp</span></b></div>
<div class="row"><button class="btn" id="r">刷新</button><a class="btn" href="/status.json" target="_blank">查看 JSON</a></div>
<hr/><div id="h" class="footer">-</div></div></div></div>
<script>
const g=i=>document.getElementById(i);const b=(ok,id)=>{const el=g(id);el.classList.remove("ok","bad");el.classList.add(ok?"ok":"bad")};
async function f(){try{const s=await fetch("/status.json?ts="+Date.now(),{cache:"no-store"}).then(r=>r.json());
g("d").textContent=s.domain;g("i").textContent=s.cert?.issuer;g("n").textContent=s.cert?.not_after;
b(s.ports?.tcp_443==="up","p443");b(s.ports?.tcp_8444==="up","p8444");b(s.ports?.tcp_8448==="up","p8448");b(s.ports?.udp_8447==="up","p8447");
g("h").textContent=`生成时间 ${s.generated_at} ｜ CPU=${s.host?.cpu_pct}% MEM=${s.host?.mem_used_mb}/${s.host?.mem_total_mb}MB ｜ 磁盘=${s.host?.disk_used_gb}/${s.host?.disk_total_gb}GB`;
g("stamp").textContent="正常"}catch(e){g("stamp").textContent="失败"}}
g("r").onclick=f;f();setInterval(f,15000);
</script></body></html>
HTML
chmod 644 "${PANEL_DIR}/index.html"

# -------------------- 定时任务 --------------------
echo "[STEP] 设置定时任务..."
echo '* * * * * root /usr/local/bin/singbox-panel-refresh >/dev/null 2>&1' > "$CRON_FILE"
chmod 644 "$CRON_FILE"
systemctl restart cron 2>/dev/null || true

# -------------------- alias 版 Nginx Snippet --------------------
echo "[STEP] 生成 Nginx alias 面板配置..."
cat >"$SNIPPET" <<'NGX'
# === singbox panel locations (alias version, safe) ===

location = /status.json {
  default_type application/json;
  alias /var/www/singbox/status.json;
  add_header Cache-Control "no-store" always;
  try_files /var/www/singbox/status.json =404;
}

location ^~ /panel/ {
  alias /var/www/singbox/;
  index index.html;
  try_files $uri /panel/index.html =404;
}

location = /panel {
  return 301 /panel/;
}
NGX
chmod 644 "$SNIPPET"

# -------------------- 挂载到主站点 --------------------
echo "[STEP] 挂载面板到主 443 server..."
if ! grep -qF "snippets/singbox-panel-locations.conf" "$SITE_AV"; then
  awk -v inc="    include /etc/nginx/snippets/singbox-panel-locations.conf;" '
    BEGIN{in443=0}
    /listen 443/ {in443=1}
    {
      if(in443 && /^}$/){print inc;in443=0}
      print
    }' "$SITE_AV" >"${SITE_AV}.tmp" && mv "${SITE_AV}.tmp" "$SITE_AV"
fi

ln -sf "$SITE_AV" "$SITE_EN"
nginx -t && systemctl reload nginx

echo
echo "✅ 面板安装完成"
echo "------------------------------------"
echo "📊 面板地址: https://${DOMAIN}/panel/"
echo "🧩 状态JSON: https://${DOMAIN}/status.json"
echo "🔗 订阅文件: https://${DOMAIN}/sub.txt"
echo "------------------------------------"
echo "⚙️ 若仍 404，请执行：nginx -t && systemctl reload nginx"
