#!/bin/bash
#
# Build a devenv flavor (default name mmenv1) for solvcon from prebuilt
# binaries, with no compiling and no package manager.  It is the prebuilt
# counterpart of build-scdv.sh: that script compiles Python and Qt from
# source, this one downloads them, pins every version, and verifies every
# download by SHA-256.  Nothing else is sourced or called, and devenv itself
# is not needed to run it, only to activate the result.
#
# The flavor is a traditional prefix, <flavor>/usr/, laid out like a
# `make install --prefix` tree (bin, lib, include, share, plugins, qml, ...):
#
#   python     CPython from python-build-standalone, extracted into the prefix
#              with its build-time "/install" prefix rewritten.
#   qt         Qt from aqt (aqtinstall) plus the qtshadertools module, merged
#              into the prefix.  qtshadertools is the only extra module solvcon
#              needs; Svg, Widgets, Gui and GuiPrivate come in the base archives.
#   cmake      Kitware's official macOS binary, command line tools only.
#   ninja      The PyPI wheel, which carries the official binary and is not
#              quarantined by Gatekeeper the way a browser download is.
#   pip        The Python packages in requirements.txt at the repository root.
#   pyside     PySide6 ships a private copy of Qt.  Move it aside and point the
#              PySide6 modules at the prefix's Qt, so one Qt serves both solvcon
#              and PySide6 (the macOS step of the CI does the same).
#   verify     Check versions, that one Qt is loaded, and that CMake finds
#              Python, NumPy, pybind11 and Qt from the prefix.
#
# Prerequisite the script cannot install: a C++ toolchain whose libc++ has
# std::jthread without -fexperimental-library.  The Command Line Tools of
# Xcode 16 do not; Xcode 26.3 (SDK 26.2) does and runs on macOS 15.6 or later.
# --print-deps lists the prerequisites; the script checks the toolchain.
#
# Usage:
#   ./build-mmenv.sh
#       Build every step.  Prompts before building; pass --no-confirm to skip.
#   ./build-mmenv.sh --dry-run
#       Print the settings and what each step would do; change nothing.
#   ./build-mmenv.sh --skip PKG [--skip PKG ...]
#       Skip a step.  PKG is one of: python qt cmake ninja pip pyside verify.
#       Accepts a comma-separated list, repetition, and the --skip=PKG form.
#   ./build-mmenv.sh --force
#       Proceed although the prefix already has a python3 (steps then write
#       over what is there; nothing is deleted).
#   ./build-mmenv.sh --no-confirm
#       Skip the "Press Enter to start the build" prompt (CI, scripts).
#   ./build-mmenv.sh --print-prefix
#       Print the prefix and exit, with no side effects; safe to capture.
#   ./build-mmenv.sh --print-deps
#       Print the system prerequisites and exit.
#
# Use the result:
#   devenv use mmenv1
#   export CMAKE_PREFIX_PATH=$DEVENVPREFIX
#   make
#
# Overridable variables (search below for defaults):
#   Location:
#     MMENV_NAME: Flavor name.
#     MMENV_FLAVOR_ROOT: Directory holding flavors; DEVENVFLAVORROOT if set,
#       else ~/devenv/flavors.
#     MMENV_BASE: The flavor directory, MMENV_FLAVOR_ROOT/MMENV_NAME.
#     MMENV_PREFIX: The install prefix, MMENV_BASE/usr.
#     MMENV_DLDIR: Download cache; DEVENVDLROOT if set, else
#       ~/devenv/var/downloaded.
#     MMENV_REQUIREMENTS: The pip requirements file; requirements.txt at the
#       repository root by default.
#
#   Versions:
#     PYTHON_VERSION, PBS_TAG: CPython release and python-build-standalone tag.
#     PYTHON_SHA256: required when overriding either, unless the tag's
#       SHA256SUMS lists the asset (it is then read from the release).
#     QT_VERSION: Qt version; PySide6 in the requirements must be the same.
#     QT_MODULES: aqt modules to add.
#     AQT_VERSION: aqtinstall version.
#     CMAKE_VERSION: CMake release.  CMAKE_SHA256 is required when overriding
#       it; the default is read from the release's SHA-256 file otherwise.
#     NINJA_VERSION: ninja version on PyPI.

