#!/usr/bin/env bash
# panel-full.sh  —  sing-box 4in1 可视化面板（安全修补版）
set -euo pipefail
IFS=$' \n\t'

PANEL_DIR="/var/www/singbox"
SITE_AV="/etc/nginx/sites-available/singbox-site.conf"
SITE_EN="/etc/nginx/sites-enabled/singbox-site.conf"
CERT="/etc/sing-box/cert.pem"
KEY="/etc/sing-box/key.pem"
REFRESH_BIN="/usr/local/bin/singbox-panel-refresh"
CRON_FILE="/etc/cron.d/singbox-panel-refresh"
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
install -d "$PANEL_DIR" "$STATE_DIR" "$RUN_DIR"

echo "[STEP] 检查环境..."
command -v nginx >/dev/null || (apt-get update -y && apt-get install -y nginx)
systemctl enable --now nginx >/dev/null 2>&1 || true

# ---------- 获取域名（不强依赖） ----------
DOMAIN=""
if [[ -f /root/sb.env ]]; then . /root/sb.env || true; DOMAIN="${DOMAIN:-}"; fi
if [[ -z "${DOMAIN}" && -f "$SITE_AV" ]]; then
  DOMAIN=$(awk '/server_name/{for(i=2;i<=NF;i++){gsub(/;|;/,"",$i); if($i!="_") print $i}}' "$SITE_AV" 2>/dev/null | head -n1 || true)
fi
if [[ -z "${DOMAIN}" && -s "$CERT" ]]; then
  DOMAIN=$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null \
      | sed -n 's/.*subjectAltName *= *//p' | tr ',' '\n' | sed -n 's/^ *DNS:\(.*\)$/\1/p' | head -n1)
  [[ -n "${DOMAIN}" ]] || DOMAIN=$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^,\/]*\).*/\1/p')
fi
[[ -n "${DOMAIN}" ]] || DOMAIN="$(hostname -f 2>/dev/null || hostname)"

# ---------- 生成刷新器：写 status.json ----------
cat >"$REFRESH_BIN" <<"SH"
#!/usr/bin/env bash
set -euo pipefail
IFS=$' \n\t'
PANEL_DIR="/var/www/singbox"
STATUS="${PANEL_DIR}/status.json"
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
install -d "$STATE_DIR" "$RUN_DIR" "$PANEL_DIR"

# 取域名
get_domain(){
  local envd="" ngxd="" sand="" cnd="" host=""
  if [[ -f /root/sb.env ]]; then . /root/sb.env || true; envd="${DOMAIN:-}"; fi
  ngxd=$(awk '/server_name/{for(i=2;i<=NF;i++){gsub(/;|;/,"",$i); if($i!="_") print $i}}' \
            /etc/nginx/sites-enabled/*.conf /etc/nginx/sites-available/*.conf 2>/dev/null | head -n1 || true)
  if [[ -s "/etc/sing-box/cert.pem" ]]; then
    sand=$(openssl x509 -in /etc/sing-box/cert.pem -noout -ext subjectAltName 2>/dev/null | sed -n 's/.*subjectAltName *= *//p' | tr ',' '\n' | sed -n 's/^ *DNS:\(.*\)$/\1/p' | head -n1)
    cnd=$(openssl x509 -in /etc/sing-box/cert.pem -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^,\/]*\).*/\1/p')
  fi
  host=$(hostname -f 2>/dev/null || hostname)
  echo "${envd:-${ngxd:-${sand:-${cnd:-$host}}}}"
}
DOMAIN="$(get_domain)"

# 服务状态
svc(){ systemctl is-active --quiet "$1" && echo "active" || echo "inactive"; }
NGINX_STATE=$(svc nginx)
SING_STATE=$(svc sing-box)

# 监听端口
LISTEN_TCP=$(ss -tlpen 2>/dev/null | awk 'NR>1{print $4}' | sed 's/.*://')
LISTEN_UDP=$(ss -ulpen 2>/dev/null | awk 'NR>1{print $4}' | sed 's/.*://')
PORTS_JSON=$(printf '%s\n%s\n' "$LISTEN_TCP" "$LISTEN_UDP" | awk 'NF' | sort -nu | awk 'BEGIN{printf "["} {printf (NR==1?"\"%s\"":",\"%s\""),$1} END{printf "]"}')

