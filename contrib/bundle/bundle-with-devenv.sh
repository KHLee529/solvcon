#!/bin/bash
#
# This script is a prototype to create a self-contained macOS .app bundle for
# solvcon from a devenv flavor, package it into a DMG file, and verify both are
# hermetic. It is the devenv counterpart of bundle-with-homebrew.sh. The
# dependencies come from the active devenv flavor ($DEVENVPREFIX):
#
#   - Python: python-build-standalone (not a macOS framework build), installed
#     in the traditional prefix layout.
#   - Qt: aqt-installed Qt merged into the prefix.
#   - PySide6, shiboken6, numpy, matplotlib: pip packages in the prefix.
#
# It employs macdeployqt, otool, and install_name_tool to process the binaries,
# and ad-hoc codesign to reseal them.
#
# !! WARNING !!
# This is a prototype. It writes under build/ and, with `bundle`, edits the
# copies of the binaries inside the .app only. It never modifies the flavor.
#
# Usage:
#   devenv use <flavor>
#   export CMAKE_PREFIX_PATH=$DEVENVPREFIX
#   ./contrib/bundle/bundle-with-devenv.sh check
#   ./contrib/bundle/bundle-with-devenv.sh bundle [--skip-build]
#                                                 [--skip-check]
#                                                 [--dry-run]
#                                                 [--output DIR]
#   ./contrib/bundle/bundle-with-devenv.sh verify path/to/pilot.dmg
#
#   --skip-build   Skip `make pilot` and use the existing build output.
#   --skip-check   Skip the bundle/DMG verification phase.
#   --dry-run      Check the environment and print the plan; change nothing.
#   --output DIR   Write pilot.dmg into DIR (default: build/).
#
# The DMG holds pilot.app and a shortcut to /Applications. The icons are placed
# with the app on the left and Applications on the right by driving Finder
# through AppleScript, which needs the Automation permission and a desktop
# session. It is best effort; set BUNDLE_DMG_LAYOUT=0 to skip the placement.
#
# Layout of the Python runtime inside the bundle:
#   Contents/Frameworks/libpython<X.Y>.dylib   found through @rpath
#   Contents/lib/python<X.Y>/                   standard library
#   Contents/lib/python<X.Y>/site-packages/     pip packages and solvcon
# The embedded interpreter is started with the default configuration, so
# CPython locates its prefix by walking up from Contents/MacOS/pilot until it
# finds lib/python<X.Y>/os.py, which resolves to Contents/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$BUNDLE_REPO_ROOT"

MIN_LOADS=${MIN_LOADS:-50}
BUNDLE_BUILD_PATH=${BUNDLE_BUILD_PATH:-build/relbundle}

PREFIX="${DEVENVPREFIX:-}"
[[ "$PREFIX" == "/dev/null" ]] && PREFIX=""

# Paths that must not survive in the bundle: Homebrew, the system local prefix,
# any devenv flavor, and the active prefix itself. The anchored form is for
# load commands and rpaths, the free form is for dyld traces.
PREFIX_ESC=""
if [[ -n "$PREFIX" ]]; then
    PREFIX_ESC=$(printf '%s' "$PREFIX" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
fi
HOST_ANY_RE='/opt/homebrew|/usr/local|/devenv/flavors/'
[[ -n "$PREFIX_ESC" ]] && HOST_ANY_RE="${HOST_ANY_RE}|${PREFIX_ESC}"
HOST_PREFIX_RE="^(${HOST_ANY_RE})"
# An absolute dependency that belongs to the flavor and must be vendored.
FLAVOR_PATH_RE='^(/devenv/flavors/|.*/devenv/flavors/)'
[[ -n "$PREFIX_ESC" ]] && FLAVOR_PATH_RE="^(${PREFIX_ESC}|.*/devenv/flavors/)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage:
  contrib/bundle/bundle-with-devenv.sh check
  contrib/bundle/bundle-with-devenv.sh bundle [--skip-build] [--skip-check] [--dry-run] [--output DIR]
  contrib/bundle/bundle-with-devenv.sh verify path/to/pilot.dmg
  contrib/bundle/bundle-with-devenv.sh all [--skip-build] [--skip-check] [--dry-run] [--output DIR]

Subcommands:
  check    Check the active devenv flavor for bundle dependencies.
  bundle   Build/package pilot.app and pilot.dmg from the devenv flavor.
  verify   Verify a generated release DMG artifact.
  all      Run check and then bundle. (No verify.)
EOF
}