set -e
# Without pipefail a failure on the left of a pipe would be lost.
set -o pipefail

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

MMENV_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MMENV_REPO_ROOT="$(cd "${MMENV_SCRIPT_DIR}/../.." && pwd)"

MMENV_NAME=${MMENV_NAME:-mmenv1}
MMENV_FLAVOR_ROOT=${MMENV_FLAVOR_ROOT:-${DEVENVFLAVORROOT:-${HOME}/devenv/flavors}}
MMENV_BASE=${MMENV_BASE:-${MMENV_FLAVOR_ROOT}/${MMENV_NAME}}
MMENV_PREFIX=${MMENV_PREFIX:-${MMENV_BASE}/usr}
MMENV_DLDIR=${MMENV_DLDIR:-${DEVENVDLROOT:-${HOME}/devenv/var/downloaded}}
MMENV_REQUIREMENTS=${MMENV_REQUIREMENTS:-${MMENV_REPO_ROOT}/requirements.txt}

PYTHON_VERSION=${PYTHON_VERSION:-3.14.8}
PBS_TAG=${PBS_TAG:-20261003}
PYTHON_SHA256=${PYTHON_SHA256:-}
# Verified against the SHA256SUMS of python-build-standalone 20261003.
PBS_PINNED_KEY="aarch64-apple-darwin|3.14.8|20261003"
PBS_PINNED_SHA256=d15291f940cfecd2e54010d5e37d2e03aa192f076a65d26ab741372fff2dabfe

QT_VERSION=${QT_VERSION:-6.12.0}
QT_MODULES=${QT_MODULES:-qtshadertools}
AQT_VERSION=${AQT_VERSION:-3.3.0}

CMAKE_VERSION=${CMAKE_VERSION:-4.4.4}
CMAKE_SHA256=${CMAKE_SHA256:-}
# Verified against the cmake-4.4.4-SHA-256.txt of the release.
CMAKE_PINNED_VERSION=4.4.4
CMAKE_PINNED_SHA256=4b7b73704b1db9b374e5c9ab8e17ac6148b817b6396ee75cd94a852cbac9d305

NINJA_VERSION=${NINJA_VERSION:-1.13.2}

PY="${MMENV_PREFIX}/bin/python3"
MMENV_STEPS="python qt cmake ninja pip pyside verify"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

say() { echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "warning: $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

DRYRUN=""
NO_CONFIRM=""
FORCE=""
MMENV_SKIP=" "

mmenv_add_skip() {
  local item
  for item in $(echo "$1" | tr ',' ' '); do
    case " ${MMENV_STEPS} " in
      *" ${item} "*) MMENV_SKIP="${MMENV_SKIP}${item} " ;;
      *) die "--skip: unknown package '${item}' (one of: ${MMENV_STEPS})" ;;
    esac
  done
}

mmenv_skip_p() {
  case "${MMENV_SKIP}" in *" $1 "*) return 0 ;; esac
  return 1
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Download $1 to $2 and verify it against the SHA-256 $3.  A cached file that
# matches is reused; one that does not is downloaded again.
download_verified() {
  local url="$1" file="$2" want="$3" got
  mkdir -p "$(dirname "${file}")"
  if [ -f "${file}" ]; then
    got=$(sha256_of "${file}")
    if [ "${got}" = "${want}" ]; then
      info "cached ${file##*/}"
      return 0
    fi
    info "cached ${file##*/} has the wrong checksum; downloading again"
    rm -f "${file}"
  fi
  info "download ${url}"
  curl -sSfL -o "${file}.part" "${url}"
  got=$(sha256_of "${file}.part")
  if [ "${got}" != "${want}" ] ; then
    rm -f "${file}.part"
    die "sha256 mismatch for ${file##*/}: expected ${want}, got ${got}"
  fi
  mv "${file}.part" "${file}"
  info "sha256 ok: ${got}"
}

