#!/data/data/com.termux/files/usr/bin/bash
#
# termux-install-release.sh
#
# On-device (Termux) one-shot installer for the "remote frida" architecture.
# Downloads the prebuilt arm64 assets from a GitHub Release of this fork and
# installs everything so that `frida` / `frida-tools` work in Termux and
# `frida-server` is staged for root.
#
# It fetches:
#   - the frida binding wheel  (frida-*-abi3-android_*_aarch64.whl)
#   - the .deb                 (frida_*_aarch64.deb)  -> for frida-server/inject/gadget
#   - the raw frida-server     (frida-server-*-android-arm64), staged via su
# then installs frida-tools, verifies `import frida`, and writes the helper
# launchers frida-server-start / frida-remote.
#
# Usage (inside Termux):
#   # newest release of the default repo:
#   bash termux-install-release.sh
#   # or pipe straight from the release:
#   curl -fsSL https://github.com/<owner>/frida/releases/latest/download/termux-install-release.sh | bash
#
# Options:
#   --repo  owner/name   GitHub repo to pull releases from (default: EduardoC3677/frida)
#   --tag   <tag>        specific release tag (default: latest)
#   --port  <port>       TCP port for frida-server (default: 27042)
#   --server-dir <dir>   where to stage frida-server for root (default: /data/local/tmp)
#   --no-server          skip staging frida-server (Termux tools only)
#   --token <ghp_...>    GitHub token (optional, for rate limits / private repos)
#
set -euo pipefail

: "${PREFIX:=/data/data/com.termux/files/usr}"
REPO="EduardoC3677/frida"
TAG="latest"
PORT=27042
SERVER_DIR="/data/local/tmp"
WANT_SERVER=1
GH_TOKEN="${GITHUB_TOKEN:-}"

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --repo=*) REPO="${1#*=}"; shift ;;
        --tag) TAG="$2"; shift 2 ;;
        --tag=*) TAG="${1#*=}"; shift ;;
        --port) PORT="$2"; shift 2 ;;
        --port=*) PORT="${1#*=}"; shift ;;
        --server-dir) SERVER_DIR="$2"; shift 2 ;;
        --server-dir=*) SERVER_DIR="${1#*=}"; shift ;;
        --no-server) WANT_SERVER=0; shift ;;
        --token) GH_TOKEN="$2"; shift 2 ;;
        --token=*) GH_TOKEN="${1#*=}"; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[ -n "${TERMUX_VERSION:-}" ] || [ -d "$PREFIX" ] || die "Run this inside Termux."

# Only arm64 assets are published.
ABI="$(uname -m 2>/dev/null || echo unknown)"
case "$ABI" in
    aarch64|arm64) : ;;
    *) warn "This device reports '$ABI', but only arm64 assets are published. Continuing anyway." ;;
esac

# --------------------------------------------------------------------------
# 0. Tools we need on-device.
# --------------------------------------------------------------------------
command -v curl   >/dev/null 2>&1 || { log "Installing curl...";   pkg install -y curl; }
command -v python3>/dev/null 2>&1 || { log "Installing python..."; pkg install -y python; }
command -v pip    >/dev/null 2>&1 || python3 -m ensurepip --upgrade || true
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

AUTH=()
if [ -n "$GH_TOKEN" ]; then AUTH=(-H "Authorization: Bearer ${GH_TOKEN}"); fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/frida-rel.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# --------------------------------------------------------------------------
# 1. Resolve the release and its asset download URLs via the GitHub API.
# --------------------------------------------------------------------------
if [ "$TAG" = "latest" ]; then
    API="https://api.github.com/repos/$REPO/releases/latest"
else
    API="https://api.github.com/repos/$REPO/releases/tags/$TAG"
fi
log "Querying release: $REPO ($TAG)"
curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github+json" "$API" -o release.json \
    || die "could not query the GitHub release API ($API)"

# Extract "name -> browser_download_url" for every asset.
if [ "$HAVE_JQ" -eq 1 ]; then
    jq -r '.assets[] | "\(.name)\t\(.browser_download_url)"' release.json > assets.tsv
else
    python3 - "$PWD/release.json" > assets.tsv <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for a in data.get("assets", []):
    print(f"{a['name']}\t{a['browser_download_url']}")
PY
fi
[ -s assets.tsv ] || die "release has no downloadable assets."
log "Assets in this release:"
cut -f1 assets.tsv | sed 's/^/    /'

# Pick an asset by a grep pattern over the asset name; echo its URL.
asset_url() {
    awk -F'\t' -v pat="$1" '$1 ~ pat {print $2; exit}' assets.tsv
}
fetch() {  # fetch <pattern> <destfile> ; returns 1 if not present
    local url; url="$(asset_url "$1")"
    [ -n "$url" ] || return 1
    log "Downloading $(basename "$url")"
    curl -fSL "${AUTH[@]}" "$url" -o "$2" || die "download failed: $url"
    return 0
}

# --------------------------------------------------------------------------
# 2. Verify checksums if SHA256SUMS.txt is present.
# --------------------------------------------------------------------------
HAVE_SUMS=0
if fetch '^SHA256SUMS\.txt$' SHA256SUMS.txt 2>/dev/null; then HAVE_SUMS=1; fi

verify() {  # verify <file>
    [ "$HAVE_SUMS" -eq 1 ] || return 0
    local base; base="$(basename "$1")"
    grep -q "  $base\$" SHA256SUMS.txt || { warn "no checksum listed for $base"; return 0; }
    local want have
    want="$(awk -v f="$base" '$2==f{print $1}' SHA256SUMS.txt)"
    have="$(sha256sum "$1" | awk '{print $1}')"
    [ "$want" = "$have" ] || die "checksum mismatch for $base"
    log "checksum OK: $base"
}

# --------------------------------------------------------------------------
# 3. Download the binding wheel + (optionally) frida-server.
# --------------------------------------------------------------------------
WHEEL=""
if fetch 'frida-.*-abi3-android_.*\.whl$' binding.whl; then
    WHEEL="$WORK/binding.whl"; verify "$WHEEL"
else
    warn "no binding wheel in the release; will rely on an already-installed frida module."
fi

SERVER_BIN=""
if [ "$WANT_SERVER" -eq 1 ]; then
    if fetch 'frida-server-.*-android-arm64$' frida-server; then
        SERVER_BIN="$WORK/frida-server"; verify "$SERVER_BIN"; chmod 755 "$SERVER_BIN"
    elif fetch 'frida_.*_aarch64\.deb$' frida.deb; then
        verify "$WORK/frida.deb"
        log "extracting frida-server from the .deb"
        dpkg-deb -x frida.deb debroot 2>/dev/null || true
        cand="debroot/data/data/com.termux/files/usr/bin/frida-server"
        [ -f "$cand" ] && { SERVER_BIN="$WORK/$cand"; chmod 755 "$SERVER_BIN"; }
    fi
    [ -n "$SERVER_BIN" ] || warn "no frida-server asset found; skipping server staging."
fi

TOOLS_WHEEL=""
if fetch 'frida_tools-.*-py3-none-any\.whl$' tools.whl; then
    TOOLS_WHEEL="$WORK/tools.whl"; verify "$TOOLS_WHEEL"
else
    warn "no frida-tools wheel in the release; will fall back to PyPI."
fi

# --------------------------------------------------------------------------
# 4. Install the binding wheel + frida-tools (both from the release), verify.
# --------------------------------------------------------------------------
if [ -n "$WHEEL" ]; then
    log "Installing frida binding wheel (pip)"
    pip install --force-reinstall --no-deps "$WHEEL" || die "wheel install failed"
fi

if [ -n "$TOOLS_WHEEL" ]; then
    log "Installing frida-tools wheel from the release (pip, no PyPI)"
    # --no-deps so pip does not try to pull/replace the frida binding we just
    # installed (the release wheel already matches it).
    pip install --force-reinstall --no-deps "$TOOLS_WHEEL" \
        || die "frida-tools wheel install failed"
    # Pull the remaining pure-Python deps of frida-tools (colorama, pygments,
    # prompt-toolkit, websockets) without touching the frida binding.
    pip install "colorama>=0.2.7,<1.0.0" "prompt-toolkit>=2.0.0,<4.0.0" \
                "pygments>=2.0.2,<3.0.0" "websockets>=13.0.0,<14.0.0" \
        || warn "could not install some frida-tools dependencies; install them manually."
else
    log "Installing frida-tools from PyPI (fallback)"
    pip install --no-build-isolation frida-tools 2>/dev/null \
        || pip install frida-tools \
        || warn "could not install frida-tools from PyPI; install it manually."
fi

log "Verifying the frida binding loads..."
if python3 - <<'PY'
import sys
try:
    import frida
    print("    frida version:", frida.__version__)
except Exception as e:
    print("IMPORT_ERROR:", e, file=sys.stderr)
    sys.exit(1)
PY
then
    log "frida binding OK."
else
    die "frida binding failed to import (wheel arch / Python mismatch)."
fi

# --------------------------------------------------------------------------
# 5. Stage frida-server for root and write the helper launchers.
# --------------------------------------------------------------------------
if [ -n "$SERVER_BIN" ]; then
    log "Staging frida-server into $SERVER_DIR (root-executable)..."
    if command -v su >/dev/null 2>&1; then
        cat "$SERVER_BIN" | su -c "cat > $SERVER_DIR/frida-server && chmod 755 $SERVER_DIR/frida-server" \
            && log "Copied to $SERVER_DIR/frida-server via su." \
            || warn "su copy failed; copy it manually as root."
    else
        cp "$SERVER_BIN" "$PREFIX/bin/frida-server" && chmod 755 "$PREFIX/bin/frida-server"
        warn "su not found. frida-server placed at \$PREFIX/bin/frida-server; move it where root can exec it."
    fi
fi

START="$PREFIX/bin/frida-server-start"
cat > "$START" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Start frida-server on the Android (root) side, listening on 127.0.0.1:$PORT.
set -e
SRV="$SERVER_DIR/frida-server"
PORT="\${1:-$PORT}"
echo "[*] Starting frida-server as root on 127.0.0.1:\$PORT ..."
su -c "\$SRV -l 127.0.0.1:\$PORT &" \\
    || { echo "[x] Could not start via su. Run manually as root:"; \\
         echo "    \$SRV -l 127.0.0.1:\$PORT &"; exit 1; }
sleep 1
echo "[*] frida-server should be up. Test with: frida-ps -H 127.0.0.1:\$PORT"
EOF
chmod 755 "$START"

CONNECT="$PREFIX/bin/frida-remote"
cat > "$CONNECT" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Point any frida-tools command at the remote frida-server over TCP.
PORT="\${FRIDA_PORT:-$PORT}"
HOST="127.0.0.1:\$PORT"
sub="\${1:-ps}"; shift || true
case "\$sub" in
    ps|ls-devices|kill|ls|rm|pull|push|discover|trace|strace|itrace|join|create|compile|pm|apk)
        exec "frida-\$sub" -H "\$HOST" "\$@" ;;
    repl|"") exec frida -H "\$HOST" "\$@" ;;
    *) exec frida -H "\$HOST" "\$sub" "\$@" ;;
esac
EOF
chmod 755 "$CONNECT"

log "Done."
echo
echo "  Frida (Termux remote mode) is installed. Typical workflow:"
echo "    1. Start the server (root):   frida-server-start"
echo "    2. List processes (Termux):   frida-ps -H 127.0.0.1:$PORT     (or: frida-remote ps)"
echo "    3. Trace:                     frida-remote trace -n <process> -i <func>"
echo "    4. REPL into an app:          frida-remote <app>"
echo
echo "  frida-server runs as root on the Android side; frida + frida-tools run in"
echo "  Termux and talk to it over TCP 127.0.0.1:$PORT."