note() { printf '==> %s\n' "$*"; }
ok() { printf 'OK    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; return 1; }

require_macos() {
    [[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required for macOS bundle release"
}

setup_hint() {
    cat >&2 <<'EOF'

Activate a flavor that carries the dependencies, then retry:
  devenv use <flavor>
  export CMAKE_PREFIX_PATH=$DEVENVPREFIX
EOF
}

require_command() {
    local cmd="$1" hint="${2:-}"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd: $(command -v "$cmd")"
    else
        fail "$cmd: not found${hint:+ ($hint)}"
    fi
}

# Resolve a command and require it to live under the active prefix.
require_in_prefix() {
    local cmd="$1" path
    path=$(command -v "$cmd" 2>/dev/null || true)
    if [[ -n "$path" && "$path" == "$PREFIX"/* ]]; then
        ok "$cmd is under the flavor prefix: $path"
    else
        fail "$cmd is not from the flavor prefix (${path:-not found}; expected under $PREFIX)"
    fi
}

python_module_check() {
    local module="$1" hint="${2:-}" out
    out=$(mktemp -t solvcon-bundle-pycheck)
    if python3 - "$module" <<'PY' >"$out" 2>&1
import importlib
import sys
module = sys.argv[1]
try:
    mod = importlib.import_module(module)
except Exception as e:
    print(f"{type(e).__name__}: {e}")
    raise SystemExit(1)
else:
    print(getattr(mod, "__file__", "built-in"))
PY
    then
        ok "python module $module: $(cat "$out")"
        rm -f "$out"
    else
        cat "$out" >&2 || true
        rm -f "$out"
        fail "python module $module: missing${hint:+ ($hint)}"
    fi
}

# The embedded interpreter needs the shared libpython. A framework build is not
# expected: python-build-standalone installs libpython<X.Y>.dylib in lib/.
python_dylib_check() {
    local ver path
    ver=$(python3 -c "import sys; print('%d.%d' % sys.version_info[:2])")
    path="$PREFIX/lib/libpython${ver}.dylib"
    [[ -f "$path" ]] || { echo "Python dylib not found: $path"; return 1; }
    [[ -f "$PREFIX/lib/python${ver}/os.py" ]] || \
        { echo "Python stdlib not found: $PREFIX/lib/python${ver}"; return 1; }
    echo "$path"
}

check_pybind11_cmake() {
    local config_dir
    if command -v pybind11-config >/dev/null 2>&1; then
        config_dir=$(pybind11-config --cmakedir 2>/dev/null || true)
        if [[ -n "$config_dir" && -f "$config_dir/pybind11Config.cmake" ]]; then
            ok "pybind11 CMake config: $config_dir/pybind11Config.cmake"
            return 0
        fi
    fi
    fail "pybind11 CMake config: not found (python3 -m pip install pybind11)"
}

check_deps() {
    local dylib_path failed=0 qt_ver pyside_ver
    require_macos

    if [[ -z "$PREFIX" ]]; then
        fail "no active devenv flavor: DEVENVPREFIX is not set" || true
        setup_hint
        exit 1
    fi
    ok "flavor prefix: $PREFIX"

    for cmd in cmake make python3 macdeployqt qtpaths otool \
        install_name_tool codesign hdiutil rsync shasum; do
        require_command "$cmd" || failed=1
    done

    require_in_prefix python3 || failed=1
    require_in_prefix macdeployqt || failed=1
    require_in_prefix qtpaths || failed=1

    if dylib_path=$(python_dylib_check 2>&1); then
        ok "Python shared library: $dylib_path"
    else
        fail "$dylib_path" || failed=1
    fi

    check_pybind11_cmake || failed=1
    python_module_check numpy "python3 -m pip install numpy" || failed=1
    python_module_check PySide6 "python3 -m pip install pyside6" || failed=1
    python_module_check shiboken6 "python3 -m pip install shiboken6" || failed=1
    python_module_check shiboken6_generator \
        "python3 -m pip install shiboken6-generator" || failed=1
    python_module_check matplotlib "python3 -m pip install matplotlib" || failed=1

    qt_ver=$(qtpaths --query QT_VERSION 2>/dev/null || true)
    pyside_ver=$(python3 -c "import PySide6; print(PySide6.__version__)" 2>/dev/null || true)
    if [[ -n "$qt_ver" && "$qt_ver" == "$pyside_ver" ]]; then
        ok "Qt $qt_ver matches PySide6 $pyside_ver"
    else
        fail "Qt (${qt_ver:-unknown}) and PySide6 (${pyside_ver:-unknown}) versions differ" || failed=1
    fi

    if [[ $failed -ne 0 ]]; then
        setup_hint
        exit 1
    fi
}

# Active Python's "X.Y" version string.
bundle_pyver() {
    python3 -c "import sys; print('%d.%d' % sys.version_info[:2])"
}

# Print every Mach-O under $1, NUL-delimited: standalone dylibs, .so
# extensions, MacOS/ binaries, and the main binary of every nested framework.
# Framework binaries cannot be matched by file mode, because the packages ship
# them as 0644, so synthesise the canonical path (Versions/<v>/<name>)
# explicitly.
list_macho() {
    find "$1" -name '*.framework' -type d -print0 | \
        while IFS= read -r -d '' fw; do
            local nm ver bin
            nm=$(basename "$fw" .framework)
            for ver in "$fw"/Versions/*; do
                [[ -d "$ver" && ! -L "$ver" ]] || continue
                bin="$ver/$nm"
                [[ -f "$bin" ]] && printf '%s\0' "$bin"
            done
        done
    find "$1" -type f \( -name '*.dylib' -o -name '*.so' -o -path '*/MacOS/*' \) -print0
}

# Print every LC_RPATH entry of the Mach-O at $1, one per line.  `otool -L`
# does not list these, so we parse `otool -l`.  The entry in the `otool -l`
# output looks like:
# ```
# Load command 33
#           cmd LC_RPATH
#       cmdsize 96
#          path /path/to/PySide6 (offset 12)
# ```
# The parsed result is:
# ```
# /path/to/PySide6
# ```
binary_rpaths() {
    otool -l "$1" 2>/dev/null | awk '
        /^[[:space:]]*cmd / { c = 0 }
        /cmd LC_RPATH/      { c = 1; next }
        c && $1 == "path"   { print $2; c = 0 }
    '
}

# Verify the .app under $1 contains no surviving reference to the flavor or
# Homebrew, in both LC_LOAD_DYLIB-style commands (visible via otool -L) and
# LC_RPATH search paths. Print offenders. Return 0 if clean and 1 otherwise.
check_self_contained() {
    local total=0 bad=0 f load_refs rpath_refs
    while IFS= read -r -d '' f; do
        total=$((total+1))
        load_refs=$(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' \
            | grep -E "$HOST_PREFIX_RE" || true)
        rpath_refs=$(binary_rpaths "$f" | grep -E "$HOST_PREFIX_RE" || true)
        if [[ -n "$load_refs" || -n "$rpath_refs" ]]; then
            bad=$((bad+1))
            echo "    BAD: $f"
            [[ -n "$load_refs" ]] && echo "$load_refs" | sed 's/^/        load:  /'
            [[ -n "$rpath_refs" ]] && echo "$rpath_refs" | sed 's/^/        rpath: /'
        fi
    done < <(list_macho "$1")
    if [[ $bad -eq 0 ]]; then
        echo "    OK: $total Mach-O files, none reference a devenv flavor, /opt/homebrew or /usr/local"
        return 0
    fi
    echo "ERROR: $bad of $total Mach-O files still reference host prefixes" >&2
    return 1
}

verify_app_structure() {
    local app="$1" bin
    [[ -d "$app" ]] || fail "app not found: $app"
    [[ -f "$app/Contents/Info.plist" ]] || fail "Info.plist not found"
    bin="$app/Contents/MacOS/$(basename "$app" .app)"
    [[ -x "$bin" ]] || fail "main binary not executable: $bin"
    [[ -d "$app/Contents/Frameworks" ]] || fail "Contents/Frameworks not found"
    [[ -d "$app/Contents/Resources" ]] || fail "Contents/Resources not found"
    file "$bin"
}

runtime_import_check() {
    local bin="$1"
    env -i HOME="${HOME:-/}" USER="${USER:-nobody}" \
        PATH=/usr/bin:/bin TERM="${TERM:-xterm}" \
        "$bin" --mode=python -c \
        "import matplotlib"
}

smoke_launch_verify() {
    local bin="$1" trace="$2" pid elapsed=0 loaded
    : > "$trace"
    env -i HOME="${HOME:-/}" USER="${USER:-nobody}" \
        PATH=/usr/bin:/bin TERM="${TERM:-xterm}" \
        DYLD_PRINT_LIBRARIES=1 \
        "$bin" >/dev/null 2>"$trace" &
    pid=$!
    while [[ $elapsed -lt 15 ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
        loaded=$(grep -c '^dyld\[' "$trace" 2>/dev/null || true)
        [[ ${loaded:-0} -ge $MIN_LOADS ]] && break
    done
    # Loading libraries is not enough: pilot can abort right after, as it does
    # when the Qt platform plugin is missing. It must still be running after
    # the settle time.
    local settle=0 early_exit=0
    while [[ $settle -lt ${SMOKE_SETTLE:-5} ]]; do
        kill -0 "$pid" 2>/dev/null || { early_exit=1; break; }
        sleep 1
        settle=$((settle + 1))
    done
    kill -0 "$pid" 2>/dev/null || early_exit=1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    if [[ $early_exit -eq 1 ]]; then
        echo "ERROR: pilot exited within ${SMOKE_SETTLE:-5}s of loading its libraries:" >&2
        grep -v '^dyld\[' "$trace" | head -20 | sed 's/^/    /' >&2
        return 1
    fi

    loaded=$(grep -c '^dyld\[' "$trace" 2>/dev/null || true)
    if [[ $loaded -lt $MIN_LOADS ]]; then
        echo "ERROR: pilot loaded only $loaded libraries; did it crash early?" >&2
        sed -n '1,80p' "$trace" >&2
        return 1
    fi
    if grep -E '^dyld\[' "$trace" | grep -E "$HOST_ANY_RE" >/dev/null; then
        echo "ERROR: smoke launch loaded libraries from host package prefixes:" >&2
        grep -E '^dyld\[' "$trace" | grep -E "$HOST_ANY_RE" | head -20 >&2
        return 1
    fi
    echo "    OK: $loaded libraries loaded, none from host package prefixes"
}

VERIFY_MNT=""
VERIFY_TMP=""
VERIFY_TRACE=""
VERIFY_MARKER=""
cleanup_verify() {
    [[ -n "${VERIFY_MNT:-}" ]] && hdiutil detach -quiet "$VERIFY_MNT" >/dev/null 2>&1 || true
    [[ -n "${VERIFY_TMP:-}" ]] && rm -rf "$VERIFY_TMP"
    [[ -n "${VERIFY_TRACE:-}" ]] && rm -f "$VERIFY_TRACE"
    [[ -n "${VERIFY_MARKER:-}" ]] && rm -f "$VERIFY_MARKER"
}

verify_dmg() {
    local dmg="$1" mnt tmp trace marker app bin copied_app
    require_macos
    [[ -f "$dmg" ]] || fail "release artifact not found: $dmg"

    note "Release artifact"
    ls -lh "$dmg"
    shasum -a 256 "$dmg"
    hdiutil imageinfo "$dmg" >/dev/null

    VERIFY_MNT=$(mktemp -d -t solvcon-release-dmg)
    VERIFY_TMP=$(mktemp -d -t solvcon-release-app)
    VERIFY_TRACE=$(mktemp -t solvcon-release-dyld)
    VERIFY_MARKER=$(mktemp -t solvcon-release-marker)
    mnt="$VERIFY_MNT"
    tmp="$VERIFY_TMP"
    trace="$VERIFY_TRACE"
    marker="$VERIFY_MARKER"
    trap cleanup_verify EXIT

    note "Mounting DMG"
    hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null
    app=$(find "$mnt" -maxdepth 2 -name '*.app' -type d -print -quit)
    [[ -n "$app" ]] || fail "no .app found in $dmg"
    bin="$app/Contents/MacOS/$(basename "$app" .app)"

    note "Checking mounted app structure"
    verify_app_structure "$app"

    note "Checking code signature before launch"
    codesign --verify --deep --strict "$app"
    spctl --assess --type execute --verbose=4 "$app" 2>&1 || \
        echo "    warning: spctl rejected this app (expected for ad-hoc signed prototype builds)"

    note "Static scan for host package paths"
    check_self_contained "$app"

    note "Runtime import check from a writable app copy"
    cp -R "$app" "$tmp/"
    copied_app="$tmp/$(basename "$app")"
    codesign --verify --deep --strict "$copied_app"
    touch "$marker"
    runtime_import_check "$copied_app/Contents/MacOS/$(basename "$copied_app" .app)"
    if find "$copied_app" -name '*.pyc' -newer "$marker" -print -quit | grep -q .; then
        echo "ERROR: runtime import wrote Python bytecode into the signed app bundle:" >&2
        find "$copied_app" -name '*.pyc' -newer "$marker" -print | sed -n '1,20p' >&2
        return 1
    fi
    codesign --verify --deep --strict "$copied_app"

    note "Smoke launch from mounted DMG"
    smoke_launch_verify "$bin" "$trace"

    note "Release artifact verification passed"
}

COMMAND=bundle
if [[ $# -gt 0 ]]; then
    case "$1" in
        check|bundle|verify|all)
            COMMAND="$1"
            shift
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
    esac
fi

VERIFY_ARTIFACT=""
case "$COMMAND" in
    check)
        [[ $# -eq 0 ]] || { usage >&2; exit 2; }
        ;;
    verify)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        VERIFY_ARTIFACT="$1"
        shift
        ;;
esac

SKIP_BUILD=0
SKIP_CHECK=0
DRY_RUN=0
OUTPUT_DIR="$BUNDLE_REPO_ROOT/build"

if [[ "$COMMAND" == "bundle" || "$COMMAND" == "all" ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-build) SKIP_BUILD=1    ; shift ;;
            --skip-check) SKIP_CHECK=1    ; shift ;;
            --dry-run)    DRY_RUN=1       ; shift ;;
            --output)
                [[ $# -ge 2 ]] || { echo "Missing argument for --output" >&2; usage >&2; exit 2; }
                OUTPUT_DIR="$2"
                shift 2
                ;;
            *) echo "Unknown option: $1" >&2 ; usage >&2 ; exit 1 ;;
        esac
    done
elif [[ $# -gt 0 ]]; then
    usage >&2
    exit 2
fi

if [[ "$COMMAND" == "all" ]]; then
    check_deps
fi

# Record the starting time of the script and the first step. SECONDS is bash's
# built-in elapsed-second counter.
T_SCRIPT=$SECONDS
T_STEP=$T_SCRIPT

# Single cleanup hook for every temp resource the script creates. Each
# variable is initialised empty here and populated lazily (in later steps).
# The trap is set once. Any later step can register a temp file or DMG mount
# without juggling its own trap.
CLOSURE_TMP=""
TRACE=""
DMG_MOUNT=""
DMG_STAGE=""
DMG_RW=""
LAYOUT_MNT=""
cleanup() {
    [[ -n "$CLOSURE_TMP" ]] && rm -rf "$CLOSURE_TMP"
    [[ -n "$TRACE" ]] && rm -f "$TRACE"
    if [[ -n "$LAYOUT_MNT" ]]; then
        hdiutil detach -quiet "$LAYOUT_MNT" >/dev/null 2>&1 \
            || hdiutil detach -force -quiet "$LAYOUT_MNT" >/dev/null 2>&1 \
            || true
    fi
    [[ -n "$DMG_STAGE" ]] && rm -rf "$DMG_STAGE"
    [[ -n "$DMG_RW" ]] && rm -f "$DMG_RW"
    if [[ -n "$DMG_MOUNT" ]]; then
        hdiutil detach -quiet "$DMG_MOUNT" >/dev/null 2>&1 \
            || hdiutil detach -force -quiet "$DMG_MOUNT" >/dev/null 2>&1 \
            || true
        rmdir "$DMG_MOUNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

case "$COMMAND" in
    check)
        check_deps
        exit 0
        ;;
    verify)
        verify_dmg "$VERIFY_ARTIFACT"
        exit 0
        ;;
esac

# `bundle` needs the same flavor; `all` has already checked it.
if [[ "$COMMAND" == "bundle" ]]; then
    [[ -n "$PREFIX" ]] || { echo "ERROR: no active devenv flavor (DEVENVPREFIX is not set)" >&2; setup_hint; exit 1; }
fi

# ---------------------------------------------------------------------------
# Derive paths
# ---------------------------------------------------------------------------

PY_VER=$(bundle_pyver)
BUILD_PATH="$BUNDLE_BUILD_PATH"
APP="$BUNDLE_REPO_ROOT/$BUILD_PATH/cpp/binary/pilot/pilot.app"
BINARY="$APP/Contents/MacOS/pilot"
FW_DIR="$APP/Contents/Frameworks"
PY_DYLIB="$PREFIX/lib/libpython${PY_VER}.dylib"
PY_STDLIB="$PREFIX/lib/python${PY_VER}"
BUNDLED_LIB="$APP/Contents/lib/python${PY_VER}"
BUNDLED_SITE="$BUNDLED_LIB/site-packages"

# Every site-packages dir the embedded interpreter would search, expanded
# through .pth files. macOS bash 3.2 has no mapfile; read into an array with a
# loop.
SITE_DIRS=()
while IFS= read -r line; do
    SITE_DIRS+=("$line")
done < <(python3 -c "
import site, os
seen, out = set(), []
def add(p):
    p = os.path.realpath(p)
    if p in seen or not os.path.isdir(p):
        return
    seen.add(p); out.append(p)
    for f in sorted(os.listdir(p)):
        if not f.endswith('.pth'):
            continue
        try:
            with open(os.path.join(p, f)) as fp:
                for line in fp:
                    line = line.strip()
                    if line and not line.startswith(('#', 'import ')):
                        add(line if os.path.isabs(line) else os.path.join(p, line))
        except OSError:
            pass
for d in site.getsitepackages():
    add(d)
print('\n'.join(out))
")

# Resolve the closure of Python packages pilot actually imports, so Step 4
# copies only those, not the whole site-packages of the flavor. Override seeds
# via BUNDLE_SEED_MODULES; force-add via BUNDLE_EXTRA_PACKAGES (for lazy /
# runtime imports the probe cannot observe, e.g. matplotlib backends loaded on
# first render). Failed seed imports go to stderr so a partial closure is
# visible instead of silently shipping a broken bundle.
WANTED_PATHS=()
if [[ $DRY_RUN -eq 0 ]]; then
while IFS= read -r line; do
    [[ -n "$line" ]] && WANTED_PATHS+=("$line")
done < <(python3 -c "
import importlib, os, sys
seeds = os.environ.get('BUNDLE_SEED_MODULES',
    'PySide6.QtCore,PySide6.QtWidgets,PySide6.QtGui,PySide6.QtSvg,numpy,'
    'matplotlib,dateutil.relativedelta,dateutil.tz,dateutil.parser,'
    'jsonschema').split(',')
default_extras = ('fontTools,PIL,kiwisolver,pyparsing,cycler,contourpy,'
    'packaging,dateutil,six,mpl_toolkits,jsonschema,'
    'jsonschema_specifications,referencing,rpds,attr,attrs,'
    'typing_extensions')
extras = os.environ.get('BUNDLE_EXTRA_PACKAGES', default_extras).split(',')
for m in seeds + extras:
    m = m.strip()
    if not m: continue
    try: importlib.import_module(m)
    except Exception as e:
        sys.stderr.write('    WARN: seed import %s failed: %s\n' % (m, e))
out = set()
for name, mod in list(sys.modules.items()):
    if mod is None or '.' in name: continue
    p = getattr(mod, '__path__', None)
    f = getattr(mod, '__file__', None) or ''
    if p:
        for d in p:
            if 'site-packages' in d:
                out.add(os.path.realpath(d)); break
    elif 'site-packages' in f:
        out.add(os.path.realpath(f))
print('\n'.join(sorted(out)))
")
fi

echo "==> Flavor     : $PREFIX"
echo "==> Build path : $BUILD_PATH"
echo "==> App bundle : $APP"
echo "==> libpython  : $PY_DYLIB"
echo "==> stdlib     : $PY_STDLIB"
echo "==> bundled at : $BUNDLED_LIB"
for d in "${SITE_DIRS[@]}"; do
    echo "==> site-pkgs  : $d"
done

[[ -f "$PY_DYLIB" ]] || { echo "ERROR: Python dylib not found at $PY_DYLIB" >&2; exit 1; }
[[ -f "$PY_STDLIB/os.py" ]] || { echo "ERROR: Python stdlib not found at $PY_STDLIB" >&2; exit 1; }

if [[ $DRY_RUN -ne 0 ]]; then
    echo ""
    echo "DRY RUN: nothing was changed. The bundle step would:"
    echo "  1. rm -rf $APP and run: make pilot BUILD_PATH=$BUILD_PATH"
    echo "  2. macdeployqt \"$APP\""
    echo "  3. copy libpython${PY_VER}.dylib into Contents/Frameworks and the stdlib into Contents/lib"
    echo "  4. copy the imported site-packages closure into $BUNDLED_SITE"
    echo "  5. copy solvcon (without _solvcon*.so) and pre-compile bytecode"
    echo "  6. vendor flavor dependencies into Contents/Frameworks, rewrite load commands and rpaths"
    echo "  7. ad-hoc codesign, 8. create $OUTPUT_DIR/pilot.dmg, 9. verify hermeticity"
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 1: Build pilot
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
if [[ $SKIP_BUILD -eq 0 ]]; then
    # macdeployqt cannot redeploy on top of an existing .app: it
    # short-circuits but its later codesign pass still walks paths the
    # (skipped) deploy step would have populated, failing nested signing.
    # `make pilot` only re-links the binary; remove the .app so the
    # build produces a virgin one each run.
    rm -rf "$APP"
    echo "==> make pilot BUILD_PATH=$BUILD_PATH"
    CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:-$PREFIX}" make pilot BUILD_PATH="$BUILD_PATH"
fi

[[ -f "$BINARY" ]] || { echo "ERROR: pilot binary not found at $BINARY" >&2; exit 1; }
echo "    [Step 1 (Build pilot): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 2: Deploy Qt
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> macdeployqt (bundles Qt frameworks, plugins, transitive dylibs)"
# The pilot binary carries the flavor's lib/ as an rpath, which is how
# macdeployqt finds Qt. libpython and libpyside6 are not Qt, so macdeployqt may
# warn about them; Step 3 and Step 6 bundle them ourselves.
macdeployqt "$APP" -verbose=1 -libpath="$PREFIX/lib"

# macdeployqt puts the plugins in Contents/PlugIns, but this Qt does not add
# that directory to its search path: it reads no Contents/Resources/qt.conf and
# only looks beside the executable, so pilot aborts with "Could not find the Qt
# platform plugin cocoa". A qt.conf beside the executable would fix it but
# breaks the code signature, because Contents/MacOS is sealed as code. A
# symlink to each plugin directory signs cleanly and is found.
echo "==> Linking Qt plugin directories next to the executable"
for plugin_dir in "$APP"/Contents/PlugIns/*/; do
    [[ -d "$plugin_dir" ]] || continue
    plugin_name=$(basename "$plugin_dir")
    ln -sfn "../PlugIns/$plugin_name" "$APP/Contents/MacOS/$plugin_name"
    echo "    MacOS/$plugin_name -> ../PlugIns/$plugin_name"
done
echo "    [Step 2 (Deploy Qt): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 3: Bundle the Python runtime
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> Bundling libpython and the standard library"
mkdir -p "$FW_DIR" "$BUNDLED_LIB"

# pilot already links @rpath/libpython<X.Y>.dylib and carries
# @executable_path/../Frameworks as its first rpath, so the dylib needs no
# rewrite of the main binary.
cp -L "$PY_DYLIB" "$FW_DIR/"
chmod u+w "$FW_DIR/$(basename "$PY_DYLIB")"
echo "    libpython -> $FW_DIR/$(basename "$PY_DYLIB")"

# The standard library, minus what pilot never uses. site-packages is filled
# in Step 4. The CPython test suite and the Tk and IDLE trees are the bulk.
rsync -a \
    --exclude '__pycache__' --exclude 'site-packages' --exclude 'test' \
    --exclude 'tkinter' --exclude 'idlelib' --exclude 'turtledemo' \
    --exclude 'ensurepip' --exclude 'config-*' \
    "$PY_STDLIB/" "$BUNDLED_LIB/"
mkdir -p "$BUNDLED_SITE"
echo "    stdlib -> $BUNDLED_LIB"
echo "    [Step 3 (Bundle Python runtime): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 4: Bundle site-packages
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> Copying Python packages into bundled site-packages"
# Copy the closure resolved above (dir => rsync tree, file => cp).
# -L dereferences symlinks. Falls back to every SITE_DIR if the probe
# failed, so the script still runs when import discovery breaks.
if [[ ${#WANTED_PATHS[@]} -gt 0 ]]; then
    echo "    closure: ${#WANTED_PATHS[@]} entries (override via BUNDLE_SEED_MODULES / BUNDLE_EXTRA_PACKAGES)"
    for path in "${WANTED_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            rsync -aL --exclude '__pycache__' --exclude '*.pth' \
                "$path" "$BUNDLED_SITE/"
        elif [[ -f "$path" ]]; then
            cp -L "$path" "$BUNDLED_SITE/"
        fi
    done
else
    echo "    WARNING: import-closure discovery failed; copying full SITE_DIRS"
    for SITE in "${SITE_DIRS[@]}"; do
        rsync -aL --exclude '__pycache__' --exclude '*.pth' \
            "$SITE/" "$BUNDLED_SITE/"
    done
fi
# The PySide6 wheel carries every Qt binding plus qml, plugins, translations,
# and deployment scripts. Its Qt frameworks are not in the flavor (the nested
# copies are removed so PySide6 shares the main Qt), so a binding for a module
# pilot does not use could never load. Keep only the bindings pilot imports.
# Override the list with BUNDLE_PYSIDE_MODULES.
prune_pyside6() {
    local pyside="$BUNDLED_SITE/PySide6" f name mod removed=0
    local keep="${BUNDLE_PYSIDE_MODULES:-QtCore,QtGui,QtWidgets,QtSvg}"
    [[ -d "$pyside" ]] || return 0
    for f in "$pyside"/Qt*.abi3.so "$pyside"/Qt*.pyi; do
        [[ -e "$f" ]] || continue
        name=$(basename "$f")
        mod=${name%%.*}
        case ",$keep," in
            *",$mod,"*) ;;
            *) rm -f "$f"; removed=$((removed + 1)) ;;
        esac
    done
    rm -rf "$pyside/Qt" "$pyside/scripts" "$pyside/include" \
        "$pyside/typesystems" "$pyside/glue" "$pyside/examples"
    rm -f "$pyside"/libpyside6qml*.dylib
    echo "    PySide6: kept $keep, removed $removed other binding file(s)"
}
prune_pyside6
echo "    [Step 4 (Bundle site-packages): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 5: Bundle solvcon
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> Copying solvcon package into bundled site-packages"
# Copy the solvcon Python package. Skip _solvcon*.so because the binary code is
# statically linked into pilot via PYBIND11_EMBEDDED_MODULE.
rsync -a --exclude '__pycache__' --exclude '_solvcon*.so' \
    "$BUNDLE_REPO_ROOT/solvcon" "$BUNDLED_SITE/"
echo "    solvcon -> $BUNDLED_SITE/solvcon"
echo "    [Step 5 (Bundle solvcon): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 5.5: Pre-compile bundled bytecode
#
# Ship .pyc alongside .py so the embedded interpreter finds a valid cache on
# import and never writes back into the signed bundle (a runtime write would
# mutate the sealed contents and break the code signature). The flavor's
# python3 has the same version as the embedded one, so the .pyc magic matches.
# unchecked-hash makes the cache trusted unconditionally, sidestepping mtime
# drift from rsync/DMG creation that would otherwise let the default timestamp
# mode falsely invalidate the cache at runtime.
#
# `|| true` keeps a stray uncompilable file in a package's own tests/ from
# killing the build; those files are not imported at runtime. The trailing
# sanity check fails loudly if compileall produced nothing at all.
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> Pre-compiling bundled Python modules"
"$PREFIX/bin/python3" -m compileall -f \
    --invalidation-mode unchecked-hash -q \
    "$BUNDLED_LIB" || true
PYC_COUNT=$(find "$BUNDLED_LIB" -name '*.pyc' | wc -l | tr -d ' ')
[[ $PYC_COUNT -gt 0 ]] || \
    { echo "ERROR: compileall produced no .pyc files under $BUNDLED_LIB" >&2; exit 1; }
echo "    compiled $PYC_COUNT .pyc files"
echo "    [Step 5.5 (Pre-compile bytecode): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 6: Vendor the flavor's dependencies
#
# macdeployqt only follows Qt's load commands, so everything else (libpyside6,
# libshiboken6, Python extension modules and what they link) still resolves
# through the flavor at runtime. Walk every Mach-O in the bundle, copy missing
# flavor dylibs/frameworks into Contents/Frameworks/, rewrite absolute load
# commands to the bundled copy, and replace the flavor's LC_RPATH entries with
# @executable_path/../Frameworks.
# ---------------------------------------------------------------------------

# Copy one dylib named $1 into Contents/Frameworks/ from the first of the
# remaining arguments that exists. Returns 1 if none exists.
vendor_dylib() {
    local base="$1" cand
    shift
    for cand in "$@"; do
        if [[ -f "$cand" ]]; then
            cp -L "$cand" "$FW_DIR/$base" 2>/dev/null || return 1
            chmod u+w "$FW_DIR/$base"
            echo "$base" >> "$SEEN_DYLIB"
            echo "$FW_DIR/$base" >> "$QUEUE"
            return 0
        fi
    done
    return 1
}

# Copy the framework $1 into Contents/Frameworks/ from the directory $2.
vendor_framework() {
    local fw="$1" src="$2"
    [[ -d "$src" ]] || return 1
    mkdir -p "$FW_DIR/$fw.framework"
    rsync -a --copy-unsafe-links "$src/" "$FW_DIR/$fw.framework/" 2>/dev/null || return 1
    chmod -R u+w "$FW_DIR/$fw.framework"
    echo "$fw" >> "$SEEN_FW"
    list_macho "$FW_DIR/$fw.framework" | xargs -0 -n1 echo >> "$QUEUE"
}

warn_missing() {
    if ! grep -qxF "$1" "$SEEN_MISSING"; then
        echo "$1" >> "$SEEN_MISSING"
        echo "    WARN: could not resolve $1" >&2
    fi
}

# BFS-walk every Mach-O in the bundle: pop one, copy any missing flavor
# dependency into Contents/Frameworks/, enqueue what we just copied. Touching
# each file once keeps cost linear in bundle size. Sets the global SEEN_DYLIB /
# SEEN_FW indexes consumed by rewrite_load_commands below.
vendor_flavor_deps() {
    CLOSURE_TMP=$(mktemp -d)
    QUEUE="$CLOSURE_TMP/queue"
    SEEN_BIN="$CLOSURE_TMP/seen_bin"
    SEEN_DYLIB="$CLOSURE_TMP/seen_dylib"
    SEEN_FW="$CLOSURE_TMP/seen_fw"
    SEEN_MISSING="$CLOSURE_TMP/seen_missing"
    touch "$QUEUE" "$SEEN_BIN" "$SEEN_DYLIB" "$SEEN_FW" "$SEEN_MISSING"

    # Skip what's already in Contents/Frameworks/.
    local f
    for f in "$FW_DIR"/*.dylib; do
        [[ -f "$f" ]] && basename "$f" >> "$SEEN_DYLIB"
    done
    for f in "$FW_DIR"/*.framework; do
        [[ -d "$f" ]] && basename "$f" .framework >> "$SEEN_FW"
    done

    list_macho "$APP" | xargs -0 -n1 echo >> "$QUEUE"

    local BIN OLD fw base name
    while [[ -s "$QUEUE" ]]; do
        BIN=$(head -n 1 "$QUEUE")
        sed -i '' '1d' "$QUEUE"
        grep -qxF "$BIN" "$SEEN_BIN" && continue
        echo "$BIN" >> "$SEEN_BIN"
        while IFS= read -r OLD; do
            case "$OLD" in
            */*.framework/Versions/*/*)
                # An absolute path into a flavor, or an @rpath reference.
                if [[ "$OLD" == @rpath/* ]]; then
                    name=${OLD#@rpath/}
                    fw=${name%%.framework*}
                    grep -qxF "$fw" "$SEEN_FW" && continue
                    vendor_framework "$fw" "$PREFIX/lib/$fw.framework" || warn_missing "$OLD"
                elif [[ "$OLD" =~ $FLAVOR_PATH_RE ]]; then
                    fw=${OLD##*/}
                    grep -qxF "$fw" "$SEEN_FW" && continue
                    vendor_framework "$fw" "${OLD%%/Versions/*}" || warn_missing "$OLD"
                fi
                ;;
            @rpath/lib*.dylib|@loader_path/lib*.dylib)
                # Sibling references such as @rpath/libpyside6.abi3.6.12.dylib.
                base=${OLD##*/}
                grep -qxF "$base" "$SEEN_DYLIB" && continue
                # A sibling of the loader (for example Pillow's .dylibs/) is
                # already in place and needs no vendoring.
                [[ "$OLD" == @loader_path/* && -f "$(dirname "$BIN")/$base" ]] && continue
                vendor_dylib "$base" \
                    "$PREFIX/lib/$base" \
                    "$PREFIX/lib/python${PY_VER}/site-packages/PySide6/$base" \
                    "$PREFIX/lib/python${PY_VER}/site-packages/shiboken6/$base" \
                    || warn_missing "$OLD"
                ;;
            /*)
                if [[ "$OLD" =~ $FLAVOR_PATH_RE ]]; then
                    base=${OLD##*/}
                    grep -qxF "$base" "$SEEN_DYLIB" && continue
                    vendor_dylib "$base" "$OLD" || warn_missing "$OLD"
                fi
                ;;
            esac
        done < <(otool -L "$BIN" 2>/dev/null | awk 'NR>1 {print $1}')
    done

    echo "    bundled $(wc -l < "$SEEN_DYLIB" | tr -d ' ') dylibs and \
$(wc -l < "$SEEN_FW" | tr -d ' ') frameworks"
}

# Rewrite every absolute flavor reference whose target is now bundled (load
# commands and LC_ID_DYLIB). @rpath references are left alone: they resolve
# through the @executable_path/../Frameworks rpath that strip_flavor_rpaths
# installs. Reads SEEN_DYLIB / SEEN_FW populated by vendor_flavor_deps.
rewrite_load_commands() {
    # Surrounding spaces let bash do containment with the *" $tok "* glob.
    local INDEX FW_INDEX
    INDEX=" $(tr '\n' ' ' < "$SEEN_DYLIB")"
    FW_INDEX=" $(tr '\n' ' ' < "$SEEN_FW")"

    local BIN OLD fw ver base NEW
    while IFS= read -r -d '' BIN; do
        while IFS= read -r OLD; do
            [[ "$OLD" =~ $FLAVOR_PATH_RE ]] || continue
            case "$OLD" in
            */*.framework/Versions/*/*)
                fw=${OLD##*/}
                if [[ "$FW_INDEX" == *" $fw "* ]]; then
                    # Preserve the original version segment.
                    ver=${OLD#*.framework/Versions/}; ver=${ver%%/*}
                    NEW="@executable_path/../Frameworks/${fw}.framework/Versions/${ver}/${fw}"
                    install_name_tool -change "$OLD" "$NEW" "$BIN" 2>/dev/null || true
                fi
                ;;
            /*)
                base=${OLD##*/}
                if [[ "$INDEX" == *" $base "* ]]; then
                    NEW="@executable_path/../Frameworks/$base"
                    install_name_tool -change "$OLD" "$NEW" "$BIN" 2>/dev/null || true
                fi
                ;;
            esac
        done < <(otool -L "$BIN" 2>/dev/null | awk 'NR>1 {print $1}')
    done < <(list_macho "$APP")

    # A bundled dylib or framework whose own LC_ID_DYLIB still names a flavor
    # path is rewritten so dyld dedupes by install name.
    local f fw_path name vname bin_path VER id
    for f in "$FW_DIR"/*.dylib; do
        [[ -f "$f" ]] || continue
        id=$(otool -D "$f" 2>/dev/null | tail -n +2 | head -n 1)
        [[ "$id" =~ $FLAVOR_PATH_RE ]] || continue
        install_name_tool -id \
            "@executable_path/../Frameworks/$(basename "$f")" "$f" \
            2>/dev/null || true
    done
    for fw_path in "$FW_DIR"/*.framework; do
        [[ -d "$fw_path" ]] || continue
        name=$(basename "$fw_path" .framework)
        for VER in "$fw_path"/Versions/*; do
            [[ -d "$VER" && ! -L "$VER" ]] || continue
            bin_path="$VER/$name"
            [[ -f "$bin_path" ]] || continue
            id=$(otool -D "$bin_path" 2>/dev/null | tail -n +2 | head -n 1)
            [[ "$id" =~ $FLAVOR_PATH_RE ]] || continue
            vname=$(basename "$VER")
            install_name_tool -id \
                "@executable_path/../Frameworks/${name}.framework/Versions/${vname}/${name}" \
                "$bin_path" 2>/dev/null || true
        done
    done
}

# LC_RPATH is invisible to otool -L so the rewrite above missed it. A surviving
# flavor rpath silently falls back at runtime on the build machine and fails
# everywhere else. For each affected Mach-O: add @executable_path/../Frameworks
# (so bundled siblings stay reachable via @rpath/), then delete every flavor
# entry one at a time (install_name_tool removes one per call).
strip_flavor_rpaths() {
    local EP_RPATH='@executable_path/../Frameworks'
    local BIN flavor_rps rp
    while IFS= read -r -d '' BIN; do
        flavor_rps=$(binary_rpaths "$BIN" | grep -E "$HOST_PREFIX_RE" || true)
        [[ -z "$flavor_rps" ]] && continue
        if ! binary_rpaths "$BIN" | grep -qxF "$EP_RPATH"; then
            install_name_tool -add_rpath "$EP_RPATH" "$BIN" 2>/dev/null || true
        fi
        while IFS= read -r rp; do
            [[ -z "$rp" ]] && continue
            install_name_tool -delete_rpath "$rp" "$BIN" 2>/dev/null || true
        done <<< "$flavor_rps"
    done < <(list_macho "$APP")
}

# Drop any Mach-O still referencing the flavor after vendor + rewrite have run:
# typically Qt plugins pre-linked against libraries not present in the flavor.
# dyld would fail to load them anyway. Skips framework MAIN binaries since
# removing those breaks the framework structure; that case is better surfaced
# by the static check.
prune_unfixable_machos() {
    local count=0 BIN load_refs rpath_refs fname fwdir
    while IFS= read -r -d '' BIN; do
        # Skip path <NAME>.framework/Versions/<V>/<NAME>. Plugins and Python
        # C extensions nested deeper than that are not main binaries.
        case "$BIN" in
        *.framework/Versions/*)
            fname="${BIN##*/}"
            fwdir="${BIN%/Versions/*}"
            if [[ "${fwdir##*/}" == "${fname}.framework" ]]; then
                continue
            fi
            ;;
        esac
        load_refs=$(otool -L "$BIN" 2>/dev/null | tail -n +2 | awk '{print $1}' \
            | grep -E "$HOST_PREFIX_RE" || true)
        rpath_refs=$(binary_rpaths "$BIN" | grep -E "$HOST_PREFIX_RE" || true)
        if [[ -n "$load_refs" || -n "$rpath_refs" ]]; then
            rm -f "$BIN"
            echo "    WARN: pruned ${BIN#"$APP/"}" >&2
            count=$((count+1))
        fi
    done < <(list_macho "$APP")
    if [[ $count -gt 0 ]]; then
        # Stderr + WARN prefix: each pruned file is a feature pilot loses on
        # this host, even if startup smoke-launch still passes.
        echo "    WARN: pruned $count Mach-O file(s) with unresolvable flavor deps" >&2
    fi
}

# A PySide6 wheel ships a private copy of Qt under PySide6/Qt/lib. Its .abi3.so
# modules load that copy via @rpath; pilot's C++ binary loads Qt from
# Contents/Frameworks/. Two Qt instances in one process => duplicate Obj-C
# classes, separate global state, "QWidget: Must construct a QApplication"
# abort. A flavor that already removed the nested frameworks (the same fix the
# CI applies on macOS) has nothing to do here. Otherwise replace each
# duplicated nested framework with a relative symlink to the main bundle copy.
# Frameworks unique to PySide6 (QtCharts, ...) are left in place; their
# @rpath/QtCore... refs resolve through these symlinks too.
dedupe_pyside_qt() {
    local pyqt_lib count=0 nested name main rel
    pyqt_lib="$BUNDLED_SITE/PySide6/Qt/lib"
    [[ -d "$pyqt_lib" ]] || return 0
    # The link lives in PySide6/Qt/lib/; six levels up reach Contents/:
    # Qt, PySide6, site-packages, python<X.Y>, lib, Contents.
    rel='../../../../../..'
    for nested in "$pyqt_lib"/Qt*.framework; do
        [[ -d "$nested" && ! -L "$nested" ]] || continue
        name=$(basename "$nested" .framework)
        main="$FW_DIR/${name}.framework"
        [[ -d "$main" && ! -L "$main" ]] || continue
        rm -rf "$nested"
        ln -s "$rel/Frameworks/${name}.framework" "$nested"
        count=$((count+1))
    done
    if [[ $count -gt 0 ]]; then
        echo "    deduped $count PySide6/Qt/lib framework(s) into main Qt"
    else
        echo "    no duplicated Qt framework under PySide6/Qt/lib"
    fi
}

# Set PYTHONNOUSERSITE=1 in LSEnvironment so a Finder/open launch of pilot
# never adds ~/Library/Python/<X.Y>/lib/python/site-packages to sys.path,
# which on dev machines may carry a second PySide6 (and its Qt). Same
# dual-instance crash as dedupe_pyside_qt fixes for the in-bundle case.
inject_pythonnousersite() {
    local plist="$APP/Contents/Info.plist"
    [[ -f "$plist" ]] || { echo "    SKIP: no Info.plist at $plist" >&2; return 0; }
    # macdeployqt's Step 2 codesign locks Info.plist read-only; Step 7
    # re-locks it.
    chmod u+w "$plist"
    if /usr/libexec/PlistBuddy -c "Print :LSEnvironment:PYTHONNOUSERSITE" \
            "$plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c \
            "Set :LSEnvironment:PYTHONNOUSERSITE 1" "$plist" || {
            echo "    ERROR: failed to set LSEnvironment.PYTHONNOUSERSITE" >&2
            return 1
        }
    else
        # Dict may already exist; tolerate either way.
        /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$plist" \
            2>/dev/null || true
        /usr/libexec/PlistBuddy -c \
            "Add :LSEnvironment:PYTHONNOUSERSITE string 1" "$plist" || {
            echo "    ERROR: failed to add LSEnvironment.PYTHONNOUSERSITE" >&2
            return 1
        }
    fi
    echo "    Info.plist LSEnvironment.PYTHONNOUSERSITE = 1"
}

T_STEP=$SECONDS
echo "==> Vendoring flavor dependencies"
vendor_flavor_deps
echo "==> Redirecting absolute flavor load commands to bundled copies"
rewrite_load_commands
echo "==> Replacing flavor rpaths with @executable_path/../Frameworks"
strip_flavor_rpaths
echo "==> Pruning Mach-O files with unresolvable flavor deps"
prune_unfixable_machos
echo "==> Deduplicating PySide6's bundled Qt against the main bundle Qt"
dedupe_pyside_qt
echo "==> Setting PYTHONNOUSERSITE=1 in Info.plist"
inject_pythonnousersite
echo "    [Step 6 (Vendor flavor deps): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 7: Ad-hoc codesign
#
# Sign bottom-up. `codesign --deep` would skip files we added after the
# original signing so each nested artifact must be sealed first, in dependency
# order: dylibs/.so, then nested helper .apps, then frameworks, then the main
# binary and main .app.
# ---------------------------------------------------------------------------

# Sign every standalone dylib and .so under Contents/.
sign_inner_machos() {
    local BIN
    while IFS= read -r -d '' BIN; do
        codesign --force --sign - "$BIN" 2>/dev/null || true
    done < <(find "$APP/Contents" \( -name '*.dylib' -o -name '*.so' \) -print0)
}

# Sign nested helper apps (e.g. QtWebEngineCore's QtWebEngineProcess.app)
# before sealing their containing framework.  Reverse-sort by path
# length so the deepest .app signs first.
sign_helper_apps() {
    local INNER_APP
    find "$APP" -name '*.app' -type d -print | awk '{print length($0), $0}' | \
        sort -k1,1nr | cut -d' ' -f2- | while IFS= read -r INNER_APP; do
        [[ "$INNER_APP" == "$APP" ]] && continue
        rm -rf "$INNER_APP/Contents/_CodeSignature"
        codesign --force --sign - "$INNER_APP" 2>/dev/null || true
    done
}

# Re-seal each nested framework (Qt*.framework, ...).
# On macOS the framework version directory carries the signature.
sign_frameworks() {
    local FW VER
    for FW in "$FW_DIR"/*.framework; do
        [[ -d "$FW" ]] || continue
        for VER in "$FW"/Versions/*; do
            [[ -d "$VER" && ! -L "$VER" ]] || continue
            rm -rf "$VER/_CodeSignature"
            codesign --force --sign - "$VER" 2>/dev/null || true
        done
    done
}

# Sign the main binary, then the outer .app.
sign_main_app() {
    codesign --force --sign - "$BINARY"
    codesign --force --sign - "$APP"
}

T_STEP=$SECONDS
echo "==> Ad-hoc re-signing all bundled Mach-O files"
sign_inner_machos
sign_helper_apps
sign_frameworks
echo "==> Ad-hoc re-signing the app bundle"
sign_main_app
echo "    [Step 7 (Ad-hoc codesign): $((SECONDS - T_STEP))s]"

echo ""
echo "Bundle complete: $APP"

# ---------------------------------------------------------------------------
# Step 8: Package DMG
# ---------------------------------------------------------------------------

# Run a command and give up after $1 seconds. macOS has no timeout(1).
# Returns 124 on timeout, otherwise the command's own status.
run_with_timeout() {
    local secs="$1" pid elapsed=0 rc=0
    shift
    # A background job reads /dev/null unless told otherwise; <&0 keeps the
    # caller's stdin, which carries the AppleScript heredoc.
    "$@" <&0 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [[ $elapsed -ge $secs ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$pid" || rc=$?
    return $rc
}

# Lay the volume out as an installer: the app on the left and a shortcut to
# /Applications on the right, so the user drags from left to right. Finder
# stores the icon positions in the volume's .DS_Store, so the image has to be
# mounted writable and Finder driven through AppleScript. That needs the
# Automation permission for the terminal and a desktop session, so it is best
# effort: on failure the DMG still carries the Applications shortcut and only
# the placement is left to Finder. BUNDLE_DMG_LAYOUT=0 skips it.
layout_dmg_window() {
    local volname="$1" app_name="$2" mnt="$3"
    run_with_timeout 90 osascript - "$volname" "$app_name" <<'APPLESCRIPT'
on run argv
    set volName to item 1 of argv
    set appName to item 2 of argv
    tell application "Finder"
        tell disk volName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 120, 800, 520}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 104
            set position of item appName of container window to {160, 190}
            set position of item "Applications" of container window to {440, 190}
            close
            open
            update without registering applications
            delay 2
        end tell
    end tell
end run
APPLESCRIPT
}

# Package $1 (.app) as the compressed image $2. The image carries the app and
# a symlink named Applications that points at /Applications.
create_dmg() {
    local app="$1" dmg="$2" volname="${BUNDLE_DMG_VOLNAME:-solvcon Pilot}"
    local app_name size_mb rc=0
    app_name=$(basename "$app")

    DMG_STAGE=$(mktemp -d -t solvcon-dmg-stage)
    # ditto keeps the symlinks, modes and xattrs the code signature seals.
    ditto "$app" "$DMG_STAGE/$app_name"
    ln -s /Applications "$DMG_STAGE/Applications"

    # Leave room for the .DS_Store that Finder writes into the volume.
    size_mb=$(( $(du -sm "$DMG_STAGE" | cut -f1) + 64 ))
    DMG_RW="$(mktemp -u -t solvcon-dmg-rw).dmg"
    hdiutil create -volname "$volname" -srcfolder "$DMG_STAGE" \
        -fs HFS+ -format UDRW -size "${size_mb}m" -ov "$DMG_RW" >/dev/null

    if [[ "${BUNDLE_DMG_LAYOUT:-1}" != "0" ]]; then
        LAYOUT_MNT="/Volumes/$volname"
        if [[ -e "$LAYOUT_MNT" ]]; then
            echo "    WARN: $LAYOUT_MNT is already mounted; eject it to place the icons" >&2
            LAYOUT_MNT=""
        else
            hdiutil attach -readwrite -noverify -noautoopen \
                -mountpoint "$LAYOUT_MNT" "$DMG_RW" >/dev/null
            # Finder does not know a volume the instant it mounts; scripting
            # it before then is accepted and silently does nothing.
            sleep 3
            layout_dmg_window "$volname" "$app_name" "$LAYOUT_MNT" >/dev/null 2>&1 || rc=$?
            local waited=0
            while [[ ! -f "$LAYOUT_MNT/.DS_Store" && $waited -lt 10 ]]; do
                sleep 1
                waited=$((waited + 1))
            done
            if [[ $rc -eq 0 && -f "$LAYOUT_MNT/.DS_Store" ]]; then
                echo "    icon layout: $app_name on the left, Applications on the right"
            else
                echo "    WARN: could not place the icons (osascript status $rc);" \
                     "the DMG still has the Applications shortcut" >&2
            fi
            sync
            hdiutil detach -quiet "$LAYOUT_MNT" >/dev/null 2>&1 \
                || { sleep 2; hdiutil detach -force -quiet "$LAYOUT_MNT" >/dev/null; }
            LAYOUT_MNT=""
        fi
    fi

    hdiutil convert "$DMG_RW" -format UDZO -ov -o "$dmg" >/dev/null
    rm -f "$DMG_RW"
    DMG_RW=""
    rm -rf "$DMG_STAGE"
    DMG_STAGE=""
}

T_STEP=$SECONDS
mkdir -p "$OUTPUT_DIR"
DMG="$OUTPUT_DIR/pilot.dmg"
echo "==> Creating $DMG from $APP (with an Applications shortcut)"
create_dmg "$APP" "$DMG"
SIZE=$(du -sh "$DMG" | cut -f1)
echo "    [Step 8 (Package DMG): $((SECONDS - T_STEP))s]"

echo ""
echo "DMG complete: $DMG ($SIZE)"

# ---------------------------------------------------------------------------
# Step 9: Verify hermeticity
#
# Two complementary checks per artifact:
#   - Static scan of every Mach-O load command and LC_RPATH for any
#     surviving flavor, Homebrew or /usr/local reference.
#   - Smoke launch under env -i with DYLD_PRINT_LIBRARIES=1 to catch
#     anything that resolves at runtime via PATH or dyld fallbacks.
# Repeated for both the .app and the .app inside the mounted DMG.
# ---------------------------------------------------------------------------

# A real launch loads ~900-1500 libraries (Qt + Python + dependents). Anything
# under this floor suggests the process was killed before dyld finished its
# initial pass and the trace tells us nothing.
# env -i drops every variable; we set only the minimum to let Cocoa initialise.
# pilot is a GUI app and never exits on its own, so we poll the trace at 1 Hz
# and SIGTERM as soon as dyld has emitted >= MIN_LOADS lines. Polling absorbs
# the multi-second kernel signature validation stall on a fresh codesign or DMG
# mount without paying a fixed wait on subsequent launches.
launch_and_trace() {
    local bin="$1" pid elapsed=0 loaded
    : > "$TRACE"
    env -i HOME="${HOME:-/}" USER="${USER:-nobody}" \
        PATH=/usr/bin:/bin TERM="${TERM:-xterm}" \
        DYLD_PRINT_LIBRARIES=1 \
        "$bin" >/dev/null 2>"$TRACE" &
    pid=$!
    while [[ $elapsed -lt 15 ]]; do
        sleep 1
        elapsed=$((elapsed+1))
        loaded=$(grep -c '^dyld\[' "$TRACE" 2>/dev/null || true)
        [[ ${loaded:-0} -ge $MIN_LOADS ]] && break
    done
    # Same liveness rule as smoke_launch_verify: the process must survive the
    # settle time after loading its libraries.
    local settle=0
    LAUNCH_EARLY_EXIT=0
    while [[ $settle -lt ${SMOKE_SETTLE:-5} ]]; do
        kill -0 "$pid" 2>/dev/null || { LAUNCH_EARLY_EXIT=1; break; }
        sleep 1
        settle=$((settle + 1))
    done
    kill -0 "$pid" 2>/dev/null || LAUNCH_EARLY_EXIT=1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# Run a sandboxed launch and verify the dyld trace: enough loads happened, none
# from host prefixes.
smoke_check() {
    local bin="$1" label="${2:-}" total host_count
    [[ -n "$label" ]] && label=" ($label)"
    echo "==> Smoke launch${label} under sandboxed env (DYLD_PRINT_LIBRARIES=1)"
    launch_and_trace "$bin"
    if [[ ${LAUNCH_EARLY_EXIT:-0} -eq 1 ]]; then
        echo "ERROR: pilot exited within ${SMOKE_SETTLE:-5}s of loading its libraries:" >&2
        grep -v '^dyld\[' "$TRACE" | head -20 | sed 's/^/    /' >&2
        exit 1
    fi
    total=$(grep -c '^dyld\[' "$TRACE" || true)
    host_count=$(grep -E '^dyld\[' "$TRACE" | grep -E -c "$HOST_ANY_RE" || true)
    if [[ $total -lt $MIN_LOADS ]]; then
        echo "ERROR: pilot loaded only $total libraries (expected >= $MIN_LOADS);" \
             "did it crash early?" >&2
        sed -n '1,40p' "$TRACE" >&2
        exit 1
    fi
    if [[ $host_count -gt 0 ]]; then
        echo "ERROR: $host_count of $total dyld loads came from host package prefixes:" >&2
        grep -E '^dyld\[' "$TRACE" | grep -E "$HOST_ANY_RE" | head -10 \
            | sed 's/^/    /' >&2
        exit 1
    fi
    echo "    OK: $total libraries loaded, none from host package prefixes"
}

# Run Step 9 against both the .app and the .app inside the mounted DMG. TRACE
# and DMG_MOUNT are set on globals so the cleanup trap can tear them down on
# any exit path.
if [[ $SKIP_CHECK -eq 0 ]]; then
    T_STEP=$SECONDS
    TRACE=$(mktemp -t check-bundle-trace)

    echo ""
    echo "==> Checking $APP"
    echo "==> Static scan for host package path references"
    check_self_contained "$APP"
    smoke_check "$BINARY"
    echo ""
    echo "Bundle check passed: $APP"

    DMG_MOUNT=$(mktemp -d -t check-dmg)
    echo ""
    echo "==> Mounting $DMG at $DMG_MOUNT"
    hdiutil attach -nobrowse -readonly -mountpoint "$DMG_MOUNT" "$DMG" \
        >/dev/null

    DMG_APP=$(find "$DMG_MOUNT" -maxdepth 2 -name '*.app' -type d -print -quit)
    [[ -n "$DMG_APP" ]] || { echo "ERROR: no .app found in $DMG" >&2; exit 1; }
    echo "==> Found app: $DMG_APP"
    echo "==> Static scan (DMG) for host package path references"
    check_self_contained "$DMG_APP"
    DMG_BINARY="$DMG_APP/Contents/MacOS/$(basename "$DMG_APP" .app)"
    smoke_check "$DMG_BINARY" "DMG"
    echo ""
    echo "DMG check passed: $DMG"
    echo "    [Step 9 (Verify hermeticity): $((SECONDS - T_STEP))s]"
fi

echo ""
echo "Total elapsed: $((SECONDS - T_SCRIPT))s"

# vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4:
