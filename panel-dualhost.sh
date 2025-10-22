#!/usr/bin/env bash
# panel-dualhost.sh — sing-box 4in1 轻量面板（复用现有站点）
# 用法：
#   bash panel-dualhost.sh -d bbvpn.example.com [--hide-ports 8443,8448]
set -euo pipefail
IFS=$' \n\t'

PANEL_DIR="/var/www/singbox"             # 复用你现有站点使用的根目录
CERT="/etc/sing-box/cert.pem"            # 复用已有证书
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
REFRESH_BIN="/usr/local/bin/singbox-panel-refresh"
CRON_FILE="/etc/cron.d/singbox-panel-refresh"
install -d "$PANEL_DIR" "$STATE_DIR" "$RUN_DIR"

DOMAIN=""
HIDE_PORTS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain) DOMAIN="${2:-}"; shift 2;;
    --hide-ports) HIDE_PORTS="${2:-}"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ -z "$DOMAIN" ]]; then
  # 1) sb.env 2) cert SAN/CN 3) hostname
  if [[ -f /root/sb.env ]]; then . /root/sb.env || true; fi
  DOMAIN="${DOMAIN:-}"
  if [[ -z "$DOMAIN" && -s "$CERT" ]]; then
    DOMAIN=$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null \
       | sed -n 's/.*subjectAltName *= *//p' | tr ',' '\n' \
       | sed -n 's/^ *DNS:\(.*\)$/\1/p' | head -n1)
    [[ -n "$DOMAIN" ]] || DOMAIN=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^,\/]*\).*/\1/p')
  fi
  [[ -n "$DOMAIN" ]] || DOMAIN=$(hostname -f 2>/dev/null || hostname)
fi

# 写入刷新器（每次执行生成 /var/www/singbox/status.json）
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

get_domain(){
  local d=""
  if [[ -f /root/sb.env ]]; then . /root/sb.env || true; d="${DOMAIN:-}"; fi
  if [[ -z "$d" && -s "$CERT" ]]; then
    d=$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | sed -n 's/.*subjectAltName *= *//p' | tr ',' '\n' | sed -n 's/^ *DNS:\(.*\)$/\1/p' | head -n1)
    [[ -n "$d" ]] || d=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^,\/]*\).*/\1/p')
  fi
  [[ -n "$d" ]] || d=$(hostname -f 2>/dev/null || hostname)
  echo "$d"
}
DOMAIN="$(get_domain)"

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

