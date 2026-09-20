#!/bin/bash
set -e

PASSWORD="${1:-giecko}"
[ "$PASSWORD" = "__BLANK__" ] && PASSWORD=""
DURATION_MIN="${2:-180}"
EXTRA_PKGS="${3:-}"
STACK="${4:-ide}"
AUTOSAVE_MIN="${5:-15}"
USER="$(printf '%s' "${6:-giecko}" | tr -cd 'A-Za-z0-9_-' | head -c 16)"
[ -n "$USER" ] || USER="giecko"
case "${7:-false}" in true|1|yes) MASK=1;; *) MASK=0;; esac
DISTRO="${8:-runner}"

TERM_PORT=7681
CODE_PORT=8080
DESK_PORT=6080
VNC_PORT=5900
DESK_DISPLAY=99
RUN_ID="${GITHUB_RUN_ID:-local}"
REPO_SLUG="${GITHUB_REPOSITORY:-}"
BOOT_START=$SECONDS
HEARTBEATS=0
URL_TERM=""
URL_CODE=""
URL_DESK=""
CODE_OK=0
CODE_WARNED=0
NAMED=0
DESK_OK=0
VNC_AUTH="not run"
DESK_USER_PW=""
OSNAME="$(uname -s)"
ARCH="amd64"; case "$(uname -m)" in arm64|aarch64) ARCH="arm64";; esac
IS_WINDOWS=0; case "$OSNAME" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1;; esac
DISTRO_EFF="runner"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNDIR="$PWD/.giecko"
CODER_VER_FALLBACK="4.137.0"
mkdir -p "$RUNDIR"

case "$STACK" in terminal|vscode|ide|desktop) ;; *) echo "  unknown stack '$STACK', using ide"; STACK="ide";; esac
case "$DISTRO" in runner|ubuntu|debian|fedora|arch|alpine) ;; *) echo "  unknown distro '$DISTRO', using runner"; DISTRO="runner";; esac
if [ "$DISTRO" != "runner" ]; then
  if [ "$OSNAME" = "Darwin" ] || [ "$IS_WINDOWS" = 1 ]; then
    echo "no docker distros on $OSNAME, using runner shell"
    DISTRO="runner"
  fi
fi
if [ "$STACK" = "desktop" ]; then
  if [ "$DISTRO" != "runner" ]; then
    echo " desktop runs on the runner host; distro forced to runner"
    DISTRO="runner"
  fi
fi
NEED_TTYD=1; NEED_CODE=1; CODE_REQUIRED=0
[ "$STACK" = "vscode" ] && NEED_TTYD=0
[ "$STACK" = "terminal" ] && NEED_CODE=0
[ "$STACK" = "vscode" ] && CODE_REQUIRED=1
[ "$STACK" = "desktop" ] && NEED_CODE=0

if [ "$(id -u)" -eq 0 ]; then SUDO=""; CAN_ROOT=1
elif command -v sudo >/dev/null 2>&1; then SUDO="sudo"; CAN_ROOT=1
else SUDO=""; CAN_ROOT=0; fi
priv() { if [ -n "$SUDO" ]; then $SUDO "$@"; else "$@"; fi; }

if [ "$CAN_ROOT" = 1 ]; then BIN_DIR="/usr/local/bin"; else BIN_DIR="$HOME/.local/bin"; mkdir -p "$BIN_DIR"; fi
export PATH="$BIN_DIR:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ "$CAN_ROOT" = 1 ]; then ENV_FILE="/etc/giecko.env"; else ENV_FILE="$HOME/.giecko.env"; fi

fail() {
  trap - ERR
  echo " $1"
  publish_report failed "$1" || true
  exit 1
}
trap 'fail "error at line $LINENO: $BASH_COMMAND"' ERR
trap 'kill $(cat "$RUNDIR"/*.pid 2>/dev/null) 2>/dev/null || true' EXIT

http_up() {
  local port="$1"; shift
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$@" "http://127.0.0.1:$port/" 2>/dev/null || echo "000")
  [ -n "$code" ] && [ "$code" != "000" ]
}

tunnel_url() {
  grep -oE 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$1" 2>/dev/null | head -n 1 || true
}

qr_block() {
  [ "$NAMED" = 1 ] && return 0
  command -v qrencode >/dev/null 2>&1 || return 0
  qrencode -t UTF8 -m 1 "$1" 2>/dev/null || true
}

redact() {
  local b64_userpass="" b64_pw=""
  if [ -n "$PASSWORD" ] && command -v base64 >/dev/null 2>&1; then
    b64_userpass=$(printf '%s:%s' "$USER" "$PASSWORD" | base64 2>/dev/null | tr -d '\n' || true)
    b64_pw=$(printf '%s' "$PASSWORD" | base64 2>/dev/null | tr -d '\n' || true)
  fi
  if command -v python3 >/dev/null 2>&1; then
    GIECKO_PW="$PASSWORD" GIECKO_B64A="$b64_userpass" GIECKO_B64B="$b64_pw" GIECKO_MASK="$MASK" python3 -c '
import sys, os, re
d = sys.stdin.read()
for k in ("GIECKO_PW", "GIECKO_B64A", "GIECKO_B64B"):
    v = os.environ.get(k, "")
    if v: d = d.replace(v, "REDACTED")
d = re.sub(r"credential:\s*\S+", "credential: REDACTED", d)
if os.environ.get("GIECKO_MASK", "0") == "1":
    d = re.sub(r"https://[A-Za-z0-9.-]+\.trycloudflare\.com", "https://****.trycloudflare.com", d)
sys.stdout.write(d)'
  else
    if [ "$MASK" = 1 ]; then
      sed -E -e 's|https://[A-Za-z0-9.-]+\.trycloudflare\.com|https://****.trycloudflare.com|g' \
               -e 's|credential:\s*\S+|credential: REDACTED|g'
    else
      sed -E -e 's|credential:\s*\S+|credential: REDACTED|g'
    fi
  fi
}

pub_url() {
  if [ -z "$1" ]; then echo ""; elif [ "$MASK" = 1 ]; then echo "https://****.trycloudflare.com"; else echo "$1"; fi
}

