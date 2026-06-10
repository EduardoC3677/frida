#!/usr/bin/env bash
#
# build-deb-cross.sh
#
# Cross-compile Frida on a Linux x86_64 PC using the Android NDK (r29) and
# package the resulting arm64 binaries into a Termux-installable .deb for the
# aarch64 architecture. This is the RELIABLE path: the NDK toolchain (the same
# one Termux uses in CI, e.g. termux/ndk-toolchain-clang-with-flang) runs on
# the host and emits ELF arm64 binaries with interpreter /system/bin/linker64,
# which run on the Android device / inside Termux.
#
# Produces a .deb containing:
#   - frida-server   (bin/frida-server)
#   - frida-inject   (bin/frida-inject)
#   - frida-gadget   (lib/frida/frida-gadget.so)
#
# The pure-Python CLI tools (frida, frida-ps, frida-trace, ...) and the _frida
# Python binding are NOT cross-packaged here because the binding must link
# against Termux's own libpython; install those on-device with the companion
# script tools/termux/termux-build-install.sh (native) or `pip install
# frida-tools` once a matching _frida wheel/build is available.
#
# Usage:
#   ANDROID_NDK_ROOT=/path/to/ndk/29.x \
#     bash tools/termux/build-deb-cross.sh [--arch arm64|arm|x86_64|x86]
#                                          [--jobs N] [--version X.Y.Z]
#                                          [--out DIR] [--clean]
#
# Requirements (host): python3, ninja, a C/C++ host toolchain, dpkg-deb,
# and the Android NDK r29 (set ANDROID_NDK_ROOT). Run from the frida checkout.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --------------------------------------------------------------------------
# Defaults / argument parsing
# --------------------------------------------------------------------------
ARCH="arm64"
JOBS="$(nproc 2>/dev/null || echo 4)"
PKG_VERSION=""
OUT_DIR="$SOURCE_ROOT/dist"
DO_CLEAN=0

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --arch=*) ARCH="${1#*=}"; shift ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --jobs=*) JOBS="${1#*=}"; shift ;;
        --version) PKG_VERSION="$2"; shift 2 ;;
        --version=*) PKG_VERSION="${1#*=}"; shift ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --out=*) OUT_DIR="${1#*=}"; shift ;;
        --clean) DO_CLEAN=1; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# Map our arch name -> frida host triplet and dpkg architecture name.
case "$ARCH" in
    arm64|aarch64) FRIDA_HOST="android-arm64"; DEB_ARCH="aarch64" ;;
    arm|armhf|armeabi*) FRIDA_HOST="android-arm"; DEB_ARCH="arm" ;;
    x86_64|amd64) FRIDA_HOST="android-x86_64"; DEB_ARCH="x86_64" ;;
    x86|i686) FRIDA_HOST="android-x86"; DEB_ARCH="i686" ;;
    *) die "Unsupported --arch '$ARCH' (use arm64|arm|x86_64|x86)" ;;
esac

# --------------------------------------------------------------------------
# Sanity checks
# --------------------------------------------------------------------------
[ -n "${ANDROID_NDK_ROOT:-}" ] || die \
    "ANDROID_NDK_ROOT is not set. Point it at an Android NDK r29 install, e.g.:
       export ANDROID_NDK_ROOT=\$HOME/Android/ndk/29.0.14206865
     You can also use the Termux NDK toolchain from
       github.com/termux/ndk-toolchain-clang-with-flang (release r29-1)."
[ -f "$ANDROID_NDK_ROOT/source.properties" ] || die \
    "ANDROID_NDK_ROOT='$ANDROID_NDK_ROOT' does not look like an NDK (no source.properties)."

NDK_REV="$(sed -n 's/^Pkg.Revision *= *//p' "$ANDROID_NDK_ROOT/source.properties" | head -n1)"
case "$NDK_REV" in
    29.*) : ;;
    *) warn "NDK revision is '$NDK_REV'; Frida expects r29. Continuing anyway." ;;
esac
log "Using NDK r$NDK_REV at $ANDROID_NDK_ROOT"

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found on host (install the 'dpkg' package)."
command -v ninja    >/dev/null 2>&1 || warn "host 'ninja' not found in PATH; Frida will use its bundled ninja."

cd "$SOURCE_ROOT"

# --------------------------------------------------------------------------
# 1. Ensure submodules (releng + frida-core + frida-gum) are present.
# --------------------------------------------------------------------------
if [ ! -f releng/meson_configure.py ]; then
    log "Initialising releng submodule..."
    git submodule update --init --depth 1 releng
    git -C releng submodule update --init --depth 1 || true
fi
log "Initialising frida-gum / frida-core submodules (this can take a while)..."
git submodule update --init --recursive --depth 1 \
    subprojects/frida-gum subprojects/frida-core

# --------------------------------------------------------------------------
# 2. Configure the cross build.
# --------------------------------------------------------------------------
BUILD_DIR="$SOURCE_ROOT/build-$FRIDA_HOST"
if [ "$DO_CLEAN" -eq 1 ]; then
    log "Cleaning $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    log "Configuring cross build for $FRIDA_HOST ..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    ( cd "$BUILD_DIR" && "$SOURCE_ROOT/configure" --host="$FRIDA_HOST" ) \
        || die "configure failed"
else
    log "Reusing existing build dir $BUILD_DIR"
fi