# 端口监听
LISTEN=$(ss -tulpen 2>/dev/null | awk '
/:443 /{a["443/tcp"]=1}
/:8443/{a["8443/tcp"]=1}
/:8444/{a["8444/tcp"]=1}
/:8448/{a["8448/tcp"]=1}
END{
  printf("%s",(a["443/tcp"] ?"443=up ":"443=down "));
  printf("%s",(a["8443/tcp"]?"8443=up ":"8443=down "));
  printf("%s",(a["8444/tcp"]?"8444=up ":"8444=down "));
  printf("%s",(a["8448/tcp"]?"8448=up ":"8448=down "));
}')
UDP8447=$(ss -ulpen 2>/dev/null | grep -q ':8447 ' && echo up || echo down)

is_active(){ systemctl is-active --quiet "$1" && echo "active" || echo "inactive"; }
NGINX_STATE=$(is_active nginx)
SING_STATE=$(is_active sing-box)

# 主机资源
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
    "tcp_8443":  "$(echo "$LISTEN" | grep -q '8443=up' && echo up || echo down)",
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

# 生成/更新前端面板（可隐藏端口）
HP_SET="$(echo ",${HIDE_PORTS}," | tr -d ' ')"  # 形如 ,8443,8448,
hide(){ [[ "$HP_SET" == *",$1,"* ]]; }

cat >"${PANEL_DIR}/index.html" <<HTML
<!doctype html><html lang="zh-CN"><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>sing-box 4in1 面板</title>
<style>
:root{--bg:#0f141b;--card:#151c24;--muted:#8aa1b4;--fg:#d6e2ee;--ok:#3ad29f;--bad:#ff6b6b;--btn:#1f2a36}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial}
.wrap{max-width:1100px;margin:24px auto;padding:0 16px}.h{display:flex;gap:10px;align-items:center}
.tag{font-size:12px;padding:2px 8px;border-radius:999px;background:#1c2732;color:var(--muted)}
.grid{display:grid;gap:16px}@media(min-width:900px){.grid{grid-template-columns:1.1fr 1.4fr}}
.card{background:var(--card);border-radius:14px;padding:16px;box-shadow:0 1px 0 rgba(255,255,255,.03) inset,0 6px 24px rgba(0,0,0,.28)}
.kv{display:grid;grid-template-columns:120px 1fr;gap:6px 12px}.kv div{color:var(--muted)}.kv b{font-weight:600}
.row{display:flex;gap:8px;flex-wrap:wrap}.btn{background:var(--btn);color:#e8f0f7;border:none;border-radius:10px;padding:8px 12px;cursor:pointer}
.badge{padding:2px 8px;border-radius:999px;border:1px solid #263342;color:var(--muted);font-size:12px}
.badge.ok{border-color:rgba(58,210,159,.3);color:var(--ok)}.badge.bad{border-color:rgba(255,107,107,.3);color:var(--bad)}
.muted{color:var(--muted);font-size:12px}.sub-wrap{display:flex;flex-direction:column;gap:8px;max-height:240px;overflow:auto}
.chip{padding:8px 10px;border:1px solid #263342;border-radius:10px;background:#0f141b;word-break:break-all;cursor:pointer}
.bar{height:10px;border-radius:999px;background:#0b1117;border:1px solid #263342;overflow:hidden}
.bar>i{display:block;height:100%;background:#2b7fff30}
</style>
<div class="wrap">
  <div class="h"><h2 style="margin:0">sing-box 4in1 面板</h2><span class="tag" id="stamp">初始化…</span></div>
  <div class="grid">
    <div class="card">
      <h3 style="margin:4px 0 12px">基本信息</h3>
      <div class="kv">
        <div>域名</div><b id="kv-domain">—</b>
        <div>证书颁发者</div><b id="kv-iss">—</b>
        <div>证书主体</div><b id="kv-sub">—</b>
        <div>生效</div><b id="kv-nb">—</b>
        <div>到期</div><b id="kv-na">—</b>
        <div>签名算法</div><b id="kv-alg">—</b>
        <div>监听端口</div>
        <b id="kv-ports">
          <span class="badge" id="p443">443</span>
          $(hide 8443 || echo '<span class="badge" id="p8443">8443</span>')
          $(hide 8444 || echo '<span class="badge" id="p8444">8444</span>')
          $(hide 8448 || echo '<span class="badge" id="p8448">8448</span>')
          <span class="badge" id="p8447">8447/udp</span>
        </b>
      </div>
      <div class="row" style="margin-top:12px">
        <a class="btn" href="/status.json" target="_blank">查看 JSON</a>
        <a class="btn" href="/sub.txt" download="sub.txt">下载 sub.txt</a>
      </div>
      <hr/>
      <div class="kv" style="grid-template-columns:120px 1fr">
        <div>CPU</div><div class="bar"><i id="cpu"></i></div>
        <div>内存</div><div class="bar"><i id="mem"></i></div>
        <div>磁盘</div><div class="bar"><i id="disk"></i></div>
      </div>
      <div class="muted" id="health">—</div>
    </div>
    <div class="card">
      <h3 style="margin:4px 0 12px">订阅与节点</h3>
      <div class="sub-wrap" id="quick-list"></div>
    </div>
  </div>
</div>
<script>
const el=id=>document.getElementById(id); const bd=(ok,id)=>{const b=el(id); if(!b) return; b.classList.remove("ok","bad"); b.classList.add(ok?"ok":"bad");};
const cp=async t=>{try{await navigator.clipboard.writeText(t);alert("已复制")}catch{prompt("复制失败，手动复制：",t)}};
async function load(){
  el("stamp").textContent="刷新中…";
  const st=await fetch("/status.json?ts="+Date.now(),{cache:"no-store"}).then(r=>r.json()).catch(()=>null);
  if(!st){ el("stamp").textContent="失败"; return; }
  el("kv-domain").textContent=st.domain||"—";
  el("kv-iss").textContent=st.cert?.issuer||"—"; el("kv-sub").textContent=st.cert?.subject||"—";
  el("kv-nb").textContent=st.cert?.not_before||"—"; el("kv-na").textContent=st.cert?.not_after||"—";
  el("kv-alg").textContent=st.cert?.sigalg||"—";
  const P=st.ports||{}; bd(P.tcp_443==="up","p443"); bd(P.tcp_8443==="up","p8443"); bd(P.tcp_8444==="up","p8444"); bd(P.tcp_8448==="up","p8448"); bd(P.udp_8447==="up","p8447");
  const memp=Math.min(100,Math.round(((st.host?.mem_used_mb||0)/Math.max(1,(st.host?.mem_total_mb||1)))*100));
  el("cpu").style.width=(st.host?.cpu_pct||0)+"%"; el("mem").style.width=memp+"%"; el("disk").style.width=(st.host?.disk_used_pct||0)+"%";
  el("health").textContent=\`时间 \${st.generated_at} ｜ 主机 \${st.host?.name} ｜ nginx=\${st.services?.nginx}、sing-box=\${st.services?.singbox} ｜ CPU=\${st.host?.cpu_pct}% ｜ MEM=\${st.host?.mem_used_mb}/\${st.host?.mem_total_mb}MB ｜ DISK=\${st.host?.disk_used_gb}/\${st.host?.disk_total_gb}GB\`;
  const sub=await fetch("/sub.txt?ts="+Date.now(),{cache:"no-store"}).then(r=>r.text()).catch(()=> "");
  const lines=sub.split(/\\r?\\n/).filter(Boolean); const want=["vmess://","vless://","trojan://","hysteria2://"];
  const box=el("quick-list"); box.innerHTML=""; want.forEach(k=>{const v=lines.find(x=>x.toLowerCase().startsWith(k))||""; if(!v) return; const d=document.createElement("div"); d.className="chip"; d.textContent=v; d.onclick=()=>cp(v); box.appendChild(d);});
  el("stamp").textContent="刷新正常";
}
load(); setInterval(load,15000);
</script>
HTML
chmod 644 "${PANEL_DIR}/index.html"

# 立即刷新一次 + 每分钟刷新
"$REFRESH_BIN" || true
echo '* * * * * root /usr/local/bin/singbox-panel-refresh >/dev/null 2>&1' > "$CRON_FILE"
chmod 644 "$CRON_FILE"

echo
echo "==== PANEL READY ===="
echo "Panel     : https://${DOMAIN}/"
echo "Status    : https://${DOMAIN}/status.json"
echo "Subscribe : https://${DOMAIN}/sub.txt"
[[ -n "$HIDE_PORTS" ]] && echo "Hidden Ports: ${HIDE_PORTS}"
