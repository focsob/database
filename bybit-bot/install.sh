#!/usr/bin/env bash
# Bybit Bot server — one-command install / upgrade for Ubuntu Server 26.04 (x64).
#
#   curl -fsSL https://raw.githubusercontent.com/focsob/database/main/bybit-bot/install.sh | sudo bash
#
# Installs Java and Caddy, the Bybit Bot server as a systemd service, and serves the web
# panel over HTTPS with a free Let's Encrypt certificate that Caddy renews automatically.
# Running it again upgrades the program and keeps all settings, accounts and passwords.
#
# Options (or the matching environment variables):
#   --domain NAME      BYBITBOT_DOMAIN   default s1233505.francecentral.cloudapp.azure.com
#   --port N           BYBITBOT_PORT     HTTPS port for the web panel, default 8443
#   --email ADDR       BYBITBOT_EMAIL    e-mail for Let's Encrypt expiry notices (optional)
#   --yes                                no questions, use defaults / previous answers
#   --mt5                                also install MetaTrader 5 (Wine + virtual screen) for
#                                        Bybit TradFi CFD trading; later runs keep it up to date
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
DEFAULT_DOMAIN="s1233505.francecentral.cloudapp.azure.com"

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
WANT_MT5=0
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --mt5) WANT_MT5=1; shift ;;
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
  systemctl disable --now "$APP-mt5" 2>/dev/null || true
  systemctl disable --now "$APP" 2>/dev/null || true
  rm -f /etc/systemd/system/$APP.service /etc/systemd/system/$APP-mt5.service /usr/local/bin/$APP
  systemctl daemon-reload || true
  if [ -f /etc/caddy/Caddyfile ] && grep -q "managed by bybitbot" /etc/caddy/Caddyfile; then
    printf ':80 {\n\trespond "OK"\n}\n' > /etc/caddy/Caddyfile
    systemctl reload caddy 2>/dev/null || true
  fi
  rm -rf "$HOME_DIR"
  if [ "$PURGE" -eq 1 ]; then rm -rf "$DATA_DIR" "$CONF_DIR"; userdel "$APP" 2>/dev/null || true; ok "已刪除程式同所有資料"
  else ok "已刪除程式；帳戶設定、密碼同 MT5 保留喺 $DATA_DIR（加 --purge 會一齊刪除）"; fi
  exit 0
fi

# ---------- checks ----------
. /etc/os-release 2>/dev/null || true
if [ "${ID:-}" != "ubuntu" ]; then warn "呢個安裝程式係為 Ubuntu 26.04 寫嘅，你嘅系統係 ${PRETTY_NAME:-未知}，照樣繼續"
else case "${VERSION_ID:-}" in 26.04) ;; *) warn "呢個安裝程式只喺 Ubuntu 26.04 測試過，你嘅係 ${PRETTY_NAME:-未知}，照樣繼續" ;; esac; fi
case "$(uname -m)" in x86_64|amd64) ;; *) warn "呢個安裝程式係為 x64 寫嘅，你嘅 CPU 係 $(uname -m)，照樣繼續" ;; esac

# previous answers
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
  # the old default domain moved to France Central: follow it; a domain you chose yourself stays
  [ "${SAVED_DOMAIN:-}" = "s1233505.switzerlandnorth.cloudapp.azure.com" ] && SAVED_DOMAIN="$DEFAULT_DOMAIN"
  DOMAIN="${DOMAIN:-${SAVED_DOMAIN:-}}"
  PORT="${PORT:-${SAVED_PORT:-}}"
  EMAIL="${EMAIL:-${SAVED_EMAIL:-}}"
  [ "${SAVED_MT5:-0}" = "1" ] && HAVE_MT5=1
fi
HAVE_MT5="${HAVE_MT5:-0}"
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
say "安裝系統套件（Java、Caddy、chrony 時間同步）"
if [ "${SKIP_APT:-0}" != "1" ]; then
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates tar gnupg python3 >/dev/null
  # Java 21 when the release has it, otherwise Ubuntu 26.04's default Java 25 (runs the program the same way)
  if ! command -v java >/dev/null; then
    apt-get install -y -qq openjdk-21-jre-headless >/dev/null 2>&1 \
      || apt-get install -y -qq openjdk-25-jre-headless >/dev/null 2>&1 \
      || apt-get install -y -qq default-jre-headless >/dev/null 2>&1 || true
  fi
  # only needed by older releases for the Caddy repository; missing on newer Ubuntu is fine
  for p in debian-keyring debian-archive-keyring apt-transport-https; do apt-get install -y -qq "$p" >/dev/null 2>&1 || true; done
  # Caddy from its own repository: Ubuntu's older Caddy lacks the HTTP→HTTPS redirect on the panel port
  if [ ! -f /etc/apt/sources.list.d/caddy-stable.list ]; then
    curl -1sLf --retry 3 --max-time 60 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf --retry 3 --max-time 60 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
  fi
  apt-get install -y -qq caddy >/dev/null
  # accurate clock: Bybit rejects signed requests that are off by more than a few seconds
  if apt-get install -y -qq chrony >/dev/null 2>&1; then
    systemctl enable --now chrony >/dev/null 2>&1 || true
  else
    warn "安裝 chrony 失敗，會用系統預設嘅時間同步"
  fi
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
  curl -fsSL --retry 3 --max-time 60 "$MANIFEST_URL?t=$(date +%s)" -o "$TMP/app.json" || die "下載版本資料失敗：$MANIFEST_URL"
  read -r URL SHA VERSION < <(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
f = m["files"]["server"]
print(f["url"], f["sha256"], m["versionName"])' "$TMP/app.json") || die "版本資料格式唔啱"
  curl -fL --retry 3 --max-time 900 -o "$TMP/server.tar.gz" "$URL" || die "下載程式失敗：$URL"
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
# Bybit Bot helper: status | logs | restart | stop | start | reset-password | update | uninstall | mt5-setup | mt5-logs | mt5-restart
set -e
case "\${1:-status}" in
  status) systemctl status $APP --no-pager; systemctl status $APP-mt5 --no-pager 2>/dev/null || true ;;
  logs) journalctl -u $APP -f ;;
  restart|stop|start) sudo systemctl "\$1" $APP ;;
  mt5-setup) curl -fsSL https://raw.githubusercontent.com/focsob/database/main/bybit-bot/install.sh | sudo bash -s -- --yes --mt5 ;;
  mt5-logs) journalctl -u $APP-mt5 -f ;;
  mt5-restart) sudo systemctl restart $APP-mt5 ;;
  reset-password)
    sudo systemctl stop $APP
    sudo -u $APP env BYBITBOT_DATA=$DATA_DIR /usr/bin/java -cp "$HOME_DIR/current/lib/*" bot.server.MainKt reset-password
    sudo systemctl start $APP ;;
  update) curl -fsSL https://raw.githubusercontent.com/focsob/database/main/bybit-bot/install.sh | sudo bash -s -- --yes ;;
  uninstall) sudo bash $HOME_DIR/install.sh --uninstall ;;
  *) echo "用法：$APP status|logs|restart|stop|start|reset-password|update|uninstall|mt5-setup|mt5-logs|mt5-restart" ;;
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

write_conf() {
  cat > "$CONF" <<EOF
SAVED_DOMAIN=$DOMAIN
SAVED_PORT=$PORT
SAVED_EMAIL=$EMAIL
SAVED_MT5=$HAVE_MT5
EOF
}
write_conf

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

# ---------- MetaTrader 5 (Bybit TradFi) ----------
MT5_DIR="$DATA_DIR/mt5"
MT5_PREFIX="$MT5_DIR/wine"
MT5_TERM="$MT5_PREFIX/drive_c/Program Files/MetaTrader 5"
# MetaQuotes' current installer (the one on metatrader5.com; under Wine it installs in seconds), and
# the older mql5.com one when that site fails
MT5_SETUP_URL="${BYBITBOT_MT5_SETUP_URL:-https://download.terminal.free/cdn/web/metaquotes.ltd/mt5/mt5setup.exe}"
MT5_SETUP_URL2="https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"
# Edge WebView2 runtime: MetaQuotes' own Linux script installs it before MT5
WEBVIEW2_URL="${BYBITBOT_WEBVIEW2_URL:-https://go.microsoft.com/fwlink/p/?LinkId=2124703}"
MT5_SETUP_WAIT="${BYBITBOT_MT5_SETUP_WAIT:-1200}"
WEBVIEW2_WAIT="${BYBITBOT_WEBVIEW2_WAIT:-900}"
MT5_MSG=""
MT5_DISPLAY=""

# Wine as the service user, on the installer's own virtual screen; .NET (Mono) is not needed
as_app() { runuser -u "$APP" -- env HOME="$MT5_DIR/home" WINEPREFIX="$MT5_PREFIX" WINEARCH=win64 WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=" DISPLAY="$MT5_DISPLAY" "$@"; }

# a virtual screen for the whole MT5 install (Wine keeps helper processes on it between steps)
mt5_display_start() {
  local n
  for n in $(seq 90 119); do
    if [ -e "/tmp/.X11-unix/X$n" ] || [ -e "/tmp/.X$n-lock" ]; then continue; fi
    # -noreset: Wine's helper processes come and go; a reset in between drops the next client
    runuser -u "$APP" -- Xvfb ":$n" -screen 0 1280x1024x24 -nolisten tcp -noreset >>"$MT5_DIR/xvfb.log" 2>&1 &
    for _ in $(seq 1 50); do
      if [ -e "/tmp/.X11-unix/X$n" ]; then MT5_DISPLAY=":$n"; return 0; fi
      sleep 0.1
    done
    pkill -u "$APP" -f "^Xvfb :$n " 2>/dev/null || true
  done
  return 1
}
mt5_display_stop() {
  if [ -n "$MT5_DISPLAY" ]; then pkill -u "$APP" -f "^Xvfb $MT5_DISPLAY " 2>/dev/null || true; fi
  MT5_DISPLAY=""
}
# picture of the virtual screen, to see a stuck installer window
mt5_screen() {
  if [ -n "$MT5_DISPLAY" ] && command -v xwd >/dev/null; then
    xwd -root -silent -display "$MT5_DISPLAY" > "$MT5_DIR/install-screen-${1:-setup}.xwd" 2>/dev/null || true
  fi
}

# Wine Gecko (Internet Explorer engine) for this Wine version, put where Wine installs it from
# without asking; the version comes from Wine's own appwiz.cpl
mt5_gecko() {
  local dir ver arch f
  dir="$(dirname "$(dirname "$(readlink -f "$1")")")"
  ver="$(grep -aoE 'wine-gecko-[0-9]+\.[0-9]+(\.[0-9]+)?-' "$dir"/lib/wine/x86_64-windows/appwiz.cpl "$dir"/lib*/wine/*/appwiz.cpl "$dir"/lib/*/wine/*/appwiz.cpl 2>/dev/null | head -1 | sed -E 's/.*wine-gecko-([0-9.]+)-.*/\1/')" || true
  [ -n "$ver" ] || ver="${BYBITBOT_GECKO_VERSION:-2.47.4}"
  install -d -m 0700 -o "$APP" -g "$APP" "$MT5_DIR/home/.cache" "$MT5_DIR/home/.cache/wine"
  for arch in x86 x86_64; do
    f="$MT5_DIR/home/.cache/wine/wine-gecko-$ver-$arch.msi"
    if [ ! -s "$f" ]; then
      curl -fsSL --retry 3 -o "$f" "https://dl.winehq.org/wine/wine-gecko/$ver/wine-gecko-$ver-$arch.msi" || { rm -f "$f"; warn "下載 Wine Gecko $ver 失敗"; }
    fi
  done
  chown -R "$APP:$APP" "$MT5_DIR/home/.cache"
  echo "$ver"
}
find_wine() {
  local c
  for c in "$(command -v wine 2>/dev/null)" "$(command -v wine64 2>/dev/null)" /opt/wine-devel/bin/wine /opt/wine-stable/bin/wine /opt/wine-staging/bin/wine; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}
find_wineserver() {
  local w c
  w="$(find_wine)" || return 1
  for c in "$(dirname "$w")/wineserver" "$(command -v wineserver 2>/dev/null)" /usr/lib/wine/wineserver /usr/lib/wine/wineserver64 /usr/lib/x86_64-linux-gnu/wine/wineserver; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}
kill_wine() {
  local srv
  srv="$(find_wineserver)" || return 0
  as_app "$srv" -k >/dev/null 2>&1 || true
}

# the runner script ships inside the program (the server also keeps it up to date)
mt5_runner_from_jar() {
  python3 -I - "$HOME_DIR/current/lib" "$MT5_DIR/mt5_runner.py" <<'PY' || true
import glob, os, sys, zipfile
for jar in sorted(glob.glob(os.path.join(sys.argv[1], "*.jar"))):
    try:
        with zipfile.ZipFile(jar) as z:
            data = z.read("mt5/mt5_runner.py")
    except (KeyError, zipfile.BadZipFile, OSError):
        continue
    tmp = sys.argv[2] + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, sys.argv[2])
    break
PY
  if [ -f "$MT5_DIR/mt5_runner.py" ]; then chown "$APP:$APP" "$MT5_DIR/mt5_runner.py"; fi
}

mt5_unit() {
  cat > /etc/systemd/system/$APP-mt5.service <<UNIT
[Unit]
Description=Bybit Bot MetaTrader 5 terminal (Wine, virtual screen)
After=network-online.target $APP.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=$APP
Group=$APP
Environment=HOME=$MT5_DIR/home
ExecStart=/usr/bin/python3 -I $MT5_DIR/mt5_runner.py
Restart=always
RestartSec=10
TimeoutStopSec=60
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$MT5_DIR
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
UNIT
}

# Wine for MT5: WineHQ's development build 11.20 (checked on Ubuntu 26.04: the MT5 installer, the
# terminal and MetaEditor all run). Ubuntu's own Wine 10 hangs in MetaEditor and does not start the
# terminal. The version is held so a system update does not change it; BYBITBOT_WINE_VERSION picks
# another one. Ubuntu's Wine or WineHQ's stable Wine from an earlier install is replaced.
APT_LOG=/var/log/bybitbot-mt5-apt.log
WINE_VERSION="${BYBITBOT_WINE_VERSION:-11.20}"
mt5_apt() { timeout 1800 apt-get "$@" >>"$APT_LOG" 2>&1; }
install_wine() {
  [ "${SKIP_APT:-0}" = "1" ] && return 0
  say "安裝 Wine $WINE_VERSION（WineHQ 開發版）、虛擬顯示（Xvfb）同截圖工具（記錄喺 $APT_LOG）"
  : >"$APT_LOG"
  dpkg --add-architecture i386
  local code="${VERSION_CODENAME:-resolute}" w ver v p old="" avahi=0
  install -d -m 0755 /etc/apt/keyrings
  # the key dearmored: APT on 26.04 does not read an ASCII-armored key from a .key file
  curl -fsSL --retry 3 --max-time 60 https://dl.winehq.org/wine-builds/winehq.key | gpg --dearmor --yes -o /etc/apt/keyrings/winehq-archive.key \
    && curl -fsSL --retry 3 --max-time 60 "https://dl.winehq.org/wine-builds/ubuntu/dists/$code/winehq-$code.sources" -o "/etc/apt/sources.list.d/winehq-$code.sources" \
    || die "下載唔到 WineHQ 套件來源（dl.winehq.org）"
  sed -i 's#^Signed-By:.*#Signed-By: /etc/apt/keyrings/winehq-archive.key#' "/etc/apt/sources.list.d/winehq-$code.sources"
  # other Wine builds share the wine command: take them out first
  for p in winehq-stable wine-stable wine-stable-amd64 wine-stable-i386:i386 wine wine64 wine32:i386 libwine libwine:i386; do
    dpkg -s "$p" >/dev/null 2>&1 && old="$old $p"
  done
  if [ -n "$old" ]; then
    # shellcheck disable=SC2086
    apt-mark unhold $old >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    mt5_apt remove -y $old || true
  fi
  systemctl list-unit-files avahi-daemon.service >/dev/null 2>&1 && dpkg -s avahi-daemon >/dev/null 2>&1 && avahi=1
  mt5_apt update || true
  # awk reads to the end: stopping early would end apt-cache with SIGPIPE (and the script with it)
  v="$(apt-cache madison winehq-devel 2>/dev/null | awk -v want="$WINE_VERSION~" 'index($3, want) == 1 && v == "" {v = $3} END {print v}')" || v=""
  apt-mark unhold winehq-devel wine-devel >/dev/null 2>&1 || true
  if [ -n "$v" ]; then
    mt5_apt install -y --install-recommends --allow-downgrades "winehq-devel=$v" "wine-devel=$v" || die "安裝 Wine $v 失敗（睇 $APT_LOG）"
  else
    warn "WineHQ 冇 Wine $WINE_VERSION，裝最新開發版"
    mt5_apt install -y --install-recommends winehq-devel || die "安裝 Wine 失敗（睇 $APT_LOG）"
  fi
  apt-mark hold winehq-devel wine-devel >/dev/null 2>&1 || true
  # a recommended package; a trading server has no use for local network discovery
  if [ "$avahi" = "0" ] && dpkg -s avahi-daemon >/dev/null 2>&1; then
    systemctl disable --now avahi-daemon.socket avahi-daemon.service >/dev/null 2>&1 || true
  fi
  mt5_apt install -y xvfb xauth x11-apps x11-utils x11-xkb-utils xkb-data python3 || die "安裝 Xvfb 失敗（睇 $APT_LOG）"
  w="$(find_wine)" || die "搵唔到 Wine（睇 $APT_LOG）"
  ver="$("$w" --version 2>/dev/null)"
  ok "Wine：$ver"
}

