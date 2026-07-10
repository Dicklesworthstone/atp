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
#   scripts/build-atp.sh --target TRIPLE # target build (also requires its linker/C toolchain)
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
    --out)
      [ "$#" -ge 2 ] || { echo "--out requires a directory" >&2; exit 2; }
      OUT_DIR="$2"
      shift 2
      ;;
    --target)
      [ "$#" -ge 2 ] || { echo "--target requires a Rust target triple" >&2; exit 2; }
      TARGET="$2"
      shift 2
      ;;
    -h|--help) sed -n '2,20p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

REV="$(tr -d '[:space:]' < "$REPO_ROOT/UPSTREAM_REV")"
if [[ ! "$REV" =~ ^[0-9a-f]{40}$ ]]; then
  echo "UPSTREAM_REV must be one lowercase 40-hex commit SHA" >&2
  exit 1
fi

SRC=""
CLEANUP_DIR=""
STAGED_BIN=""
cleanup() {
  if [ -n "$STAGED_BIN" ] && [ -e "$STAGED_BIN" ]; then rm -f "$STAGED_BIN"; fi
  if [ -n "$CLEANUP_DIR" ]; then rm -rf "$CLEANUP_DIR"; fi
  return 0
}
trap cleanup EXIT

if [ "$PINNED" -eq 0 ] && [ -d "$REPO_ROOT/upstream/.git" ]; then
  SRC="$REPO_ROOT/upstream"
  echo "==> building from local upstream checkout: $SRC"
  echo "    (working-tree state, not necessarily UPSTREAM_REV $REV;"
  echo "     use --pinned to build the same pinned source snapshot)"
else
  CLEANUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/atp-upstream.XXXXXX")"
  SRC="$CLEANUP_DIR/asupersync"
  echo "==> cloning $UPSTREAM_REPO @ $REV"
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$UPSTREAM_REPO"
  git -C "$SRC" fetch -q --depth 1 origin "$REV"
  git -C "$SRC" checkout -q FETCH_HEAD
  ACTUAL_REV="$(git -C "$SRC" rev-parse HEAD)"
  if [ "$ACTUAL_REV" != "$REV" ]; then
    echo "upstream checkout mismatch: expected $REV, got $ACTUAL_REV" >&2
    exit 1
  fi
  git -C "$SRC" fetch -q --filter=blob:none origin main
  if ! git -C "$SRC" merge-base --is-ancestor "$REV" origin/main; then
    echo "pinned upstream commit $REV is not contained in origin/main" >&2
    exit 1
  fi
fi

BUILD_ARGS=(build --release --locked --bin atp --features atp-cli)
BIN_SUBPATH="release/atp"
if [ -n "$TARGET" ]; then
  BUILD_ARGS+=(--target "$TARGET")
  BIN_SUBPATH="$TARGET/release/atp"
  # Run inside the source tree so the target lands on the toolchain pinned by
  # its rust-toolchain.toml, not whatever toolchain is active in this repo.
  (cd "$SRC" && rustup target add "$TARGET")
fi

echo "==> cargo ${BUILD_ARGS[*]}"
(cd "$SRC" && cargo "${BUILD_ARGS[@]}")

mkdir -p "$OUT_DIR"
FINAL_BIN="$OUT_DIR/atp"
if [ -d "$FINAL_BIN" ]; then
  echo "output path is a directory: $FINAL_BIN" >&2
  exit 1
fi
STAGED_BIN="$(mktemp "$OUT_DIR/.atp-build.XXXXXX")"
install -m 0755 "$SRC/target/$BIN_SUBPATH" "$STAGED_BIN"

HOST_TARGET="$(cd "$SRC" && rustc -vV | sed -n 's/^host: //p')"
BUILT_TARGET="${TARGET:-$HOST_TARGET}"
if [ "$BUILT_TARGET" = "$HOST_TARGET" ]; then
  "$STAGED_BIN" --version
else
  echo "==> foreign target $BUILT_TARGET built successfully; runtime smoke test skipped on $HOST_TARGET"
fi

# Recheck after the build and smoke test so an existing binary is preserved on
# every failure, including a concurrent directory appearing at the destination.
if [ -d "$FINAL_BIN" ]; then
  echo "output path became a directory: $FINAL_BIN" >&2
  exit 1
fi
STAGED_NAME="${STAGED_BIN##*/}"
mv -f "$STAGED_BIN" "$FINAL_BIN"
# POSIX `mv source existing-directory` succeeds by moving the source inside the
# directory. Detect that destination race and remove the misplaced staged file
# instead of reporting a build that did not install `atp`.
if [ -d "$FINAL_BIN" ]; then
  if [ -e "$FINAL_BIN/$STAGED_NAME" ] || [ -L "$FINAL_BIN/$STAGED_NAME" ]; then
    rm -f "$FINAL_BIN/$STAGED_NAME"
  fi
  echo "output path became a directory during install: $FINAL_BIN" >&2
  exit 1
fi
STAGED_BIN=""
echo "==> built: $FINAL_BIN"
