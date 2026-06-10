#!/data/data/com.termux/files/usr/bin/bash
#
# termux-build-install.sh
#
# Build Frida (frida-server, frida-gadget, frida-inject, the Python `_frida`
# binding and the `frida` / `frida-*` CLI tools) entirely from source,
# NATIVELY inside Termux on Android arm64, and install everything into the
# Termux prefix. No NDK is used: this relies on the patched releng that drives
# Termux's own Bionic-linked clang (see releng/env_android.py).
#
# Usage:
#   bash tools/termux/termux-build-install.sh [--jobs N] [--clean]
#                                             [--prefix DIR] [--no-install]
#
# Run this from the root of the frida checkout, inside Termux.
#
set -euo pipefail

# --------------------------------------------------------------------------
# Sanity: must be Termux
# --------------------------------------------------------------------------
: "${PREFIX:=/data/data/com.termux/files/usr}"
if [ -z "${TERMUX_VERSION:-}" ] && [ ! -d "$PREFIX" ]; then
    echo "ERROR: this script must be run inside Termux." >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Resolve paths / args
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

JOBS="$(nproc 2>/dev/null || echo 4)"
DO_CLEAN=0
DO_INSTALL=1
INSTALL_PREFIX="$PREFIX"
BUILD_DIR="$SOURCE_ROOT/build"

while [ $# -gt 0 ]; do
    case "$1" in
        --jobs) JOBS="$2"; shift 2 ;;
        --jobs=*) JOBS="${1#*=}"; shift ;;
        --clean) DO_CLEAN=1; shift ;;
        --no-install) DO_INSTALL=0; shift ;;
        --prefix) INSTALL_PREFIX="$2"; shift 2 ;;
        --prefix=*) INSTALL_PREFIX="${1#*=}"; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Dependencies
# --------------------------------------------------------------------------
log "Ensuring Termux build dependencies are installed..."
PKGS=(
    git python clang make pkg-config binutils
    libtool autoconf automake bison flex
    glib gettext ncurses readline zlib openssl
    golang nodejs-lts xz-utils
)
MISSING=()
for p in "${PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    warn "Installing missing packages: ${MISSING[*]}"
    pkg install -y "${MISSING[@]}" || die "pkg install failed"
else
    log "All base packages already present."
fi

# Frida needs its Vala fork; Termux's vala is usually fine for building the
# binding but frida-core needs the frida-optimised valac. Try Termux's vala;
# the build will tell us if a fork is required.
if ! command -v valac >/dev/null 2>&1; then
    warn "valac not found; installing Termux 'vala' (frida-core may require the frida fork)."
    pkg install -y vala || warn "Could not install vala; frida-core build may fail."
fi

# --------------------------------------------------------------------------
# Environment for a native Termux/Bionic build
# --------------------------------------------------------------------------
export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"
# Make absolutely sure no stale NDK var pushes releng down the cross path.
unset ANDROID_NDK_ROOT ANDROID_NDK || true
# Help meson/glib find Termux's pkg-config metadata.
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-$PREFIX/lib/pkgconfig}"

log "Source root : $SOURCE_ROOT"
log "Build dir   : $BUILD_DIR"
log "Install pfx : $INSTALL_PREFIX"
log "Jobs        : $JOBS"
log "Compiler    : $CC / $CXX"

cd "$SOURCE_ROOT"

# --------------------------------------------------------------------------
# Submodules (uses the forked releng pinned in .gitmodules)
# --------------------------------------------------------------------------
log "Synchronising git submodules..."
git submodule sync --recursive
git submodule update --init --recursive --depth 1 releng \
    || die "Failed to fetch releng submodule"
git -C releng submodule update --init --depth 1 || true
git submodule update --init --recursive --depth 1 \
    subprojects/frida-gum subprojects/frida-core \
    subprojects/frida-python subprojects/frida-tools \
    || die "Failed to fetch core submodules"

# --------------------------------------------------------------------------
# Clean if requested
# --------------------------------------------------------------------------
if [ "$DO_CLEAN" -eq 1 ] && [ -d "$BUILD_DIR" ]; then
    log "Cleaning previous build dir..."
    rm -rf "$BUILD_DIR"
fi

# --------------------------------------------------------------------------
# Configure
#   --without-prebuilds : never download glibc toolchain/SDK bundles (they
#                         can't run on Bionic). Build deps from source.
#   --enable-shared     : produce usable .so for the gadget / python binding.
# --------------------------------------------------------------------------
if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    log "Configuring (native Termux, no prebuilts)..."
    ./configure \
        --prefix="$INSTALL_PREFIX" \
        --without-prebuilds=toolchain,sdk:build,sdk:host \
        --enable-shared \
        || die "configure failed"
else
    log "Already configured (build.ninja exists); skipping configure."
fi

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------
log "Building Frida (this can take a long time on-device)..."
make -j"$JOBS" || die "make failed"

# --------------------------------------------------------------------------
# Install
# --------------------------------------------------------------------------
if [ "$DO_INSTALL" -eq 1 ]; then
    log "Installing build artifacts into $INSTALL_PREFIX ..."
    make install || die "make install failed"

    # Install the Python CLI tools (frida, frida-ps, frida-trace, ...).
    if [ -d subprojects/frida-tools ]; then
        log "Installing frida-tools Python package..."
        pip install --no-build-isolation ./subprojects/frida-tools \
            || pip install ./subprojects/frida-tools \
            || warn "frida-tools pip install failed; install manually."
    fi

    log "Done. Installed binaries:"
    for b in frida frida-server frida-inject frida-ps frida-trace \
             frida-ls-devices frida-kill frida-discover; do
        if command -v "$b" >/dev/null 2>&1; then
            printf '    %-18s %s\n' "$b" "$(command -v "$b")"
        fi
    done
    # The gadget is a library, report its location too.
    find "$BUILD_DIR" -name 'frida-gadget*.so' 2>/dev/null | while read -r g; do
        printf '    %-18s %s\n' "frida-gadget" "$g"
    done
else
    log "Build complete (install skipped). Artifacts under $BUILD_DIR"
fi

log "All done."
