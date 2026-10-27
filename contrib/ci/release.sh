#!/bin/bash
#
# Copyright (c) 2026, solvcon team <contact@solvcon.net>
# BSD 3-Clause License, see COPYING
#
# Stages of the release pipeline driven by .github/workflows/release.yml. Each
# subcommand is one stage, so a stage that fails in CI can be rerun by hand on
# an Apple Silicon macOS host:
#
#   contrib/ci/release.sh setup
#   contrib/ci/release.sh build
#   VERSION=v0.0.0 contrib/ci/release.sh package
#   contrib/ci/release.sh unbox dist/solvcon-pilot-v0.0.0-macos-arm64.dmg
#
# VERSION names the packaged file (default: the short commit hash), and
# DIST_DIR is where package writes it (default: dist). The dependencies are
# the ones contrib/bundle/prepare-with-aqt.sh pins under build/bundle-deps.
#
# The macOS DMG produced by the `make bundle` targets is the only release
# artifact so far. A new platform adds its own branch to each stage.

set -euo pipefail

cd "$(dirname "$0")/../.."

# Where `make bundle` writes pilot.dmg for package to pick up.
BUNDLE_OUTPUT=build/relbundle-dist
DIST_DIR="${DIST_DIR:-dist}"

artifact_name() {
    local version="${VERSION:-$(git rev-parse --short HEAD)}"
    local arch
    arch=$(uname -m)
    printf 'solvcon-pilot-%s-macos-%s.dmg\n' "$version" "$arch"
}

stage_setup() {
    # Prepared dependencies that already pass the check are reused, for reruns
    # by hand; preparing again downloads everything from scratch.
    if make bundle-precheck >/dev/null 2>&1; then
        echo "reusing the dependencies under build/bundle-deps"
    else
        make bundle-prepare
    fi
    make bundle-precheck
}

# The bundler builds the pilot with the flags it needs to deploy it, so build
# goes through it instead of `make pilot`.
stage_build() {
    make bundle RELEASE_OUTPUT="$BUNDLE_OUTPUT"
}

stage_package() {
    local name
    name=$(artifact_name)

    mkdir -p "$DIST_DIR"
    cp "$BUNDLE_OUTPUT/pilot.dmg" "$DIST_DIR/$name"
    (cd "$DIST_DIR" && shasum -a 256 "$name" > "$name.sha256")
    ls -lh "$DIST_DIR"
}

# Nothing is prepared: the artifact has to run without the dependencies.
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
