#!/usr/bin/env bash
# panel-dualhost.sh - Attach a lightweight sing-box status/subscription panel
# to the existing 443 SSL server without touching protocols/certs.
set -euo pipefail
IFS=$' \n\t'

PANEL_DIR="/var/www/singbox"
PANEL_SUBDIR="${PANEL_DIR}/panel"
STATUS_JSON="${PANEL_DIR}/status.json"
SUBTXT="${PANEL_DIR}/sub.txt"           # 由你的4in1脚本生成；若不存在也不报错
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
REFRESH_BIN="/usr/local/bin/singbox-panel-refresh"
CRON_FILE="/etc/cron.d/singbox-panel-refresh"

SITE_AV="/etc/nginx/sites-available/singbox-site.conf"
SITE_EN="/etc/nginx/sites-enabled/singbox-site.conf"

CERT="/etc/sing-box/cert.pem"   # 仅用于读取证书信息，不做签发
KEY="/etc/sing-box/key.pem"

echo "[STEP] 检查环境..."
command -v nginx >/dev/null 2>&1 || { echo "nginx 未安装"; exit 1; }
install -d "$PANEL_DIR" "$PANEL_SUBDIR" "$STATE_DIR" "$RUN_DIR"

# -------------------------
# 1) 生成状态刷新脚本
# -------------------------
echo "[STEP] 生成状态脚本..."
cat >"$REFRESH_BIN" <<"SH"
#!/usr/bin/env bash
set -euo pipefail
IFS=$' \n\t'
PANEL_DIR="/var/www/singbox"
STATUS="${PANEL_DIR}/status.json"
CERT="/etc/sing-box/cert.pem"
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
install -d "$STATE_DIR" "$RUN_DIR"

# 尝试推断域名（env -> nginx -> cert -> hostname）
DOMAIN=""
if [[ -f /root/sb.env ]]; then . /root/sb.env || true; DOMAIN="${DOMAIN:-}"; fi
if [[ -z "${DOMAIN}" ]]; then
  DOMAIN=$(awk '/server_name/{for(i=2;i<=NF;i++){gsub(/;|;/,"",$i); if($i!="_") print $i}}' \
            /etc/nginx/sites-enabled/*.conf /etc/nginx/sites-available/*.conf 2>/dev/null | head -n1 || true)
fi
if [[ -z "${DOMAIN}" && -s "$CERT" ]]; then
  DOMAIN=$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null \
            | sed -n 's/.*subjectAltName *= *//p' | tr ',' '\n' \
            | sed -n 's/^ *DNS:\(.*\)$/\1/p' | head -n1)
  [[ -n "${DOMAIN}" ]] || DOMAIN=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^,\/]*\).*/\1/p')
fi
if [[ -z "${DOMAIN}" ]]; then
  DOMAIN=$(hostname -f 2>/dev/null || hostname)
fi

# 证书信息
ISSUER=""; SUBJECT=""; NOT_BEFORE=""; NOT_AFTER=""; SIGALG=""
if [[ -s "$CERT" ]]; then
  RAW=$(openssl x509 -in "$CERT" -noout -issuer -subject -dates -text 2>/dev/null || true)
  ISSUER=$(echo "$RAW" | awk -F'issuer=' '/issuer=/{print $2}' | sed 's/^ *//; s/ *$//')
  SUBJECT=$(echo "$RAW" | awk -F'subject=' '/subject=/{print $2}' | sed 's/^ *//; s/ *$//')
  NOT_BEFORE=$(echo "$RAW" | awk -F'notBefore=' '/notBefore=/{print $2}')
  NOT_AFTER=$( echo "$RAW" | awk -F'notAfter='  '/notAfter=/{print  $2}')
  SIGALG=$(echo "$RAW" | awk -F': ' '/Signature Algorithm:/{print $2; exit}')
fi

# 监听端口（按你最终需要显示的端口；WS由Nginx反代，不必探测12080）
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

# -------------------------
# 2) 写入前端面板 (简化为 /panel/)
# -------------------------
echo "[STEP] 写入前端面板..."
cat >"${PANEL_SUBDIR}/index.html" <<'HTML'
<!doctype html><html lang="zh-CN"><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>sing-box 4in1 面板</title>
<style>
:root{--bg:#0f141b;--card:#151c24;--muted:#8aa1b4;--fg:#d6e2ee;--ok:#3ad29f;--bad:#ff6b6b;--btn:#1f2a36}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial}
.wrap{max-width:1100px;margin:24px auto;padding:0 16px}
.h{display:flex;align-items:center;gap:10px;margin:8px 0 16px}
.tag{font-size:12px;padding:2px 8px;border-radius:999px;background:#1c2732;color:var(--muted)}
.grid{display:grid;gap:16px}
@media(min-width:900px){.grid{grid-template-columns:1.1fr 1.4fr}}
.card{background:var(--card);border-radius:14px;padding:16px;box-shadow:0 1px 0 rgba(255,255,255,.03) inset,0 6px 24px rgba(0,0,0,.28)}
.kv{display:grid;grid-template-columns:120px 1fr;gap:6px 12px}
.kv div{padding:2px 0;color:var(--muted)}
.kv b{color:var(--fg);font-weight:600}
.row{display:flex;gap:8px;flex-wrap:wrap}
.btn{background:var(--btn);color:#e8f0f7;border:none;border-radius:10px;padding:8px 12px;cursor:pointer}
.btn:hover{filter:brightness(1.1)}
.badge{padding:2px 8px;border-radius:999px;border:1px solid #263342;color:var(--muted);font-size:12px}
.badge.ok{border-color:rgba(58,210,159,.3);color:var(--ok)}
.badge.bad{border-color:rgba(255,107,107,.3);color:var(--bad)}
.footer{margin-top:12px;color:var(--muted);font-size:12px}
hr{border:0;border-top:1px solid #213041;margin:16px 0}
.muted{color:var(--muted);font-size:12px}
.sub-wrap{display:flex;flex-direction:column;gap:8px;max-height:240px;overflow:auto}
.chip{padding:8px 10px;border:1px solid #263342;border-radius:10px;background:#0f141b;word-break:break-all;cursor:pointer}
.bar{height:10px;border-radius:999px;background:#0b1117;border:1px solid #263342;overflow:hidden}
.bar>i{display:block;height:100%;background:#2b7fff30}
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
        <button class="btn" onclick="location.reload()">刷新数据</button>
        <a class="btn" href="/status.json" target="_blank" rel="noopener">查看 JSON</a>
      </div>
      <hr/><div id="healthline" class="footer">—</div>
    </div>
    <div class="card">
      <h3 style="margin:4px 0 12px">订阅与节点</h3>
      <div class="row">
        <a class="btn" href="/sub.txt" download="sub.txt">下载 sub.txt</a>
        <button class="btn" id="btn-copy-url">复制订阅 URL</button>
      </div>
      <div class="sub-wrap" id="quick-list"></div>
    </div>
  </div>
  <div class="card" style="margin-top:16px">
    <h3 style="margin:4px 0 12px">VPS 健康概览（15 秒自动刷新）</h3>
    <div class="kv" style="grid-template-columns:120px 1fr">
      <div>CPU 占用</div><div class="bar"><i id="cpu"></i></div>
      <div>内存使用</div><div class="bar"><i id="mem"></i></div>
      <div>系统盘</div><div class="bar"><i id="disk"></i></div>
    </div>
  </div>
</div>
<script>
const el=(id)=>document.getElementById(id);
const badge=(ok,id)=>{const b=el(id); b&&b.classList.add(ok?"ok":"bad");};
const cp=async(t)=>{try{await navigator.clipboard.writeText(t);alert("已复制");}catch(e){prompt("复制失败，手动复制：",t)}};
async function load(){
  try{
    const st = await fetch("/status.json?ts="+Date.now(),{cache:"no-store"}).then(r=>r.json());
    el("kv-domain").textContent=st.domain||"—";
    el("kv-iss").textContent=st.cert?.issuer||"—";
    el("kv-sub").textContent=st.cert?.subject||"—";
    el("kv-nb").textContent=st.cert?.not_before||"—";
    el("kv-na").textContent=st.cert?.not_after||"—";
    el("kv-alg").textContent=st.cert?.sigalg||"—";
    const P=st.ports||{}; badge(P.tcp_443==="up","p443"); badge(P.tcp_8444==="up","p8444"); badge(P.tcp_8448==="up","p8448"); badge(P.udp_8447==="up","p8447");
    el("cpu").style.width=(st.host?.cpu_pct||0)+"%";
    const memUsed=st.host?.mem_used_mb||0, memTot=st.host?.mem_total_mb||1;
    el("mem").style.width=Math.min(100,Math.round(memUsed*100/memTot))+"%";
    el("disk").style.width=(st.host?.disk_used_pct||0)+"%";
    const lines=(await fetch("/sub.txt?ts="+Date.now(),{cache:"no-store"}).then(r=>r.text()).catch(()=>"" )).split(/\r?\n/).filter(Boolean);
    const box=el("quick-list"); box.innerHTML="";
    lines.slice(0,6).forEach(v=>{const d=document.createElement("div");d.className="chip";d.textContent=v;d.onclick=()=>cp(v);box.appendChild(d);});
    el("stamp").textContent="刷新正常";
    el("btn-copy-url").onclick=()=>cp(location.origin+"/sub.txt");
  }catch(e){
    el("stamp").textContent="失败"; const eb=document.createElement("div"); eb.className="err"; eb.textContent="加载失败: "+(e?.message||e); document.body.prepend(eb);
  }
}
load(); setInterval(load,15000);
</script>
</body></html>
HTML
chmod 644 "${PANEL_SUBDIR}/index.html"

# -------------------------
# 3) 定时任务（每分钟刷新一次）
# -------------------------
echo "[STEP] 设置定时任务..."
echo '* * * * * root /usr/local/bin/singbox-panel-refresh >/dev/null 2>&1' > "$CRON_FILE"
chmod 644 "$CRON_FILE"
"$REFRESH_BIN" || true

# -------------------------
# 4) 生成 Nginx 面板 locations (alias 版)
# -------------------------
echo "[STEP] 生成 Nginx 面板 locations..."
P_LOC_PANEL=$(cat <<'NGX'
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
)

# -------------------------
# 5) 将面板 locations 挂到主 443 server
# -------------------------
echo "[STEP] 挂载面板到主 443 server..."
if [[ ! -f "$SITE_AV" ]]; then
  echo "未找到 $SITE_AV，放弃自动挂载。请手动把以下片段加入到你的 443 server{} 内："
  echo "$P_LOC_PANEL"
  exit 1
fi

# 若已存在标记，先移除再写入，避免重复
sed -i '/# === singbox-panel BEGIN ===/,/# === singbox-panel END ===/d' "$SITE_AV"

# 把片段插入到 443 SSL 的 server 块内（靠近结尾大括号前）
# 简单做法：在第二个 server {listen 443 ssl ... } 的尾部前插入；若只有一个 443 server，同样生效
# 这里用 awk 粗分，找到含 "listen 443" 的 server 范围再拼接
awk -v PANEL="$P_LOC_PANEL" '
  BEGIN{in443=0; depth=0}
  function print_panel(){ if(!printed){ print PANEL; printed=1 } }
  {
    line=$0
    # 跟踪大括号深度
    n_open=gsub(/{/,"{",line)
    n_close=gsub(/}/,"}",line)
    # 检测进入server块
    if($0 ~ /^[ \t]*server[ \t]*\{/){ depth++; if($0 ~ /listen[ \t]+443/){ in443=1 } next_line=$0; print next_line; next; }
    # 非第一行 server 继续
    if(in443 && $0 ~ /listen[ \t]+443/){ }

    # 在即将离开 443 这个 server 之前注入
    if(in443 && depth>0 && $0 ~ /^[ \t]*}/){
      print_panel()
      print $0
      in443=0
      next
    }
    print $0
    # 更新深度（在打印后更新更直观）
  }
' "$SITE_AV" > "${SITE_AV}.tmp" || true

# 如果 awk 没写出文件（失败或没有匹配），则退回简单方式：直接在文件末尾补一个 server 块（备选，不影响已有站）
if [[ ! -s "${SITE_AV}.tmp" ]]; then
  echo "⚠️ 未能定位 443 server，退回追加一个独立 server（与原同域名可能冲突，请自行合并）。"
  cat >> "$SITE_AV" <<'NGX'
server {
  listen 443 ssl http2;
  # 请确保与主站 server_name 一致
  # server_name YOUR.DOMAIN.HERE;

  # === singbox-panel BEGIN (fallback) ===
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
  # === singbox-panel END (fallback) ===
}
NGX
else
  mv "${SITE_AV}.tmp" "$SITE_AV"
fi

# 确保被启用
ln -sf "$SITE_AV" "$SITE_EN" >/dev/null 2>&1 || true

echo "[STEP] 校验并重载 Nginx..."
nginx -t
systemctl reload nginx || systemctl restart nginx

echo
echo "✅ 面板已启用"
echo "------------------------------------------"
echo "📊 状态面板:  https://<你的域名>/panel/"
echo "🧩 状态JSON:  https://<你的域名>/status.json"
echo "🔗 订阅链接:  https://<你的域名>/sub.txt"
echo "------------------------------------------"
echo "⚙️ 如挂了 CDN，请把 /status.json 与 /sub.txt 设为不缓存；面板目录 /panel/ 默认静态可缓存。"