install_mt5() {
  say "安裝 MetaTrader 5（Bybit TradFi 用）"
  local mem wine found="" pid gecko
  mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  if [ "$mem" -lt 1800 ]; then warn "伺服器得 ${mem} MB 記憶體：MT5 加 Wine 大約要多 500 MB，可能會唔夠"; fi
  install_wine
  wine="$(find_wine)" || die "搵唔到 Wine"
  command -v Xvfb >/dev/null || die "搵唔到 Xvfb"
  install -d -m 0700 -o "$APP" -g "$APP" "$MT5_DIR" "$MT5_DIR/home"
  systemctl stop "$APP-mt5" 2>/dev/null || true
  kill_wine
  rm -f "$MT5_DIR"/install-screen-*.xwd
  mt5_display_start || die "開唔到虛擬顯示（Xvfb）"
  if [ ! -f "$MT5_PREFIX/system.reg" ]; then
    say "建立 Wine 環境（第一次需時一兩分鐘）"
    gecko="$(mt5_gecko "$wine")"
    echo "Wine $("$wine" --version 2>/dev/null), Gecko $gecko" >>"$MT5_DIR/install-wine.log"
    as_app timeout 600 "$wine" wineboot --init >>"$MT5_DIR/install-wine.log" 2>&1 || true
    as_app timeout 120 "$(find_wineserver)" -w >/dev/null 2>&1 || true
    if [ ! -f "$MT5_PREFIX/system.reg" ]; then
      # once more on a new virtual screen, then without one (the Wine folder needs no screen)
      mt5_screen wineboot
      warn "第一次建立 Wine 環境唔成功，再試"
      kill_wine; mt5_display_stop; mt5_display_start || true
      as_app timeout 600 "$wine" wineboot --init >>"$MT5_DIR/install-wine.log" 2>&1 || true
      as_app timeout 120 "$(find_wineserver)" -w >/dev/null 2>&1 || true
    fi
    if [ ! -f "$MT5_PREFIX/system.reg" ]; then
      kill_wine
      runuser -u "$APP" -- env HOME="$MT5_DIR/home" WINEPREFIX="$MT5_PREFIX" WINEARCH=win64 WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=" \
        timeout 600 "$wine" wineboot --init >>"$MT5_DIR/install-wine.log" 2>&1 || true
      as_app timeout 120 "$(find_wineserver)" -w >/dev/null 2>&1 || true
    fi
    [ -f "$MT5_PREFIX/system.reg" ] || { mt5_screen wineboot2; mt5_display_stop; die "建立 Wine 環境失敗（Wine 輸出：$MT5_DIR/install-wine.log）"; }
  fi
  as_app "$wine" reg add 'HKCU\Software\Wine' /v Version /t REG_SZ /d win10 /f >>"$MT5_DIR/install-wine.log" 2>&1 || true
  if [ ! -f "$MT5_DIR/webview2.done" ]; then
    say "安裝 Microsoft Edge WebView2（MT5 介面用）"
    if curl -fsSL --retry 3 -o "$MT5_DIR/webview2.exe" "$WEBVIEW2_URL"; then
      chown "$APP:$APP" "$MT5_DIR/webview2.exe"
      if as_app timeout "$WEBVIEW2_WAIT" "$wine" "$MT5_DIR/webview2.exe" /silent /install >>"$MT5_DIR/install-wine.log" 2>&1; then
        touch "$MT5_DIR/webview2.done"
      else
        mt5_screen webview2
        kill_wine
        warn "WebView2 安裝唔到（MT5 交易唔需要，照樣繼續）"
      fi
      rm -f "$MT5_DIR/webview2.exe"
    else
      warn "下載 WebView2 失敗（MT5 交易唔需要，照樣繼續）"
    fi
  fi
  if [ ! -f "$MT5_TERM/terminal64.exe" ]; then
    say "下載同安裝 MT5 終端機（大約 5 分鐘）"
    if ! curl -fsSL --retry 3 --max-time 600 -o "$MT5_DIR/mt5setup.exe" "$MT5_SETUP_URL" 2>"$MT5_DIR/download.err" \
       && ! curl -fsSL --retry 3 --max-time 600 -o "$MT5_DIR/mt5setup.exe" "$MT5_SETUP_URL2" 2>>"$MT5_DIR/download.err"; then
      mt5_display_stop
      if grep -qi "certificate" "$MT5_DIR/download.err"; then
        die "下載 MT5 安裝程式失敗：MetaQuotes 下載網站嘅證書有問題（$(grep -i certificate "$MT5_DIR/download.err" | head -1)）。通常係對方暫時出錯，遲啲再執行：sudo $APP mt5-setup"
      fi
      die "下載 MT5 安裝程式失敗：$(tail -1 "$MT5_DIR/download.err")"
    fi
    chown "$APP:$APP" "$MT5_DIR/mt5setup.exe"
    echo "== mt5setup.exe /auto $(date -u +%FT%TZ)" >>"$MT5_DIR/install-wine.log"
    # no Wine debug output here: MetaQuotes' protection can take Wine's tracing for a debugger
    as_app timeout "$MT5_SETUP_WAIT" "$wine" "$MT5_DIR/mt5setup.exe" /auto >>"$MT5_DIR/install-wine.log" 2>&1 &
    pid=$!
    local waited=0 shots=0
    for _ in $(seq 1 "$MT5_SETUP_WAIT"); do
      found="$(find "$MT5_PREFIX/drive_c" -maxdepth 4 -name terminal64.exe -path '*MetaTrader*' 2>/dev/null | head -1)" || true
      if [ -n "$found" ] && [ -f "$(dirname "$found")/MetaEditor64.exe" ]; then break; fi
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
      waited=$((waited + 1))
      # a picture of the screen now and then, to see a window waiting for an answer
      if [ $((waited % 90)) -eq 0 ] && [ "$shots" -lt 8 ]; then shots=$((shots + 1)); mt5_screen "setup-$shots"; fi
    done
    echo "== mt5setup.exe after ${waited}s: $(if kill -0 "$pid" 2>/dev/null; then echo running; else echo ended; fi), terminal: ${found:-none}" >>"$MT5_DIR/install-wine.log"
    # let the installer finish writing, then stop it (it opens the terminal at the end)
    if [ -n "$found" ]; then sleep 30; fi
    mt5_screen setup
    kill_wine
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    found="$(find "$MT5_PREFIX/drive_c" -maxdepth 4 -name terminal64.exe -path '*MetaTrader*' 2>/dev/null | head -1)" || true
    if [ -z "$found" ]; then
      mt5_display_stop
      die "MT5 安裝失敗（搵唔到 terminal64.exe；Wine 輸出：$MT5_DIR/install-wine.log）。可以再執行一次：sudo $APP mt5-setup"
    fi
    if [ "$(dirname "$found")" != "$MT5_TERM" ] && [ ! -e "$MT5_TERM" ]; then
      runuser -u "$APP" -- ln -s "$(dirname "$found")" "$MT5_TERM"
    fi
    rm -f "$MT5_DIR/mt5setup.exe"
  fi
  kill_wine
  mt5_display_stop
  [ -f "$MT5_TERM/terminal64.exe" ] || die "MT5 安裝失敗"
  # a fresh install looks for the chart symbol again
  rm -f "$MT5_DIR/chart_symbol" "$MT5_DIR/chart_try"
  printf '{"installedAt": %s, "wine": "%s", "installer": "%s"}\n' "$(date +%s)" "$wine" "$VERSION" > "$MT5_DIR/setup.json"
  chown -R "$APP:$APP" "$MT5_DIR"
  HAVE_MT5=1
  ok "MT5 已安裝喺 $MT5_TERM"
}

