#!/usr/bin/env bash
# panel-dualhost.sh — mount sing-box panel safely (no duplicate root)
# Author: hans
set -euo pipefail
IFS=$' \n\t'

log(){ echo "[STEP] $*"; }
ok(){  echo "✅ $*"; }
warn(){ echo "⚠️  $*" >&2; }
die(){  echo "❌ $*" >&2; exit 1; }

# ----------------- paths -----------------
PANEL_DIR="/var/www/singbox"
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
REFRESH_BIN="/usr/local/bin/sbx-panel-refresh"
CRON_FILE="/etc/cron.d/sbx-panel-refresh"
SNIPPET="/etc/nginx/snippets/sbx_panel_locations.conf"
SITE_EN="/etc/nginx/sites-enabled/singbox-site.conf"
SITE_AV="/etc/nginx/sites-available/singbox-site.conf"
CERT="/etc/sing-box/cert.pem"
KEY="/etc/sing-box/key.pem"

install -d "$PANEL_DIR" "$STATE_DIR" "$RUN_DIR" /etc/nginx/snippets

# ----------------- detect domain & ws path -----------------
DOMAIN=""
WS_PATH="ws"
if [[ -f /root/sb.env ]]; then
  # shellcheck disable=SC1091
  . /root/sb.env || true
  DOMAIN="${DOMAIN:-${DOMAIN:-}}"
  WS_PATH="${WS_PATH:-${WS_PATH:-ws}}"
fi

if [[ -z "${DOMAIN}" && -f "$SITE_EN" ]]; then
  DOMAIN=$(awk '/server_name/{for(i=2;i<=NF;i++){gsub(/;|;/,"",$i); if($i!="_") print $i}}' "$SITE_EN" 2>/dev/null | head -n1 || true)
fi
if [[ -z "${DOMAIN}" && -s "$CERT" ]]; then
  DOMAIN=$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null \
         | sed -n 's/.*subjectAltName *= *//p' | tr ',' '\n' | sed -n 's/^ *DNS:\(.*\)$/\1/p' | head -n1)
  [[ -n "${DOMAIN}" ]] || DOMAIN=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^,\/]*\).*/\1/p')
fi
if [[ -z "${DOMAIN}" ]]; then
  DOMAIN=$(hostname -f 2>/dev/null || hostname)
fi

log "检查环境..."
command -v nginx >/dev/null || die "未安装 nginx"
command -v ss >/dev/null     || die "未找到 ss (iproute2)"
command -v awk >/dev/null    || die "缺少 awk"

# ----------------- write refresher (status.json) -----------------
log "生成状态脚本..."
cat >"$REFRESH_BIN" <<"SH"
#!/usr/bin/env bash
set -euo pipefail
IFS=$' \n\t'

PANEL_DIR="/var/www/singbox"
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
STATUS="${PANEL_DIR}/status.json"
CERT="/etc/sing-box/cert.pem"

install -d "$PANEL_DIR" "$STATE_DIR" "$RUN_DIR"

get_domain(){
  local envd="" ngxd="" sand="" cnd="" host=""
  if [[ -f /root/sb.env ]]; then . /root/sb.env || true; envd="${DOMAIN:-}"; fi
  ngxd=$(awk '/server_name/{for(i=2;i<=NF;i++){gsub(/;|;/,"",$i); if($i!="_") print $i}}' \
            /etc/nginx/sites-enabled/*.conf /etc/nginx/sites-available/*.conf 2>/dev/null | head -n1 || true)
  if [[ -s "$CERT" ]]; then
    sand=$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | sed -n 's/.*subjectAltName *= *//p' | tr ',' '\n' | sed -n 's/^ *DNS:\(.*\)$/\1/p' | head -n1)
    cnd=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^,\/]*\).*/\1/p')
  fi
  host=$(hostname -f 2>/dev/null || hostname)
  echo "${envd:-${ngxd:-${sand:-${cnd:-$host}}}}"
}
DOMAIN="$(get_domain)"

