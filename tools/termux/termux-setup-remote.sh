#!/data/data/com.termux/files/usr/bin/bash
#
# termux-setup-remote.sh
#
# On-device (Termux) installer + launcher for the "remote frida" architecture:
#
#   [ Android side, root/su ]            [ Termux side, your user ]
#   frida-server  (arm64, /system area)  <--- TCP --->  frida / frida-tools
#       listens on 127.0.0.1:27042                      connects with -H
#
# What it does:
#   1. Installs the cross-built `frida` wheel (the _frida binding) + frida-tools
#      into Termux's Python, so `frida`, `frida-ps`, `frida-trace`, ... work.
#   2. Places the arm64 `frida-server` binary where root can exec it, and gives
#      you helper commands to start it with su and to connect to it remotely.
#
# Why remote: frida-server must run with root/su to instrument other apps, but
# Termux runs unprivileged. So the server lives on the Android (root) side and
# Termux's frida-tools attach over TCP (-H 127.0.0.1:27042). This is the
# officially supported "remote" mode.
#
# Usage (run inside Termux):
#   bash termux-setup-remote.sh --wheel frida-*.whl --server frida-server \
#        [--port 27042] [--server-dir /data/local/tmp]
#
# --wheel    path to the cross-built frida-*-abi3-linux_aarch64.whl
# --server   path to the cross-built arm64 frida-server binary
# --port     TCP port frida-server listens on (default 27042)
# --server-dir  where to stage frida-server for root (default /data/local/tmp)
#
set -euo pipefail

: "${PREFIX:=/data/data/com.termux/files/usr}"
WHEEL=""
SERVER_BIN=""
PORT=27042
SERVER_DIR="/data/local/tmp"

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --wheel) WHEEL="$2"; shift 2 ;;
        --wheel=*) WHEEL="${1#*=}"; shift ;;
        --server) SERVER_BIN="$2"; shift 2 ;;
        --server=*) SERVER_BIN="${1#*=}"; shift ;;
        --port) PORT="$2"; shift 2 ;;
        --port=*) PORT="${1#*=}"; shift ;;
        --server-dir) SERVER_DIR="$2"; shift 2 ;;
        --server-dir=*) SERVER_DIR="${1#*=}"; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[ -n "${TERMUX_VERSION:-}" ] || [ -d "$PREFIX" ] || die "Run this inside Termux."

# --------------------------------------------------------------------------
# 1. Python tooling: install the binding wheel + frida-tools.
# --------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { log "Installing python..."; pkg install -y python; }
command -v pip      >/dev/null 2>&1 || python3 -m ensurepip --upgrade || true

if [ -n "$WHEEL" ]; then
    [ -f "$WHEEL" ] || die "wheel not found: $WHEEL"
    log "Installing frida binding wheel: $WHEEL"
    pip install --force-reinstall --no-deps "$WHEEL" || die "wheel install failed"
else
    warn "No --wheel given; assuming the 'frida' module is already installed."
fi

log "Installing frida-tools (pure Python CLI)..."
# --no-build-isolation keeps pip from trying to rebuild the frida binding.
pip install --no-build-isolation frida-tools 2>/dev/null \
    || pip install frida-tools \
    || warn "Could not install frida-tools from PyPI; install it manually."

# Verify the binding actually imports (this is the real test).
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
    die "frida binding failed to import. The wheel arch/Python may not match."
fi

# --------------------------------------------------------------------------
# 2. Stage frida-server for the root/Android side.
# --------------------------------------------------------------------------
if [ -n "$SERVER_BIN" ]; then
    [ -f "$SERVER_BIN" ] || die "frida-server not found: $SERVER_BIN"
    log "Staging frida-server into $SERVER_DIR (needs to be root-executable)..."
    # Try to copy via su (root) so it lands outside Termux's no-exec sandbox.
    if command -v su >/dev/null 2>&1; then
        cat "$SERVER_BIN" | su -c "cat > $SERVER_DIR/frida-server && chmod 755 $SERVER_DIR/frida-server" \
            && log "Copied to $SERVER_DIR/frida-server via su." \
            || warn "su copy failed; copy it manually as root."
    else
        cp "$SERVER_BIN" "$PREFIX/bin/frida-server" && chmod 755 "$PREFIX/bin/frida-server"
        warn "su not found. Put frida-server somewhere root can exec it:"
        warn "  it is at \$PREFIX/bin/frida-server for now."
    fi
fi

# --------------------------------------------------------------------------
# 3. Write convenience launcher + connect scripts.
# --------------------------------------------------------------------------
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
# Thin wrapper that points any frida-tools command at the remote frida-server.
# Usage: frida-remote ps                  -> frida-ps -H 127.0.0.1:$PORT
#        frida-remote trace -n com.app ... -> frida-trace -H ... -n com.app ...
#        frida-remote <app>                -> frida -H ... <app>  (REPL)
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
echo "  Remote-frida is set up. Typical workflow:"
echo "    1. Start the server (root):   frida-server-start"
echo "    2. List processes (Termux):   frida-ps -H 127.0.0.1:$PORT"
echo "                          or:     frida-remote ps"
echo "    3. Attach / trace:            frida-remote trace -n <process> -i <func>"
echo "    4. REPL into an app:          frida-remote -U <app>   (or: frida -H 127.0.0.1:$PORT <app>)"
echo
echo "  The binding (frida module) and frida-tools run in Termux; frida-server"
echo "  runs as root on the Android side and they talk over TCP 127.0.0.1:$PORT."
