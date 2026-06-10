#!/usr/bin/env bash
#
# build-tools-wheel.sh
#
# Build the `frida-tools` wheel (the CLI: frida, frida-ps, frida-trace, ...)
# from this checkout instead of pulling it from PyPI. frida-tools is pure
# Python, BUT it ships compiled JavaScript agents (*_agent.js), the language
# bridges (java/objc/swift) and the tracer UI zip, which are generated at build
# time with Node.js + npm via meson. This script runs that build and then
# produces an installable, universal (py3-none-any) wheel.
#
# The resulting wheel is arch-independent: the same file installs in Termux,
# desktop Linux, etc. It depends on the `frida` binding wheel (built separately
# with build-python-binding-cross.sh).
#
# Output:
#   dist/frida_tools-<ver>-py3-none-any.whl
#
# Usage:
#   bash tools/termux/build-tools-wheel.sh [--jobs N] [--out DIR]
#
# Requirements (host): python3, setuptools+wheel, Node.js >= 18 and npm
# (meson uses them to bundle the JS agents). No NDK needed (pure Python wheel).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

JOBS="$(nproc 2>/dev/null || echo 4)"
OUT_DIR="$SOURCE_ROOT/dist"
PKG_VERSION=""

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --jobs) JOBS="$2"; shift 2 ;;
        --jobs=*) JOBS="${1#*=}"; shift ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --out=*) OUT_DIR="${1#*=}"; shift ;;
        --version) PKG_VERSION="$2"; shift 2 ;;
        --version=*) PKG_VERSION="${1#*=}"; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

command -v node >/dev/null 2>&1 || die "Node.js >= 18 is required to bundle the JS agents."
command -v npm  >/dev/null 2>&1 || die "npm is required to bundle the JS agents."
python3 -c "import setuptools, wheel" 2>/dev/null \
    || die "python3 setuptools + wheel are required (pip install setuptools wheel)."

TOOLS="$SOURCE_ROOT/subprojects/frida-tools"

# --------------------------------------------------------------------------
# 1. Make sure the frida-tools submodule (and its releng) is present.
# --------------------------------------------------------------------------
if [ ! -f "$TOOLS/setup.py" ]; then
    log "Initialising frida-tools submodule ..."
    git -C "$SOURCE_ROOT" submodule update --init --depth 1 subprojects/frida-tools
fi
if [ ! -f "$TOOLS/releng/meson/meson.py" ]; then
    log "Initialising frida-tools releng submodules ..."
    git -C "$TOOLS" submodule update --init --recursive --depth 1
fi

cd "$TOOLS"

# --------------------------------------------------------------------------
# 2. Configure + build the JS agents (meson drives node/npm).
# --------------------------------------------------------------------------
if [ ! -f build/build.ninja ]; then
    log "Configuring frida-tools build (node $(node --version)) ..."
    rm -rf build
    ./configure || die "frida-tools configure failed"
fi
log "Building JS agents / bridges / tracer UI (-j$JOBS) ..."
./releng/meson/meson.py compile -C build -j "$JOBS" || die "frida-tools agent build failed"

# Sanity: the agents must exist before packaging.
built_agents="$(find build/agents -name '*_agent.js' 2>/dev/null | wc -l)"
[ "$built_agents" -ge 1 ] || die "no *_agent.js were generated; the JS build did not run."
log "Built $built_agents JS agent(s)."

# --------------------------------------------------------------------------
# 3. Build the wheel. setup.py's fetch_built_assets() copies the freshly built
#    agents/bridges/zip from build/ into frida_tools/ and bundles them.
# --------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
log "Building frida-tools wheel ..."
if [ -n "$PKG_VERSION" ]; then
    log "Forcing frida-tools version: $PKG_VERSION"
    export FRIDA_VERSION="$PKG_VERSION"
fi
python3 setup.py bdist_wheel --dist-dir "$OUT_DIR" >/dev/null \
    || die "bdist_wheel failed"

WHL="$(ls -t "$OUT_DIR"/frida_tools-*.whl 2>/dev/null | head -1 || true)"
[ -n "$WHL" ] || die "wheel was not produced."

# Verify the JS assets actually made it into the wheel.
if ! python3 - "$WHL" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
agents = [n for n in names if n.endswith("_agent.js")]
bridges = [n for n in names if "/bridges/" in n and n.endswith(".js")]
if not agents:
    print("NO_AGENTS", file=sys.stderr); sys.exit(1)
print("    agents :", ", ".join(sorted(n.split("/")[-1] for n in agents)))
print("    bridges:", ", ".join(sorted(n.split("/")[-1] for n in bridges)) or "(none)")
PY
then
    die "the wheel is missing the compiled JS agents."
fi

log "Output: $WHL"
echo
log "Install on the phone (Termux) with:"
echo "    pip install $(basename "$WHL")"