ISSUER=""; SUBJECT=""; NOT_BEFORE=""; NOT_AFTER=""; SIGALG=""
if [[ -s "$CERT" ]]; then
  RAW=$(openssl x509 -in "$CERT" -noout -issuer -subject -dates -text 2>/dev/null || true)
  ISSUER=$(echo "$RAW" | awk -F'issuer=' '/issuer=/{print $2}' | sed 's/^ *//; s/ *$//')
  SUBJECT=$(echo "$RAW" | awk -F'subject=' '/subject=/{print $2}' | sed 's/^ *//; s/ *$//')
  NOT_BEFORE=$(echo "$RAW" | awk -F'notBefore=' '/notBefore=/{print $2}')
  NOT_AFTER=$( echo "$RAW" | awk -F'notAfter='  '/notAfter=/{print  $2}')
  SIGALG=$(echo "$RAW" | awk -F': ' '/Signature Algorithm:/{print $2; exit}')
fi

# 监听端口（不包含 8443，WS 走 443+location)
LISTEN=$(ss -tulpen 2>/dev/null | awk '
/:443 /{a["443/tcp"]=1}
/:8444/{a["8444/tcp"]=1}
/:8448/{a["8448/tcp"]=1}
END{
  printf("%s",(a["443/tcp"] ?"443=up ":"443=down "));
  printf("%s",(a["8444/tcp"]?"8444=up ":"8444=down "));
  printf("%s",(a["8448/tcp"]?"8448=up ":"8448=down "));
}')
UDP8447=$(ss -ulpen 2>/dev/null | grep -q ':8447 ' && echo up || echo down)

is_active(){ systemctl is-active --quiet "$1" && echo "active" || echo "inactive"; }
NGINX_STATE=$(is_active nginx)
SING_STATE=$(is_active sing-box)

HOST=$(hostname -f 2>/dev/null || hostname)
IPV4=$(hostname -I 2>/dev/null | awk '{print $1}')
LOADAVG=$(cut -d' ' -f1-3 /proc/loadavg)
UPTIME=$(uptime -p 2>/dev/null || true)

read MEM_TOTAL_KB MEM_AVAIL_KB < <(awk '/MemTotal:|MemAvailable:/{gsub(/[^0-9]/,"",$2); print $2}' /proc/meminfo | xargs)
MEM_TOTAL_MB=$(( MEM_TOTAL_KB/1024 ))
MEM_USED_MB=$(( (MEM_TOTAL_KB - MEM_AVAIL_KB)/1024 ))

read -r C1_IDLE C1_TOTAL < <(awk '/^cpu /{idle=$5; total=0; for(i=2;i<=NF;i++) total+=$i; print idle,total}' /proc/stat)
sleep 0.2
read -r C2_IDLE C2_TOTAL < <(awk '/^cpu /{idle=$5; total=0; for(i=2;i<=NF;i++) total+=$i; print idle,total}' /proc/stat)
DIFF_TOTAL=$(( C2_TOTAL - C1_TOTAL ))
DIFF_IDLE=$(( C2_IDLE - C1_IDLE ))
CPU_PCT=0
if (( DIFF_TOTAL > 0 )); then
  CPU_PCT=$(( (100*(DIFF_TOTAL - DIFF_IDLE) + DIFF_TOTAL/2) / DIFF_TOTAL ))
fi

read -r BYTES_USED BYTES_TOTAL < <(df -B1 -P / | awk 'NR==2{print $3,$2}')
DISK_USED_GB=$(( BYTES_USED  / 1024 / 1024 / 1024 ))
DISK_TOTAL_GB=$(( BYTES_TOTAL / 1024 / 1024 / 1024 ))
DISK_PCT=0
if (( BYTES_TOTAL > 0 )); then
  DISK_PCT=$(( (100*BYTES_USED + BYTES_TOTAL/2) / BYTES_TOTAL ))
fi

now_ts=$(date +%s)
rx_bytes=$(awk -F'[: ]+' 'NR>2 && $1!="lo"{sum+=$3} END{printf "%.0f",sum+0}' /proc/net/dev)
tx_bytes=$(awk -F'[: ]+' 'NR>2 && $1!="lo"{sum+=$11} END{printf "%.0f",sum+0}' /proc/net/dev)

rate_state="$RUN_DIR/rate.prev"
old_ts=$now_ts; old_rx=$rx_bytes; old_tx=$tx_bytes
if [[ -s "$rate_state" ]]; then
  read -r old_ts old_rx old_tx < "$rate_state" || true
fi
echo "$now_ts $rx_bytes $tx_bytes" > "$rate_state"
dt=$(( now_ts - old_ts ))
rx_rate_kbps=0; tx_rate_kbps=0
if (( dt > 0 )); then
  rx_rate_kbps=$(( ((rx_bytes - old_rx) * 8) / 1024 / dt ))
  tx_rate_kbps=$(( ((tx_bytes - old_tx) * 8) / 1024 / dt ))
  [[ $rx_rate_kbps -lt 0 ]] && rx_rate_kbps=0
  [[ $tx_rate_kbps -lt 0 ]] && tx_rate_kbps=0
fi

day_tag=$(date +%Y%m%d)
day_state="$STATE_DIR/traffic-$day_tag.base"
if [[ ! -s "$day_state" ]]; then
  echo "$now_ts $rx_bytes $tx_bytes" > "$day_state"
fi
read -r base_ts base_rx base_tx < "$day_state"
rx_today_mb=$(( (rx_bytes - base_rx) / 1024 / 1024 ))
tx_today_mb=$(( (tx_bytes - base_tx) / 1024 / 1024 ))
[[ $rx_today_mb -lt 0 ]] && rx_today_mb=0
[[ $tx_today_mb -lt 0 ]] && tx_today_mb=0

cat >"$STATUS" <<JSON
{
  "domain": "${DOMAIN}",
  "cert": {
    "issuer": "${ISSUER}",
    "subject": "${SUBJECT}",
    "sigalg": "${SIGALG}",
    "not_before": "${NOT_BEFORE}",
    "not_after":  "${NOT_AFTER}"
  },
  "ports": {
    "tcp_443":   "$(echo "$LISTEN" | grep -q '443=up'  && echo up || echo down)",
    "tcp_8444":  "$(echo "$LISTEN" | grep -q '8444=up' && echo up || echo down)",
    "tcp_8448":  "$(echo "$LISTEN" | grep -q '8448=up' && echo up || echo down)",
    "udp_8447":  "${UDP8447}"
  },
  "services": { "nginx":"${NGINX_STATE}", "singbox":"${SING_STATE}" },
  "host": {
    "name": "${HOST}",
    "ipv4": "${IPV4}",
    "loadavg": "${LOADAVG}",
    "uptime": "${UPTIME}",
    "mem_total_mb": ${MEM_TOTAL_MB},
    "mem_used_mb": ${MEM_USED_MB},
    "cpu_pct": ${CPU_PCT},
    "disk_total_gb": ${DISK_TOTAL_GB},
    "disk_used_gb": ${DISK_USED_GB},
    "disk_used_pct": ${DISK_PCT},
    "rx_rate_kbps": ${rx_rate_kbps},
    "tx_rate_kbps": ${tx_rate_kbps},
    "rx_today_mb": ${rx_today_mb},
    "tx_today_mb": ${tx_today_mb}
  },
  "generated_at": "$(date -u +%FT%TZ)"
}
JSON

chmod 644 "$STATUS"
SH
chmod +x "$REFRESH_BIN"

# ----------------- write front panel -----------------
log "写入前端面板..."
cat >"${PANEL_DIR}/index.html" <<"HTML"
<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>sing-box 4in1 面板</title>
<style>
:root{--bg:#0f141b;--card:#151c24;--muted:#8aa1b4;--fg:#d6e2ee;--ok:#3ad29f;--bad:#ff6b6b;--btn:#1f2a36}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial}
.wrap{max-width:1100px;margin:24px auto;padding:0 16px}
.h{display:flex;align-items:center;gap:10px;margin:8px 0 16px}.tag{font-size:12px;padding:2px 8px;border-radius:999px;background:#1c2732;color:var(--muted)}
.grid{display:grid;gap:16px}@media(min-width:900px){.grid{grid-template-columns:1.1fr 1.4fr}}
.card{background:var(--card);border-radius:14px;padding:16px;box-shadow:0 1px 0 rgba(255,255,255,.03) inset,0 6px 24px rgba(0,0,0,.28)}
.kv{display:grid;grid-template-columns:120px 1fr;gap:6px 12px}.kv div{padding:2px 0;color:var(--muted)}.kv b{color:var(--fg);font-weight:600}
.row{display:flex;gap:8px;flex-wrap:wrap}.btn{background:var(--btn);color:#e8f0f7;border:none;border-radius:10px;padding:8px 12px;cursor:pointer}.btn:hover{filter:brightness(1.1)}
.badge{padding:2px 8px;border-radius:999px;border:1px solid #263342;color:var(--muted);font-size:12px}.badge.ok{border-color:rgba(58,210,159,.3);color:var(--ok)}.badge.bad{border-color:rgba(255,107,107,.3);color:var(--bad)}
.footer{margin-top:12px;color:var(--muted);font-size:12px}hr{border:0;border-top:1px solid #213041;margin:16px 0}.muted{color:var(--muted);font-size:12px}
.sub-head{display:flex;gap:8px;align-items:center;justify-content:space-between;margin-top:8px}.sub-wrap{display:flex;flex-direction:column;gap:8px;max-height:240px;overflow:auto}
.chip{padding:8px 10px;border:1px solid #263342;border-radius:10px;background:#0f141b;word-break:break-all;cursor:pointer}
.bar{height:10px;border-radius:999px;background:#0b1117;border:1px solid #263342;overflow:hidden}.bar>i{display:block;height:100%;background:#2b7fff30}
.err{background:#3a0f13;border:1px solid #c44242;color:#ffc6c6;padding:8px 12px;border-radius:10px;margin-bottom:10px}
</style></head><body>
<div class="wrap">
  <div class="h"><h2 style="margin:0">sing-box 4in1 面板</h2><span class="tag" id="stamp">初始化中…</span></div>
  <div id="errbox" style="display:none" class="err"></div>
  <div class="grid">
    <div class="card">
      <h3 style="margin:4px 0 12px">基本信息</h3>
      <div class="kv">
        <div>域名</div><b id="kv-domain">—</b>
        <div>证书颁发者</div><b id="kv-iss">—</b>
        <div>证书主体</div><b id="kv-sub">—</b>
        <div>生效时间</div><b id="kv-nb">—</b>
        <div>到期时间</div><b id="kv-na">—</b>
        <div>证书类型</div><b id="kv-alg">—</b>
        <div>监听端口</div>
        <b id="kv-ports">
          <span class="badge" id="p443">443</span>
          <span class="badge" id="p8444">8444</span>
          <span class="badge" id="p8448">8448</span>
          <span class="badge" id="p8447">8447/udp</span>
        </b>
      </div>
      <div class="row" style="margin-top:12px">
        <button class="btn" id="btn-refresh">刷新数据</button>
        <a class="btn" href="/status.json" target="_blank" rel="noopener">查看 JSON</a>
      </div><hr/>
      <div id="hostline" class="footer"></div>
    </div>
    <div class="card">
      <h3 style="margin:4px 0 12px">订阅与节点</h3>
      <div class="row">
        <button class="btn" id="btn-copy-url">复制订阅 URL</button>
        <a class="btn" href="/sub.txt" download="sub.txt">下载 sub.txt</a>
        <button class="btn" id="btn-copy-vmess">复制 VMESS</button>
        <button class="btn" id="btn-copy-vless">复制 VLESS</button>
        <button class="btn" id="btn-copy-trojan">复制 TROJAN</button>
        <button class="btn" id="btn-copy-hy2">复制 HY2</button>
      </div>
      <div class="sub-head"><span class="muted" id="subMeta">—</span><button class="btn" id="btn-toggle">折叠</button></div>
      <div id="quick-list" class="sub-wrap"></div>
    </div>
  </div>
  <div class="card" style="margin-top:16px">
    <h3 style="margin:4px 0 12px">VPS 健康概览（15 秒自动刷新）</h3>
    <div class="kv" style="grid-template-columns:120px 1fr">
      <div>CPU 占用</div><div class="bar"><i id="cpu"></i></div>
      <div>内存使用</div><div class="bar"><i id="mem"></i></div>
      <div>系统盘</div><div class="bar"><i id="disk"></i></div>
    </div>
    <div class="footer" id="healthline">—</div>
  </div>
</div>
<script>
const el=(id)=>document.getElementById(id);
const badge=(ok,id)=>{const b=el(id);b.classList.remove("ok","bad");b.classList.add(ok?"ok":"bad");};
const cp=async(t)=>{try{await navigator.clipboard.writeText(t);alert("已复制")}catch(e){prompt("复制失败，手动复制：",t)}};
async function loadStatus(){
  el("stamp").textContent="刷新中…"; el("errbox").style.display="none"; let st=null;
  try{const r=await fetch("/status.json?ts="+Date.now(),{cache:"no-store"}); st=JSON.parse(await r.text());}
  catch(e){el("errbox").style.display="block";el("errbox").textContent="加载 /status.json 失败";el("stamp").textContent="失败";return;}
  try{
    el("kv-domain").textContent=st.domain||"—";
    el("kv-iss").textContent=st.cert?.issuer||"—";
    el("kv-sub").textContent=st.cert?.subject||"—";
    el("kv-nb").textContent=st.cert?.not_before||"—";
    el("kv-na").textContent=st.cert?.not_after||"—";
    el("kv-alg").textContent=st.cert?.sigalg||"—";
    const P=st.ports||{};
    badge(P.tcp_443==="up","p443"); badge(P.tcp_8444==="up","p8444"); badge(P.tcp_8448==="up","p8448"); badge(P.udp_8447==="up","p8447");
    const memp=Math.min(100,Math.round(((st.host?.mem_used_mb||0)/Math.max(1,(st.host?.mem_total_mb||1)))*100));
    el("cpu").style.width=(st.host?.cpu_pct??0)+"%"; el("mem").style.width=memp+"%"; el("disk").style.width=(st.host?.disk_used_pct??0)+"%";
    el("healthline").textContent=`时间 ${st.generated_at} ｜ 主机 ${st.host?.name} ｜ nginx=${st.services?.nginx}、sing-box=${st.services?.singbox} ｜ uptime="${st.host?.uptime}"、loadavg=${st.host?.loadavg} ｜ CPU=${st.host?.cpu_pct}% ｜ MEM=${st.host?.mem_used_mb}/${st.host?.mem_total_mb}MB ｜ DISK=${st.host?.disk_used_gb}/${st.host?.disk_total_gb}GB (${st.host?.disk_used_pct}%) ｜ ↑${st.host?.tx_rate_kbps}KB/s ↓${st.host?.rx_rate_kbps}KB/s ｜ ↑${st.host?.tx_today_mb}MB 今日 ↓${st.host?.rx_today_mb}MB`;
    const sub=await fetch("/sub.txt?ts="+Date.now(),{cache:"no-store"}).then(x=>x.text()).catch(()=> "");
    const lines=sub.split(/\r?\n/).filter(Boolean), want=["vmess://","vless://","trojan://","hysteria2://"]; const pick=kw=>lines.find(x=>x.toLowerCase().startsWith(kw))||"";
    const box=el("quick-list"); box.innerHTML=""; let shown=0; want.forEach(kw=>{const v=pick(kw); if(!v) return; shown++; const d=document.createElement("div"); d.className="chip"; d.textContent=v; d.onclick=()=>cp(v); box.appendChild(d);});
    el("subMeta").textContent=shown?`已解析 ${shown} 条（各协议各 1 条）`:"未在 sub.txt 发现可用节点";
    el("btn-copy-url").onclick=()=>cp(location.origin+"/sub.txt");
    el("btn-copy-vmess").onclick=()=>cp(pick("vmess://")||"未找到 vmess");
    el("btn-copy-vless").onclick=()=>cp(pick("vless://")||"未找到 vless");
    el("btn-copy-trojan").onclick=()=>cp(pick("trojan://")||"未找到 trojan");
    el("btn-copy-hy2").onclick=()=>cp(pick("hysteria2://")||"未找到 hysteria2");
    el("stamp").textContent="刷新正常";
  }catch(e){el("errbox").style.display="block";el("errbox").textContent="前端渲染异常："+(e?.message||e);el("stamp").textContent="失败";}
}
document.getElementById("btn-refresh").onclick=loadStatus;
const quickWrap=document.getElementById("quick-list"), btnT=document.getElementById("btn-toggle");
let folded=false; btnT.onclick=()=>{ folded=!folded; quickWrap.style.maxHeight=folded?"0px":"240px"; quickWrap.style.overflow=folded?"hidden":"auto"; btnT.textContent=folded?"展开":"折叠"; };
loadStatus(); setInterval(loadStatus,15000);
</script></body></html>
HTML
chmod 644 "${PANEL_DIR}/index.html"

# ----------------- cron: refresh every minute -----------------
log "设置定时任务..."
echo '* * * * * root /usr/local/bin/sbx-panel-refresh >/dev/null 2>&1' > "$CRON_FILE"
chmod 644 "$CRON_FILE"
# 首次刷新
timeout 10s "$REFRESH_BIN" || warn "首次刷新失败，稍后 cron 会再跑"

# ----------------- nginx locations snippet -----------------
log "生成 Nginx 面板 locations..."
cat >"$SNIPPET" <<NGX
# === PANEL-LITE START ===
# panel UI
location /panel/ {
  alias ${PANEL_DIR}/;
  try_files \$uri \$uri/ /index.html;
  add_header Cache-Control "no-store" always;
}
# status json
location = /status.json {
  default_type application/json;
  add_header Cache-Control "no-store" always;
  try_files /status.json =404;
}
# subscription file
location = /sub.txt {
  default_type text/plain;
  add_header Cache-Control "no-store" always;
  try_files /sub.txt =404;
}
# ws reverse proxy (vmess/ws via 443)
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
# === PANEL-LITE END ===
NGX
chmod 644 "$SNIPPET"

# ----------------- mount snippet into 443 server -----------------
log "挂载面板到主 443 server..."

TARGET="$SITE_EN"
[[ -f "$SITE_AV" ]] && TARGET="$SITE_AV"

[[ -f "$TARGET" ]] || die "未找到 $TARGET，请确认你的 4in1 脚本已生成该站点文件。"

# 1) 清理老的面板段（标记之间）
sed -i '/# === PANEL-LITE START ===/,/# === PANEL-LITE END ===/d' "$TARGET" || true

# 2) 确保 443 server 只有一个 root（去重）
awk '
  /listen[ \t]+443/ { in443=1 }
  in443 && /^\s*root\s+/ { if(++root_seen>1) next }
  in443 && /^\s*}\s*$/ { in443=0; root_seen=0 }
  { print }
' "$TARGET" > /tmp/site.fixed && mv /tmp/site.fixed "$TARGET"

# 3) 在 443 server 的右花括号前插入 include 片段（若尚未包含）
if ! grep -qF "$SNIPPET" "$TARGET"; then
  awk -v inc="$SNIPPET" '
    /listen[ \t]+443/ { in443=1 }
    in443 && /^\s*}\s*$/ && !done { print "  include " inc ";" ; done=1 }
    { print }
  ' "$TARGET" > /tmp/site.fixed && mv /tmp/site.fixed "$TARGET"
fi

# 4) 确保启用的实际文件是 sites-enabled/singbox-site.conf
ln -sf "$TARGET" "$SITE_EN"

# ----------------- nginx reload (with timeout) -----------------
log "校验并重载 Nginx..."
timeout 8s nginx -t >/dev/null || { nginx -t; die "Nginx 配置有误"; }
timeout 8s systemctl reload nginx || die "重载 Nginx 失败"

ok "面板已启用"
echo "------------------------------------------"
echo "📊 状态面板:  https://${DOMAIN}/panel/"
echo "🧩 状态JSON:  https://${DOMAIN}/status.json"
echo "🔗 订阅链接:  https://${DOMAIN}/sub.txt"
echo "------------------------------------------"
echo "⚙️ 如仍 404，可执行： nginx -t && systemctl reload nginx"
