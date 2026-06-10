#!/usr/bin/env bash
#
# build-python-binding-cross.sh
#
# Cross-compile the Frida Python binding (_frida, the C extension behind the
# `frida` module that frida-tools needs) for Android arm64 on a Linux x86_64
# PC using the Android NDK r29, then build an installable `frida` wheel whose
# extension is the prebuilt arm64 .so (no on-device compilation needed).
#
# Why this exists: `pip install frida` on Termux fails because it tries to
# build _frida from source, needs the frida-core devkit (frida-core.h +
# libfrida-core.a) which pip cannot produce in isolation -> "frida-core.h file
# not found". We cross-build the devkit + the extension here instead. The
# extension is built against Py_LIMITED_API (abi3), so a single .so works for
# any Python 3.x in Termux.
#
# Output:
#   dist/frida-<ver>-cp37-abi3-android_<api>_aarch64.whl  (or a plain copy of
#   the .so under dist/_frida.abi3.so if --so-only is given)
#
# Usage:
#   ANDROID_NDK_ROOT=/path/to/ndk/29.x \
#     bash tools/termux/build-python-binding-cross.sh \
#         [--arch arm64|x86_64] [--python-deb URL_or_PATH] [--jobs N]
#         [--py-tag 3.13] [--so-only] [--out DIR]
#
# Requirements (host): python3, ninja, dpkg-deb, the NDK r29, and a Termux
# python .deb (auto-downloaded for the chosen arch if not provided) to supply
# the target Python headers + libpython.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ARCH="arm64"
JOBS="$(nproc 2>/dev/null || echo 4)"
PY_TAG="3.13"
PYTHON_DEB=""
OUT_DIR="$SOURCE_ROOT/dist"
SO_ONLY=0
PKG_VERSION=""

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --arch=*) ARCH="${1#*=}"; shift ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --jobs=*) JOBS="${1#*=}"; shift ;;
        --py-tag) PY_TAG="$2"; shift 2 ;;
        --py-tag=*) PY_TAG="${1#*=}"; shift ;;
        --python-deb) PYTHON_DEB="$2"; shift 2 ;;
        --python-deb=*) PYTHON_DEB="${1#*=}"; shift ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --out=*) OUT_DIR="${1#*=}"; shift ;;
        --so-only) SO_ONLY=1; shift ;;
        --version) PKG_VERSION="$2"; shift 2 ;;
        --version=*) PKG_VERSION="${1#*=}"; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

case "$ARCH" in
    arm64|aarch64) FRIDA_HOST="android-arm64"; DEB_ARCH="aarch64"
                   NDK_TRIPLE="aarch64-linux-android" ;;
    x86_64|amd64)  FRIDA_HOST="android-x86_64"; DEB_ARCH="x86_64"
                   NDK_TRIPLE="x86_64-linux-android" ;;
    *) die "Unsupported --arch '$ARCH' (use arm64|x86_64)" ;;
esac

[ -n "${ANDROID_NDK_ROOT:-}" ] || die "ANDROID_NDK_ROOT is not set (need NDK r29)."
[ -f "$ANDROID_NDK_ROOT/source.properties" ] || die "ANDROID_NDK_ROOT does not look like an NDK."
command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found on host (install 'dpkg')."

NDK_API=24
NDK_HOSTDIR="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
CLANG="$NDK_HOSTDIR/${NDK_TRIPLE}${NDK_API}-clang"
STRIP="$NDK_HOSTDIR/llvm-strip"
NM="$NDK_HOSTDIR/llvm-nm"
[ -x "$CLANG" ] || die "NDK clang not found: $CLANG"

cd "$SOURCE_ROOT"

# --------------------------------------------------------------------------
# 1. Ensure submodules.
# --------------------------------------------------------------------------
if [ ! -f releng/meson_configure.py ]; then
    git submodule update --init --depth 1 releng
    git -C releng submodule update --init --depth 1 || true
fi
git submodule update --init --recursive --depth 1 \
    subprojects/frida-gum subprojects/frida-core subprojects/frida-python

# --------------------------------------------------------------------------
# 2. Configure cross build with the frida-core devkit enabled.
# --------------------------------------------------------------------------
BUILD_DIR="$SOURCE_ROOT/build-$FRIDA_HOST"
MESON="$SOURCE_ROOT/releng/meson/meson.py"

if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    log "Configuring cross build for $FRIDA_HOST ..."
    rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
    ( cd "$BUILD_DIR" && "$SOURCE_ROOT/configure" --host="$FRIDA_HOST" ) \
        || die "configure failed"
fi
log "Enabling frida-core devkit ..."
( cd "$BUILD_DIR" && python3 "$MESON" configure -Dfrida-core:devkits=core . >/dev/null ) \
    || die "meson configure (devkit) failed"

# --------------------------------------------------------------------------
# 3. Build the devkit (frida-core.h + libfrida-core.a).
#    The selinux umbrella header must be materialised first on Android.
# --------------------------------------------------------------------------
DK="subprojects/frida-core/src/devkit"
log "Building frida-core devkit (this is the heavy step) ..."
( cd "$BUILD_DIR" && ninja -j "$JOBS" \
    subprojects/frida-core/src/api/frida-selinux.h ) || true
( cd "$BUILD_DIR" && ninja -j "$JOBS" \
    "$DK/frida-core.h" "$DK/libfrida-core.a" ) || die "devkit build failed"

DEVKIT_DIR="$BUILD_DIR/$DK"
[ -f "$DEVKIT_DIR/frida-core.h" ]   || die "missing $DEVKIT_DIR/frida-core.h"
[ -f "$DEVKIT_DIR/libfrida-core.a" ] || die "missing $DEVKIT_DIR/libfrida-core.a"
log "Devkit ready: $DEVKIT_DIR"

