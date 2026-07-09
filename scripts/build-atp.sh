#!/usr/bin/env bash
#
# build-atp.sh — build the `atp` release binary from the canonical asupersync
# source tree.
#
# The canonical ATP code lives in https://github.com/Dicklesworthstone/asupersync
# (this repo is the standalone product/distribution repo for the `atp` CLI).
# Releases are built from the exact commit recorded in UPSTREAM_REV.
#
# Usage:
#   scripts/build-atp.sh                 # build from ./upstream symlink if present,
#                                        # otherwise clone the pinned rev to a temp dir
#   scripts/build-atp.sh --pinned        # always clone the pinned UPSTREAM_REV
#   scripts/build-atp.sh --out DIR       # copy the built binary to DIR (default ./dist)
#   scripts/build-atp.sh --target TRIPLE # cross-target build (requires rustup target)
#
# Requires: git, rustup (the asupersync tree pins its own nightly toolchain via
# rust-toolchain.toml, which rustup installs automatically on first build).
#
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/Dicklesworthstone/asupersync}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$REPO_ROOT/dist"
PINNED=0
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pinned) PINNED=1; shift ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

REV="$(tr -d '[:space:]' < "$REPO_ROOT/UPSTREAM_REV")"
if [ -z "$REV" ]; then
  echo "UPSTREAM_REV is empty; cannot pin a build" >&2
  exit 1
fi

SRC=""
CLEANUP_DIR=""
cleanup() { [ -n "$CLEANUP_DIR" ] && rm -rf "$CLEANUP_DIR"; }
trap cleanup EXIT

if [ "$PINNED" -eq 0 ] && [ -d "$REPO_ROOT/upstream/.git" ]; then
  SRC="$REPO_ROOT/upstream"
  echo "==> building from local upstream checkout: $SRC"
  echo "    (working-tree state, not necessarily UPSTREAM_REV $REV;"
  echo "     use --pinned for a release-identical build)"
else
  CLEANUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/atp-upstream.XXXXXX")"
  SRC="$CLEANUP_DIR/asupersync"
  echo "==> cloning $UPSTREAM_REPO @ $REV"
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$UPSTREAM_REPO"
  git -C "$SRC" fetch -q --depth 1 origin "$REV"
  git -C "$SRC" checkout -q FETCH_HEAD
fi

BUILD_ARGS=(build --release --locked --bin atp --features atp-cli)
BIN_SUBPATH="release/atp"
if [ -n "$TARGET" ]; then
  BUILD_ARGS+=(--target "$TARGET")
  BIN_SUBPATH="$TARGET/release/atp"
  rustup target add "$TARGET" >/dev/null 2>&1 || true
fi

echo "==> cargo ${BUILD_ARGS[*]}"
(cd "$SRC" && cargo "${BUILD_ARGS[@]}")

mkdir -p "$OUT_DIR"
cp "$SRC/target/$BIN_SUBPATH" "$OUT_DIR/atp"
echo "==> built: $OUT_DIR/atp"
"$OUT_DIR/atp" --version