# Escape a string for the replacement side of a sed s### command.
sed_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//&/\\&}
  s=${s//#/\\#}
  printf '%s' "${s}"
}

# Remove a staging directory that this script created under MMENV_BASE.
remove_stage() {
  case "$1" in
    "${MMENV_BASE}"/.*-stage) rm -rf "$1" ;;
    *) die "refusing to remove '$1': not a staging directory under ${MMENV_BASE}" ;;
  esac
}

# Platform: Darwin on arm64 or x86_64.  Linux is not supported yet.
detect_platform() {
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  PBS_TRIPLE=aarch64-apple-darwin ;;
    Darwin-x86_64) PBS_TRIPLE=x86_64-apple-darwin ;;
    *) die "unsupported platform $(uname -s)-$(uname -m); only macOS is supported" ;;
  esac
  QT_HOST=mac
  QT_ARCH=clang_64
  QT_TREE_OS=macos
}

print_deps() {
  cat <<'EOF'
# System prerequisites (this script never installs them):
#   - macOS 15.6 or later with Xcode 26.3 or later selected:
#       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
#     (Command Line Tools alone lack std::jthread in libc++.)
#   - curl, tar, rsync, shasum, otool, install_name_tool, codesign (macOS has
#     them) and network access to github.com, download.qt.io and pypi.org.
EOF
}

# The solvcon pilot uses std::jthread, which Apple's libc++ gates behind
# -fexperimental-library in older SDKs.  Warn early rather than at link time.
check_toolchain() {
  local tmp
  tmp=$(mktemp -d)
  printf '#include <thread>\nint main(){ std::jthread t([]{}); }\n' > "${tmp}/jt.cpp"
  if clang++ -std=c++23 -c "${tmp}/jt.cpp" -o /dev/null 2>/dev/null ; then
    info "C++ toolchain: std::jthread compiles ($(xcodebuild -version 2>/dev/null | head -n 1))"
  else
    warn "this C++ toolchain cannot compile std::jthread; building solvcon will" \
         "fail. Select Xcode 26.3 or later (see --print-deps)."
  fi
  rm -rf "${tmp}"
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

while [ $# -gt 0 ] ; do
  case "$1" in
    --dry-run) DRYRUN=1 ; shift ;;
    --no-confirm) NO_CONFIRM=1 ; shift ;;
    --force) FORCE=1 ; shift ;;
    --skip)
      [ $# -ge 2 ] || die "--skip needs an argument"
      mmenv_add_skip "$2" ; shift 2 ;;
    --skip=*) mmenv_add_skip "${1#--skip=}" ; shift ;;
    --print-prefix) echo "${MMENV_PREFIX}" ; exit 0 ;;
    --print-deps) print_deps ; exit 0 ;;
    -h|--help)
      sed -n '2,/^set -e$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
done

detect_platform

# Resolve what is not pinned.
cmake_asset="cmake-${CMAKE_VERSION}-macos-universal.tar.gz"
cmake_base="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}"
if [ -z "${CMAKE_SHA256}" ] && [ "${CMAKE_VERSION}" = "${CMAKE_PINNED_VERSION}" ] ; then
  CMAKE_SHA256=${CMAKE_PINNED_SHA256}
fi
pbs_asset="cpython-${PYTHON_VERSION}+${PBS_TAG}-${PBS_TRIPLE}-install_only.tar.gz"
pbs_base="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}"
if [ -z "${PYTHON_SHA256}" ] \
   && [ "${PBS_TRIPLE}|${PYTHON_VERSION}|${PBS_TAG}" = "${PBS_PINNED_KEY}" ] ; then
  PYTHON_SHA256=${PBS_PINNED_SHA256}
fi

say "mmenv: ${MMENV_NAME}"
info "prefix       : ${MMENV_PREFIX}"
info "download dir : ${MMENV_DLDIR}"
info "requirements : ${MMENV_REQUIREMENTS}"
info "platform     : ${PBS_TRIPLE}"
info "python       : ${PYTHON_VERSION} (python-build-standalone ${PBS_TAG})"
info "qt           : ${QT_VERSION} (${QT_HOST} ${QT_ARCH}, modules: ${QT_MODULES}; aqtinstall ${AQT_VERSION})"
info "cmake        : ${CMAKE_VERSION}"
info "ninja        : ${NINJA_VERSION}"
info "skipped      :${MMENV_SKIP}"
[ -n "${DRYRUN}" ] && info "DRY RUN: nothing will be changed"

[ -f "${MMENV_REQUIREMENTS}" ] || die "requirements file not found: ${MMENV_REQUIREMENTS}"
if [ -x "${PY}" ] && [ -z "${FORCE}" ] && [ -z "${DRYRUN}" ] && ! mmenv_skip_p python ; then
  die "${PY} exists; the prefix is already built. Remove the flavor, use" \
      "--skip python, or pass --force"
fi

check_toolchain

if [ -z "${NO_CONFIRM}" ] && [ -z "${DRYRUN}" ] ; then
  printf 'Press Enter to start the build (Ctrl-C to abort) ... '
  read -r _
fi

# ---------------------------------------------------------------------------
# Step: python
# ---------------------------------------------------------------------------

build_python() {
  say "python ${PYTHON_VERSION}"
  if [ -n "${DRYRUN}" ] ; then
    info "(dry-run) download ${pbs_asset}, verify, extract into ${MMENV_PREFIX}"
    info "(dry-run) rewrite /install -> ${MMENV_PREFIX} in the three sysconfig files"
    return 0
  fi

  local want="${PYTHON_SHA256}" tarball="${MMENV_DLDIR}/${pbs_asset}" sums
  if [ -z "${want}" ] ; then
    info "no pinned checksum; reading SHA256SUMS of release ${PBS_TAG}"
    sums=$(curl -sSfL "${pbs_base}/SHA256SUMS")
    want=$(grep -F "${pbs_asset}" <<< "${sums}" | awk '{print $1}')
    [ -n "${want}" ] || die "${pbs_asset} is not in the SHA256SUMS of ${PBS_TAG}"
  fi
  download_verified "${pbs_base}/${pbs_asset//+/%2B}" "${tarball}" "${want}"

  mkdir -p "${MMENV_PREFIX}"
  tar xzf "${tarball}" --strip-components=1 -C "${MMENV_PREFIX}"

  # The tarball was built with prefix /install and its sysconfig files keep it,
  # which CMake's Development.Embed and extension builds read.  Rewrite it, in
  # these three files only: pip and install-sh also contain "install" as text.
  local esc expr f n patched=0
  esc=$(sed_escape "${MMENV_PREFIX}")
  expr="s#/install(/|\"|'|[[:space:]]|\$)#${esc}\\1#g"
  for f in "${MMENV_PREFIX}"/lib/python*/_sysconfigdata_*.py \
           "${MMENV_PREFIX}"/lib/python*/_sysconfig_vars_*.json \
           "${MMENV_PREFIX}"/lib/python*/config-*/Makefile ; do
    [ -f "${f}" ] || continue
    if grep -qE '/install(/|"|'"'"'|[[:space:]]|$)' "${f}" ; then
      n=$(grep -cE '/install(/|"|'"'"'|[[:space:]]|$)' "${f}")
      sed -i.orig -E "${expr}" "${f}"
      rm -f "${f}.orig"
      info "rewrote ${n} line(s) in ${f#${MMENV_PREFIX}/}"
      patched=$((patched + 1))
    fi
  done
  [ ${patched} -gt 0 ] || die "found no /install to rewrite; was the tarball layout changed?"
  "${PY}" --version
}

# ---------------------------------------------------------------------------
# Step: qt (aqt), merged into the prefix
# ---------------------------------------------------------------------------

build_qt() {
  say "qt ${QT_VERSION} (aqt ${AQT_VERSION}, modules: ${QT_MODULES})"
  if [ -n "${DRYRUN}" ] ; then
    info "(dry-run) pip install aqtinstall==${AQT_VERSION}"
    info "(dry-run) aqt install-qt ${QT_HOST} desktop ${QT_VERSION} ${QT_ARCH} -m ${QT_MODULES}"
    info "(dry-run) merge the Qt tree into ${MMENV_PREFIX} and repoint lib/pkgconfig/*.pc"
    return 0
  fi

  local stage="${MMENV_BASE}/.aqt-stage" tree m modules=""
  [ -x "${PY}" ] || die "no python in ${MMENV_PREFIX}; run the python step first"
  "${PY}" -m pip install --disable-pip-version-check -q "aqtinstall==${AQT_VERSION}"

  for m in ${QT_MODULES} ; do modules="${modules} -m ${m}" ; done
  remove_stage "${stage}"
  mkdir -p "${stage}"
  # aqt writes aqtinstall.log into the working directory.
  ( cd "${MMENV_BASE}" \
    && "${MMENV_PREFIX}/bin/aqt" install-qt ${QT_HOST} desktop "${QT_VERSION}" \
         ${QT_ARCH} ${modules} -O "${stage}" )

  tree="${stage}/${QT_VERSION}/${QT_TREE_OS}"
  [ -d "${tree}/bin" ] || die "aqt did not produce ${tree}"

  # The aqt tree matches a source install (bin lib include libexec mkspecs
  # plugins qml ...) and finds its own prefix at run time (qt.conf has
  # Prefix=.., and the CMake files are relative), so it can be merged as is.
  # Only the pkg-config files carry the staging path.
  rsync -a "${tree}/" "${MMENV_PREFIX}/"
  local pc old new left
  old=$(sed_escape "${tree}")
  new=$(sed_escape "${MMENV_PREFIX}")
  for pc in "${MMENV_PREFIX}"/lib/pkgconfig/Qt6*.pc ; do
    [ -f "${pc}" ] || continue
    if grep -qF "${tree}" "${pc}" ; then
      sed -i.orig "s#${old}#${new}#g" "${pc}"
      rm -f "${pc}.orig"
    fi
  done
  left=$(grep -rIlF "${tree}" "${MMENV_PREFIX}" 2>/dev/null | head -n 3 || true)
  [ -z "${left}" ] || warn "files still name the Qt staging directory: ${left}"

  remove_stage "${stage}"
  info "Qt $("${MMENV_PREFIX}/bin/qmake6" -query QT_VERSION) merged into ${MMENV_PREFIX}"
}

# ---------------------------------------------------------------------------
# Step: cmake (Kitware's macOS binary, command line tools only)
# ---------------------------------------------------------------------------

build_cmake() {
  say "cmake ${CMAKE_VERSION}"
  if [ -n "${DRYRUN}" ] ; then
    info "(dry-run) download ${cmake_asset}, verify, install cmake ctest cpack ccmake and share/"
    return 0
  fi

  local want="${CMAKE_SHA256}" tarball="${MMENV_DLDIR}/${cmake_asset}" stage root b
  local sumfile="${MMENV_DLDIR}/cmake-${CMAKE_VERSION}-SHA-256.txt"
  if [ -z "${want}" ] ; then
    info "no pinned checksum; reading the release's SHA-256 file"
    curl -sSfL -o "${sumfile}" "${cmake_base}/cmake-${CMAKE_VERSION}-SHA-256.txt"
    want=$(grep -F "${cmake_asset}" "${sumfile}" | awk '{print $1}')
    [ -n "${want}" ] || die "${cmake_asset} is not in the release's SHA-256 file"
  fi
  download_verified "${cmake_base}/${cmake_asset}" "${tarball}" "${want}"

  stage="${MMENV_BASE}/.cmake-stage"
  remove_stage "${stage}"
  mkdir -p "${stage}"
  root="cmake-${CMAKE_VERSION}-macos-universal/CMake.app/Contents"
  tar xzf "${tarball}" -C "${stage}" --strip-components=3 \
    "${root}/bin" "${root}/share" "${root}/doc" "${root}/man"

  mkdir -p "${MMENV_PREFIX}/bin" "${MMENV_PREFIX}/share/doc" "${MMENV_PREFIX}/share/man"
  for b in cmake ctest cpack ccmake ; do
    install -m 755 "${stage}/bin/${b}" "${MMENV_PREFIX}/bin/${b}"
  done
  rsync -a "${stage}/share/" "${MMENV_PREFIX}/share/"
  rsync -a "${stage}/doc/" "${MMENV_PREFIX}/share/doc/"
  rsync -a "${stage}/man/" "${MMENV_PREFIX}/share/man/"
  remove_stage "${stage}"
  "${MMENV_PREFIX}/bin/cmake" --version | head -n 1
}

# ---------------------------------------------------------------------------
# Step: ninja (PyPI wheel)
# ---------------------------------------------------------------------------

build_ninja() {
  say "ninja ${NINJA_VERSION}"
  if [ -n "${DRYRUN}" ] ; then
    info "(dry-run) pip install ninja==${NINJA_VERSION}"
    return 0
  fi
  [ -x "${PY}" ] || die "no python in ${MMENV_PREFIX}; run the python step first"
  "${PY}" -m pip install --disable-pip-version-check -q "ninja==${NINJA_VERSION}"
  info "ninja $("${MMENV_PREFIX}/bin/ninja" --version)"
}

# ---------------------------------------------------------------------------
# Step: pip (requirements.txt)
# ---------------------------------------------------------------------------

build_pip() {
  say "python packages from ${MMENV_REQUIREMENTS##*/}"
  if [ -n "${DRYRUN}" ] ; then
    info "(dry-run) pip install -r ${MMENV_REQUIREMENTS}"
    info "(dry-run) check that PySide6 is ${QT_VERSION}, the version of Qt"
    return 0
  fi
  [ -x "${PY}" ] || die "no python in ${MMENV_PREFIX}; run the python step first"
  # pip expands ${QT_VERSION} in the file, for a requirements file that uses it.
  QT_VERSION="${QT_VERSION}" "${PY}" -m pip install --disable-pip-version-check \
    -r "${MMENV_REQUIREMENTS}"

  local pyside
  pyside=$("${PY}" -c "import PySide6; print(PySide6.__version__)")
  if [ "${pyside}" != "${QT_VERSION}" ] ; then
    die "PySide6 is ${pyside} but Qt is ${QT_VERSION}; they must match. Fix" \
        "${MMENV_REQUIREMENTS##*/} or set QT_VERSION"
  fi
  info "PySide6 ${pyside} matches Qt ${QT_VERSION}"
}

# ---------------------------------------------------------------------------
# Step: pyside (one Qt at run time)
# ---------------------------------------------------------------------------

