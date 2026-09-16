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
RUN_ID="${GITHUB_RUN_ID:-local}"
REPO_SLUG="${GITHUB_REPOSITORY:-}"
BOOT_START=$SECONDS
HEARTBEATS=0
URL_TERM=""
URL_CODE=""
CODE_OK=0
CODE_WARNED=0
OSNAME="$(uname -s)"
ARCH="amd64"; case "$(uname -m)" in arm64|aarch64) ARCH="arm64";; esac
IS_WINDOWS=0; case "$OSNAME" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1;; esac
DISTRO_EFF="runner"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNDIR="$PWD/.giecko"
CODER_VER_FALLBACK="4.137.0"
mkdir -p "$RUNDIR"

case "$STACK" in terminal|vscode|ide) ;; *) echo "  unknown stack '$STACK', using ide"; STACK="ide";; esac
case "$DISTRO" in runner|ubuntu|debian|fedora|arch|alpine) ;; *) echo "  unknown distro '$DISTRO', using runner"; DISTRO="runner";; esac
if [ "$DISTRO" != "runner" ]; then
  if [ "$OSNAME" = "Darwin" ] || [ "$IS_WINDOWS" = 1 ]; then
    echo "no docker distros on $OSNAME, using runner shell"
    DISTRO="runner"
  fi
fi
NEED_TTYD=1; NEED_CODE=1; CODE_REQUIRED=0
[ "$STACK" = "vscode" ] && NEED_TTYD=0
[ "$STACK" = "terminal" ] && NEED_CODE=0
[ "$STACK" = "vscode" ] && CODE_REQUIRED=1

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
    echo "::notice::giecko report [$1]: term=$(pub_url "$URL_TERM") code=$(pub_url "$URL_CODE") boot=${BOOT_SECS:-?}s heartbeats=$HEARTBEATS"
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
    echo "- work_branch: $WORK_BRANCH"
    echo "- versions: $(cloudflared --version 2>/dev/null | head -n 1) / $([ "$NEED_TTYD" = 1 ] && ttyd --version 2>/dev/null || echo "ttyd: n/a") / $([ "$CODE_OK" = 1 ] && "$CODE_BIN" --version 2>/dev/null | head -n 1 || echo "code-server: n/a")"
    for f in ttyd.log term-tunnel.log code-server.log code-tunnel.log distro-setup.log; do
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
    echo "windows beta: system packages are not installed automatically"
    return 0
  fi
  if [ "$OSNAME" = "Darwin" ]; then
    command -v brew >/dev/null 2>&1 || { echo "  no brew, skipping system packages (macOS experimental)"; return 0; }
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
      echo "  no macOS code-server found (experimental OS); vscode unavailable"
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

{
  echo "GIECKO_URL_TERM='$URL_TERM'"
  echo "GIECKO_URL_CODE='$URL_CODE'"
  echo "GIECKO_USER='$USER'"
  echo "GIECKO_RUN_ID='$RUN_ID'"
  echo "GIECKO_REGION='$REGION'"
  echo "GIECKO_STACK='$STACK'"
  echo "GIECKO_DISTRO='$DISTRO_EFF'"
} > /tmp/giecko.env && (priv mv /tmp/giecko.env "$ENV_FILE" || mv /tmp/giecko.env "$ENV_FILE") || true

BOOT_SECS=$((SECONDS - BOOT_START))
DISP_TERM=$(pub_url "$URL_TERM")
DISP_CODE=$(pub_url "$URL_CODE")
LOGIN_LINE="user \`$USER\` + your workflow password"
[ -z "$PASSWORD" ] && LOGIN_LINE="none — OPEN SESSION, anyone with the link gets in "
cat <<EOF

============================================================
   GIECKO IS LIVE! (booted in ${BOOT_SECS}s)
============================================================
EOF
[ -n "$URL_TERM" ] && echo "    terminal: $DISP_TERM"
[ -n "$URL_CODE" ] && echo "   vscode:    $DISP_CODE"
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
[ "$MASK" = 1 ] && echo " mask is ON: hostnames hidden above; the QR codes still carry the real URLs."
echo " code feels laggy in raw terminal? Use the vscode URL — the editor types instantly."
echo ""

echo "::notice::giecko-live term=${DISP_TERM:-none} code=${DISP_CODE:-none} boot=${BOOT_SECS}s region=$REGION stack=$STACK distro=$DISTRO_EFF auth=$([ -n "$PASSWORD" ] && echo on || echo OFF) run=$RUN_ID work=$WORK_BRANCH"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "##  Giecko is live!"
    echo ""
    echo "| | |"
    echo "|---|---|"
    if [ -n "$URL_TERM" ]; then
      if [ "$MASK" = 1 ]; then echo "| **Terminal** | \`$DISP_TERM\` (masked — scan the QR in the logs) |"
      else echo "| **Terminal** | [$URL_TERM]($URL_TERM) |"; fi
    fi
    if [ -n "$URL_CODE" ]; then
      if [ "$MASK" = 1 ]; then echo "| **VS Code** | \`$DISP_CODE\` (masked — scan the QR in the logs) |"
      else echo "| **VS Code** | [$URL_CODE]($URL_CODE) |"; fi
    fi
    echo "| **Login** | $LOGIN_LINE |"
    echo "| **Region** | \`$REGION\` |"
    echo "| **Stack** | \`$STACK\` on \`$DISTRO_EFF\` ($OSNAME) |"
    echo "| **Expires in** | ~${DURATION_MIN} min |"
    echo ""
    if [ "$MASK" = 0 ]; then
      [ -n "$URL_TERM" ] && { echo "Terminal QR:"; echo '```'; qr_block "$URL_TERM"; echo '```'; }
      [ -n "$URL_CODE" ] && { echo "VS Code QR:"; echo '```'; qr_block "$URL_CODE"; echo '```'; }
    fi
    echo " Save work with \`giecko save\` ·  download files with \`tsz <file>\` ·  upload with \`trz\`"
    echo " Files live on branch \`$WORK_BRANCH\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "url=$URL_TERM" >> "$GITHUB_OUTPUT"
  [ -n "$URL_CODE" ] && echo "url_code=$URL_CODE" >> "$GITHUB_OUTPUT"
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
    kill -0 "$(cat "$RUNDIR/term-tunnel.pid" 2>/dev/null)" 2>/dev/null || { tail -n 20 "$RUNDIR/term-tunnel.log" || true; fail "terminal tunnel died mid-run"; }
    if [ "$USE_DISTRO" = 1 ]; then
      [ "$(docker inspect -f '{{.State.Running}}' giecko-box 2>/dev/null || echo false)" = "true" ] || fail "distro container died mid-run"
    fi
  fi
  if [ "$CODE_OK" = 1 ]; then
    if ! kill -0 "$(cat "$RUNDIR/code.pid" 2>/dev/null)" 2>/dev/null \
       || ! kill -0 "$(cat "$RUNDIR/code-tunnel.pid" 2>/dev/null)" 2>/dev/null; then
      if [ "$CODE_REQUIRED" = 1 ]; then fail "vscode side died mid-run (stack=vscode)"; fi
      CODE_OK=0
      [ "$CODE_WARNED" = 0 ] && { echo "  vscode side died mid-run, terminal continues"; CODE_WARNED=1; }
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
