#!/usr/bin/env bash
# =====================================================================
# 案件管理系統　一鍵安裝程式
# 用法：curl -fsSL <安裝檔網址> | sudo bash -s -- <安裝金鑰>
# 適用：Ubuntu／Debian（使用 systemd）全新或已有其他網站的伺服器
# - 伺服器已安裝 Caddy 或 nginx：會加入本系統的網站設定，不會改動其他網站
# - 所有程式均經加密下載，並以安裝金鑰核對及解密
# - 重新執行亦安全：現有資料庫及相片會保留
# Copyright by 27456
# =====================================================================
set -euo pipefail
umask 022

URL_BASE="https://raw.githubusercontent.com/focsob/database/main/case-web"
KEY="${1:-}"
TTY=/dev/tty

say(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
note(){ printf '%s\n' "$*"; }
warn(){ printf '\033[1;33m[注意] %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m[錯誤] %s\033[0m\n' "$*"; exit 1; }
ask(){ local v; read -r -p "$1" v < "$TTY" || true; printf '%s' "$v"; }
ask_secret(){ local v; read -r -s -p "$1" v < "$TTY" || true; echo > "$TTY"; printf '%s' "$v"; }
yesno(){  # $1 提示；$2 預設 y/n
  local v; while :; do v=$(ask "$1"); v=${v:-$2}
    case "$v" in y|Y|是) return 0 ;; n|N|否) return 1 ;; esac; note "請輸入 y 或 n"; done
}
new_pw(){  # $1 名稱；$2 = 不可相同的密碼
  local a b; while :; do
    a=$(ask_secret "請設定$1（最少 8 個字元，輸入時不會顯示）：")
    [ ${#a} -ge 8 ] || { note "密碼最少 8 個字元"; continue; }
    [ -z "${2:-}" ] || [ "$a" != "$2" ] || { note "$1不可與系統密碼相同"; continue; }
    b=$(ask_secret "請再輸入一次$1：")
    [ "$a" = "$b" ] && break; note "兩次輸入不一致，請重新輸入"
  done; printf '%s' "$a"
}
trap 'printf "\n"; warn "安裝未完成。如需協助，請把上面的訊息交予系統管理員。"' ERR

printf '\033[1;31m\n  案件管理系統　一鍵安裝程式\033[0m\n  Copyright by 27456\n'
[ "$(id -u)" -eq 0 ] || die "請以管理員權限執行（在指令前加上 sudo）"
[ -r "$TTY" ] || die "未能讀取鍵盤輸入，請於終端機直接執行安裝指令"
command -v apt-get >/dev/null && command -v systemctl >/dev/null || die "本安裝程式只支援使用 apt 及 systemd 的 Ubuntu／Debian"
[[ "$KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "安裝金鑰不正確：請使用完整的安裝指令（指令最後一段為安裝金鑰）"
. /etc/os-release
note "作業系統：${PRETTY_NAME:-未知}"

export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -o DPkg::Lock::Timeout=300 -y -q)
need_pkgs(){ local miss=""; for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || miss="$miss $p"; done; printf '%s' "$miss"; }
apt_add(){  # 只安裝未有的套件
  local miss; miss=$(need_pkgs "$@")
  [ -z "$miss" ] && return 0
  note "安裝套件：$miss"
  apt-get -o DPkg::Lock::Timeout=300 update -q >/dev/null
  # shellcheck disable=SC2086
  "${APT[@]}" install $miss >/dev/null
}

# ---------- 1. 下載及解密程式 ----------
say "下載程式（經加密，並以安裝金鑰核對）"
apt_add curl openssl ca-certificates tar
hexof(){ od -An -v -tx1 | tr -d ' \n'; }
b64u_hex(){ local s; s=$(tr '_-' '/+' <<<"$1"); while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done; base64 -d <<<"$s" | hexof; }
hmac_hex(){ openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" -binary | hexof; }
KHEX=$(b64u_hex "$KEY")
ENC=$(printf 'cw-release-enc' | hmac_hex "$KHEX"); MAC=$(printf 'cw-release-mac' | hmac_hex "$KHEX")
FILE=$(printf 'cw-release-name' | hmac_hex "$KHEX" | cut -c1-32)
TMP=$(mktemp -d /tmp/cw-install.XXXXXX); trap 'rm -rf "$TMP"' EXIT
LATEST=$(curl -fsS --max-time 30 "$URL_BASE/$FILE.sha" | tr -d ' \n' || true)
[[ "$LATEST" =~ ^[0-9a-f]{64}$ ]] || die "未能取得程式資料：請檢查安裝金鑰是否正確，以及伺服器能否連接互聯網"
curl -fsS --max-time 600 -o "$TMP/r.enc" "$URL_BASE/$FILE.enc" || die "下載程式失敗，請稍後再試"
[ "$(sha256sum "$TMP/r.enc" | cut -d' ' -f1)" = "$LATEST" ] || die "下載的檔案不完整，請稍後再試"
[ "$(head -c 4 "$TMP/r.enc")" = "CWR1" ] || die "程式檔案格式不正確"
[ "$(tail -c 32 "$TMP/r.enc" | hexof)" = "$(head -c -32 "$TMP/r.enc" | hmac_hex "$MAC")" ] || die "程式核對失敗：安裝金鑰不正確，或檔案曾被改動"
IV=$(head -c 20 "$TMP/r.enc" | tail -c 16 | hexof)
mkdir "$TMP/rel"
tail -c +21 "$TMP/r.enc" | head -c -32 | openssl enc -d -aes-256-ctr -K "$ENC" -iv "$IV" | tar xz -C "$TMP/rel" || die "解密程式失敗"
REL="$TMP/rel"; VERSION=$(cat "$REL/VERSION" 2>/dev/null || echo '?')
note "程式版本：$VERSION（已核對）"

# ---------- 2. 安裝方式 ----------
say "安裝方式"
note "  1. 全新安裝"
note "  2. 由舊伺服器轉移資料（需要舊伺服器「系統」頁「轉移伺服器」產生的一次性連結）"
while :; do MODE=$(ask "請選擇（1 或 2，預設 1）："); MODE=${MODE:-1}; [[ "$MODE" =~ ^[12]$ ]] && break; done
MIGLINK=""
if [ "$MODE" = 2 ]; then
  while :; do
    MIGLINK=$(ask "請貼上轉移連結：" | tr -d ' \r')
    [[ "$MIGLINK" =~ ^https?://[^/#?]+/migrate#m1\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}$ ]] && break
    note "連結格式不正確，請貼上完整連結（以 https:// 開始，包括 # 後面的部分）"
  done
fi

# ---------- 3. 網址及加密連線 ----------
say "網址及加密連線（SSL／TLS）"
while :; do
  DOMAIN=$(ask "請輸入網址（例如 case.example.com；不使用加密連線亦可輸入伺服器 IP）：")
  DOMAIN=$(tr 'A-Z' 'a-z' <<<"$DOMAIN" | sed -E 's#^https?://##; s#/.*$##; s/[[:space:]]//g')
  [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && break
  note "網址格式不正確，請重新輸入"
done
IS_IP=0; [[ "$DOMAIN" =~ ^[0-9.]+$ ]] && IS_IP=1
note "  1. 使用 Cloudflare DNS（Cloudflare 代理，自動申請及續期 Let's Encrypt 憑證）"
note "  2. 使用自備的 SSL／TLS 憑證"
note "  3. 不使用加密連線（只用 HTTP；不建議，亦不能使用 Passkey）"
while :; do T=$(ask "請選擇（1、2 或 3，預設 1）："); T=${T:-1}; [[ "$T" =~ ^[123]$ ]] && break; done
case "$T" in 1) TLS=cloudflare ;; 2) TLS=own ;; 3) TLS=none ;; esac
[ "$TLS" = none ] || [ "$IS_IP" = 0 ] || die "使用加密連線須輸入網域名稱，不可使用 IP"
CERT_SRC=""; KEY_SRC=""
if [ "$TLS" = own ]; then
  while :; do
    CERT_SRC=$(ask "憑證檔案路徑（fullchain，PEM 格式）：")
    KEY_SRC=$(ask "私密金鑰檔案路徑（PEM 格式）：")
    [ -s "$CERT_SRC" ] && [ -s "$KEY_SRC" ] && openssl x509 -in "$CERT_SRC" -noout 2>/dev/null && break
    note "找不到檔案，或憑證格式不正確，請重新輸入"
  done
fi

# ---------- 4. 網頁伺服器及埠 ----------
port_owner(){ ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2 || true; }
WEB=""
if systemctl is-active -q caddy 2>/dev/null && [ -f /etc/caddy/Caddyfile ]; then WEB=caddy
elif systemctl is-active -q nginx 2>/dev/null; then WEB=nginx
elif command -v nginx >/dev/null; then WEB=nginx; fi
for p in 80 443; do
  o=$(port_owner "$p")
  case "$o" in caddy) WEB=caddy ;; nginx) [ "$WEB" = caddy ] || WEB=nginx ;; esac
done
[ -n "$WEB" ] || WEB=nginx
DEF=443; [ "$TLS" = none ] && DEF=80
HPORT=$DEF
o=$(port_owner "$HPORT")
if [ -n "$o" ] && [ "$o" != "$WEB" ] && [ "$o" != caddy ] && [ "$o" != nginx ]; then
  warn "埠 $HPORT 已被「$o」使用。"
  [ "$TLS" = cloudflare ] && note "Cloudflare 代理可使用的加密埠：443、2053、2083、2087、2096、8443"
  while :; do
    HPORT=$(ask "請輸入本系統使用的網頁埠：")
    [[ "$HPORT" =~ ^[0-9]{2,5}$ ]] && [ "$HPORT" -le 65535 ] && { o2=$(port_owner "$HPORT"); [ -z "$o2" ] || [ "$o2" = "$WEB" ]; } && break
    note "埠不正確或已被使用"
  done
fi
if [ "$TLS" = cloudflare ] && ! [[ " 443 2053 2083 2087 2096 8443 " == *" $HPORT "* ]]; then
  warn "Cloudflare 代理不支援埠 $HPORT，網站將未能經 Cloudflare 開啟"
fi
note "網頁伺服器：$( [ "$WEB" = caddy ] && echo "Caddy（已安裝，會加入獨立網站設定）" || { command -v nginx >/dev/null && echo "nginx（已安裝，會加入獨立網站設定）" || echo "nginx（將會安裝）"; })；網頁埠：$HPORT"

# ---------- 5. 隊伍資料 ----------
slug(){ tr 'A-Z' 'a-z' <<<"$1" | tr -c 'a-z0-9\n' '-' | sed -E 's/-+/-/g; s/^-|-$//g' | cut -c1-24; }
TEAM=""; ADMPW=""; WEBPW=""; FIRST=""; UPW=0
ask_team(){
  while :; do
    TEAM=$(ask "隊伍名稱（只限英文字母、數字及空格，例如 Team A；與網頁標題不同）：")
    TEAM=$(sed -E 's/^ +| +$//g; s/ +/ /g' <<<"$TEAM")
    [[ "$TEAM" =~ ^[A-Za-z][A-Za-z0-9\ _-]{0,39}$ ]] && break; note "隊伍名稱只可使用英文字母、數字、空格、- 或 _，並以英文字母開始"
  done
}
if [ "$MODE" = 1 ]; then
  say "隊伍資料"
  ask_team
  NAME="cw-$(slug "$TEAM")"; APPDIR="/opt/$NAME"
  if [ -f "$APPDIR/data/config.json" ]; then
    note "此伺服器已安裝隊伍「$TEAM」：將會更新程式及網站設定，現有資料、密碼及設定全部保留"
  else
    note "資料庫名稱：${TEAM// /}"
    ADMPW=$(new_pw "系統密碼（管理員用：系統頁、新增案件、管理裝置）")
    WEBPW=$(new_pw "網頁密碼（同事登入用）" "$ADMPW")
    while :; do FIRST=$(ask "首名使用者名稱（例如 DPC 12345）：" | tr 'a-z' 'A-Z' | sed -E 's/^ +| +$//g; s/ +/ /g'); [ ${#FIRST} -ge 2 ] && break; done
    if yesno "是否每一名使用者都設有獨立密碼？（y／n，預設 n）：" n; then UPW=1; fi
  fi
fi

# ---------- 6. 套件 ----------
say "安裝所需套件（已安裝的會略過）"
PKGS=(python3 python3-venv python3-cryptography rsync sqlite3 jq iproute2)
[ "$WEB" = nginx ] && PKGS+=(nginx)
[ "$TLS" = cloudflare ] && PKGS+=(certbot python3-certbot-dns-cloudflare)
apt_add "${PKGS[@]}"
IP4=$(curl -4 -fsS --max-time 15 https://api.ipify.org || curl -4 -fsS --max-time 15 https://ifconfig.me || true)

# ---------- 7. 轉移資料（如適用） ----------
STAGE=""
if [ "$MODE" = 2 ]; then
  say "由舊伺服器轉移資料"
  STAGE=$(mktemp -d /var/tmp/cw-migrate.XXXXXX); chmod 700 "$STAGE"
  python3 -I "$REL/app/migrate.py" pull "$MIGLINK" --dest "$STAGE/data" --domain "$DOMAIN" --port "$HPORT" --ip "${IP4:-}" \
    || { rm -rf "$STAGE"; die "轉移資料失敗（舊伺服器的資料未有改動）。請在舊伺服器重新產生轉移連結再試"; }
  TEAM=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1])).get("team",""))' "$STAGE/data/config.json" 2>/dev/null || true)
  if [ -z "$TEAM" ]; then
    note "舊伺服器未設定隊伍名稱，請輸入："; ask_team
    python3 -I - "$STAGE/data/config.json" "$TEAM" <<'PY'
import json, os, sys
p, t = sys.argv[1], sys.argv[2]
c = json.load(open(p)); c['team'] = t
open(p + '.tmp', 'w').write(json.dumps(c)); os.chmod(p + '.tmp', 0o600); os.replace(p + '.tmp', p)
PY
  fi
  NAME="cw-$(slug "$TEAM")"; APPDIR="/opt/$NAME"
  [ ! -f "$APPDIR/data/config.json" ] || { rm -rf "$STAGE"; die "此伺服器已安裝隊伍「$TEAM」，為免覆蓋資料，已停止"; }
  note "隊伍：$TEAM"
fi
ENVF="/etc/caseweb/$NAME.env"

# ---------- 8. 程式及服務 ----------
say "安裝程式（$APPDIR）"
id "$NAME" >/dev/null 2>&1 || useradd --system --home-dir "$APPDIR" --shell /usr/sbin/nologin "$NAME"
mkdir -p "$APPDIR/data" /etc/caseweb; chmod 700 /etc/caseweb
PORT=$(sed -n 's/^PORT=//p' "$ENVF" 2>/dev/null || true)
if [ -z "$PORT" ]; then
  for p in $(seq 8765 8899); do
    ss -ltnH "sport = :$p" | grep -q . || grep -qsx "PORT=$p" /etc/caseweb/*.env || { PORT=$p; break; }
  done
fi
[ -n "$PORT" ] || die "找不到可用的內部埠"
printf '%s\n' "$KEY" > "$APPDIR/release.key"; chmod 600 "$APPDIR/release.key"; chown root:root "$APPDIR/release.key"
CERT_DIR="/etc/caseweb/certs/$NAME"
cat > "$ENVF" <<EOF
NAME=$NAME
APPDIR=$APPDIR
SERVICE=$NAME
RUNAS=$NAME
PORT=$PORT
DOMAIN=$DOMAIN
HPORT=$HPORT
WEB=$WEB
TLS=$TLS
CERT_DIR=$CERT_DIR
URL_BASE=$URL_BASE
EOF
chmod 600 "$ENVF"
rsync -a --delete "$REL/app/" "$APPDIR/app/"; cp "$REL/VERSION" "$APPDIR/app/VERSION"
chown -R "root:$NAME" "$APPDIR/app"; chmod -R u=rwX,g=rX,o= "$APPDIR/app"
[ -x "$APPDIR/venv/bin/python" ] || python3 -m venv "$APPDIR/venv"
"$APPDIR/venv/bin/pip" install -q --upgrade pip
note "安裝 Python 套件（需時數分鐘）"
"$APPDIR/venv/bin/pip" install -q -r "$REL/requirements.txt"
if [ -f "$REL/requirements-optional.txt" ]; then
  grep -Ev '^\s*(#|$)' "$REL/requirements-optional.txt" | while read -r pkg; do
    "$APPDIR/venv/bin/pip" install -q "$pkg" >/dev/null 2>&1 || warn "選用套件 $pkg 未能安裝（相關功能不可用，其他功能不受影響）"
  done
fi

# ---------- 9. 資料 ----------
if [ -f "$APPDIR/data/config.json" ]; then
  note "保留現有資料"
elif [ "$MODE" = 2 ]; then
  rsync -a "$STAGE/data/" "$APPDIR/data/"; rm -rf "$STAGE"
  note "已還原舊伺服器的資料（包括所有案件、身份、裝置、密碼及設定）"
else
  # 密碼經環境變數及管道傳遞，不會出現在指令列（其他用戶看不到）
  CW_T="$TEAM" CW_A="$ADMPW" CW_W="$WEBPW" CW_F="$FIRST" CW_U="$UPW" python3 -I -c \
    'import json,os;e=os.environ;print(json.dumps({"team":e["CW_T"],"admin":e["CW_A"],"web":e["CW_W"],"first_user":e["CW_F"],"user_pw":e["CW_U"]=="1"}))' \
    | "$APPDIR/venv/bin/python" -I "$APPDIR/app/teamcfg.py" "$APPDIR/data" >/dev/null
  ADMPW=""; WEBPW=""
fi
chown -R "$NAME:$NAME" "$APPDIR/data"; chmod 750 "$APPDIR/data"; chown "root:$NAME" "$APPDIR"; chmod 750 "$APPDIR"

cat > "/etc/systemd/system/$NAME.service" <<EOF
[Unit]
Description=Case management system ($TEAM)
After=network.target

[Service]
User=$NAME
Group=$NAME
WorkingDirectory=$APPDIR/app
Environment=CW_DATA=$APPDIR/data
Environment=CW_COOKIE_SECURE=$( [ "$TLS" = none ] && echo 0 || echo 1 )
ExecStart=$APPDIR/venv/bin/uvicorn app:app --host 127.0.0.1 --port $PORT --workers 1
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$APPDIR/data

[Install]
WantedBy=multi-user.target
EOF
cat > "/etc/systemd/system/$NAME-update.service" <<EOF
[Unit]
Description=Case management system auto update ($TEAM)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/$NAME-update
EOF
cat > "/etc/systemd/system/$NAME-update.timer" <<EOF
[Unit]
Description=Check for updates every 5 minutes ($TEAM)

[Timer]
OnBootSec=2min
OnCalendar=*:0/5
RandomizedDelaySec=30
Persistent=true

[Install]
WantedBy=timers.target
EOF
sed "s#@ENV@#$ENVF#" "$REL/deploy/update.sh" > "/usr/local/sbin/$NAME-update"; chmod 755 "/usr/local/sbin/$NAME-update"
install -m 755 "$REL/deploy/web_site.sh" "$APPDIR/web_site.sh"
APPDIR="$APPDIR" SERVICE="$NAME" RUNAS="$NAME" bash "$REL/deploy/system_deps.sh" || warn "部分系統套件未能安裝（PDF 或文字辨識功能可能受影響）"
echo "$LATEST" > "$APPDIR/release.sha"
systemctl daemon-reload
systemctl enable -q "$NAME" "$NAME-update.timer"
systemctl restart "$NAME"; systemctl start "$NAME-update.timer"

# ---------- 10. 憑證 ----------
mkdir -p "$CERT_DIR"; chmod 750 "$CERT_DIR"
CERT_GROUP=root; [ "$WEB" = caddy ] && CERT_GROUP=caddy
chgrp "$CERT_GROUP" "$CERT_DIR"
if [ "$TLS" = own ]; then
  install -o root -g "$CERT_GROUP" -m 640 "$CERT_SRC" "$CERT_DIR/fullchain.pem"
  install -o root -g "$CERT_GROUP" -m 640 "$KEY_SRC" "$CERT_DIR/privkey.pem"
  note "已複製憑證。日後更換憑證：把新檔案放到 $CERT_DIR（fullchain.pem、privkey.pem），再重新載入網頁伺服器"
elif [ "$TLS" = cloudflare ]; then
  say "Cloudflare 設定"
  CF_INI="/etc/caseweb/cloudflare-$NAME.ini"
  if [ ! -s "$CF_INI" ]; then
    note "需要 Cloudflare API Token：Cloudflare 主控台 → My Profile → API Tokens → Create Token"
    note "→ 選擇「Edit zone DNS」範本，Zone Resources 選擇網址所屬的網域"
    note "→（建議）另加權限 Zone → Zone Settings → Edit，以便自動設定 SSL 模式"
    while :; do CF_TOKEN=$(ask_secret "請貼上 Cloudflare API Token（輸入時不會顯示）："); [ -n "$CF_TOKEN" ] && break; done
    printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > "$CF_INI"; chmod 600 "$CF_INI"
  fi
  CF_TOKEN=$(sed -n 's/^dns_cloudflare_api_token *= *//p' "$CF_INI")
  cf(){ curl -sS -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" "$@"; }
  cf_ok(){ jq -e '.success == true' >/dev/null 2>&1 <<<"$1"; }
  cf_fail(){ note "Cloudflare 回覆：$(jq -r '[.errors[]? | "\(.code) \(.message)"] | join("；")' <<<"$1" 2>/dev/null)"; rm -f "$CF_INI"
    die "$2失敗：Token 權限不足。請重新建立 Token（須有 Zone → DNS → Edit，並包括 $DOMAIN 所屬網域），再重新執行安裝程式"; }
  ZID=""; cand="$DOMAIN"
  while [[ "$cand" == *.* ]]; do
    R=$(cf "https://api.cloudflare.com/client/v4/zones?name=$cand"); cf_ok "$R" || cf_fail "$R" "讀取網域"
    ZID=$(jq -r '.result[0].id // empty' <<<"$R"); [ -n "$ZID" ] && break; cand="${cand#*.}"
  done
  [ -n "$ZID" ] || cf_fail '{"errors":[{"code":0,"message":"Token 未能讀取此網域"}]}' "讀取網域"
  [ -n "$IP4" ] || die "未能取得伺服器的公開 IP"
  R=$(cf "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records?type=A&name=$DOMAIN"); cf_ok "$R" || cf_fail "$R" "讀取 DNS 記錄"
  REC=$(jq -r '.result[0].id // empty' <<<"$R")
  BODY=$(jq -nc --arg n "$DOMAIN" --arg ip "$IP4" '{type:"A",name:$n,content:$ip,ttl:1,proxied:true}')
  if [ -n "$REC" ]; then R=$(cf -X PUT "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records/$REC" --data "$BODY")
  else R=$(cf -X POST "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records" --data "$BODY"); fi
  cf_ok "$R" || cf_fail "$R" "寫入 DNS 記錄"
  note "DNS 記錄已設定：$DOMAIN → $IP4（Cloudflare 代理）"
  R=$(cf -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZID/settings/ssl" --data '{"value":"strict"}')
  cf_ok "$R" && note "Cloudflare SSL 模式已設為 Full (strict)" || warn "請自行在 Cloudflare → SSL/TLS → Overview 選擇「Full (strict)」"
  HOOK="/etc/letsencrypt/renewal-hooks/deploy/$NAME.sh"; mkdir -p "$(dirname "$HOOK")"
  cat > "$HOOK" <<EOF
#!/bin/sh
case " \${RENEWED_DOMAINS:-$DOMAIN} " in *" $DOMAIN "*) ;; *) exit 0 ;; esac
install -o root -g $CERT_GROUP -m 640 /etc/letsencrypt/live/$DOMAIN/fullchain.pem $CERT_DIR/fullchain.pem
install -o root -g $CERT_GROUP -m 640 /etc/letsencrypt/live/$DOMAIN/privkey.pem $CERT_DIR/privkey.pem
systemctl reload $WEB 2>/dev/null || true
EOF
  chmod 755 "$HOOK"
  if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    note "申請 Let's Encrypt 憑證（Cloudflare DNS 驗證）"
    certbot certonly -n --agree-tos --register-unsafely-without-email --dns-cloudflare --dns-cloudflare-credentials "$CF_INI" \
      --dns-cloudflare-propagation-seconds 30 -d "$DOMAIN" >/dev/null || die "申請憑證失敗"
  fi
  RENEWED_DOMAINS="$DOMAIN" sh "$HOOK"
  systemctl enable -q --now certbot.timer 2>/dev/null || true
fi

# ---------- 11. 網頁伺服器 ----------
say "設定網頁伺服器"
CW_ENV="$ENVF" bash "$APPDIR/web_site.sh" || die "網頁伺服器設定失敗（已還原原有設定，其他網站不受影響）"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow "$HPORT/tcp" >/dev/null; [ "$TLS" != none ] && [ "$HPORT" = 443 ] && ufw allow 80/tcp >/dev/null
fi

# ---------- 12. 每日備份（本機） ----------
cat > "/etc/cron.daily/$NAME-backup" <<EOF
#!/bin/sh
B=/var/backups/$NAME; mkdir -p \$B && chmod 700 \$B
for f in \$(find $APPDIR/data -name '*.db' -not -path '*/models/*'); do
  n=\$(echo "\${f#$APPDIR/data/}" | tr '/' '_')
  sqlite3 "\$f" ".backup \$B/\${n%.db}-\$(date +%F).db"
done
find \$B -type f -mtime +14 -delete
EOF
chmod 755 "/etc/cron.daily/$NAME-backup"

# ---------- 13. 檢查 ----------
say "檢查"
ok=0; for _ in $(seq 1 30); do curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] && note "系統：運作正常" || warn "系統未能啟動，請執行：journalctl -u $NAME -n 50"
note "自動更新：每 5 分鐘檢查一次"
SCHEME=https; [ "$TLS" = none ] && SCHEME=http
URL="$SCHEME://$DOMAIN"; { [ "$SCHEME" = https ] && [ "$HPORT" = 443 ]; } || { [ "$SCHEME" = http ] && [ "$HPORT" = 80 ]; } || URL="$URL:$HPORT"
trap - ERR
printf '\n\033[1;32m安裝完成！\033[0m\n網址：%s（DNS 生效可能需要數分鐘）\n' "$URL"
if [ "$MODE" = 2 ]; then
  note "資料已由舊伺服器轉移。舊伺服器會保留原有資料，並在「系統」頁顯示此伺服器的 IP、網址及埠。"
  note "如網址與舊伺服器不同，所有裝置須重新登記 Passkey（以網頁密碼登記）。"
elif [ -n "$TEAM" ] && [ -n "$FIRST" ]; then
  note "第一次開啟網頁時，請輸入系統密碼，再設定第一個案件名稱及是否使用 Passkey。"
  note "首名使用者：$FIRST（以網頁密碼登記裝置）"
fi
note "隊伍：$TEAM　｜　系統服務：$NAME　｜　資料：$APPDIR/data"
printf '\nCopyright by 27456\n'
exit 0
