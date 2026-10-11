#!/bin/bash
#
# Copyright (c) 2026, solvcon team <contact@solvcon.net>
# BSD 3-Clause License, see COPYING
#
# Stages of the release pipeline driven by .github/workflows/release.yml. Each
# subcommand is one stage, so a stage that fails in CI can be rerun by hand on
# a macOS host with Homebrew:
#
#   contrib/ci/release.sh setup
#   contrib/ci/release.sh build
#   VERSION=v0.0.0 contrib/ci/release.sh package
#   contrib/ci/release.sh unbox dist/solvcon-pilot-v0.0.0-macos-arm64.dmg
#
# VERSION names the packaged file (default: the short commit hash), and
# DIST_DIR is where package writes it (default: dist).
#
# The macOS DMG produced by contrib/bundle/bundle-with-homebrew.sh is the only
# release artifact so far. A new platform adds its own branch to each stage.

set -euo pipefail

cd "$(dirname "$0")/../.."

BUNDLE=contrib/bundle/bundle-with-homebrew.sh
# bundle-with-homebrew.sh reads the pilot build from this tree, so build must
# write it here for package to run with --skip-build.
BUNDLE_BUILD_PATH=build/relbundle
DIST_DIR="${DIST_DIR:-dist}"

artifact_name() {
    local version="${VERSION:-$(git rev-parse --short HEAD)}"
    local arch
    arch=$(uname -m)
    printf 'solvcon-pilot-%s-macos-%s.dmg\n' "$version" "$arch"
}

stage_setup() {
    export HOMEBREW_NO_AUTO_UPDATE=1
    export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
    # The bundle copies Python and Qt out of the Homebrew prefix, so every
    # runtime dependency has to come from Homebrew, not pip or aqt.
    brew install cmake qt pyside python numpy python-matplotlib pybind11
    "$BUNDLE" check
}

stage_build() {
    make pilot BUILD_PATH="$BUNDLE_BUILD_PATH"
}

stage_package() {
    local name
    name=$(artifact_name)

    "$BUNDLE" bundle --skip-build --output "$DIST_DIR"

    mv "$DIST_DIR/pilot.dmg" "$DIST_DIR/$name"
    (cd "$DIST_DIR" && shasum -a 256 "$name" > "$name.sha256")
    ls -lh "$DIST_DIR"
}

stage_unbox() {
    local dmg="$1"

    (cd "$(dirname "$dmg")" && shasum -a 256 -c "$(basename "$dmg").sha256")
    "$BUNDLE" verify "$dmg"
}

case "${1:-}" in
    setup) stage_setup ;;
    build) stage_build ;;
    package) stage_package ;;
    unbox)
        [[ $# -eq 2 ]] || { echo "usage: $0 unbox path/to/artifact" >&2; exit 2; }
        stage_unbox "$2"
        ;;
    *)
        echo "usage: $0 {setup|build|package|unbox artifact}" >&2
        exit 2
        ;;
esac

# vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4:
