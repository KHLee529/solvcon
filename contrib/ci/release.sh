#!/bin/bash
#
# Copyright (c) 2026, solvcon team <contact@solvcon.net>
# BSD 3-Clause License, see COPYING
#
# Stages of the release pipeline driven by .github/workflows/release.yml. Each
# subcommand is one stage, so a stage that fails in CI can be rerun by hand on
# a macOS host:
#
#   contrib/ci/release.sh setup
#   contrib/ci/release.sh build
#   VERSION=v0.0.0 contrib/ci/release.sh package
#   contrib/ci/release.sh unbox dist/solvcon-pilot-v0.0.0-macos-arm64.dmg
#
# VERSION names the packaged file (default: the short commit hash), and
# DIST_DIR is where package writes it (default: dist). The dependencies come
# from the devenv flavor that contrib/dependency/build-mmenv.sh builds; its
# MMENV_* variables select the flavor.
#
# The macOS DMG produced by the `make bundle` targets is the only release
# artifact so far. A new platform adds its own branch to each stage.

set -euo pipefail

cd "$(dirname "$0")/../.."

MMENV=contrib/dependency/build-mmenv.sh
# bundle-with-devenv.sh reads the pilot build from this tree, so build must
# write it here for package to run with --skip-build.
export BUNDLE_BUILD_PATH=build/relbundle
export BUNDLE_WITH=devenv
DIST_DIR="${DIST_DIR:-dist}"

artifact_name() {
    local version="${VERSION:-$(git rev-parse --short HEAD)}"
    local arch
    arch=$(uname -m)
    printf 'solvcon-pilot-%s-macos-%s.dmg\n' "$version" "$arch"
}

# What `devenv use` does for the flavor, without needing devenv itself.
activate_flavor() {
    local prefix
    prefix=$("$MMENV" --print-prefix)
    export DEVENVPREFIX="$prefix"
    export PATH="$prefix/bin:$PATH"
    export CMAKE_PREFIX_PATH="$prefix"
}

stage_setup() {
    # A flavor already in place is reused, for reruns by hand.
    if [[ -x "$("$MMENV" --print-prefix)/bin/python3" ]]; then
        echo "reusing the flavor at $("$MMENV" --print-prefix)"
    else
        "$MMENV" --no-confirm
    fi
    activate_flavor
    make bundle-precheck
}

stage_build() {
    activate_flavor
    make pilot BUILD_PATH="$BUNDLE_BUILD_PATH"
}

stage_package() {
    local name
    name=$(artifact_name)

    activate_flavor
    make bundle RELEASE_OUTPUT="$DIST_DIR" RELEASE_ARGS=--skip-build

    mv "$DIST_DIR/pilot.dmg" "$DIST_DIR/$name"
    (cd "$DIST_DIR" && shasum -a 256 "$name" > "$name.sha256")
    ls -lh "$DIST_DIR"
}

# No flavor is activated: the artifact has to run without one.
stage_unbox() {
    local dmg="$1"

    (cd "$(dirname "$dmg")" && shasum -a 256 -c "$(basename "$dmg").sha256")
    make bundle-test RELEASE_ARTIFACT="$dmg"
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
