#!/usr/bin/env bash
# panel-lite.sh — 只添加面板与状态文件；不签发证书、不改 server_name、不新建 server{}
set -euo pipefail
IFS=$' \n\t'

PANEL_DIR="/var/www/singbox"
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
SITE_AV="/etc/nginx/sites-available/singbox-site.conf"
SITE_EN="/etc/nginx/sites-enabled/singbox-site.conf"
REFRESH_BIN="/usr/local/bin/singbox-panel-refresh"
CRON_FILE="/etc/cron.d/singbox-panel-refresh"

install -d "$PANEL_DIR" "$STATE_DIR" "$RUN_DIR"

# 取域名（仅用于显示，不做证书）
DOMAIN=""
if [[ -f /root/sb.env ]]; then . /root/sb.env || true; DOMAIN="${DOMAIN:-}"; fi
if [[ -z "${DOMAIN}" && -f "$SITE_AV" ]]; then
  DOMAIN=$(awk '/server_name/{for(i=2;i<=NF;i++){gsub(/;|;/,"",$i);if($i!="_")print $i}}' "$SITE_AV" 2>/dev/null | head -n1 || true)
fi
DOMAIN="${DOMAIN:-$(hostname -f 2>/dev/null || hostname)}"

# 生成状态刷新器（与之前功能一致）
cat >"$REFRESH_BIN" <<"SH"
#!/usr/bin/env bash
set -euo pipefail
IFS=$' \n\t'
PANEL_DIR="/var/www/singbox"
STATUS="${PANEL_DIR}/status.json"
STATE_DIR="/var/lib/singbox-panel"
RUN_DIR="/var/run/singbox-panel"
install -d "$STATE_DIR" "$RUN_DIR"