# --------------------------------------------------------------------------
# 3. Build the native targets.
# --------------------------------------------------------------------------
SERVER_T="subprojects/frida-core/server/frida-server"
INJECT_T="subprojects/frida-core/inject/frida-inject"
GADGET_T="subprojects/frida-core/lib/gadget/frida-gadget.so"

log "Building frida-server, frida-inject, frida-gadget (-j$JOBS) ..."
( cd "$BUILD_DIR" && ninja -j "$JOBS" "$SERVER_T" "$INJECT_T" "$GADGET_T" ) \
    || die "ninja build failed"

SERVER_BIN="$BUILD_DIR/$SERVER_T"
INJECT_BIN="$BUILD_DIR/$INJECT_T"
GADGET_BIN="$BUILD_DIR/$GADGET_T"
for f in "$SERVER_BIN" "$INJECT_BIN" "$GADGET_BIN"; do
    [ -f "$f" ] || die "expected output missing: $f"
done
log "Built binaries:"
file "$SERVER_BIN" "$INJECT_BIN" "$GADGET_BIN" | sed 's/^/    /'

# --------------------------------------------------------------------------
# 4. Determine version.
# --------------------------------------------------------------------------
if [ -z "$PKG_VERSION" ]; then
    PKG_VERSION="$(python3 "$SOURCE_ROOT/releng/frida_version.py" 2>/dev/null \
        | head -n1 | tr -d '[:space:]')"
    [ -z "$PKG_VERSION" ] && PKG_VERSION="0.0.0"
fi
case "$PKG_VERSION" in [0-9]*) : ;; *) PKG_VERSION="0.0.0-$PKG_VERSION" ;; esac
log "Package version: $PKG_VERSION"

# --------------------------------------------------------------------------
# 5. Stage the Termux file tree.
#    Termux prefix is /data/data/com.termux/files/usr; packages lay files out
#    relative to that prefix.
# --------------------------------------------------------------------------
TPREFIX="/data/data/com.termux/files/usr"
STAGE="$SOURCE_ROOT/stage-deb-$DEB_ARCH"
rm -rf "$STAGE"
mkdir -p "$STAGE$TPREFIX/bin" \
         "$STAGE$TPREFIX/lib/frida" \
         "$STAGE$TPREFIX/share/doc/frida"

install -m 0755 "$SERVER_BIN" "$STAGE$TPREFIX/bin/frida-server"
install -m 0755 "$INJECT_BIN" "$STAGE$TPREFIX/bin/frida-inject"
install -m 0644 "$GADGET_BIN" "$STAGE$TPREFIX/lib/frida/frida-gadget.so"

cat > "$STAGE$TPREFIX/share/doc/frida/README.termux" <<EOF
Frida native binaries (arm64) cross-compiled with the Android NDK r$NDK_REV.

Installed:
  bin/frida-server          - the Frida server (run as root for system-wide use)
  bin/frida-inject          - standalone gadget injector
  lib/frida/frida-gadget.so - the Frida gadget shared library

Quick start:
  frida-server &            # start the server (root recommended)
  frida-ps -U               # list processes (needs frida-tools, see below)

The Python CLI tools (frida, frida-ps, frida-trace, ...) are NOT in this
package. Install them on-device with:
  pip install frida-tools
(the _frida Python binding must match Termux's libpython).
EOF

# --------------------------------------------------------------------------
# 6. DEBIAN control metadata.
# --------------------------------------------------------------------------
mkdir -p "$STAGE/DEBIAN"
INSTALLED_SIZE="$(du -ks "$STAGE$TPREFIX" 2>/dev/null | cut -f1)"
[ -z "$INSTALLED_SIZE" ] && INSTALLED_SIZE=0

cat > "$STAGE/DEBIAN/control" <<EOF
Package: frida
Version: $PKG_VERSION
Architecture: $DEB_ARCH
Maintainer: EduardoC3677 <ealvarado2677@gmail.com>
Installed-Size: $INSTALLED_SIZE
Depends: libc++
Recommends: python (>= 3.9)
Section: devel
Priority: optional
Homepage: https://frida.re/
Description: Frida dynamic instrumentation toolkit (native arm64 binaries)
 frida-server, frida-inject and frida-gadget, cross-compiled for Android
 $DEB_ARCH with the Android NDK r$NDK_REV. Install frida-tools via pip for
 the Python CLI. Built for use on-device / inside Termux.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
set -e
echo "Frida native binaries installed:"
echo "  frida-server  -> \$PREFIX/bin/frida-server"
echo "  frida-inject  -> \$PREFIX/bin/frida-inject"
echo "  frida-gadget  -> \$PREFIX/lib/frida/frida-gadget.so"
echo
echo "Start the server with:  frida-server &"
echo "Install the CLI with:   pip install frida-tools"
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

# --------------------------------------------------------------------------
# 7. Build the .deb.
# --------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
DEB_NAME="frida_${PKG_VERSION}_${DEB_ARCH}.deb"
DEB_PATH="$OUT_DIR/$DEB_NAME"

log "Building Debian package: $DEB_PATH"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB_PATH" || die "dpkg-deb failed"

log "Package built successfully:"
dpkg-deb --info "$DEB_PATH" | sed 's/^/    /'
echo
log "Contents:"
dpkg-deb --contents "$DEB_PATH" | sed 's/^/    /'
echo
log "Copy it to your phone and install inside Termux with:"
echo "    dpkg -i $DEB_NAME      # or: apt install ./$DEB_NAME"
echo
log "Output: $DEB_PATH"