if [ "$WANT_MT5" -eq 1 ]; then
  install_mt5
  write_conf
elif [ "$HAVE_MT5" -eq 1 ] && [ -f "$MT5_DIR/setup.json" ]; then
  # an update moves an existing MT5 to the Wine this version runs it on
  cur_wine="$(w="$(find_wine)" && "$w" --version 2>/dev/null)" || cur_wine=""
  if [ "$cur_wine" != "wine-$WINE_VERSION" ]; then
    systemctl stop "$APP-mt5" 2>/dev/null || true
    kill_wine
    ( install_wine ) || warn "換 Wine 唔成功（睇 $APT_LOG），MT5 照用原本嘅 Wine"
  fi
fi
if [ "$HAVE_MT5" -eq 1 ] && [ -f "$MT5_DIR/setup.json" ]; then
  mt5_runner_from_jar
  mt5_unit
  systemctl daemon-reload
  systemctl enable "$APP-mt5" >/dev/null 2>&1
  if [ "$WANT_MT5" -eq 1 ]; then systemctl restart "$APP-mt5"; else systemctl start "$APP-mt5" 2>/dev/null || true; fi
  if systemctl is-active --quiet "$APP-mt5"; then ok "MT5 服務運行中（喺網頁「系統」頁睇狀態）"; else warn "MT5 服務未啟動：journalctl -u $APP-mt5 -e"; fi
  MT5_MSG="  MT5：網頁「系統」頁睇狀態；帳戶設定「交易平台」揀 MT5，再填 MT5 帳戶號碼、交易密碼同伺服器名"
fi

echo
echo "  ─────────────────────────────────────────────"
echo "  網頁控制台：https://$DOMAIN:$PORT"
echo "  預設帳戶：Bosco   預設密碼：Bosco（第一次登入要即刻改密碼）"
echo "  HTTP 會自動轉去 HTTPS；證書由 Caddy 自動續期"
echo "  常用指令：$APP status | $APP logs | $APP restart | $APP reset-password | $APP update"
if [ -n "$MT5_MSG" ]; then
  echo "$MT5_MSG"
  echo "  MT5 指令：$APP mt5-logs | $APP mt5-restart | $APP mt5-setup（重裝）"
fi
echo "  ─────────────────────────────────────────────"
echo "  記得喺 Azure 網絡安全組開放入站 TCP 80（證書驗證）同 $PORT（控制台）。"
echo
