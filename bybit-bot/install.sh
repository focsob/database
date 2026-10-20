#!/usr/bin/env bash
# Bybit Bot server — one-command install / upgrade for Ubuntu Server 24.04 (x64).
#
#   curl -fsSL https://raw.githubusercontent.com/focsob/database/main/bybit-bot/install.sh | sudo bash
#
# Installs Java and Caddy, the Bybit Bot server as a systemd service, and serves the web
# panel over HTTPS with a free Let's Encrypt certificate that Caddy renews automatically.
# Running it again upgrades the program and keeps all settings, accounts and passwords.
#
# Options (or the matching environment variables):
#   --domain NAME      BYBITBOT_DOMAIN   default s1233505.switzerlandnorth.cloudapp.azure.com
#   --port N           BYBITBOT_PORT     HTTPS port for the web panel, default 8443
#   --email ADDR       BYBITBOT_EMAIL    e-mail for Let's Encrypt expiry notices (optional)
#   --yes                                no questions, use defaults / previous answers
#   --uninstall                          remove the program (keeps /var/lib/bybitbot)
#   --purge                              with --uninstall: also delete all data
set -euo pipefail

APP=bybitbot
MANIFEST_URL="https://raw.githubusercontent.com/focsob/database/main/bybit-bot/app.json"
HOME_DIR=/opt/bybitbot
DATA_DIR=/var/lib/bybitbot
CONF_DIR=/etc/bybitbot
CONF="$CONF_DIR/install.conf"
INTERNAL_PORT=18080
DEFAULT_DOMAIN="s1233505.switzerlandnorth.cloudapp.azure.com"

say()  { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;31m !\033[0m %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

DOMAIN="${BYBITBOT_DOMAIN:-}"
PORT="${BYBITBOT_PORT:-}"
EMAIL="${BYBITBOT_EMAIL:-}"
ASSUME_YES=0
UNINSTALL=0
PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "唔識呢個選項：$1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "請用 sudo 執行：curl -fsSL ... | sudo bash"

# ---------- uninstall ----------
if [ "$UNINSTALL" -eq 1 ]; then
  say "移除 Bybit Bot"
  systemctl disable --now "$APP" 2>/dev/null || true
  rm -f /etc/systemd/system/$APP.service /usr/local/bin/$APP
  systemctl daemon-reload || true
  if [ -f /etc/caddy/Caddyfile ] && grep -q "managed by bybitbot" /etc/caddy/Caddyfile; then
    printf ':80 {\n\trespond "OK"\n}\n' > /etc/caddy/Caddyfile
    systemctl reload caddy 2>/dev/null || true
  fi
  rm -rf "$HOME_DIR"
  if [ "$PURGE" -eq 1 ]; then rm -rf "$DATA_DIR" "$CONF_DIR"; userdel "$APP" 2>/dev/null || true; ok "已刪除程式同所有資料"
  else ok "已刪除程式；帳戶設定同密碼保留喺 $DATA_DIR（加 --purge 會一齊刪除）"; fi
  exit 0
fi

# ---------- checks ----------
. /etc/os-release 2>/dev/null || true
if [ "${ID:-}" != "ubuntu" ]; then warn "呢個安裝程式係為 Ubuntu 24.04 寫嘅，你嘅系統係 ${PRETTY_NAME:-未知}，照樣繼續"; fi
case "$(uname -m)" in x86_64|amd64) ;; *) warn "呢個安裝程式係為 x64 寫嘅，你嘅 CPU 係 $(uname -m)，照樣繼續" ;; esac

# previous answers
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
  DOMAIN="${DOMAIN:-${SAVED_DOMAIN:-}}"
  PORT="${PORT:-${SAVED_PORT:-}}"
  EMAIL="${EMAIL:-${SAVED_EMAIL:-}}"
fi
DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
PORT="${PORT:-8443}"

ask() { # ask VAR "question" default
  local var="$1" q="$2" def="$3" ans=""
  if [ "$ASSUME_YES" -eq 0 ] && [ -r /dev/tty ]; then
    printf '%s [%s]: ' "$q" "$def" > /dev/tty
    IFS= read -r ans < /dev/tty || ans=""
  fi
  printf -v "$var" '%s' "${ans:-$def}"
}

echo
echo "  Bybit Bot 伺服器安裝"
echo "  ─────────────────────"
ask DOMAIN "網域名稱" "$DOMAIN"
ask PORT "網頁控制台 HTTPS 端口" "$PORT"
ask EMAIL "Let's Encrypt 通知電郵（可留空）" "${EMAIL:-}"
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "端口唔啱：$PORT"
[ "$PORT" != "80" ] || die "端口 80 要留俾 Let's Encrypt 驗證同 HTTP 轉 HTTPS 用，請揀其他端口"
[ "$PORT" != "$INTERNAL_PORT" ] || die "端口 $INTERNAL_PORT 係程式內部用，請揀其他端口"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "網域名稱唔啱：$DOMAIN"
if [ -n "$EMAIL" ] && ! [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]]; then die "電郵唔啱：$EMAIL"; fi

# something else on port 80 or the panel port?
busy_port() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q . ; }
for p in 80 "$PORT"; do
  if busy_port "$p" && ! ss -ltnpH "sport = :$p" 2>/dev/null | grep -q caddy; then
    warn "端口 $p 已經俾其他程式用緊：$(ss -ltnpH "sport = :$p" | head -1)"
    die "請先停咗佢（例如 sudo systemctl disable --now nginx apache2）再重新執行"
  fi
done

# accounts trading right now? (they restart by themselves and keep managing their positions)
if [ -f "$DATA_DIR/accounts.json" ] && grep -q '"autoStart": true' "$DATA_DIR/accounts.json" 2>/dev/null; then
  warn "有帳戶交易緊：安裝會重新啟動程式大約半分鐘，之後佢哋會自動繼續（交易所嘅止蝕止賺一直有效）"
  if [ "$ASSUME_YES" -eq 0 ] && [ -r /dev/tty ]; then
    printf '繼續？[y/N]: ' > /dev/tty
    IFS= read -r go < /dev/tty || go=""
    case "$go" in y|Y|yes|YES) ;; *) die "已取消" ;; esac
  fi
fi

# ---------- packages ----------
export DEBIAN_FRONTEND=noninteractive
say "安裝系統套件（Java 21、Caddy）"
if [ "${SKIP_APT:-0}" != "1" ]; then
  apt-get update -qq
  apt-get install -y -qq openjdk-21-jre-headless curl ca-certificates tar gnupg python3 debian-keyring debian-archive-keyring apt-transport-https >/dev/null
  # Caddy from its own repository: Ubuntu's older Caddy lacks the HTTP→HTTPS redirect on the panel port
  if [ ! -f /etc/apt/sources.list.d/caddy-stable.list ]; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
  fi
  apt-get install -y -qq caddy >/dev/null
fi
command -v java >/dev/null || die "安裝 Java 失敗"
command -v caddy >/dev/null || die "安裝 Caddy 失敗"
ok "Java $(java -version 2>&1 | head -1 | sed 's/.*version "\([^"]*\)".*/\1/')、Caddy $(caddy version | cut -d' ' -f1)"

# ---------- user and folders ----------
id "$APP" >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$APP"
install -d -m 0755 -o "$APP" -g "$APP" "$HOME_DIR" "$HOME_DIR/releases"
install -d -m 0700 -o "$APP" -g "$APP" "$DATA_DIR"
install -d -m 0755 "$CONF_DIR"

# ---------- program files ----------
SRC_DIR=/nonexistent
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [ -d "$SRC_DIR/lib" ] && [ -f "$SRC_DIR/VERSION" ]; then
  VERSION="$(tr -d '\r\n' < "$SRC_DIR/VERSION")"
  say "用本機檔案安裝版本 $VERSION"
  mkdir -p "$TMP/pkg/bybitbot-server-$VERSION"
  cp -r "$SRC_DIR/lib" "$SRC_DIR/VERSION" "$TMP/pkg/bybitbot-server-$VERSION/"
  cp "$SRC_DIR/install.sh" "$TMP/pkg/bybitbot-server-$VERSION/" 2>/dev/null || true
elif [ -n "${BYBITBOT_PACKAGE:-}" ]; then
  say "用指定檔案安裝：$BYBITBOT_PACKAGE"
  mkdir -p "$TMP/pkg"
  tar -xzf "$BYBITBOT_PACKAGE" -C "$TMP/pkg"
else
  say "下載最新版本"
  curl -fsSL "$MANIFEST_URL?t=$(date +%s)" -o "$TMP/app.json" || die "下載版本資料失敗：$MANIFEST_URL"
  read -r URL SHA VERSION < <(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
f = m["files"]["server"]
print(f["url"], f["sha256"], m["versionName"])' "$TMP/app.json") || die "版本資料格式唔啱"
  curl -fL --retry 3 -o "$TMP/server.tar.gz" "$URL" || die "下載程式失敗：$URL"
  echo "$SHA  $TMP/server.tar.gz" | sha256sum -c --quiet - || die "下載檔案校驗失敗（SHA-256 唔夾），已停止安裝"
  mkdir -p "$TMP/pkg"
  tar -xzf "$TMP/server.tar.gz" -C "$TMP/pkg"
fi
PKG="$(find "$TMP/pkg" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$PKG" ] && [ -d "$PKG/lib" ] || die "程式檔案入面冇 lib 資料夾"
VERSION="$(tr -d '\r\n' < "$PKG/VERSION" 2>/dev/null || echo "${VERSION:-unknown}")"
rm -rf "${HOME_DIR:?}/releases/$VERSION"
mv "$PKG" "$HOME_DIR/releases/$VERSION"
ln -sfn "releases/$VERSION" "$HOME_DIR/current.new"
mv -Tf "$HOME_DIR/current.new" "$HOME_DIR/current"
cp "$HOME_DIR/releases/$VERSION/install.sh" "$HOME_DIR/install.sh" 2>/dev/null || true
chmod +x "$HOME_DIR/install.sh" 2>/dev/null || true
# keep the three newest releases
find "$HOME_DIR/releases" -mindepth 1 -maxdepth 1 -type d ! -name ".*" ! -name "$VERSION" -printf '%T@ %p\n' \
  | sort -rn | tail -n +3 | cut -d' ' -f2- | while IFS= read -r old; do rm -rf "$old"; done
chown -R "$APP:$APP" "$HOME_DIR"
ok "程式版本 $VERSION 已放喺 $HOME_DIR"

# ---------- service ----------
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
HEAP=$(( MEM_MB / 2 )); [ "$HEAP" -gt 1536 ] && HEAP=1536; [ "$HEAP" -lt 256 ] && HEAP=256
cat > /etc/systemd/system/$APP.service <<EOF
[Unit]
Description=Bybit Bot server
After=network-online.target
Wants=network-online.target

[Service]
User=$APP
Group=$APP
Environment=BYBITBOT_DATA=$DATA_DIR
Environment=BYBITBOT_HOME=$HOME_DIR
Environment=BYBITBOT_HOST=127.0.0.1
Environment=BYBITBOT_PORT=$INTERNAL_PORT
ExecStart=/usr/bin/java -Xms64m -Xmx${HEAP}m -XX:+UseSerialGC -XX:+ExitOnOutOfMemoryError -Dfile.encoding=UTF-8 -Duser.timezone=Asia/Hong_Kong -cp "$HOME_DIR/current/lib/*" bot.server.MainKt
Restart=always
RestartSec=5
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$DATA_DIR $HOME_DIR
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
LockPersonality=yes
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF

# helper command
cat > /usr/local/bin/$APP <<EOF
#!/usr/bin/env bash
# Bybit Bot helper: status | logs | restart | stop | start | reset-password | update | uninstall
set -e
case "\${1:-status}" in
  status) systemctl status $APP --no-pager ;;
  logs) journalctl -u $APP -f ;;
  restart|stop|start) sudo systemctl "\$1" $APP ;;
  reset-password)
    sudo systemctl stop $APP
    sudo -u $APP env BYBITBOT_DATA=$DATA_DIR /usr/bin/java -cp "$HOME_DIR/current/lib/*" bot.server.MainKt reset-password
    sudo systemctl start $APP ;;
  update) curl -fsSL https://raw.githubusercontent.com/focsob/database/main/bybit-bot/install.sh | sudo bash -s -- --yes ;;
  uninstall) sudo bash $HOME_DIR/install.sh --uninstall ;;
  *) echo "用法：$APP status|logs|restart|stop|start|reset-password|update|uninstall" ;;