# 资源
read MT MA < <(awk '/MemTotal:|MemAvailable:/{gsub(/[^0-9]/,"",$2); print $2}' /proc/meminfo | xargs)
MEM_TOTAL_MB=$(( MT/1024 )); MEM_USED_MB=$(( (MT-MA)/1024 ))
read -r I1 T1 < <(awk '/^cpu /{print $5,$2+$3+$4+$5+$6+$7+$8+$9+$10+$11}' /proc/stat); sleep 0.2
read -r I2 T2 < <(awk '/^cpu /{print $5,$2+$3+$4+$5+$6+$7+$8+$9+$10+$11}' /proc/stat)
CPU_PCT=$(( (100*( (T2-T1)-(I2-I1) ) + (T2-T1)/2 ) / (T2-T1) ))
read -r DU DT < <(df -B1 -P / | awk 'NR==2{print $3,$2}')
DISK_USED_GB=$(( DU/1024/1024/1024 )); DISK_TOTAL_GB=$(( DT/1024/1024/1024 ))
DISK_PCT=$(( (100*DU + DT/2) / DT ))

# 网速/今日流量
now=$(date +%s)
rx=$(awk -F'[: ]+' 'NR>2&&$1!="lo"{s+=$3} END{printf "%.0f",s}' /proc/net/dev)
tx=$(awk -F'[: ]+' 'NR>2&&$1!="lo"{s+=$11} END{printf "%.0f",s}' /proc/net/dev)
base="$RUN_DIR/rate.prev"; old_t=$now; old_rx=$rx; old_tx=$tx
[[ -s "$base" ]] && read -r old_t old_rx old_tx < "$base" || true
echo "$now $rx $tx" > "$base"
dt=$(( now-old_t )); rx_kbps=0; tx_kbps=0
(( dt>0 )) && { rx_kbps=$(( ((rx-old_rx)*8)/1024/dt )); tx_kbps=$(( ((tx-old_tx)*8)/1024/dt )); }

day="$STATE_DIR/traffic-$(date +%Y%m%d).base"
[[ -s "$day" ]] || echo "$now $rx $tx" > "$day"
read -r b_t b_rx b_tx < "$day"
rx_today_mb=$(( (rx-b_rx)/1024/1024 )); tx_today_mb=$(( (tx-b_tx)/1024/1024 ))
(( rx_today_mb<0 )) && rx_today_mb=0; (( tx_today_mb<0 )) && tx_today_mb=0

cat >"$STATUS" <<JSON
{
  "domain": "$DOMAIN",
  "services": { "nginx": "$NGINX_STATE", "singbox": "$SING_STATE" },
  "ports": $PORTS_JSON,
  "host": {
    "name": "$(hostname -f 2>/dev/null || hostname)",
    "mem_total_mb": $MEM_TOTAL_MB, "mem_used_mb": $MEM_USED_MB,
    "cpu_pct": $CPU_PCT,
    "disk_total_gb": $DISK_TOTAL_GB, "disk_used_gb": $DISK_USED_GB, "disk_used_pct": $DISK_PCT,
    "rx_rate_kbps": $rx_kbps, "tx_rate_kbps": $tx_kbps,
    "rx_today_mb": $rx_today_mb, "tx_today_mb": $tx_today_mb
  },
  "generated_at": "$(date -u +%FT%TZ)"
}
JSON
chmod 644 "$STATUS"
SH
chmod +x "$REFRESH_BIN"
"$REFRESH_BIN" || true
echo '* * * * * root /usr/local/bin/singbox-panel-refresh >/dev/null 2>&1' > "$CRON_FILE"
chmod 644 "$CRON_FILE"

