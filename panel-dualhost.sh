#!/usr/bin/env bash
# 修复 sing-box 双域名 + 面板访问异常 (404 / 521) 的专用脚本
# 作者：Hans 调试定制版

set -euo pipefail
IFS=$'\n\t'

echo "[STEP] 检查环境..."
apt update -y >/dev/null 2>&1 || true
apt install -y nginx curl jq >/dev/null 2>&1 || true

PANEL_DIR="/var/www/singbox"
CERT="/etc/sing-box/cert.pem"
KEY="/etc/sing-box/key.pem"
SITE_AV="/etc/nginx/sites-available/singbox-site.conf"
SITE_EN="/etc/nginx/sites-enabled/singbox-site.conf"

mkdir -p "$PANEL_DIR"

echo "[STEP] 检测 WS_PATH..."
if [[ -f /root/sb.env ]]; then
  . /root/sb.env || true
fi
WS_PATH="${WS_PATH:-}"
if [[ -z "$WS_PATH" ]]; then
  echo "[WARN] 未在 /root/sb.env 找到 WS_PATH，使用默认路径 /ws"
  WS_PATH="ws"
fi

echo "[STEP] 生成 Nginx 配置..."
cat >"$SITE_AV" <<EOF
server {
  listen 80;
  server_name cdnvpn.100998.xyz bbvpn.100998.xyz;
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name cdnvpn.100998.xyz bbvpn.100998.xyz;

  ssl_certificate     $CERT;
  ssl_certificate_key $KEY;

  # === 面板部分 ===
  root $PANEL_DIR;
  index index.html;

  # 面板访问路径（panel 页面）
  location /panel/ {
    alias $PANEL_DIR/;
    index index.html;
  }

  # 订阅与状态接口
  location = /sub.txt {
    default_type text/plain;
    try_files /sub.txt =404;
  }

  location = /status.json {
    default_type application/json;
    try_files /status.json =404;
  }

  # WebSocket 反代 (VMess-WS)
  location /$WS_PATH {
    proxy_pass http://127.0.0.1:12080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_read_timeout 86400;
  }

  # 其它路径禁止访问
  location / {
    return 404;
  }
}
EOF

ln -sf "$SITE_AV" "$SITE_EN"
unlink /etc/nginx/sites-enabled/default 2>/dev/null || true

echo "[STEP] 校验 Nginx 配置..."
nginx -t
systemctl reload nginx
systemctl enable nginx --now

echo "[STEP] 生成面板状态脚本..."
REFRESH_BIN="/usr/local/bin/singbox-panel-refresh"
cat >"$REFRESH_BIN" <<"SH"
#!/usr/bin/env bash
set -euo pipefail
PANEL_DIR="/var/www/singbox"
STATUS="${PANEL_DIR}/status.json"
mkdir -p "$PANEL_DIR"

is_active(){ systemctl is-active --quiet "$1" && echo "active" || echo "inactive"; }

cat >"$STATUS" <<JSON
{
  "domain": "$(hostname -f)",
  "services": {
    "nginx": "$(is_active nginx)",
    "singbox": "$(is_active sing-box)"
  },
  "ports": $(ss -tulpen | awk '{print $5}' | grep -Eo '[0-9]+$' | sort -u | jq -R . | jq -s .),
  "time": "$(date -u +%FT%TZ)"
}
JSON
SH
chmod +x "$REFRESH_BIN"

echo "[STEP] 设置定时任务..."
echo '* * * * * root /usr/local/bin/singbox-panel-refresh >/dev/null 2>&1' >/etc/cron.d/singbox-panel-refresh
chmod 644 /etc/cron.d/singbox-panel-refresh

# 生成初始数据
"$REFRESH_BIN" || true

echo
echo "✅ 修复完成！面板已启用"
echo "------------------------------------------"
echo "📊 状态面板:  https://bbvpn.100998.xyz/panel/"
echo "🧩 状态JSON:  https://bbvpn.100998.xyz/status.json"
echo "🔗 订阅链接:  https://bbvpn.100998.xyz/sub.txt"
echo "------------------------------------------"
echo "⚙️ 若仍 404，可执行："
echo "nginx -t && systemctl reload nginx"