get_domain(){
  local envd="" ngxd="" host=""
  if [[ -f /root/sb.env ]]; then . /root/sb.env || true; envd="${DOMAIN:-}"; fi
  ngxd=$(awk '/server_name/{for(i=2;i<=NF;i++){gsub(/;|;/,"",$i);if($i!="_")print $i}}' \
          /etc/nginx/sites-enabled/*.conf /etc/nginx/sites-available/*.conf 2>/dev/null | head -n1 || true)
  host=$(hostname -f 2>/dev/null || hostname)
  echo "${envd:-${ngxd:-$host}}"
}
DOMAIN="$(get_domain)"

# 监听与服务状态
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
if [[ -s "$rate_state" ]]; then read -r old_ts old_rx old_tx < "$rate_state" || true; fi
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
[[ -s "$day_state" ]] || echo "$now_ts $rx_bytes $tx_bytes" > "$day_state"
read -r base_ts base_rx base_tx < "$day_state"
rx_today_mb=$(( (rx_bytes - base_rx) / 1024 / 1024 ))
tx_today_mb=$(( (tx_bytes - base_tx) / 1024 / 1024 ))
[[ $rx_today_mb -lt 0 ]] && rx_today_mb=0
[[ $tx_today_mb -lt 0 ]] && tx_today_mb=0

# 证书信息仅读取已存在的 443 证书（若找不到则为空）
CERT="/etc/sing-box/cert.pem"
ISSUER=""; SUBJECT=""; NOT_BEFORE=""; NOT_AFTER=""; SIGALG=""
if [[ -s "$CERT" ]]; then
  RAW=$(openssl x509 -in "$CERT" -noout -issuer -subject -dates -text 2>/dev/null || true)
  ISSUER=$(echo "$RAW" | awk -F'issuer=' '/issuer=/{print $2}' | sed 's/^ *//;s/ *$//')
  SUBJECT=$(echo "$RAW" | awk -F'subject=' '/subject=/{print $2}' | sed 's/^ *//;s/ *$//')
  NOT_BEFORE=$(echo "$RAW" | awk -F'notBefore=' '/notBefore=/{print $2}')
  NOT_AFTER=$( echo "$RAW" | awk -F'notAfter='  '/notAfter=/{print  $2}')
  SIGALG=$(echo "$RAW" | awk -F': ' '/Signature Algorithm:/{print $2; exit}')
fi

cat >"$STATUS" <<JSON
{
  "domain": "${DOMAIN}",
  "cert": {"issuer":"${ISSUER}","subject":"${SUBJECT}","sigalg":"${SIGALG}",
           "not_before":"${NOT_BEFORE}","not_after":"${NOT_AFTER}"},
  "ports": {
    "tcp_443":   "$(echo "$LISTEN" | grep -q '443=up'  && echo up || echo down)",
    "tcp_8443":  "$(echo "$LISTEN" | grep -q '8443=up' && echo up || echo down)",
    "tcp_8444":  "$(echo "$LISTEN" | grep -q '8444=up' && echo up || echo down)",
    "tcp_8448":  "$(echo "$LISTEN" | grep -q '8448=up' && echo up || echo down)",
    "udp_8447":  "${UDP8447}"
  },
  "services": { "nginx":"${NGINX_STATE}", "sing-box":"${SING_STATE}" },
  "host": {
    "name":"${HOST}","ipv4":"${IPV4}","loadavg":"${LOADAVG}","uptime":"${UPTIME}",
    "mem_total_mb":${MEM_TOTAL_MB},"mem_used_mb":${MEM_USED_MB},
    "cpu_pct":${CPU_PCT},"disk_total_gb":${DISK_TOTAL_GB},
    "disk_used_gb":${DISK_USED_GB},"disk_used_pct":${DISK_PCT},
    "rx_rate_kbps":${rx_rate_kbps},"tx_rate_kbps":${tx_rate_kbps},
    "rx_today_mb":${rx_today_mb},"tx_today_mb":${tx_today_mb}
  },
  "generated_at":"$(date -u +%FT%TZ)"
}
JSON
chmod 644 "$STATUS"
SH
chmod +x "$REFRESH_BIN"
"$REFRESH_BIN" || true

# 每分钟刷新
echo '* * * * * root /usr/local/bin/singbox-panel-refresh >/dev/null 2>&1' > "$CRON_FILE"
chmod 644 "$CRON_FILE"

# 极简页面（/panel 或直接打开 /index.html）
cat >"${PANEL_DIR}/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"/>
<title>sing-box 4in1 面板（Lite）</title>
<body style="font:14px/1.5 system-ui;margin:20px;max-width:900px">
<h2>sing-box 4in1 面板（Lite）</h2>
<p id="tip">加载中…</p>
<pre id="out" style="background:#111;color:#eee;padding:12px;border-radius:8px;overflow:auto"></pre>
<script>
(async()=>{
  try{
    const j=await fetch("/status.json?ts="+Date.now(),{cache:"no-store"}).then(r=>r.json());
    document.getElementById('tip').textContent="域名："+(j.domain||"—");
    document.getElementById('out').textContent=JSON.stringify(j,null,2);
  }catch(e){ document.getElementById('tip').textContent="载入失败："+e; }
})();
</script>
</body>
HTML
chmod 644 "${PANEL_DIR}/index.html"

# 仅在既有 443 server{} 内“补充”两个 location；不改 server_name/证书/反代
if [[ -f "$SITE_AV" ]]; then
  if ! grep -q 'location = /status.json' "$SITE_AV"; then
    # 在 443 的 server{} 里插入两个精确 location
    awk '
      BEGIN{in443=0}
      /server\s*\{/ {stack++; print; next}
      /\}/          {if(stack>0)stack--; print; next}
      {
        if($0 ~ /listen[[:space:]]+443/){in443=1}
        if(in443 && $0 ~ /ssl_certificate_key/){print; next}
        print
      }
    ' "$SITE_AV" > "${SITE_AV}.tmp"

    # 简单追加到文件末尾的 443 server{} 内（防止破坏现有反代）
    cat >> "${SITE_AV}.tmp" <<'LCT'
# === panel-lite: precise locations ===
location = /status.json { default_type application/json; alias /var/www/singbox/status.json; }
location = /panel      { index index.html; alias /var/www/singbox/; }
# === /panel-lite ===
LCT
    mv "${SITE_AV}.tmp" "$SITE_AV"
  fi
  ln -sf "$SITE_AV" "$SITE_EN"
  nginx -t && systemctl reload nginx
else
  echo "[WARN] $SITE_AV 不存在，未调整 nginx；你仍可手动把以上两个 location 放进 443 的 server{}"
fi

echo
echo "==== panel-lite 安装完成 ===="
echo "状态JSON : https://${DOMAIN}/status.json"
echo "简易面板 : https://${DOMAIN}/panel"
echo "订阅     : https://${DOMAIN}/sub.txt"