# ---------- 前端（完整可视化） ----------
cat >"${PANEL_DIR}/index.html" <<'HTML'
<!doctype html><html lang="zh-CN"><head>
<meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>sing-box 4in1 面板</title>
<style>
:root{--bg:#0f141b;--card:#151c24;--muted:#8aa1b4;--fg:#d6e2ee;--ok:#3ad29f;--bad:#ff6b6b;--btn:#1f2a36}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto}
.wrap{max-width:1100px;margin:24px auto;padding:0 16px}.h{display:flex;align-items:center;gap:10px;margin:8px 0 16px}
.tag{font-size:12px;padding:2px 8px;border-radius:999px;background:#1c2732;color:var(--muted)}
.grid{display:grid;gap:16px}@media(min-width:900px){.grid{grid-template-columns:1.1fr 1.4fr}}
.card{background:var(--card);border-radius:14px;padding:16px;box-shadow:0 1px 0 rgba(255,255,255,.03) inset,0 6px 24px rgba(0,0,0,.28)}
.kv{display:grid;grid-template-columns:120px 1fr;gap:6px 12px}.kv div{padding:2px 0;color:var(--muted)}.kv b{color:var(--fg);font-weight:600}
.row{display:flex;gap:8px;flex-wrap:wrap}.btn{background:var(--btn);color:#e8f0f7;border:none;border-radius:10px;padding:8px 12px;cursor:pointer}
.btn:hover{filter:brightness(1.1)}.badge{padding:2px 8px;border-radius:999px;border:1px solid #263342;color:var(--muted);font-size:12px}
.badge.ok{border-color:rgba(58,210,159,.3);color:var(--ok)}.badge.bad{border-color:rgba(255,107,107,.3);color:var(--bad)}
.footer{margin-top:12px;color:var(--muted);font-size:12px}hr{border:0;border-top:1px solid #213041;margin:16px 0}
.muted{color:var(--muted);font-size:12px}.sub-head{display:flex;gap:8px;align-items:center;justify-content:space-between;margin-top:8px}
.sub-wrap{display:flex;flex-direction:column;gap:8px;max-height:240px;overflow:auto}
.chip{padding:8px 10px;border:1px solid #263342;border-radius:10px;background:#0f141b;word-break:break-all;cursor:pointer}
.bar{height:10px;border-radius:999px;background:#0b1117;border:1px solid #263342;overflow:hidden}.bar>i{display:block;height:100%;background:#2b7fff30}
.err{background:#3a0f13;border:1px solid #c44242;color:#ffc6c6;padding:8px 12px;border-radius:10px;margin-bottom:10px}
</style></head><body><div class="wrap">
<div class="h"><h2 style="margin:0">sing-box 4in1 面板</h2><span class="tag" id="stamp">初始化中…</span></div>
<div id="errbox" style="display:none" class="err"></div>
<div class="grid">
  <div class="card">
    <h3 style="margin:4px 0 12px">基本信息</h3>
    <div class="kv">
      <div>域名</div><b id="kv-domain">—</b>
      <div>nginx</div><b id="kv-ng">—</b>
      <div>sing-box</div><b id="kv-sb">—</b>
      <div>监听端口</div>
      <b id="kv-ports"><span class="badge" id="p443">443</span><span class="badge" id="p8443">8443</span><span class="badge" id="p8444">8444</span><span class="badge" id="p8448">8448</span><span class="badge" id="p8447">8447/udp</span></b>
    </div>
    <div class="row" style="margin-top:12px">
      <button class="btn" id="btn-refresh">刷新数据</button>
      <a class="btn" href="/status.json" target="_blank" rel="noopener">查看 JSON</a>
      <a class="btn" href="/sub.txt" download="sub.txt">下载 sub.txt</a>
    </div><hr/><div id="hostline" class="footer"></div>
  </div>
  <div class="card">
    <h3 style="margin:4px 0 12px">订阅与节点</h3>
    <div class="row">
      <button class="btn" id="btn-copy-url">复制订阅 URL</button>
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
    <div>CPU 占用</div><div class="bar"><i id="cpu"></i><span id="cpu_val" class="muted" style="position:absolute;right:8px;top:50%;transform:translateY(-50%)">—</span></div>
    <div>内存使用</div><div class="bar"><i id="mem"></i><span id="mem_val" class="muted" style="position:absolute;right:8px;top:50%;transform:translateY(-50%)">—</span></div>
    <div>系统盘</div><div class="bar"><i id="disk"></i><span id="disk_val" class="muted" style="position:absolute;right:8px;top:50%;transform:translateY(-50%)">—</span></div>
  </div>
  <div class="footer" id="healthline">—</div>
</div>
</div>
<script>
const el = (id)=>document.getElementById(id);
const badge=(ok,id)=>{const b=el(id); b&&b.classList&&(b.classList.remove("ok","bad"), b.classList.add(ok?"ok":"bad"));};
const cp = async (t)=>{ try{ await navigator.clipboard.writeText(t); alert("已复制"); }catch(e){ prompt("复制失败，手动复制：",t) } };

async function loadStatus(){
  el("stamp").textContent="刷新中…"; el("errbox").style.display="none";
  let st=null, raw="";
  try { const r=await fetch("/status.json?ts="+Date.now(),{cache:"no-store"}); raw=await r.text(); st=JSON.parse(raw); }
  catch(e){ el("errbox").style.display="block"; el("errbox").textContent="加载 /status.json 失败。"; el("stamp").textContent="失败"; return; }

  el("kv-domain").textContent = st.domain || "—";
  el("kv-ng").textContent = st.services?.nginx || "—";
  el("kv-sb").textContent = st.services?.singbox || "—";
  (st.ports||[]).forEach(p=>{ const id = "p"+p; badge(true,id); });
  const memp = Math.min(100, Math.round(((st.host?.mem_used_mb||0)/Math.max(1,(st.host?.mem_total_mb||1)))*100));
  el("cpu").style.width=(st.host?.cpu_pct||0)+"%"; el("cpu_val").textContent=(st.host?.cpu_pct||0)+"%";
  el("mem").style.width=memp+"%"; el("mem_val").textContent=`${st.host?.mem_used_mb}/${st.host?.mem_total_mb} MB (${memp}%)`;
  el("disk").style.width=(st.host?.disk_used_pct||0)+"%"; el("disk_val").textContent=`${st.host?.disk_used_gb}/${st.host?.disk_total_gb} GB (${st.host?.disk_used_pct}%)`;
  el("healthline").textContent = `时间 ${st.generated_at} ｜ 主机 ${st.host?.name} ｜ CPU=${st.host?.cpu_pct}% ｜ MEM=${st.host?.mem_used_mb}/${st.host?.mem_total_mb}MB ｜ 磁盘=${st.host?.disk_used_gb}/${st.host?.disk_total_gb}GB (${st.host?.disk_used_pct}%) ｜ ↑${st.host?.tx_rate_kbps}KB/s ↓${st.host?.rx_rate_kbps}KB/s ｜ 今日↑${st.host?.tx_today_mb}MB ↓${st.host?.rx_today_mb}MB`;

  // 订阅解析
  const sub = await fetch("/sub.txt?ts="+Date.now(),{cache:"no-store"}).then(x=>x.text()).catch(()=> "");
  const lines = (sub||"").split(/\r?\n/).filter(Boolean);
  const want = ["vmess://","vless://","trojan://","hysteria2://"];
  const pick = kw=>lines.find(x=>x.toLowerCase().startsWith(kw))||"";
  const box=el("quick-list"); box.innerHTML=""; let shown=0;
  want.forEach(kw=>{ const v=pick(kw); if(!v) return; shown++; const d=document.createElement("div"); d.className="chip"; d.textContent=v; d.onclick=()=>cp(v); box.appendChild(d); });
  el("subMeta").textContent = shown ? `已解析 ${shown} 条（各协议各 1 条）` : "未在 sub.txt 发现可用节点";

  el("btn-copy-url").onclick = ()=>cp(location.origin+"/sub.txt");
  el("btn-copy-vmess").onclick = ()=>cp((lines.find(x=>x.startsWith("vmess://"))||"未找到 vmess"));
  el("btn-copy-vless").onclick = ()=>cp((lines.find(x=>x.startsWith("vless://"))||"未找到 vless"));
  el("btn-copy-trojan").onclick= ()=>cp((lines.find(x=>x.startsWith("trojan://"))||"未找到 trojan"));
  el("btn-copy-hy2").onclick   = ()=>cp((lines.find(x=>x.startsWith("hysteria2://"))||"未找到 hysteria2"));
  el("stamp").textContent="刷新正常";
}
el("btn-refresh").onclick=loadStatus;
let folded=false; el("btn-toggle").onclick=()=>{ folded=!folded; const q=el("quick-list"); q.style.maxHeight=folded?"0px":"240px"; q.style.overflow=folded?"hidden":"auto"; el("btn-toggle").textContent=folded?"展开":"折叠"; };
loadStatus(); setInterval(loadStatus,15000);
</script></body></html>
HTML
chmod 644 "${PANEL_DIR}/index.html"

# ---------- 修补 Nginx 443 server 块（只追加，不重复建站） ----------
echo "[STEP] 修补 Nginx 配置..."
if [[ ! -f "$SITE_AV" ]]; then
  echo "ERROR: 未找到 $SITE_AV，面板只写入了文件。请先安装 4in1（确保此文件存在）。"
else
  # 给 443 的 server 块补上 root/index 与 /panel /status.json 路由（幂等）
  tmp="$(mktemp)"; add_root=0; add_panel=0; add_status=0
  awk -v ROOT="$PANEL_DIR" '
    BEGIN{in443=0}
    /server[ \t]*\{/ {stack++; print; next}
    /\}/ {stack--; print; next}
    { line=$0 }
    (stack>0 && line ~ /listen[ \t]+443/){ in443=1 }
    (stack==0){ in443=0 }
    {
      print
      if(in443 && line ~ /server_name/ && !seen_root++){
        print "  root " ROOT ";"
        print "  index index.html;"
      }
      if(in443 && line ~ /{ *$/){
        # 留给后续幂等性检查处理
      }
    }
  ' "$SITE_AV" > "$tmp" && mv "$tmp" "$SITE_AV"

  # 幂等追加 location（若已存在则跳过）
  grep -qE 'location[[:space:]]*=/panel' "$SITE_AV" || \
    sed -i '/listen[[:space:]]\+443/,$a\  location = /panel { try_files /index.html =404; }' "$SITE_AV"
  grep -qE 'location[[:space:]]*=/status\.json' "$SITE_AV" || \
    sed -i '/listen[[:space:]]\+443/,$a\  location = /status.json { default_type application/json; try_files /status.json =404; }' "$SITE_AV"

  ln -sf "$SITE_AV" "$SITE_EN"
  nginx -t && systemctl reload nginx
fi

echo
echo "==== 面板就绪 ===="
echo "面板 URL : https://${DOMAIN}/panel"
echo "状态 JSON: https://${DOMAIN}/status.json"
echo "订阅     : https://${DOMAIN}/sub.txt"
