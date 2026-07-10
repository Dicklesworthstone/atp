#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_HELPER="$SCRIPT_DIR/build-atp.sh"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"
ORIGINAL_PATH="$PATH"
REAL_MV=$(command -v mv)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/atp-build-tests.XXXXXX")
FAKE_BIN="$TEST_TMP/fake-bin"
PASS_COUNT=0

cleanup() {
  if [ "${KEEP_TEST_TMP:-0}" = "1" ]; then
    printf 'kept test workspace: %s\n' "$TEST_TMP"
  else
    rm -rf "$TEST_TMP"
  fi
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [ -n "${LAST_OUTPUT:-}" ] && [ -f "$LAST_OUTPUT" ]; then
    printf '%s\n' '--- build helper output ---' >&2
    sed -n '1,160p' "$LAST_OUTPUT" >&2
  fi
  exit 1
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok %02d - %s\n' "$PASS_COUNT" "$1"
}

expect_rc() {
  local expected="$1"
  local label="$2"
  [ "$LAST_RC" -eq "$expected" ] || fail "$label: expected rc=$expected, got rc=$LAST_RC"
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -F -- "$needle" "$file" >/dev/null 2>&1 || fail "missing '$needle' in $file"
}

assert_not_contains() {
  local needle="$1"
  local file="$2"
  if grep -F -- "$needle" "$file" >/dev/null 2>&1; then
    fail "unexpected '$needle' in $file"
  fi
}

assert_empty_or_missing() {
  local file="$1"
  [ ! -s "$file" ] || fail "expected empty or missing file: $file"
}

assert_no_stage_files() {
  local out_dir="$1"
  if compgen -G "$out_dir/.atp-build.*" >/dev/null; then
    fail "staged build file leaked in $out_dir"
  fi
}

make_existing_binary() {
  local path="$1"
  local version="$2"
  cat > "$path" <<EOF
#!/bin/sh
if [ "\${1:-}" = "--version" ]; then
  printf '%s\n' 'atp $version'
fi
EOF
  chmod 0755 "$path"
}

mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_LOG_DIR:?}/git.log"
if [ "${1:-}" = "init" ]; then
  destination="${3:?}"
  case "$destination" in
    "${FAKE_TEST_ROOT:?}"/*) : ;;
    *) printf 'fake git init escaped test root: %s\n' "$destination" >&2; exit 91 ;;
  esac
  mkdir -p "$destination/.git"
  exit 0
fi
if [ "${1:-}" = "-C" ]; then
  source_dir="${2:?}"
  command_name="${3:?}"
  case "$command_name" in
    rev-parse) printf '%s\n' "${FAKE_REV:?}" ;;
    remote|fetch|checkout|merge-base) : ;;
    *) printf 'unexpected fake git command: %s\n' "$*" >&2; exit 90 ;;
  esac
  case "$source_dir" in
    "${FAKE_TEST_ROOT:?}"/*) : ;;
    *) printf 'fake git escaped test root: %s\n' "$source_dir" >&2; exit 91 ;;
  esac
  exit 0
fi
printf 'unexpected fake git invocation: %s\n' "$*" >&2
exit 92
EOF

cat > "$FAKE_BIN/cargo" <<'EOF'
#!/bin/sh
case "$PWD" in
  "${FAKE_TEST_ROOT:?}"/*) : ;;
  *) printf 'fake cargo escaped test root: %s\n' "$PWD" >&2; exit 93 ;;
esac
driver=${0##*/}
printf '%s\n' "$*" >> "${FAKE_LOG_DIR:?}/$driver.log"
target=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "--target" ]; then
    target="$argument"
    previous=""
    continue
  fi
  previous="$argument"
done
if [ -n "$target" ]; then
  case "$target" in
    *-windows-*) binary="target/$target/release/atp.exe" ;;
    *) binary="target/$target/release/atp" ;;
  esac
else
  case "${FAKE_HOST_TARGET:-x86_64-unknown-linux-gnu}" in
    *-windows-*) binary="target/release/atp.exe" ;;
    *) binary="target/release/atp" ;;
  esac
fi
mkdir -p "$(dirname "$binary")"
cat > "$binary" <<SCRIPT
#!/bin/sh
if [ -n "${FAKE_EXEC_MARKER:-}" ]; then
  printf '%s\n' executed > "${FAKE_EXEC_MARKER:-/dev/null}"
fi
if [ "\${1:-}" = "--version" ]; then
  printf '%s\n' '${FAKE_VERSION_TEXT:-atp 9.9.9}'
  exit ${FAKE_VERSION_STATUS:-0}
fi
exit 0
SCRIPT
chmod 0755 "$binary"
EOF

cp "$FAKE_BIN/cargo" "$FAKE_BIN/cross"

cat > "$FAKE_BIN/rustc" <<'EOF'
#!/bin/sh
case "$PWD" in
  "${FAKE_TEST_ROOT:?}"/*) : ;;
  *) printf 'fake rustc escaped test root: %s\n' "$PWD" >&2; exit 94 ;;
esac
printf '%s\n' "$*" >> "${FAKE_LOG_DIR:?}/rustc.log"
printf '%s\n' 'rustc 1.99.0 (fake)' 'binary: rustc' 'commit-hash: fake' \
  'commit-date: 2099-01-01' "host: ${FAKE_HOST_TARGET:-x86_64-unknown-linux-gnu}"
EOF

cat > "$FAKE_BIN/rustup" <<'EOF'
#!/bin/sh
case "$PWD" in
  "${FAKE_TEST_ROOT:?}"/*) : ;;
  *) printf 'fake rustup escaped test root: %s\n' "$PWD" >&2; exit 95 ;;
esac
printf '%s\n' "$*" >> "${FAKE_LOG_DIR:?}/rustup.log"
exit 0
EOF

cat > "$FAKE_BIN/mv" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_LOG_DIR:?}/mv.log"
if [ -n "${FAKE_MV_RACE_DIR:-}" ]; then
  case "$FAKE_MV_RACE_DIR" in
    "${FAKE_TEST_ROOT:?}"/*) : ;;
    *) printf 'fake mv race escaped test root: %s\n' "$FAKE_MV_RACE_DIR" >&2; exit 96 ;;
  esac
  rm -f "$FAKE_MV_RACE_DIR"
  mkdir -p "$FAKE_MV_RACE_DIR"
fi
exec "${REAL_MV:?}" "$@"
EOF

chmod 0755 "$FAKE_BIN/git" "$FAKE_BIN/cargo" "$FAKE_BIN/cross" "$FAKE_BIN/rustc" \
  "$FAKE_BIN/rustup" "$FAKE_BIN/mv"

REV=$(tr -d '[:space:]' < "$REPO_ROOT/UPSTREAM_REV")
RUN_VERSION_STATUS=0
RUN_VERSION_TEXT="atp 9.9.9"
RUN_EXEC_MARKER=""
RUN_HOST_TARGET="x86_64-unknown-linux-gnu"
RUN_MV_RACE_DIR=""
RUN_CROSS_DRIVER="$FAKE_BIN/cross"
LAST_RC=0
LAST_OUTPUT=""
LAST_LOG_DIR=""

run_build() {
  local name="$1"
  shift
  local run_root="$TEST_TMP/run-$name"
  local run_tmp="$run_root/tmp"
  LAST_LOG_DIR="$run_root/logs"
  LAST_OUTPUT="$run_root/output"
  mkdir -p "$run_tmp" "$LAST_LOG_DIR"

  set +e
  env \
    HOME="$run_root/home" \
    TMPDIR="$run_tmp" \
    PATH="$FAKE_BIN:$ORIGINAL_PATH" \
    UPSTREAM_REPO="https://invalid.test/asupersync" \
    FAKE_LOG_DIR="$LAST_LOG_DIR" \
    FAKE_REV="$REV" \
    FAKE_TEST_ROOT="$TEST_TMP" \
    FAKE_VERSION_STATUS="$RUN_VERSION_STATUS" \
    FAKE_VERSION_TEXT="$RUN_VERSION_TEXT" \
    FAKE_EXEC_MARKER="$RUN_EXEC_MARKER" \
    FAKE_HOST_TARGET="$RUN_HOST_TARGET" \
    FAKE_MV_RACE_DIR="$RUN_MV_RACE_DIR" \
    ATP_CROSS_DRIVER="$RUN_CROSS_DRIVER" \
    REAL_MV="$REAL_MV" \
    "$BASH_BIN" "$BUILD_HELPER" --pinned "$@" > "$LAST_OUTPUT" 2>&1
  LAST_RC=$?
  set -e

  RUN_VERSION_STATUS=0
  RUN_VERSION_TEXT="atp 9.9.9"
  RUN_EXEC_MARKER=""
  RUN_HOST_TARGET="x86_64-unknown-linux-gnu"
  RUN_MV_RACE_DIR=""
  RUN_CROSS_DRIVER="$FAKE_BIN/cross"
}

out_dir="$TEST_TMP/out-native-failure"
mkdir -p "$out_dir"
make_existing_binary "$out_dir/atp" "0.1.0"
cp "$out_dir/atp" "$TEST_TMP/native-failure-old"
RUN_VERSION_STATUS=42
RUN_VERSION_TEXT="atp 9.9.9"
run_build native-version-failure --out "$out_dir"
expect_rc 42 "native staged --version failure"
cmp "$out_dir/atp" "$TEST_TMP/native-failure-old" >/dev/null || \
  fail "native smoke failure replaced the existing binary"
[ ! -s "$LAST_LOG_DIR/mv.log" ] || fail "native smoke failure reached final mv"
assert_no_stage_files "$out_dir"
pass "native staged --version failure preserves the existing output"

out_dir="$TEST_TMP/out-native-success"
mkdir -p "$out_dir"
make_existing_binary "$out_dir/atp" "0.1.0"
cp "$out_dir/atp" "$TEST_TMP/native-success-old"
RUN_VERSION_STATUS=0
RUN_VERSION_TEXT="atp 9.9.9"
run_build native-success --out "$out_dir"
expect_rc 0 "native successful build"
[ "$("$out_dir/atp" --version)" = "atp 9.9.9" ] || fail "native binary was not replaced"
if cmp "$out_dir/atp" "$TEST_TMP/native-success-old" >/dev/null; then
  fail "native success left the old binary in place"
fi
assert_contains "/.atp-build." "$LAST_LOG_DIR/mv.log"
assert_contains "$out_dir/atp" "$LAST_LOG_DIR/mv.log"
assert_no_stage_files "$out_dir"
pass "successful native smoke atomically replaces the output"

out_dir="$TEST_TMP/out-native-explicit-target"
mkdir -p "$out_dir"
make_existing_binary "$out_dir/atp" "0.1.0"
native_target_marker="$TEST_TMP/native-target-executed"
RUN_VERSION_TEXT="atp 9.9.8"
RUN_EXEC_MARKER="$native_target_marker"
run_build native-explicit-target --out "$out_dir" --target x86_64-unknown-linux-gnu
expect_rc 0 "explicit native target build"
[ -f "$native_target_marker" ] || fail "explicit native target skipped its runtime smoke test"
[ "$("$out_dir/atp" --version)" = "atp 9.9.8" ] || fail "explicit native target was not installed"
assert_contains "target add x86_64-unknown-linux-gnu" "$LAST_LOG_DIR/rustup.log"
assert_contains "--target x86_64-unknown-linux-gnu" "$LAST_LOG_DIR/cargo.log"
assert_empty_or_missing "$LAST_LOG_DIR/cross.log"
assert_not_contains "runtime smoke test skipped" "$LAST_OUTPUT"
assert_no_stage_files "$out_dir"
pass "explicit host target stays on cargo and runs native smoke"

out_dir="$TEST_TMP/out-directory-target"
mkdir -p "$out_dir/atp"
printf '%s\n' keep > "$out_dir/atp/sentinel"
run_build directory-target --out "$out_dir"
expect_rc 1 "directory output target"
assert_contains "output path is a directory" "$LAST_OUTPUT"
[ -f "$out_dir/atp/sentinel" ] || fail "directory output target was mutated"
[ ! -s "$LAST_LOG_DIR/mv.log" ] || fail "directory output target reached mv"
assert_no_stage_files "$out_dir"
pass "existing directory output is rejected and preserved"

out_dir="$TEST_TMP/out-symlink-directory-target"
mkdir -p "$out_dir/actual-directory"
printf '%s\n' keep > "$out_dir/actual-directory/sentinel"
ln -s actual-directory "$out_dir/atp"
run_build symlink-directory-target --out "$out_dir"
expect_rc 1 "symlink-to-directory output target"
assert_contains "output path is a directory" "$LAST_OUTPUT"
[ -L "$out_dir/atp" ] || fail "symlink-to-directory output was replaced"
[ -f "$out_dir/actual-directory/sentinel" ] || fail "symlink target was mutated"
[ ! -s "$LAST_LOG_DIR/mv.log" ] || fail "symlink-to-directory output reached mv"
assert_no_stage_files "$out_dir"
pass "symlink-to-directory output is rejected and preserved"

out_dir="$TEST_TMP/out-directory-race"
mkdir -p "$out_dir"
make_existing_binary "$out_dir/atp" "0.1.0"
RUN_MV_RACE_DIR="$out_dir/atp"
run_build directory-race --out "$out_dir"
expect_rc 1 "directory output race"
assert_contains "output path became a directory during install" "$LAST_OUTPUT"
[ -d "$out_dir/atp" ] || fail "injected directory race did not create the destination directory"
if compgen -G "$out_dir/atp/.atp-build.*" >/dev/null; then
  fail "directory race leaked the staged binary inside the destination directory"
fi
assert_no_stage_files "$out_dir"
pass "concurrent directory replacement fails without reporting a false install"

for cross_target in \
  x86_64-unknown-linux-musl \
  aarch64-unknown-linux-gnu \
  aarch64-unknown-linux-musl
do
  case "$cross_target" in
    x86_64-unknown-linux-musl) cross_label="x86-musl" ;;
    aarch64-unknown-linux-gnu) cross_label="arm-gnu" ;;
    aarch64-unknown-linux-musl) cross_label="arm-musl" ;;
  esac
  out_dir="$TEST_TMP/out-cross-$cross_label"
  mkdir -p "$out_dir"
  make_existing_binary "$out_dir/atp" "0.1.0"
  cross_marker="$TEST_TMP/cross-$cross_label-executed"
  RUN_VERSION_STATUS=97
  RUN_VERSION_TEXT="atp 8.8.8-$cross_label"
  RUN_EXEC_MARKER="$cross_marker"
  run_build "cross-$cross_label" --out "$out_dir" --target "$cross_target"
  expect_rc 0 "$cross_target build"
  assert_contains "runtime smoke test skipped" "$LAST_OUTPUT"
  [ ! -e "$cross_marker" ] || fail "$cross_target binary was executed"
  [ -x "$out_dir/atp" ] || fail "$cross_target binary was not installed"
  assert_contains "atp 8.8.8-$cross_label" "$out_dir/atp"
  assert_contains "--target $cross_target" "$LAST_LOG_DIR/cross.log"
  assert_empty_or_missing "$LAST_LOG_DIR/cargo.log"
  assert_empty_or_missing "$LAST_LOG_DIR/rustup.log"
  assert_contains "/.atp-build." "$LAST_LOG_DIR/mv.log"
  assert_no_stage_files "$out_dir"
  pass "$cross_target uses cross, skips execution, and installs atomically"
done

out_dir="$TEST_TMP/out-missing-cross-driver"
mkdir -p "$out_dir"
make_existing_binary "$out_dir/atp" "0.1.0"
cp "$out_dir/atp" "$TEST_TMP/missing-cross-driver-old"
RUN_CROSS_DRIVER="missing-atp-cross-driver"
run_build missing-cross-driver --out "$out_dir" --target aarch64-unknown-linux-gnu
expect_rc 1 "missing cross driver"
assert_contains "required build driver not found" "$LAST_OUTPUT"
cmp "$out_dir/atp" "$TEST_TMP/missing-cross-driver-old" >/dev/null || \
  fail "missing cross driver replaced the existing output"
assert_empty_or_missing "$LAST_LOG_DIR/cargo.log"
assert_empty_or_missing "$LAST_LOG_DIR/cross.log"
assert_empty_or_missing "$LAST_LOG_DIR/rustup.log"
assert_empty_or_missing "$LAST_LOG_DIR/mv.log"
assert_no_stage_files "$out_dir"
pass "missing cross driver fails before build and preserves existing output"

out_dir="$TEST_TMP/out-windows-target"
mkdir -p "$out_dir"
make_existing_binary "$out_dir/atp.exe" "0.1.0"
cp "$out_dir/atp.exe" "$TEST_TMP/windows-target-old"
windows_marker="$TEST_TMP/windows-executed"
RUN_HOST_TARGET="x86_64-pc-windows-msvc"
RUN_VERSION_STATUS=0
RUN_VERSION_TEXT="atp 7.7.7"
RUN_EXEC_MARKER="$windows_marker"
run_build windows-target --out "$out_dir" --target x86_64-pc-windows-msvc
expect_rc 0 "Windows target build"
[ -f "$windows_marker" ] || fail "native Windows binary skipped its runtime smoke test"
assert_not_contains "runtime smoke test skipped" "$LAST_OUTPUT"
[ -x "$out_dir/atp.exe" ] || fail "Windows binary was not installed with its .exe suffix"
[ ! -e "$out_dir/atp" ] || fail "Windows build created an extensionless output"
if cmp "$out_dir/atp.exe" "$TEST_TMP/windows-target-old" >/dev/null; then
  fail "Windows success left the old binary in place"
fi
assert_contains "atp 7.7.7" "$out_dir/atp.exe"
assert_contains "target add x86_64-pc-windows-msvc" "$LAST_LOG_DIR/rustup.log"
assert_contains "--target x86_64-pc-windows-msvc" "$LAST_LOG_DIR/cargo.log"
assert_contains "/.atp-build." "$LAST_LOG_DIR/mv.log"
assert_contains "$out_dir/atp.exe" "$LAST_LOG_DIR/mv.log"
assert_empty_or_missing "$LAST_LOG_DIR/cross.log"
assert_no_stage_files "$out_dir"
pass "native Windows target smokes, preserves .exe naming, and installs atomically"

for git_log in "$TEST_TMP"/run-*/logs/git.log; do
  if grep -F -- "$REPO_ROOT/upstream" "$git_log" >/dev/null 2>&1; then
    fail "fake build touched the real upstream checkout"
  fi
done
pass "all builds used fake pinned clones under the sandbox"

printf 'PASS: %d build helper regression groups\n' "$PASS_COUNT"