publish_report() {
  [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0
  [ -n "${GITHUB_TOKEN:-}" ] || { echo "  no GITHUB_TOKEN, skipping report publish"; return 0; }
  [ -n "$REPO_SLUG" ] || { echo "  no GITHUB_REPOSITORY, skipping report publish"; return 0; }
  local out
  if out=$( ( _publish_report_inner "$@" ) 2>&1 ); then
    echo "$out"
    echo "::notice::giecko report [$1]: term=$(pub_url "$URL_TERM") code=$(pub_url "$URL_CODE") desk=$(pub_url "$URL_DESK") boot=${BOOT_SECS:-?}s heartbeats=$HEARTBEATS"
  else
    out="${out//$GITHUB_TOKEN/REDACTED}"
    echo "::warning::giecko report publish failed ($1): ${out:0:500}"
    echo "  report publish failed (non-fatal): ${out:0:300}"
  fi
}
_publish_report_inner() {
  local status="$1" note="$2"
  local rdir auth_url
  rdir=$(mktemp -d) || return 1
  auth_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO_SLUG}.git"
  if ! git clone -q --depth 1 --branch giecko-reports "$auth_url" "$rdir" 2>/dev/null; then
    rm -rf "$rdir"; rdir=$(mktemp -d) || return 1
    git clone -q --depth 1 "$auth_url" "$rdir" 2>/dev/null || { rm -rf "$rdir"; return 1; }
    ( cd "$rdir" && git checkout -q --orphan giecko-reports && git rm -q -rf . >/dev/null ) || { rm -rf "$rdir"; return 1; }
  fi
  mkdir -p "$rdir/reports"
  {
    echo "#  Giecko report — run \`$RUN_ID\`"
    echo ""
    echo "- status: **$status** ${note:+($note)}"
    echo "- time_utc: $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo "- os: $OSNAME, stack: $STACK, distro: $DISTRO (effective: $DISTRO_EFF)"
    echo "- user: $USER, auth: $([ -n "$PASSWORD" ] && echo "on" || echo "OFF (open)"), mask: $MASK, duration_min: $DURATION_MIN, autosave_min: $AUTOSAVE_MIN"
    echo "- region: ${REGION:-unknown}, egress_ip: ${EGRESS_IP:-?}"
    echo "- boot_seconds: ${BOOT_SECS:-$((SECONDS - BOOT_START))}, heartbeats: $HEARTBEATS"
    echo "- url_terminal: $([ -n "$URL_TERM" ] && pub_url "$URL_TERM" || echo "NO")"
    echo "- url_code: $([ -n "$URL_CODE" ] && pub_url "$URL_CODE" || echo "NO")"
    echo "- url_desktop: $([ -n "$URL_DESK" ] && pub_url "$URL_DESK" || echo "NO")"
    echo "- work_branch: $WORK_BRANCH"
    echo "- versions: $(cloudflared --version 2>/dev/null | head -n 1) / $([ "$NEED_TTYD" = 1 ] && ttyd --version 2>/dev/null || echo "ttyd: n/a") / $([ "$CODE_OK" = 1 ] && "$CODE_BIN" --version 2>/dev/null | head -n 1 || echo "code-server: n/a")"
    echo "- binaries (sha256): cloudflared=$(sha256_of "$(command -v cloudflared)") ttyd=$([ "$NEED_TTYD" = 1 ] && sha256_of "$(command -v ttyd)" || echo "n/a") code-server=$([ "$NEED_CODE" = 1 ] && sha256_of "$CODE_BIN" || echo "n/a")"
    echo "- vnc_auth: ${VNC_AUTH:-not run}"
    for f in ttyd.log term-tunnel.log code-server.log code-tunnel.log distro-setup.log xvfb.log xfce.log x11vnc.log novnc.log desk-tunnel.log; do
      if [ -f "$RUNDIR/$f" ]; then
        echo ""
        echo "## $f (tail, redacted)"
        echo '```'
        tail -n 12 "$RUNDIR/$f" | redact || true
        echo '```'
      fi
    done
  } > "$rdir/reports/run-$RUN_ID.md"
  ( cd "$rdir" \
    && git add "reports/run-$RUN_ID.md" \
    && git -c user.email="giecko@local" -c user.name="giecko" commit -qm "report $RUN_ID: $status" \
    && ( git push -q -u origin giecko-reports 2>/dev/null || ( git pull -q --rebase origin giecko-reports 2>/dev/null && git push -q origin giecko-reports 2>/dev/null ) ) ) \
    || { rm -rf "$rdir"; return 1; }
  rm -rf "$rdir"
  echo " report published (status=$status)"
}

echo " Giecko booting..."
echo "   os/stack  : $OSNAME / $STACK"
echo "   distro    : $DISTRO"
echo "   user      : $USER"
echo "   auth      : $([ -n "$PASSWORD" ] && echo "enabled " || echo "DISABLED   (public!)")"
echo "   mask      : $([ "$MASK" = 1 ] && echo "on (hostnames hidden)" || echo "off")"
echo "   duration  : ${DURATION_MIN} min"
echo "   autosave  : $([ "${AUTOSAVE_MIN:-0}" -gt 0 ] 2>/dev/null && echo "every ${AUTOSAVE_MIN} min" || echo "off")"
echo "   extras    : ${EXTRA_PKGS:-none}"
echo "   run_id    : $RUN_ID"
[ -n "$PASSWORD" ] && echo "::add-mask::$PASSWORD" 2>/dev/null || true
echo "::notice::giecko-env ACTIONS=${GITHUB_ACTIONS:-EMPTY} TOKEN_LEN=${#GITHUB_TOKEN} REPO=${GITHUB_REPOSITORY:-EMPTY} EVENT=${GITHUB_EVENT_NAME:-EMPTY} SHA=${GITHUB_SHA:-EMPTY}"

REGION="unknown"
if GEO_JSON=$(curl -s -m 8 'http://ip-api.com/json/?fields=status,countryCode,regionName' 2>/dev/null); then
  if echo "$GEO_JSON" | grep -q '"status":"success"'; then
    GEO_CC=$(echo "$GEO_JSON" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4 || true)
    GEO_RG=$(echo "$GEO_JSON" | grep -o '"regionName":"[^"]*"' | cut -d'"' -f4 || true)
    [ -n "$GEO_CC" ] && REGION="$GEO_CC${GEO_RG:+/$GEO_RG}"
  fi
fi
EGRESS_IP=$(curl -s -m 5 https://api.ipify.org 2>/dev/null || echo "?")
echo "   region    : $REGION — if that's far from you, that's the typing lag. Physics! "
echo ""

sys_pkgs() {
  EPA=()
  [ -n "$EXTRA_PKGS" ] && read -ra EPA <<< "$EXTRA_PKGS"
  if [ "$IS_WINDOWS" = 1 ]; then
    echo "windows: system packages are not installed automatically"
    return 0
  fi
  if [ "$OSNAME" = "Darwin" ]; then
    command -v brew >/dev/null 2>&1 || { echo "  no brew, skipping system packages"; return 0; }
    echo " brew: installing tools (may take a while on first run)..."
    for p in tmux qrencode lrzsz; do
      command -v "$p" >/dev/null 2>&1 || brew install "$p" 2>/dev/null || echo "  $p via brew failed"
    done
    if [ -n "$EXTRA_PKGS" ]; then
      brew install "${EPA[@]}" 2>/dev/null || echo "  some brew extras failed"
    fi
    return 0
  fi
  command -v apt-get >/dev/null 2>&1 || { echo "  no apt-get, skipping system packages"; return 0; }
  [ "$CAN_ROOT" = 1 ] || { echo "  no root, skipping system packages"; return 0; }
  echo " apt: updating..."
  priv apt-get update -qq || echo "  apt update had issues, continuing"
  echo " apt: installing core tools..."
  priv apt-get install -y -qq tmux tree jq htop zip unzip sqlite3 qrencode lrzsz "${EPA[@]}" \
    || echo "  some apt packages failed (run the install command live to retry)"
  priv apt-get install -y -qq fastfetch 2>/dev/null || true
  if [ "$STACK" = "desktop" ]; then
    echo " apt: installing desktop (XFCE + noVNC)..."
    priv apt-get install -y -qq --no-install-recommends xvfb x11vnc novnc websockify dbus dbus-x11 x11-xserver-utils xfce4 xfce4-terminal thunar xterm fonts-dejavu-core adwaita-icon-theme \
      || echo "  some desktop packages failed"
  fi
}
fetch() {
  curl -fsSL --retry 8 --retry-delay 5 --retry-max-time 150 --retry-all-errors "$@"
}
dl_cloudflared() {
  command -v cloudflared >/dev/null 2>&1 && return 0
  if [ "$OSNAME" = "Darwin" ]; then
    echo " downloading cloudflared (macOS)..."
    fetch -o /tmp/giecko-cfd.tgz "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-$ARCH.tgz" || return 1
    tar -xzf /tmp/giecko-cfd.tgz -C /tmp || return 1
    chmod +x /tmp/cloudflared && priv mv /tmp/cloudflared "$BIN_DIR/cloudflared"
    return 0
  fi
  if [ "$IS_WINDOWS" = 1 ]; then
    echo "downloading cloudflared (windows)..."
    fetch -o /tmp/giecko-cloudflared.exe https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe || return 1
    chmod +x /tmp/giecko-cloudflared.exe && priv mv /tmp/giecko-cloudflared.exe "$BIN_DIR/cloudflared.exe"
    return 0
  fi
  echo "downloading cloudflared..."
  fetch -o /tmp/giecko-cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH" \
    || return 1
  chmod +x /tmp/giecko-cloudflared && priv mv /tmp/giecko-cloudflared "$BIN_DIR/cloudflared"
}
dl_ttyd() {
  [ "$NEED_TTYD" = 1 ] || return 0
  command -v ttyd >/dev/null 2>&1 && return 0
  if [ "$OSNAME" = "Darwin" ]; then
    echo " installing ttyd via brew..."
    brew install ttyd 2>/dev/null || return 1
    return 0
  fi
  if [ "$IS_WINDOWS" = 1 ]; then
    echo "downloading ttyd (windows)..."
    fetch -o /tmp/giecko-ttyd.exe https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.win32.exe || return 1
    chmod +x /tmp/giecko-ttyd.exe && priv mv /tmp/giecko-ttyd.exe "$BIN_DIR/ttyd.exe"
    return 0
  fi
  echo "downloading ttyd..."
  TTYD_ARCH="x86_64"; [ "$ARCH" = "arm64" ] && TTYD_ARCH="aarch64"
  fetch -o /tmp/giecko-ttyd "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.$TTYD_ARCH" \
    || return 1
  chmod +x /tmp/giecko-ttyd && priv mv /tmp/giecko-ttyd "$BIN_DIR/ttyd"
}
dl_code() {
  [ "$NEED_CODE" = 1 ] || return 0
  [ -n "${CODE_BIN:-}" ] && [ -x "$CODE_BIN" ] && return 0
  echo " resolving code-server..."
  local url="" auth=() ospat="linux" pat=""
  [ "$OSNAME" = "Darwin" ] && ospat="macos"
  [ "$IS_WINDOWS" = 1 ] && ospat="windows"
  pat="$ospat-$ARCH"
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  url=$(fetch -m 20 "${auth[@]}" https://api.github.com/repos/coder/code-server/releases/latest 2>/dev/null \
    | grep -o "https://[^\"]*${pat}[^\"]*\\.tar\\.gz" | head -n 1 || true)
  if [ -z "$url" ]; then
    if [ "$OSNAME" = "Darwin" ]; then
      echo " trying code-server via brew..."
      brew install code-server 2>/dev/null && { CODE_BIN="$(command -v code-server)"; return 0; }
      echo "  no macOS code-server found; vscode unavailable"
      return 1
    fi
    echo "  code-server API lookup failed, using pinned v$CODER_VER_FALLBACK"
    url="https://github.com/coder/code-server/releases/download/v$CODER_VER_FALLBACK/code-server-$CODER_VER_FALLBACK-$ospat-$ARCH.tar.gz"
  fi
  echo " downloading code-server (~100MB)..."
  fetch -o /tmp/giecko-code.tar.gz "$url" || return 1
}
pip_trzsz() {
  [ "$NEED_TTYD" = 1 ] || return 0
  (command -v trz >/dev/null 2>&1 && command -v tsz >/dev/null 2>&1) && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  echo " installing trzsz (fast file transfer)..."
  python3 -m pip install -q --user --break-system-packages trzsz 2>/dev/null \
    || echo "  trzsz install failed, ZMODEM (sz/rz) still available"
}

sys_pkgs & AP=$!
vnc_selfcheck() {
  if [ -z "$VNC_PW" ] && [ -z "$DESK_USER_PW" ]; then
    VNC_AUTH="skipped (no password)"
    return 0
  fi
  local pyn=python3 out=""
  command -v python3 >/dev/null 2>&1 || pyn=python
  if out=$("$pyn" - "$VNC_PORT" "$VNC_PW" "$USER" "$DESK_USER_PW" 2>&1 <<'PYEOF'

import socket, sys, os, hashlib, subprocess
port = int(sys.argv[1])
pw2 = sys.argv[2]
uname = sys.argv[3]
pw30 = sys.argv[4]
import sys

IP = [58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7]
FP = [40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25]
E = [32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1]
PC1 = [57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,60,52,44,36,63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,28,20,12,4]
P = [16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25]
PC2 = [14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,41,52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32]
SHIFTS = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1]
S = [
[14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
[15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
[10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
[7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14],
[2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
[12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
[4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
[13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11],
]

def bits(data):
    out = []
    for b in data:
        out.extend([(b >> (7 - i)) & 1 for i in range(8)])
    return out

def permute(bt, table):
    return [bt[t - 1] for t in table]

def lrot(bt, n):
    return bt[n:] + bt[:n]

def xor(a, b):
    return [x ^ y for x, y in zip(a, b)]

def subkeys(key):
    k = permute(bits(key), PC1)
    left, right = k[:28], k[28:]
    out = []
    for s in SHIFTS:
        left = lrot(left, s)
        right = lrot(right, s)
        out.append(permute(left + right, PC2))
    return out

def f(right, sub):
    x = permute(right, E)
    x = xor(x, sub)
    res = []
    for i in range(8):
        chunk = x[i * 6:(i + 1) * 6]
        row = (chunk[0] << 1) | chunk[5]
        col = (chunk[1] << 3) | (chunk[2] << 2) | (chunk[3] << 1) | chunk[4]
        v = S[i][row * 16 + col]
        res.extend([(v >> (3 - j)) & 1 for j in range(4)])
    return permute(res, P)

def block(blockbits, keys):
    b = permute(blockbits, IP)
    left, right = b[:32], b[32:]
    for i in range(16):
        prev = left
        left = right
        right = xor(prev, f(right, keys[i]))
    return permute(right + left, FP)

def vnc_key(pw):
    d = pw.encode("utf8").ljust(8, b"\x00")[:8]
    return bytes(int("{:08b}".format(x)[::-1], 2) for x in d)

def des_ecb(key, data):
    keys = subkeys(key)
    assert len(data) % 8 == 0
    out = bytearray()
    for i in range(0, len(data), 8):
        bb = bits(data[i:i + 8])
        res = block(bb, keys)
        for j in range(8):
            v = 0
            for bit in res[j * 8:(j + 1) * 8]:
                v = (v << 1) | bit
            out.append(v)
    return bytes(out)

class Conn:
    def __init__(self):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=15)
        self.b = b""
    def recvn(self, n):
        while len(self.b) < n:
            d = self.s.recv(n - len(self.b))
            if not d:
                raise SystemExit("eof at %d of %d bytes" % (len(self.b), n))
            self.b += d
        out, self.b = self.b[:n], self.b[n:]
        return out
    def hello(self):
        ver = self.recvn(12)
        self.s.sendall(b"RFB 003.008\n")
        n = self.recvn(1)[0]
        if n == 0:
            rl = int.from_bytes(self.recvn(4), "big")
            raise SystemExit("server refused: %s" % self.recvn(rl).decode("utf8", "replace"))
        return ver, list(self.recvn(n))

def reason(c):
    try:
        rl = int.from_bytes(c.recvn(4), "big")
        if rl:
            return c.recvn(rl).decode("utf8", "replace")
    except Exception:
        pass
    return ""

c = Conn()
ver, types = c.hello()
print("server=%s types=%s" % (ver.decode("latin1").strip(), types))
results = {}
if 2 in types and pw2:
    try:
        c.s.sendall(bytes([2]))
        ch = c.recvn(16)
        c.s.sendall(des_ecb(vnc_key(pw2), ch))
        res = int.from_bytes(c.recvn(4), "big")
        if res != 0:
            print("type2 rejected: %s" % reason(c).strip())
        results[2] = res
    except SystemExit as e:
        results[2] = str(e)
if 30 in types and uname and pw30:
    try:
        c2 = Conn()
        v2, t2 = c2.hello()
        c2.s.sendall(bytes([30]))
        g = int.from_bytes(c2.recvn(2), "big")
        klen = int.from_bytes(c2.recvn(2), "big")
        prime = int.from_bytes(c2.recvn(klen), "big")
        spub = int.from_bytes(c2.recvn(klen), "big")
        e = int.from_bytes(os.urandom(klen), "big")
        cpub = pow(g, e, prime).to_bytes(klen, "big")
        shared = pow(spub, e, prime).to_bytes(klen, "big")
        pad = "".join(chr(65 + b % 26) for b in os.urandom(64))
        pu = (uname[:63] + "\0" + pad)[:64]
        pp = (pw30[:63] + "\0" + pad)[:64]
        creds = (pu + pp).encode("utf8")
        key = hashlib.md5(shared).digest()
        r = subprocess.run(["openssl", "enc", "-aes-128-ecb", "-K", key.hex(), "-nopad"], input=creds, capture_output=True)
        if r.returncode != 0 or len(r.stdout) != 128:
            raise SystemExit("openssl aes failed")
        c2.s.sendall(r.stdout)
        c2.s.sendall(cpub)
        res = int.from_bytes(c2.recvn(4), "big")
        if res != 0:
            print("type30 rejected: %s" % reason(c2).strip())
        results[30] = res
    except SystemExit as e:
        results[30] = str(e)
print("results=%s" % results)
need = 30 if 30 in types else 2
if results.get(need) == 0:
    print("authenticated (type %d)" % need)
else:
    raise SystemExit("auth failed for type %d: %s" % (need, results.get(need, "not tested")))
PYEOF
  ); then
    VNC_AUTH="ok"
    echo "  vnc auth self-check: $out"
  else
    VNC_AUTH="failed"
    echo "  vnc auth self-check: FAILED"
    echo "$out"
  fi
  return 0
}
sha256_of() {
  if [ -n "$1" ] && [ -f "$1" ]; then
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'; return 0; fi
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; return 0; fi
  fi
  echo "n/a"
}
patch_novnc() {
  [ -d "$1" ] || return 0
  local owner="" av="" img=""
  if [ -n "${REPO_SLUG:-}" ]; then owner="${REPO_SLUG%%/*}"; fi
  if [ -n "$owner" ]; then
    av=$(curl -s -m 10 -L "https://github.com/${owner}.png?size=96" 2>/dev/null | base64 2>/dev/null | tr -d "\n\r" )
  fi
  if [ -n "$av" ]; then
    img="<image href=\"data:image/png;base64,${av}\" x=\"8\" y=\"8\" width=\"48\" height=\"48\" clip-path=\"url(#c)\"/>"
  fi
  cat > "$RUNDIR/favicon.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
<clipPath id="c"><circle cx="32" cy="32" r="24"/></clipPath>
<rect width="64" height="64" fill="#0B0F14"/>
${img}
<circle cx="32" cy="32" r="24" fill="none" stroke="#4ADE80" stroke-width="4"/>
<text x="34" y="18" font-size="16">&#x1F98E;</text>
</svg>
EOF
  if [ -w "$1" ]; then
    cp -f "$RUNDIR/favicon.svg" "$1/favicon.svg" || return 0
  else
    priv cp -f "$RUNDIR/favicon.svg" "$1/favicon.svg" 2>/dev/null || return 0
  fi
  local pyn=python3
  command -v python3 >/dev/null 2>&1 || pyn=python
  cp -f "$1/vnc.html" "$RUNDIR/vnc.html" 2>/dev/null || return 0
  "$pyn" - "$RUNDIR/vnc.html" <<'PYEOF' 2>/dev/null || return 0
import re, sys
p = sys.argv[1]
try:
    t = open(p, encoding="utf8").read()
except Exception:
    sys.exit(0)
t2 = re.sub(r'<link rel="icon"[^>]*>', '<link rel="icon" href="favicon.svg" type="image/svg+xml">', t, count=1)
if t2 == t and "<head>" in t2:
    t2 = t2.replace("<head>", '<head><link rel="icon" href="favicon.svg" type="image/svg+xml">', 1)
t2 = re.sub(r"<title>[^<]*</title>", "<title>Giecko Desktop</title>", t2, count=1)
if t2 != t:
    open(p, "w", encoding="utf8").write(t2)
PYEOF
  if [ -w "$1" ]; then
    cp -f "$RUNDIR/vnc.html" "$1/vnc.html" || return 0
  else
    priv cp -f "$RUNDIR/vnc.html" "$1/vnc.html" 2>/dev/null || return 0
  fi
  echo "  favicon patched"
}
dl_cloudflared & P1=$!
dl_ttyd & P2=$!
dl_code & P3=$!
pip_trzsz & P4=$!
wait $AP || echo "  system packages job had issues"
wait $P1 || fail "cloudflared download failed"
if [ "$NEED_TTYD" = 1 ]; then wait $P2 || fail "ttyd install failed"; fi
CODE_DL_OK=1
if [ "$NEED_CODE" = 1 ]; then wait $P3 || CODE_DL_OK=0; fi
wait $P4 || true
if [ "$STACK" = "desktop" ] && [ "$OSNAME" = "Linux" ]; then command -v Xvfb >/dev/null 2>&1 || fail "desktop packages did not install"; fi
cloudflared --version
[ "$NEED_TTYD" = 1 ] && ttyd --version

CODE_BIN="${CODE_BIN:-}"
if [ "$NEED_CODE" = 1 ] && [ "$CODE_DL_OK" = 1 ] && [ -z "$CODE_BIN" ]; then
  echo " extracting code-server..."
  rm -rf /tmp/code-server-*
  tar -xzf /tmp/giecko-code.tar.gz -C /tmp || fail "code-server extract failed"
  CODE_BIN=""
  for c in /tmp/code-server-*/bin/code-server /tmp/code-server-*/code-server.exe; do [ -x "$c" ] && { CODE_BIN="$c"; break; }; done
  [ -n "$CODE_BIN" ] && [ -x "$CODE_BIN" ] || fail "code-server binary not found after extract"
  "$CODE_BIN" --version | head -n 1
fi
echo "  binary checksums (sha256):"
echo "    cloudflared: $(sha256_of "$(command -v cloudflared)")"
if [ "$NEED_TTYD" = 1 ]; then echo "    ttyd: $(sha256_of "$(command -v ttyd)")"; fi
if [ "$NEED_CODE" = 1 ]; then echo "    code-server: $(sha256_of "$CODE_BIN")"; fi
if [ "$NEED_CODE" = 1 ] && { [ "$CODE_DL_OK" = 0 ] || [ -z "$CODE_BIN" ]; }; then
  if [ "$CODE_REQUIRED" = 1 ]; then fail "code-server unavailable but stack=vscode needs it"; fi
  echo "  code-server unavailable, continuing terminal-only"
  NEED_CODE=0
fi

if [ -f "$SCRIPT_DIR/giecko" ]; then
  priv cp "$SCRIPT_DIR/giecko" "$BIN_DIR/giecko" && priv chmod +x "$BIN_DIR/giecko" && echo " giecko CLI installed"
else
  echo "  scripts/giecko not found next to installer, 'giecko save' disabled"
fi

if [ -n "${GIECKO_PLUGINS:-}" ]; then
  echo " installing plugins..."
  if command -v npm >/dev/null 2>&1; then
    read -ra PLUGIN_PKGS <<< "$GIECKO_PLUGINS"
    npm install -g --silent "${PLUGIN_PKGS[@]}" 2>/dev/null || echo "  some plugins failed to install"
  else
    echo "  no npm on this runner, plugins skipped"
  fi
fi
if [ "$NEED_TTYD" = 1 ]; then command -v tmux >/dev/null 2>&1 || echo "  no tmux, shell won't persist across reconnects"; fi

if command -v fastfetch >/dev/null 2>&1; then fastfetch --logo none 2>/dev/null | head -n 12 || true; fi
cat <<'BANNER'
   ____ _           _
  / ___(_) ___  ___| | _____
 | |  _| |/ _ \/ __| |/ / _ \
 | |_| | |  __/ (__|   < (_) |
  \____|_|\___|\___|_|\_\___/
  virtual dev environment 
BANNER
uname -a
echo ""

install_shell_candy() {
  local snip="$RUNDIR/shell.sh"
  cat > "$snip" <<EOF
#  Giecko shell candy (safe to delete)
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
export PATH="\$HOME/.local/bin:/usr/local/bin:\$PATH"
alias ll='ls -la' gs='git status --short --branch' save='giecko save' 2>/dev/null || true
if [ -n "\$PS1" ]; then export PS1=' \[\e[1;32m\]giecko\[\e[0m\]:\[\e[1;34m\]\W\[\e[0m\]\$ '; fi
giecko_motd() {
  echo " Giecko run \$GIECKO_RUN_ID · \$GIECKO_REGION · \$GIECKO_STACK on \$GIECKO_DISTRO"
  [ -n "\$GIECKO_URL_TERM" ] && echo "   terminal: \$GIECKO_URL_TERM"
  [ -n "\$GIECKO_URL_CODE" ] && echo "   vscode:   \$GIECKO_URL_CODE"
  echo "   save work: giecko save · download: tsz <file> · upload: trz (or drag-drop)"
}
case \$- in *i*) giecko_motd 2>/dev/null || true;; esac
EOF
  if [ "$CAN_ROOT" = 1 ] && [ "$OSNAME" = "Linux" ]; then
    priv cp "$snip" /etc/profile.d/giecko.sh || true
    grep -q "profile.d/giecko.sh" "$HOME/.bashrc" 2>/dev/null \
      || echo '[ -f /etc/profile.d/giecko.sh ] && . /etc/profile.d/giecko.sh' >> "$HOME/.bashrc"
  else
    cp "$snip" "$HOME/.giecko.sh"
    grep -q ".giecko.sh" "$HOME/.bashrc" 2>/dev/null \
      || echo "[ -f \$HOME/.giecko.sh ] && . \$HOME/.giecko.sh" >> "$HOME/.bashrc"
  fi
}
install_shell_candy || true

WORK_BRANCH="giecko-work/run-$RUN_ID"
WORKDIR="${RUNNER_TEMP:-/tmp}/giecko-work"
[ "$IS_WINDOWS" = 1 ] && WORKDIR="/tmp/giecko-work"
echo "\U0001f33f work branch: $WORK_BRANCH"
if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "${GITHUB_TOKEN:-}" ] && [ -n "$REPO_SLUG" ]; then
  rm -rf "$WORKDIR"
  _AUTH_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO_SLUG}.git"
  if git clone -q --depth 1 "$_AUTH_URL" "$WORKDIR" 2>"$RUNDIR/work-clone.log" \
     && ( cd "$WORKDIR" && git checkout -q -b "$WORK_BRANCH" && git push -q -f -u origin "$WORK_BRANCH" ) 2>>"$RUNDIR/work-clone.log"; then
    echo "\u2705 work branch ready"
  else
    tail -n 5 "$RUNDIR/work-clone.log" 2>/dev/null | sed "s/${GITHUB_TOKEN}/REDACTED/g" || true
    fail "work branch setup failed"
  fi
  unset _AUTH_URL
else
  mkdir -p "$WORKDIR"
fi
if [ "${GITHUB_EVENT_NAME:-}" = "push" ]; then
  echo "save-test $RUN_ID @ $(date -u)" > "$WORKDIR/.giecko-save-test.txt"
fi

if [ -n "${GIECKO_RESTORE:-}" ] && [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "$REPO_SLUG" ]; then
  echo " restoring files from run $GIECKO_RESTORE..."
  _RAUTH="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO_SLUG}.git"
  rm -rf /tmp/giecko-restore
  if git clone -q --depth 1 --branch "giecko-work/run-$GIECKO_RESTORE" "$_RAUTH" /tmp/giecko-restore 2>"$RUNDIR/restore.log"; then
    ( cd /tmp/giecko-restore && tar --exclude=.git -cf - . ) | ( cd "$WORKDIR" && tar -xf - )
    echo " restored files from run $GIECKO_RESTORE"
  else
    echo "  restore failed (no saved branch for that run?), continuing fresh"
    tail -n 3 "$RUNDIR/restore.log" 2>/dev/null || true
  fi
  rm -rf /tmp/giecko-restore
  unset _RAUTH
fi

setup_distro() {
  local img setup
  case "$DISTRO" in
    ubuntu) img="ubuntu:24.04"; setup="apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux curl ca-certificates bash";;
    debian) img="debian:12"; setup="apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux curl ca-certificates bash";;
    fedora) img="fedora:42"; setup="dnf install -y -q tmux curl ca-certificates bash";;
    arch) img="archlinux:base"; setup="pacman -Sy --noconfirm --quiet tmux curl ca-certificates bash";;
    alpine) img="alpine:3.21"; setup="apk add --no-cache tmux curl ca-certificates bash";;
    *) return 1;;
  esac
  command -v docker >/dev/null 2>&1 || { echo "  no docker, distro unavailable"; return 1; }
  docker info >/dev/null 2>&1 || { echo "  docker daemon unreachable"; return 1; }
  echo " starting $DISTRO container ($img)..."
  docker rm -f giecko-box >/dev/null 2>&1 || true
  docker run -d --name giecko-box -w /work -v "$WORKDIR:/work" "$img" sleep infinity > "$RUNDIR/distro-cid" 2> "$RUNDIR/distro-run.log" \
    || { echo "  docker run failed:"; tail -n 5 "$RUNDIR/distro-run.log" || true; return 1; }
  echo " provisioning container shell (tmux + curl)..."
  docker exec giecko-box sh -c "$setup" > "$RUNDIR/distro-setup.log" 2>&1 \
    || echo "  container provisioning had issues, probing for a usable shell anyway"
  if docker exec giecko-box command -v tmux >/dev/null 2>&1; then CONTAINER_SHELL=(tmux new -A -s giecko)
  elif docker exec giecko-box command -v bash >/dev/null 2>&1; then CONTAINER_SHELL=(bash -l)
  else CONTAINER_SHELL=(sh); fi
  echo " container shell: ${CONTAINER_SHELL[*]}"
  echo " pre-flight: testing container exec under a pty (like ttyd will)..."
  if command -v script >/dev/null 2>&1; then
    if script -qec "docker exec -it -e TERM=xterm-256color giecko-box sh -c 'echo PTY_OK'" /dev/null 2>/dev/null | grep -q PTY_OK; then
      echo " container pty pre-flight passed"
    else
      echo "  container pty pre-flight FAILED, falling back to runner shell"
      return 1
    fi
  else
    echo "  no 'script' binary, skipping pty pre-flight (blind)"
  fi
  return 0
}
USE_DISTRO=0
if [ "$DISTRO" != "runner" ]; then
  if [ "$NEED_TTYD" = 0 ]; then
    echo "  distro only affects the CLI shell; vscode terminals run on the host. Skipping container."
  elif setup_distro; then
    USE_DISTRO=1
    DISTRO_EFF="$DISTRO"
  else
    echo "  distro setup failed, falling back to runner shell"
  fi
fi

if [ "$NEED_TTYD" = 1 ]; then
  if [ "$USE_DISTRO" = 1 ]; then
    SHELL_CMD=(docker exec -it -e TERM=xterm-256color giecko-box "${CONTAINER_SHELL[@]}")
  elif command -v tmux >/dev/null 2>&1; then SHELL_CMD=(tmux new -A -s giecko); else SHELL_CMD=(bash -l); fi
  CURL_AUTH=()
  TTYD_OPTS=(-p "$TERM_PORT" --writable)
  if [ -n "$PASSWORD" ]; then
    TTYD_OPTS+=(-c "$USER:$PASSWORD")
    CURL_AUTH=(-u "$USER:$PASSWORD")
  fi
  TTYD_OPTS+=(
    -t 'fontSize=15'
    -t 'fontFamily=JetBrains Mono, Fira Code, Menlo, Consolas, monospace'
    -t 'theme={"background":"#0B0F14","foreground":"#E6EDF3","cursor":"#FFB454","selection":"#1E3A5F"}'
    -t 'titleFixed=Giecko Terminal'
  )
  echo "  starting ttyd on :$TERM_PORT (cmd: ${SHELL_CMD[*]})..."
  rm -f "$RUNDIR"/ttyd.log "$RUNDIR"/ttyd.pid
  _TTYD_PWD="$PWD"; cd "$WORKDIR"
  nohup ttyd "${TTYD_OPTS[@]}" "${SHELL_CMD[@]}" > "$RUNDIR/ttyd.log" 2>&1 &
  echo "$!" > "$RUNDIR/ttyd.pid"
  cd "$_TTYD_PWD"
  echo "⏳ waiting for ttyd..."
  up=0
  for _ in {1..20}; do http_up "$TERM_PORT" "${CURL_AUTH[@]}" && { up=1; break; }; sleep 1; done
  [ "$up" = 1 ] || { echo " ttyd failed. Log:"; cat "$RUNDIR/ttyd.log"; fail "ttyd failed to start"; }
  echo " ttyd is up"
fi

if [ "$NEED_CODE" = 1 ]; then
  echo " starting code-server on :$CODE_PORT..."
  rm -f "$RUNDIR"/code-server.log "$RUNDIR"/code.pid
  CODE_DIR="$WORKDIR"
  if [ "$IS_WINDOWS" = 1 ] && command -v cygpath >/dev/null 2>&1; then CODE_DIR="$(cygpath -m "$WORKDIR")"; fi
  if [ -n "$PASSWORD" ]; then
    PASSWORD="$PASSWORD" nohup "$CODE_BIN" --bind-addr "127.0.0.1:$CODE_PORT" \
      --auth password --disable-telemetry "$CODE_DIR" > "$RUNDIR/code-server.log" 2>&1 &
  else
    nohup "$CODE_BIN" --bind-addr "127.0.0.1:$CODE_PORT" \
      --auth none --disable-telemetry "$CODE_DIR" > "$RUNDIR/code-server.log" 2>&1 &
  fi
  echo "$!" > "$RUNDIR/code.pid"
  echo "⏳ waiting for code-server..."
  up=0
  for _ in {1..45}; do http_up "$CODE_PORT" && { up=1; break; }; sleep 2; done
  if [ "$up" = 1 ]; then CODE_OK=1; echo " code-server is up"
  elif [ "$CODE_REQUIRED" = 1 ]; then tail -n 10 "$RUNDIR/code-server.log" || true; fail "code-server failed but stack=vscode needs it"
  else echo "  code-server didn't start, continuing terminal-only:"; tail -n 10 "$RUNDIR/code-server.log" || true; fi