# A PySide6 wheel carries its own Qt under PySide6/Qt/lib, and its modules load
# it through @rpath.  solvcon is compiled against the prefix's Qt, so which Qt
# a process runs would depend on which was imported first, and solvcon uses
# private Qt API that wants the Qt it was compiled against.  Move the wheel's
# frameworks aside (not deleted: they go to backup/pyside6-qt) and give each
# PySide6 module the prefix's lib/ as an rpath.  Editing the load commands
# drops the ad-hoc signature, so sign again.
build_pyside() {
  say "pyside: share the prefix's Qt with PySide6"
  if [ -n "${DRYRUN}" ] ; then
    info "(dry-run) move PySide6/Qt/lib/*.framework to ${MMENV_BASE}/backup/pyside6-qt"
    info "(dry-run) add rpath ${MMENV_PREFIX}/lib to PySide6/Qt*.abi3.so and re-sign them"
    return 0
  fi

  local pyside qlib backup nfw so
  [ -x "${PY}" ] || die "no python in ${MMENV_PREFIX}; run the python step first"
  pyside=$("${PY}" -c "import os, PySide6; print(os.path.dirname(PySide6.__file__))")
  qlib="${MMENV_PREFIX}/lib"
  backup="${MMENV_BASE}/backup/pyside6-qt"

  nfw=$(ls -d "${pyside}"/Qt/lib/*.framework 2>/dev/null | wc -l | tr -d ' ')
  if [ "${nfw}" = "0" ] ; then
    info "no framework under PySide6/Qt/lib; already done"
    return 0
  fi
  [ ! -e "${backup}" ] || die "${backup} already exists; move it away first"

  mkdir -p "${backup}/Qt/lib" "${backup}/modules"
  for so in "${pyside}"/Qt*.abi3.so ; do
    [ -f "${so}" ] || continue
    cp -p "${so}" "${backup}/modules/"
  done
  mv "${pyside}"/Qt/lib/*.framework "${backup}/Qt/lib/"

  for so in "${pyside}"/Qt*.abi3.so ; do
    [ -f "${so}" ] || continue
    if ! otool -l "${so}" | grep -A2 LC_RPATH | grep -qF "path ${qlib} " ; then
      install_name_tool -add_rpath "${qlib}" "${so}"
    fi
    codesign --force --sign - "${so}" 2>/dev/null
  done

  cat > "${backup}/RESTORE.txt" <<EOF
Moved here by build-mmenv.sh to make PySide6 use the Qt in ${MMENV_PREFIX}.
Restore:
  mv ${backup}/Qt/lib/*.framework ${pyside}/Qt/lib/
  cp -p ${backup}/modules/*.abi3.so ${pyside}/
Or: ${PY} -m pip install --force-reinstall --no-deps PySide6_Essentials
EOF
  info "moved ${nfw} framework(s) to ${backup}; rpath ${qlib} added"
}

# ---------------------------------------------------------------------------
# Step: verify
# ---------------------------------------------------------------------------

build_verify() {
  say "verify"
  if [ -n "${DRYRUN}" ] ; then
    info "(dry-run) check python sysconfig, versions, Qt images and a CMake configure"
    return 0
  fi
  [ -x "${PY}" ] || die "no python in ${MMENV_PREFIX}"

  PATH="${MMENV_PREFIX}/bin:${PATH}" "${PY}" -I - "${MMENV_PREFIX}" <<'EOF'
import ctypes
import os
import sys
import sysconfig

prefix = sys.argv[1]
bad = [k for k in ("LIBDIR", "INCLUDEPY", "prefix")
       if not str(sysconfig.get_config_var(k)).startswith(prefix)]
if bad:
    sys.exit("sysconfig variables outside the prefix: %s" % bad)
print("    sysconfig inside the prefix: ok")

import numpy  # noqa: F401
import ssl  # noqa: F401
import sqlite3  # noqa: F401
from PySide6 import QtCore, QtGui, QtSvg, QtWidgets  # noqa: F401
import shiboken6  # noqa: F401

print("    python %s, PySide6 %s, Qt %s" % (
    sys.version.split()[0], QtCore.__version__, QtCore.qVersion()))

# Exactly the Qt of the prefix may be loaded: the PySide6 copy is moved away.
libc = ctypes.CDLL(None)
libc._dyld_image_count.restype = ctypes.c_uint32
libc._dyld_get_image_name.restype = ctypes.c_char_p
libc._dyld_get_image_name.argtypes = [ctypes.c_uint32]
names = [libc._dyld_get_image_name(i).decode()
         for i in range(libc._dyld_image_count())]
qt = [n for n in names if n.endswith(("/QtCore", "/QtGui", "/QtWidgets"))]
outside = [n for n in qt if not n.startswith(prefix + "/lib/")]
if not qt or outside:
    sys.exit("Qt is loaded from outside the prefix: %s" % (outside or "none"))
print("    one Qt loaded, from the prefix: ok")
EOF

  local qt_ver ninja_ver
  qt_ver=$("${MMENV_PREFIX}/bin/qmake6" -query QT_VERSION)
  [ "${qt_ver}" = "${QT_VERSION}" ] || die "qmake6 reports Qt ${qt_ver}, expected ${QT_VERSION}"
  info "cmake $("${MMENV_PREFIX}/bin/cmake" --version | head -n 1 | awk '{print $3}'), qmake6 Qt ${qt_ver}"
  if [ -x "${MMENV_PREFIX}/bin/ninja" ] ; then
    ninja_ver=$("${MMENV_PREFIX}/bin/ninja" --version)
    info "ninja ${ninja_ver}"
  fi

  # What the solvcon CMakeLists asks for, from the prefix alone.
  local tmp="${MMENV_BASE}/.verify-stage"
  remove_stage "${tmp}"
  mkdir -p "${tmp}"
  cat > "${tmp}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 4.0.1)
project(mmenv_verify CXX)
set(PYBIND11_FINDPYTHON ON)
set(QT_NO_PRIVATE_MODULE_WARNING ON)
find_package(Python REQUIRED
    COMPONENTS Interpreter Development.Module Development.Embed NumPy)
find_package(pybind11 2.12.0 REQUIRED)
find_package(Qt6 REQUIRED COMPONENTS Core Widgets Gui Svg ShaderTools)
find_package(Qt6 REQUIRED OPTIONAL_COMPONENTS GuiPrivate)
if(NOT TARGET Qt6::GuiPrivate)
    message(FATAL_ERROR "Qt6::GuiPrivate is missing")
endif()
message(STATUS "verify: Python ${Python_VERSION}, NumPy ${Python_NumPy_VERSION}, "
    "pybind11 ${pybind11_VERSION}, Qt ${Qt6_VERSION}")
EOF
  if PATH="${MMENV_PREFIX}/bin:${PATH}" cmake -S "${tmp}" -B "${tmp}/b" \
       -DCMAKE_PREFIX_PATH="${MMENV_PREFIX}" -DPython_EXECUTABLE="${PY}" \
       > "${tmp}/configure.log" 2>&1 ; then
    info "$(grep 'verify:' "${tmp}/configure.log" | sed 's/^-- //')"
    remove_stage "${tmp}"
  else
    tail -n 15 "${tmp}/configure.log" >&2
    die "CMake could not find the dependencies from the prefix (log in ${tmp})"
  fi
}

# ---------------------------------------------------------------------------
# Record, run, summary
# ---------------------------------------------------------------------------

write_manifest() {
  local f="${MMENV_BASE}/MANIFEST.txt"
  {
    echo "Built by contrib/dependency/build-mmenv.sh on $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "prefix: ${MMENV_PREFIX}"
    echo "platform: ${PBS_TRIPLE}"
    echo "python: ${PYTHON_VERSION} (python-build-standalone ${PBS_TAG})"
    echo "qt: ${QT_VERSION} (modules: ${QT_MODULES}; aqtinstall ${AQT_VERSION})"
    echo "cmake: ${CMAKE_VERSION}"
    echo "ninja: ${NINJA_VERSION}"
    echo "requirements: ${MMENV_REQUIREMENTS}"
    echo "installed python packages:"
    "${PY}" -m pip list --disable-pip-version-check --format=freeze 2>/dev/null \
      | sed 's/^/  /'
  } > "${f}"
  info "wrote ${f}"
}

for step in ${MMENV_STEPS} ; do
  if mmenv_skip_p "${step}" ; then
    say "skip ${step}"
    continue
  fi
  "build_${step}"
done

if [ -z "${DRYRUN}" ] ; then
  [ -x "${PY}" ] && write_manifest
  echo ""
  say "done: ${MMENV_PREFIX}"
  info "devenv use ${MMENV_NAME}"
  info "export CMAKE_PREFIX_PATH=\$DEVENVPREFIX"
  info "cd ${MMENV_REPO_ROOT} && make"
else
  echo ""
  say "dry run finished; nothing was changed"
fi

# vim: set ff=unix fenc=utf8 et sw=2 ts=2 sts=2:
