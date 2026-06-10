#!/data/data/com.termux/files/usr/bin/bash
#
# build-deb.sh
#
# Build Frida natively in Termux (using Termux's own clang toolchain, no NDK)
# and package the resulting binaries + Python tooling into a Termux .deb for
# the aarch64 (arm64) architecture. Installing the .deb with `dpkg -i` drops
# all the Frida tools into the Termux prefix automatically.
#
# Usage:
#   bash tools/termux/build-deb.sh [--jobs N] [--clean] [--version X.Y.Z]
#                                  [--out DIR]
#
# Run from the root of the frida checkout, inside Termux.
#
set -euo pipefail

: "${PREFIX:=/data/data/com.termux/files/usr}"
if [ -z "${TERMUX_VERSION:-}" ] && [ ! -d "$PREFIX" ]; then
    echo "ERROR: this script must be run inside Termux." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

JOBS="$(nproc 2>/dev/null || echo 4)"
DO_CLEAN=0
PKG_VERSION=""
OUT_DIR="$SOURCE_ROOT/dist"
BUILD_DIR="$SOURCE_ROOT/build"
# Termux/dpkg arm64 architecture name is "aarch64".
DEB_ARCH="aarch64"

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --jobs) JOBS="$2"; shift 2 ;;
        --jobs=*) JOBS="${1#*=}"; shift ;;
        --clean) DO_CLEAN=1; shift ;;
        --version) PKG_VERSION="$2"; shift 2 ;;
        --version=*) PKG_VERSION="${1#*=}"; shift ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --out=*) OUT_DIR="${1#*=}"; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

cd "$SOURCE_ROOT"

# --------------------------------------------------------------------------
# 1. Build + install into a staging prefix (DESTDIR), not the live system.
#    We reuse termux-build-install.sh to do the actual compile, but install
#    into a staging tree so we can package it.
# --------------------------------------------------------------------------
STAGE="$SOURCE_ROOT/stage-deb"
rm -rf "$STAGE"
mkdir -p "$STAGE"

CLEAN_FLAG=""
[ "$DO_CLEAN" -eq 1 ] && CLEAN_FLAG="--clean"

log "Building Frida natively (delegating to termux-build-install.sh)..."
# Build only (no live install); we install into the staging dir ourselves.
bash "$SCRIPT_DIR/termux-build-install.sh" \
    --jobs "$JOBS" $CLEAN_FLAG --no-install --prefix "$PREFIX" \
    || die "native build failed"

# Meson install into the staging tree via DESTDIR.
log "Installing into staging tree: $STAGE"
DESTDIR="$STAGE" make -C "$SOURCE_ROOT" install \
    || ( cd "$BUILD_DIR" && DESTDIR="$STAGE" ninja install ) \
    || die "staged install failed"

# Stage the Python CLI tools into the same tree as a wheel install.
if [ -d subprojects/frida-tools ]; then
    log "Staging frida-tools (Python CLI) into package tree..."
    SITE="$(python3 -c 'import sysconfig;print(sysconfig.get_paths()["purelib"])')"
    pip install --no-build-isolation \
        --prefix "$STAGE$PREFIX" \
        ./subprojects/frida-tools 2>/dev/null \
        || pip install --prefix "$STAGE$PREFIX" ./subprojects/frida-tools \
        || warn "Could not stage frida-tools into package."
fi

# --------------------------------------------------------------------------
# 2. Determine version.
# --------------------------------------------------------------------------
if [ -z "$PKG_VERSION" ]; then
    PKG_VERSION="$(python3 "$SOURCE_ROOT/releng/frida_version.py" 2>/dev/null \
        | head -n1 | tr -d '[:space:]')"
    [ -z "$PKG_VERSION" ] && PKG_VERSION="0.0.0"
fi
# dpkg dislikes '+'-laden dev versions in some contexts; keep as-is but ensure
# it starts with a digit.
case "$PKG_VERSION" in [0-9]*) : ;; *) PKG_VERSION="0.0.0-$PKG_VERSION" ;; esac
log "Package version: $PKG_VERSION"

# --------------------------------------------------------------------------
# 3. Build the DEBIAN control metadata.
# --------------------------------------------------------------------------
# The staging tree currently has files under $STAGE/$PREFIX (absolute Termux
# prefix). Termux .deb packages files relative to /data/data/.../usr, which is
# exactly $PREFIX, so the layout already matches. We just add DEBIAN/.
mkdir -p "$STAGE/DEBIAN"

INSTALLED_SIZE="$(du -ks "$STAGE$PREFIX" 2>/dev/null | cut -f1)"
[ -z "$INSTALLED_SIZE" ] && INSTALLED_SIZE=0

cat > "$STAGE/DEBIAN/control" <<EOF
Package: frida
Version: $PKG_VERSION
Architecture: $DEB_ARCH
Maintainer: EduardoC3677 <ealvarado2677@gmail.com>
Installed-Size: $INSTALLED_SIZE
Depends: glib, python (>= 3.9), libc++
Recommends: nodejs-lts
Section: devel
Priority: optional
Homepage: https://frida.re/
Description: Frida dynamic instrumentation toolkit (native Termux build)
 Frida server, gadget, inject, the Python binding and the frida-* CLI
 tools, compiled natively in Termux for Android arm64 (Bionic) using
 Termux's own clang toolchain. No NDK required.
EOF

# Post-install: refresh the shared library cache hint and report success.
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
set -e
echo "Frida installed. Available tools: frida, frida-server, frida-ps,"
echo "frida-trace, frida-inject, frida-ls-devices, frida-kill, frida-discover."
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/postinst"

# Record packaged files as conffiles? No -- binaries, leave default.

# --------------------------------------------------------------------------
# 4. Build the .deb.
# --------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
DEB_NAME="frida_${PKG_VERSION}_${DEB_ARCH}.deb"
DEB_PATH="$OUT_DIR/$DEB_NAME"

if ! command -v dpkg-deb >/dev/null 2>&1; then
    warn "dpkg-deb not found; installing 'dpkg'..."
    pkg install -y dpkg || die "could not install dpkg"
fi

log "Building Debian package: $DEB_PATH"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB_PATH" \
    || die "dpkg-deb failed"

log "Package built successfully:"
dpkg-deb --info "$DEB_PATH" | sed 's/^/    /'
echo
log "Contents (first 40 entries):"
dpkg-deb --contents "$DEB_PATH" | head -40 | sed 's/^/    /'
echo
log "Install it with:"
echo "    dpkg -i $DEB_PATH"
echo "    # or: apt install $DEB_PATH"
echo
log "Output: $DEB_PATH"