fi

if [ "$STACK" = "desktop" ]; then
  VNC_PW="${PASSWORD:0:8}"
  WS_CMD=(websockify)
  rm -f "$RUNDIR"/xvfb.log "$RUNDIR"/xfce.log "$RUNDIR"/x11vnc.log "$RUNDIR"/novnc.log "$RUNDIR"/xvfb.pid "$RUNDIR"/xfce.pid "$RUNDIR"/x11vnc.pid "$RUNDIR"/novnc.pid "$RUNDIR"/novnc.tgz
  if [ "$OSNAME" = "Linux" ]; then
    echo "  starting desktop (Xvfb + XFCE + x11vnc + noVNC)..."
    nohup Xvfb ":$DESK_DISPLAY" -screen 0 1600x900x24 > "$RUNDIR/xvfb.log" 2>&1 &
    echo "$!" > "$RUNDIR/xvfb.pid"
    sleep 2
    kill -0 "$(cat "$RUNDIR/xvfb.pid" 2>/dev/null)" 2>/dev/null || { cat "$RUNDIR/xvfb.log" || true; fail "Xvfb failed to start"; }
    DISPLAY=":$DESK_DISPLAY" nohup dbus-run-session -- startxfce4 > "$RUNDIR/xfce.log" 2>&1 &
    echo "$!" > "$RUNDIR/xfce.pid"
    sleep 3
    VNC_OPTS=(-display ":$DESK_DISPLAY" -rfbport "$VNC_PORT" -forever -shared -noxdamage)
    [ -n "$VNC_PW" ] && VNC_OPTS+=(-passwd "$VNC_PW")
    nohup x11vnc "${VNC_OPTS[@]}" > "$RUNDIR/x11vnc.log" 2>&1 &
    echo "$!" > "$RUNDIR/x11vnc.pid"
    sleep 1
    kill -0 "$(cat "$RUNDIR/x11vnc.pid" 2>/dev/null)" 2>/dev/null || { cat "$RUNDIR/x11vnc.log" || true; fail "x11vnc failed to start"; }
    NOVNC_DIR=/usr/share/novnc
    [ -d "$NOVNC_DIR" ] || NOVNC_DIR=/usr/share/webapps/novnc
  elif [ "$OSNAME" = "Darwin" ]; then
    echo "  macOS desktop: enabling the built-in VNC server..."
    echo "  macOS $(sw_vers -productVersion 2>/dev/null || echo unknown)"
    KS="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
    ACCOUNT_PW="$PASSWORD"
    if [ -z "$ACCOUNT_PW" ]; then
      ACCOUNT_PW="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 8)"
      echo "  auth is off, but macOS still needs a desktop login: $USER / $ACCOUNT_PW"
    fi
    VNC_PW="${ACCOUNT_PW:0:8}"
    DESK_USER_PW="$ACCOUNT_PW"
    if priv sysadminctl -addUser "$USER" -password "$ACCOUNT_PW" -admin >/dev/null 2>&1; then
      echo "  macOS desktop login created: $USER / the session password"
      if dseditgroup -o read com.apple.access_screensharing >/dev/null 2>&1; then
        priv dseditgroup -o edit -a "$USER" -t user com.apple.access_screensharing || true
      fi
    else
      echo "  could not create the macOS desktop login; the VNC password still applies"
    fi
    priv "$KS" -activate -configure -access -on -clientopts -setvnclegacy -vnclegacy yes -setvncpw -vncpw "$VNC_PW" -restart -agent -privs -all || fail "could not enable the macOS VNC server"
    vup=0
    for _ in {1..30}; do nc -z 127.0.0.1 "$VNC_PORT" 2>/dev/null && { vup=1; break; }; sleep 2; done
    [ "$vup" = 1 ] || fail "macOS VNC server never came up on port $VNC_PORT"
    PYBIN=python3
    command -v python3 >/dev/null 2>&1 || PYBIN=python
    "$PYBIN" -m pip install --user --quiet websockify >/dev/null 2>&1 || fail "websockify install failed"
    WS_CMD=("$PYBIN" -c "from websockify.websocketproxy import websockify_init; websockify_init()")
    NOVNC_DIR="$RUNDIR/novnc-1.4.0"
    if [ ! -d "$NOVNC_DIR" ]; then
      echo "  fetching noVNC (web client)..."
      fetch -o "$RUNDIR/novnc.tgz" "https://github.com/novnc/noVNC/archive/refs/tags/v1.4.0.tar.gz" || fail "noVNC download failed"
      tar -xzf "$RUNDIR/novnc.tgz" -C "$RUNDIR" || fail "noVNC extract failed"
    fi
  elif [ "$IS_WINDOWS" = 1 ]; then
    echo "  windows desktop: installing TightVNC..."
    if [ -n "$VNC_PW" ]; then
      choco install tightvnc -y --params "/PASSWORD:$VNC_PW" >/dev/null 2>&1 || fail "tightvnc install failed (password mode)"
    else
      choco install tightvnc -y >/dev/null 2>&1 || fail "tightvnc install failed"
    fi
    (cmd //c start explorer.exe >/dev/null 2>&1 || true) &
    vup=0
    for _ in {1..45}; do netstat -an | grep -q ":$VNC_PORT .*LISTENING" && { vup=1; break; }; sleep 2; done
    [ "$vup" = 1 ] || fail "tightvnc never came up on port $VNC_PORT"
    PYBIN=python3
    command -v python3 >/dev/null 2>&1 || PYBIN=python
    "$PYBIN" -m pip install --user --quiet websockify >/dev/null 2>&1 || fail "websockify install failed"
    WS_CMD=("$PYBIN" -c "from websockify.websocketproxy import websockify_init; websockify_init()")
    NOVNC_DIR="$RUNDIR/novnc-1.4.0"
    if [ ! -d "$NOVNC_DIR" ]; then
      echo "  fetching noVNC (web client)..."
      fetch -o "$RUNDIR/novnc.tgz" "https://github.com/novnc/noVNC/archive/refs/tags/v1.4.0.tar.gz" || fail "noVNC download failed"
      tar -xzf "$RUNDIR/novnc.tgz" -C "$RUNDIR" || fail "noVNC extract failed"
    fi
  else
    fail "desktop mode is not supported on this OS"
  fi
  vnc_selfcheck
  patch_novnc "$NOVNC_DIR" || echo "  favicon patch skipped"
  nohup "${WS_CMD[@]}" --web "$NOVNC_DIR" "$DESK_PORT" "localhost:$VNC_PORT" > "$RUNDIR/novnc.log" 2>&1 &
  echo "$!" > "$RUNDIR/novnc.pid"
  up=0
  for _ in {1..30}; do http_up "$DESK_PORT" && { up=1; break; }; sleep 1; done
  [ "$up" = 1 ] || { cat "$RUNDIR/novnc.log" || true; fail "noVNC failed to start"; }
  DESK_OK=1
  echo " desktop is up"
fi

start_tunnel() {
  rm -f "$2" "$3"
  nohup cloudflared tunnel --url "http://127.0.0.1:$1" --no-autoupdate > "$2" 2>&1 &
  echo "$!" > "$3"
}
wait_tunnel() {
  local url=""
  for _ in {1..60}; do
    url=$(tunnel_url "$1")
    [ -n "$url" ] && { echo "$url"; return 0; }
    kill -0 "$(cat "$2" 2>/dev/null)" 2>/dev/null || return 1
    sleep 2
  done
  return 1
}

if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
  NAMED=1
  echo "  starting named cloudflare tunnel (hostnames come from your Cloudflare dashboard)..."
  rm -f "$RUNDIR/named-tunnel.log" "$RUNDIR/named-tunnel.pid"
  nohup cloudflared tunnel run --token "$CF_TUNNEL_TOKEN" --no-autoupdate > "$RUNDIR/named-tunnel.log" 2>&1 &
  echo "$!" > "$RUNDIR/named-tunnel.pid"
  up=0
  for _ in {1..45}; do
    grep -q "Registered tunnel connection" "$RUNDIR/named-tunnel.log" 2>/dev/null && { up=1; break; }
    kill -0 "$(cat "$RUNDIR/named-tunnel.pid" 2>/dev/null)" 2>/dev/null || break
    sleep 2
  done
  if [ "$up" = 1 ]; then
    [ "$NEED_TTYD" = 1 ] && URL_TERM="named-tunnel"
    [ "$CODE_OK" = 1 ] && URL_CODE="named-tunnel"
    [ "$DESK_OK" = 1 ] && URL_DESK="named-tunnel"
    echo " named tunnel is up"
  else
    tail -n 10 "$RUNDIR/named-tunnel.log" 2>/dev/null || true
    fail "named tunnel failed to connect (check the token and your Cloudflare dashboard)"
  fi
else
if [ "$NEED_TTYD" = 1 ]; then
  echo "  opening terminal tunnel..."
  start_tunnel "$TERM_PORT" "$RUNDIR/term-tunnel.log" "$RUNDIR/term-tunnel.pid"
  URL_TERM=$(wait_tunnel "$RUNDIR/term-tunnel.log" "$RUNDIR/term-tunnel.pid") \
    || { echo " terminal tunnel failed. Log:"; cat "$RUNDIR/term-tunnel.log"; fail "terminal tunnel failed"; }
fi

if [ "$CODE_OK" = 1 ]; then
  echo "  opening vscode tunnel..."
  start_tunnel "$CODE_PORT" "$RUNDIR/code-tunnel.log" "$RUNDIR/code-tunnel.pid"
  URL_CODE=$(wait_tunnel "$RUNDIR/code-tunnel.log" "$RUNDIR/code-tunnel.pid" || true)
  if [ -z "$URL_CODE" ]; then
    if [ "$CODE_REQUIRED" = 1 ]; then cat "$RUNDIR/code-tunnel.log"; fail "vscode tunnel failed but stack=vscode needs it"; fi
    echo "  vscode tunnel failed, continuing terminal-only"; CODE_OK=0
  fi
fi
fi

if [ "$DESK_OK" = 1 ]; then
  echo "  opening desktop tunnel..."
  start_tunnel "$DESK_PORT" "$RUNDIR/desk-tunnel.log" "$RUNDIR/desk-tunnel.pid"
  URL_DESK=$(wait_tunnel "$RUNDIR/desk-tunnel.log" "$RUNDIR/desk-tunnel.pid") \
    || { echo " desktop tunnel failed. Log:"; cat "$RUNDIR/desk-tunnel.log"; fail "desktop tunnel failed"; }
  URL_DESK="$URL_DESK/vnc.html?autoconnect=true&resize=scale"
fi
{
  echo "GIECKO_URL_TERM='$URL_TERM'"
  echo "GIECKO_URL_CODE='$URL_CODE'"
  echo "GIECKO_URL_DESK='$URL_DESK'"
  echo "GIECKO_USER='$USER'"
  echo "GIECKO_RUN_ID='$RUN_ID'"
  echo "GIECKO_REGION='$REGION'"
  echo "GIECKO_STACK='$STACK'"
  echo "GIECKO_DISTRO='$DISTRO_EFF'"
} > /tmp/giecko.env && (priv mv /tmp/giecko.env "$ENV_FILE" || mv /tmp/giecko.env "$ENV_FILE") || true

BOOT_SECS=$((SECONDS - BOOT_START))
DISP_TERM=$(pub_url "$URL_TERM")
DISP_CODE=$(pub_url "$URL_CODE")
DISP_DESK=$(pub_url "$URL_DESK")
if [ "$NAMED" = 1 ]; then
  DISP_TERM="your Cloudflare hostname"
  DISP_CODE="your Cloudflare hostname"
  DISP_DESK="your Cloudflare hostname"
fi
LOGIN_LINE="user \`$USER\` + your workflow password"
[ -z "$PASSWORD" ] && LOGIN_LINE="none — OPEN SESSION, anyone with the link gets in "
cat <<EOF

============================================================
   GIECKO IS LIVE! (booted in ${BOOT_SECS}s)
============================================================
EOF
[ -n "$URL_TERM" ] && echo "    terminal: $DISP_TERM"
[ -n "$URL_CODE" ] && echo "   vscode:    $DISP_CODE"
[ -n "$URL_DESK" ] && echo "   desktop:   $DISP_DESK"
[ -n "$URL_DESK" ] && [ -n "$PASSWORD" ] && echo "   desktop login: type the FIRST 8 characters of your password"
cat <<EOF
   login: $LOGIN_LINE
   runner region: $REGION — typing lag ≈ your distance to here
   shell: $DISTRO_EFF on $OSNAME · stack: $STACK
   files: branch '$WORK_BRANCH'
 ⏱   alive ~${DURATION_MIN} min ·  backup: run 'giecko save' (autosave: $([ "${AUTOSAVE_MIN:-0}" -gt 0 ] 2>/dev/null && echo "every ${AUTOSAVE_MIN}m" || echo "off"))
============================================================
EOF
if [ -n "$URL_TERM" ]; then
  echo " terminal QR (square — scan it):"
  qr_block "$URL_TERM"
fi
if [ -n "$URL_CODE" ]; then
  echo " vscode QR (square — scan it):"
  qr_block "$URL_CODE"
fi
if [ -n "$URL_DESK" ]; then
  echo " desktop QR (square — scan it):"
  qr_block "$URL_DESK"
fi
[ "$MASK" = 1 ] && echo " mask is ON: hostnames hidden above; the QR codes still carry the real URLs."
echo " code feels laggy in raw terminal? Use the vscode URL — the editor types instantly."
echo ""

echo "::notice::giecko-live term=${DISP_TERM:-none} code=${DISP_CODE:-none} desk=${DISP_DESK:-none} boot=${BOOT_SECS}s region=$REGION stack=$STACK distro=$DISTRO_EFF auth=$([ -n "$PASSWORD" ] && echo on || echo OFF) run=$RUN_ID work=$WORK_BRANCH"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "##  Giecko is live!"
    echo ""
    echo "| | |"
    echo "|---|---|"
    if [ "$NAMED" = 1 ]; then
      [ "$NEED_TTYD" = 1 ] && echo "| **Terminal** | your Cloudflare hostname (named tunnel) |"
    elif [ -n "$URL_TERM" ]; then
      if [ "$MASK" = 1 ]; then echo "| **Terminal** | \`$DISP_TERM\` (masked — scan the QR in the logs) |"
      else echo "| **Terminal** | [$URL_TERM]($URL_TERM) |"; fi
    fi
    if [ "$NAMED" = 1 ]; then
      [ "$CODE_OK" = 1 ] && echo "| **VS Code** | your Cloudflare hostname (named tunnel) |"
    elif [ -n "$URL_CODE" ]; then
      if [ "$MASK" = 1 ]; then echo "| **VS Code** | \`$DISP_CODE\` (masked — scan the QR in the logs) |"
      else echo "| **VS Code** | [$URL_CODE]($URL_CODE) |"; fi
    fi
    if [ -n "$URL_DESK" ]; then
      if [ "$MASK" = 1 ]; then echo "| **Desktop** | \`$DISP_DESK\` (masked — scan the QR in the logs) |"
      else echo "| **Desktop** | [open desktop]($URL_DESK) |"; fi
    fi
    echo "| **Login** | $LOGIN_LINE |"
    echo "| **Region** | \`$REGION\` |"
    echo "| **Stack** | \`$STACK\` on \`$DISTRO_EFF\` ($OSNAME) |"
    echo "| **Expires in** | ~${DURATION_MIN} min |"
    echo ""
    if [ "$MASK" = 0 ]; then
      [ "$NAMED" != 1 ] && [ -n "$URL_TERM" ] && { echo "Terminal QR:"; echo '```'; qr_block "$URL_TERM"; echo '```'; }
      [ "$NAMED" != 1 ] && [ -n "$URL_CODE" ] && { echo "VS Code QR:"; echo '```'; qr_block "$URL_CODE"; echo '```'; }
      [ "$NAMED" != 1 ] && [ -n "$URL_DESK" ] && { echo "Desktop QR:"; echo '```'; qr_block "$URL_DESK"; echo '```'; }
    fi
    echo " Save work with \`giecko save\` ·  download files with \`tsz <file>\` ·  upload with \`trz\`"
    echo " Files live on branch \`$WORK_BRANCH\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "url=$URL_TERM" >> "$GITHUB_OUTPUT"
  [ -n "$URL_CODE" ] && echo "url_code=$URL_CODE" >> "$GITHUB_OUTPUT"
  [ -n "$URL_DESK" ] && echo "url_desk=$URL_DESK" >> "$GITHUB_OUTPUT"
fi

publish_report live "booted in ${BOOT_SECS}s" || true

if [ "${GITHUB_EVENT_NAME:-}" = "push" ] && [ -n "${GITHUB_TOKEN:-}" ] && [ -n "$REPO_SLUG" ] && [ -n "${GITHUB_SHA:-}" ]; then
  CBODY=" Giecko self-test **live** (run \`$RUN_ID\`): terminal=$DISP_TERM · vscode=${DISP_CODE:-none} · boot=${BOOT_SECS}s · region=$REGION · $STACK on $DISTRO_EFF"
  if [ "$MASK" = 0 ] && [ -n "$URL_TERM" ]; then
    CBODY="$CBODY

Terminal QR:
\`\`\`
$(qr_block "$URL_TERM")
\`\`\`"
  fi
  ( GH_TOKEN="$GITHUB_TOKEN" gh api "repos/$REPO_SLUG/commits/$GITHUB_SHA/comments" \
      -f body="$CBODY" >/dev/null 2>&1 \
    && echo "::notice::giecko-comment posted" || echo "::warning::giecko-comment failed (non-fatal)" ) || true
fi

if [ "${AUTOSAVE_MIN:-0}" -gt 0 ] 2>/dev/null && command -v giecko >/dev/null 2>&1; then
  ( while true; do sleep $((AUTOSAVE_MIN * 60)); ( cd "$WORKDIR" && giecko save --quiet ) || true; done ) &
  echo "$!" > "$RUNDIR/autosave.pid"
  echo " autosave armed (every ${AUTOSAVE_MIN}m)"
fi

END=$((SECONDS + DURATION_MIN * 60))
while [ "$SECONDS" -lt "$END" ]; do
  if [ "$NEED_TTYD" = 1 ]; then
    kill -0 "$(cat "$RUNDIR/ttyd.pid" 2>/dev/null)" 2>/dev/null || { tail -n 20 "$RUNDIR/ttyd.log" || true; fail "ttyd died mid-run"; }
    if [ "$NAMED" = 1 ]; then
      kill -0 "$(cat "$RUNDIR/named-tunnel.pid" 2>/dev/null)" 2>/dev/null || { tail -n 20 "$RUNDIR/named-tunnel.log" || true; fail "named tunnel died mid-run"; }
    else
      kill -0 "$(cat "$RUNDIR/term-tunnel.pid" 2>/dev/null)" 2>/dev/null || { tail -n 20 "$RUNDIR/term-tunnel.log" || true; fail "terminal tunnel died mid-run"; }
    fi
    if [ "$USE_DISTRO" = 1 ]; then
      [ "$(docker inspect -f '{{.State.Running}}' giecko-box 2>/dev/null || echo false)" = "true" ] || fail "distro container died mid-run"
    fi
  fi
  if [ "$CODE_OK" = 1 ]; then
    if ! kill -0 "$(cat "$RUNDIR/code.pid" 2>/dev/null)" 2>/dev/null \
       || { [ "$NAMED" != 1 ] && ! kill -0 "$(cat "$RUNDIR/code-tunnel.pid" 2>/dev/null)" 2>/dev/null; }; then
      if [ "$CODE_REQUIRED" = 1 ]; then fail "vscode side died mid-run (stack=vscode)"; fi
      CODE_OK=0
      [ "$CODE_WARNED" = 0 ] && { echo "  vscode side died mid-run, terminal continues"; CODE_WARNED=1; }
    fi
  fi
  if [ "$DESK_OK" = 1 ]; then
    if [ "$NAMED" = 1 ]; then
      kill -0 "$(cat "$RUNDIR/named-tunnel.pid" 2>/dev/null)" 2>/dev/null || fail "named tunnel died mid-run"
    else
      kill -0 "$(cat "$RUNDIR/desk-tunnel.pid" 2>/dev/null)" 2>/dev/null || { tail -n 20 "$RUNDIR/desk-tunnel.log" || true; fail "desktop tunnel died mid-run"; }
    fi
    kill -0 "$(cat "$RUNDIR/novnc.pid" 2>/dev/null)" 2>/dev/null || { tail -n 20 "$RUNDIR/novnc.log" || true; fail "noVNC died mid-run"; }
    if [ "$OSNAME" = "Linux" ]; then
      kill -0 "$(cat "$RUNDIR/xvfb.pid" 2>/dev/null)" 2>/dev/null || fail "Xvfb died mid-run"
    fi
  fi
  HEARTBEATS=$((HEARTBEATS + 1))
  REM_MIN=$(((END - SECONDS) / 60))
  echo " alive — ~${REM_MIN}m left — ${DISP_TERM:-$DISP_CODE} — $(date -u '+%H:%M:%S UTC')"
  sleep 60
done

if [ "${DURATION_MIN:-1}" = "0" ]; then
  echo " quick check done (tunnels verified, shutting down)."
else
  echo "⏰ time's up (${DURATION_MIN} min). Final backup..."
fi
command -v giecko >/dev/null 2>&1 && ( cd "$WORKDIR" && giecko save --quiet ) || true
publish_report completed "$HEARTBEATS heartbeats" || true
echo "Bye! "