# --------------------------------------------------------------------------
# 4. Fetch the Termux Python headers + libpython for the target arch.
# --------------------------------------------------------------------------
PYWORK="$BUILD_DIR/termux-python"
rm -rf "$PYWORK"; mkdir -p "$PYWORK"
if [ -z "$PYTHON_DEB" ]; then
    log "Resolving Termux python_*_$DEB_ARCH.deb ..."
    PKGS_URL="https://packages.termux.dev/apt/termux-main/dists/stable/main/binary-$DEB_ARCH/Packages"
    curl -fsSL "$PKGS_URL" -o "$PYWORK/Packages.txt" || die "could not fetch $PKGS_URL"
    FN="$(awk '/^Package: python$/{f=1} f&&/^Filename:/{print $2; exit}' "$PYWORK/Packages.txt")"
    [ -n "$FN" ] || die "could not resolve python package filename from $PKGS_URL"
    PYTHON_DEB="https://packages.termux.dev/apt/termux-main/$FN"
fi
log "Using Termux python: $PYTHON_DEB"
if [ -f "$PYTHON_DEB" ]; then
    cp "$PYTHON_DEB" "$PYWORK/python.deb"
else
    curl -fsSL "$PYTHON_DEB" -o "$PYWORK/python.deb" || die "download failed: $PYTHON_DEB"
fi
dpkg-deb -x "$PYWORK/python.deb" "$PYWORK/root"
TPREFIX_IN_DEB="$PYWORK/root/data/data/com.termux/files/usr"
PYINC="$(dirname "$(find "$TPREFIX_IN_DEB/include" -name Python.h | head -1)")"
PYLIB="$TPREFIX_IN_DEB/lib"
[ -n "$PYINC" ] && [ -f "$PYINC/Python.h" ] || die "Python.h not found in python deb"
PY_SO="$(basename "$(find "$PYLIB" -name 'libpython3.*.so' | head -1)")"
PY_LINK="${PY_SO#lib}"; PY_LINK="${PY_LINK%.so}"   # e.g. python3.13
log "Python headers: $PYINC ; lib: -l$PY_LINK"

# --------------------------------------------------------------------------
# 5. Cross-compile the extension (abi3) against the devkit + Termux libpython.
# --------------------------------------------------------------------------
EXT_SRC="$SOURCE_ROOT/subprojects/frida-python/frida/_frida/extension.c"
SO_OUT="$BUILD_DIR/_frida.abi3.so"
log "Cross-compiling _frida.abi3.so ($FRIDA_HOST) ..."
"$CLANG" -shared -fPIC -O2 \
    -DPy_LIMITED_API=0x03070000 \
    -I"$DEVKIT_DIR" -I"$PYINC" \
    "$EXT_SRC" \
    "$DEVKIT_DIR/libfrida-core.a" \
    -L"$PYLIB" -l"$PY_LINK" \
    -llog -lz \
    -o "$SO_OUT" || die "extension link failed"
"$STRIP" --strip-all "$SO_OUT" || warn "strip failed (continuing)"
if ! "$NM" -D "$SO_OUT" 2>/dev/null | grep "PyInit__frida" >/dev/null; then
    die "built .so does not export PyInit__frida"
fi
log "Built: $SO_OUT"
file "$SO_OUT" | sed 's/^/    /'

mkdir -p "$OUT_DIR"
if [ "$SO_ONLY" -eq 1 ]; then
    cp "$SO_OUT" "$OUT_DIR/_frida.abi3.so"
    log "Output: $OUT_DIR/_frida.abi3.so"
    exit 0
fi

# --------------------------------------------------------------------------
# 6. Build an installable `frida` wheel using FRIDA_EXTENSION (prebuilt path).
#    setup.py's FridaPrebuiltExt just copies $FRIDA_EXTENSION into the wheel.
# --------------------------------------------------------------------------
PYBINDING="$SOURCE_ROOT/subprojects/frida-python"
if [ -n "$PKG_VERSION" ]; then
    VER="$PKG_VERSION"
else
    VER="$(python3 "$SOURCE_ROOT/releng/frida_version.py" 2>/dev/null | head -n1 | tr -d '[:space:]')"
fi
[ -z "$VER" ] && VER="0.0.0"
# PEP 440: dev marker uses '.devN', not '-dev.N'
WHEEL_VER="${VER/-dev./.dev}"
log "Building frida wheel version $WHEEL_VER ..."

if python3 -c "import wheel" 2>/dev/null && python3 -c "import setuptools" 2>/dev/null; then
    ( cd "$PYBINDING" && \
        FRIDA_EXTENSION="$SO_OUT" FRIDA_VERSION="$WHEEL_VER" \
        python3 setup.py bdist_wheel --plat-name "android_${NDK_API}_${DEB_ARCH}" \
            --dist-dir "$OUT_DIR" >/dev/null ) \
        && log "Wheel built in $OUT_DIR" \
        || warn "bdist_wheel failed; falling back to .so output"
fi

WHL="$(ls -t "$OUT_DIR"/frida-*.whl 2>/dev/null | head -1 || true)"
if [ -n "$WHL" ]; then
    log "Output wheel: $WHL"
    echo
    log "Install on the phone (Termux) with:"
    echo "    pip install $(basename "$WHL")"
    echo "    pip install frida-tools"
else
    cp "$SO_OUT" "$OUT_DIR/_frida.abi3.so"
    warn "Could not build a wheel; copied the raw extension to:"
    echo "    $OUT_DIR/_frida.abi3.so"
    echo "  Install it on-device with tools/termux/termux-install-binding.sh"
fi