esac
EOF
chmod 0755 /usr/local/bin/$APP

# ---------- Caddy: HTTPS with Let's Encrypt, HTTP → HTTPS ----------
EMAIL_LINE=""
[ -n "$EMAIL" ] && EMAIL_LINE="			email $EMAIL"
if [ -f /etc/caddy/Caddyfile ] && ! grep -q "managed by bybitbot" /etc/caddy/Caddyfile; then
  cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-bybitbot.$(date +%Y%m%d%H%M%S)"
fi
cat > /etc/caddy/Caddyfile <<EOF
# managed by bybitbot install.sh — re-run the installer to change it
{
	http_port 80
	https_port $PORT
	servers :$PORT {
		listener_wrappers {
			http_redirect
			tls
		}
	}
}

$DOMAIN:$PORT {
	tls {
		issuer acme {
			dir https://acme-v02.api.letsencrypt.org/directory
$EMAIL_LINE
			disable_tlsalpn_challenge
		}
	}
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000"
		-Server
	}
	reverse_proxy 127.0.0.1:$INTERNAL_PORT
}

http://$DOMAIN {
	redir https://$DOMAIN:$PORT{uri} permanent
}
EOF
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || { caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; die "Caddy 設定有錯"; }

# firewall
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null && ufw allow "$PORT"/tcp >/dev/null && ok "已喺 ufw 開放 80 同 $PORT"
fi

cat > "$CONF" <<EOF
SAVED_DOMAIN=$DOMAIN
SAVED_PORT=$PORT
SAVED_EMAIL=$EMAIL
EOF

say "啟動服務"
systemctl daemon-reload
systemctl enable "$APP" >/dev/null 2>&1
systemctl restart "$APP"
systemctl enable caddy >/dev/null 2>&1
systemctl restart caddy

for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:$INTERNAL_PORT/api/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$INTERNAL_PORT/api/health" >/dev/null 2>&1 && ok "Bybit Bot 已運行" || warn "Bybit Bot 未有回應，請睇：journalctl -u $APP -e"

CERT_TRIES=${BYBITBOT_CERT_TRIES:-30}
say "申請 Let's Encrypt 證書（最多等 $((CERT_TRIES * 3)) 秒）"
CERT_OK=0
for _ in $(seq 1 "$CERT_TRIES"); do
  if curl -fsS --max-time 5 "https://$DOMAIN:$PORT/api/health" >/dev/null 2>&1; then CERT_OK=1; break; fi
  sleep 3
done
if [ "$CERT_OK" -eq 1 ]; then
  ok "HTTPS 證書正常，Caddy 會喺到期前自動續期"
else
  warn "暫時未能用 HTTPS 連線。請檢查："
  warn "  1. Azure 網絡安全組（NSG）有冇開放入站 TCP 80 同 $PORT"
  warn "  2. 網域 $DOMAIN 有冇指向呢部伺服器嘅公共 IP"
  warn "  證書狀態：journalctl -u caddy -e"
fi

echo
echo "  ─────────────────────────────────────────────"
echo "  網頁控制台：https://$DOMAIN:$PORT"
echo "  預設帳戶：Bosco   預設密碼：Bosco（第一次登入要即刻改密碼）"
echo "  HTTP 會自動轉去 HTTPS；證書由 Caddy 自動續期"
echo "  常用指令：$APP status | $APP logs | $APP restart | $APP reset-password | $APP update"
echo "  ─────────────────────────────────────────────"
echo "  記得喺 Azure 網絡安全組開放入站 TCP 80（證書驗證）同 $PORT（控制台）。"
echo
