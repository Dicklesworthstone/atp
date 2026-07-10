#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
INSTALLER="$REPO_ROOT/install.sh"
BASH_BIN="${BASH_BIN:-/bin/bash}"
ORIGINAL_PATH="$PATH"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/atp-install-tests.XXXXXX")
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
    printf '%s\n' '--- installer output ---' >&2
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

assert_not_exists() {
  [ ! -e "$1" ] || fail "unexpected path exists: $1"
}

assert_no_network() {
  [ ! -s "$LAST_NETWORK_LOG" ] || fail "unexpected curl call in offline test: $(cat "$LAST_NETWORK_LOG")"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

make_binary() {
  local path="$1"
  local version="$2"
  local rq_status="$3"
  cat > "$path" <<EOF
#!/bin/sh
case "\${1:-}" in
  --version) printf '%s\n' 'atp $version' ;;
  rq-keygen) exit $rq_status ;;
  *) exit 0 ;;
esac
EOF
  chmod 0755 "$path"
}

NO_NETWORK_BIN="$TEST_TMP/no-network-bin"
mkdir -p "$NO_NETWORK_BIN"
cat > "$NO_NETWORK_BIN/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${NETWORK_LOG:?}"
exit 22
EOF
chmod 0755 "$NO_NETWORK_BIN/curl"

RUN_HOME=""
RUN_PATH=""
RUN_ARTIFACT_URL=""
RUN_FALLBACK_ARCHIVE=""
RUN_ONLINE_ARCHIVE=""
RUN_ONLINE_SIGNATURE=""
RUN_ONLINE_SIGNATURE_STATUS=""
RUN_DISABLE_MINISIGN_SHIM=0
LAST_RC=0
LAST_OUTPUT=""
LAST_NETWORK_LOG=""
LAST_MINISIGN_LOG=""

run_installer() {
  local name="$1"
  shift
  local home="${RUN_HOME:-$TEST_TMP/home-$name}"
  local run_tmp="$TEST_TMP/tmp-$name"
  local run_path="${RUN_PATH:-$NO_NETWORK_BIN:$ORIGINAL_PATH}"
  if [ "$RUN_DISABLE_MINISIGN_SHIM" -eq 0 ] && [ -n "${ONLINE_MINISIGN_BIN:-}" ]; then
    run_path="$ONLINE_MINISIGN_BIN:$run_path"
  fi
  mkdir -p "$home" "$run_tmp"
  LAST_OUTPUT="$TEST_TMP/$name.out"
  LAST_NETWORK_LOG="$TEST_TMP/$name.network"
  LAST_MINISIGN_LOG="$TEST_TMP/$name.minisign"
  : > "$LAST_NETWORK_LOG"
  : > "$LAST_MINISIGN_LOG"

  set +e
  env \
    HOME="$home" \
    TMPDIR="$run_tmp" \
    PATH="$run_path" \
    NETWORK_LOG="$LAST_NETWORK_LOG" \
    MINISIGN_LOG="$LAST_MINISIGN_LOG" \
    FALLBACK_ARCHIVE="$RUN_FALLBACK_ARCHIVE" \
    ONLINE_ARCHIVE="$RUN_ONLINE_ARCHIVE" \
    ONLINE_SIGNATURE="$RUN_ONLINE_SIGNATURE" \
    ONLINE_SIGNATURE_STATUS="$RUN_ONLINE_SIGNATURE_STATUS" \
    VERSION="" CHECKSUM="" ARTIFACT_URL="$RUN_ARTIFACT_URL" \
    HTTPS_PROXY="" HTTP_PROXY="" \
    "$BASH_BIN" "$INSTALLER" --no-gum "$@" > "$LAST_OUTPUT" 2>&1
  LAST_RC=$?
  set -e

  RUN_HOME=""
  RUN_PATH=""
  RUN_ARTIFACT_URL=""
  RUN_FALLBACK_ARCHIVE=""
  RUN_ONLINE_ARCHIVE=""
  RUN_ONLINE_SIGNATURE=""
  RUN_ONLINE_SIGNATURE_STATUS=""
  RUN_DISABLE_MINISIGN_SHIM=0
}

FIXTURES="$TEST_TMP/fixtures"
mkdir -p "$FIXTURES/valid" "$FIXTURES/fail-self-test" "$FIXTURES/nested/pkg" \
  "$FIXTURES/duplicate/pkg" "$FIXTURES/nonregular" "$FIXTURES/hardlink" "$FIXTURES/fifo" \
  "$FIXTURES/release-0.3.7" "$FIXTURES/release-0.3.8"

make_binary "$FIXTURES/valid/atp" "1.2.3" 0
printf '%s\n' 'fixture license' > "$FIXTURES/valid/LICENSE"
tar -C "$FIXTURES/valid" -czf "$FIXTURES/valid.tar.gz" atp LICENSE
VALID_SUM=$(sha256_file "$FIXTURES/valid.tar.gz")

make_binary "$FIXTURES/release-0.3.7/atp" "0.3.7" 0
printf '%s\n' 'fixture license' > "$FIXTURES/release-0.3.7/LICENSE"
tar -C "$FIXTURES/release-0.3.7" -czf "$FIXTURES/release-0.3.7.tar.gz" atp LICENSE
LEGACY_037_SUM=$(sha256_file "$FIXTURES/release-0.3.7.tar.gz")

make_binary "$FIXTURES/release-0.3.8/atp" "0.3.8" 0
printf '%s\n' 'fixture license' > "$FIXTURES/release-0.3.8/LICENSE"
tar -C "$FIXTURES/release-0.3.8" -czf "$FIXTURES/release-0.3.8.tar.gz" atp LICENSE
BOUNDARY_038_SUM=$(sha256_file "$FIXTURES/release-0.3.8.tar.gz")

make_binary "$FIXTURES/fail-self-test/atp" "1.2.3" 42
tar -C "$FIXTURES/fail-self-test" -czf "$FIXTURES/fail-self-test.tar.gz" atp
FAIL_SELF_TEST_SUM=$(sha256_file "$FIXTURES/fail-self-test.tar.gz")

cp "$FIXTURES/valid/atp" "$FIXTURES/nested/pkg/atp"
tar -C "$FIXTURES/nested" -czf "$FIXTURES/nested.tar.gz" pkg/atp
NESTED_SUM=$(sha256_file "$FIXTURES/nested.tar.gz")

cp "$FIXTURES/valid/atp" "$FIXTURES/duplicate/atp"
cp "$FIXTURES/valid/atp" "$FIXTURES/duplicate/pkg/atp"
tar -C "$FIXTURES/duplicate" -czf "$FIXTURES/duplicate.tar.gz" atp pkg/atp
DUPLICATE_SUM=$(sha256_file "$FIXTURES/duplicate.tar.gz")

ln -s ../valid/atp "$FIXTURES/nonregular/atp"
tar -C "$FIXTURES/nonregular" -czf "$FIXTURES/nonregular.tar.gz" atp
NONREGULAR_SUM=$(sha256_file "$FIXTURES/nonregular.tar.gz")

cp "$FIXTURES/valid/atp" "$FIXTURES/hardlink/original"
ln "$FIXTURES/hardlink/original" "$FIXTURES/hardlink/atp"
tar -C "$FIXTURES/hardlink" -czf "$FIXTURES/hardlink.tar.gz" original atp
HARDLINK_SUM=$(sha256_file "$FIXTURES/hardlink.tar.gz")

mkfifo "$FIXTURES/fifo/atp"
tar -C "$FIXTURES/fifo" -czf "$FIXTURES/fifo.tar.gz" atp
FIFO_SUM=$(sha256_file "$FIXTURES/fifo.tar.gz")

# Deterministic online-release harness. The curl shim serves one archive and
# optional sidecar signature; the minisign shim enforces that the sidecar binds
# the archive hash and that the installer supplied ATP's embedded public key.
VALID_SIGNATURE="$FIXTURES/valid.tar.gz.minisig"
printf '%s\n' "$VALID_SUM" > "$VALID_SIGNATURE"
LEGACY_037_SIGNATURE="$FIXTURES/release-0.3.7.tar.gz.minisig"
printf '%s\n' "$LEGACY_037_SUM" > "$LEGACY_037_SIGNATURE"
BOUNDARY_038_SIGNATURE="$FIXTURES/release-0.3.8.tar.gz.minisig"
printf '%s\n' "$BOUNDARY_038_SUM" > "$BOUNDARY_038_SIGNATURE"
printf '%s\n' "$FAIL_SELF_TEST_SUM" > "$FIXTURES/fail-self-test.tar.gz.minisig"
printf '%s\n' "$NESTED_SUM" > "$FIXTURES/nested.tar.gz.minisig"
printf '%s\n' "$DUPLICATE_SUM" > "$FIXTURES/duplicate.tar.gz.minisig"
printf '%s\n' "$NONREGULAR_SUM" > "$FIXTURES/nonregular.tar.gz.minisig"
printf '%s\n' "$HARDLINK_SUM" > "$FIXTURES/hardlink.tar.gz.minisig"
printf '%s\n' "$FIFO_SUM" > "$FIXTURES/fifo.tar.gz.minisig"
OFFLINE_MISSING_SIGNATURE_ARCHIVE="$FIXTURES/offline-missing-signature.tar.gz"
cp "$FIXTURES/valid.tar.gz" "$OFFLINE_MISSING_SIGNATURE_ARCHIVE"
OFFLINE_MISSING_SIGNATURE_SUM=$(sha256_file "$OFFLINE_MISSING_SIGNATURE_ARCHIVE")
OFFLINE_TAMPERED_SIGNATURE_ARCHIVE="$FIXTURES/offline-tampered-signature.tar.gz"
cp "$FIXTURES/valid.tar.gz" "$OFFLINE_TAMPERED_SIGNATURE_ARCHIVE"
OFFLINE_TAMPERED_SIGNATURE_SUM=$(sha256_file "$OFFLINE_TAMPERED_SIGNATURE_ARCHIVE")
TAMPERED_ARCHIVE="$FIXTURES/tampered.tar.gz"
cp "$FIXTURES/valid.tar.gz" "$TAMPERED_ARCHIVE"
printf '%s\n' tampered >> "$TAMPERED_ARCHIVE"
TAMPERED_SUM=$(sha256_file "$TAMPERED_ARCHIVE")
TAMPERED_SIGNATURE="$FIXTURES/tampered.minisig"
printf '%064d\n' 0 > "$TAMPERED_SIGNATURE"
cp "$TAMPERED_SIGNATURE" "$OFFLINE_TAMPERED_SIGNATURE_ARCHIVE.minisig"
OFFLINE_LEGACY_MISSING_SIGNATURE_ARCHIVE="$FIXTURES/offline-legacy-missing-signature.tar.gz"
cp "$FIXTURES/release-0.3.7.tar.gz" "$OFFLINE_LEGACY_MISSING_SIGNATURE_ARCHIVE"
OFFLINE_LEGACY_MISSING_SIGNATURE_SUM=$(sha256_file "$OFFLINE_LEGACY_MISSING_SIGNATURE_ARCHIVE")

ONLINE_BASE_BIN="$TEST_TMP/online-base-bin"
ONLINE_MINISIGN_BIN="$TEST_TMP/online-minisign-bin"
mkdir -p "$ONLINE_BASE_BIN" "$ONLINE_MINISIGN_BIN"
for command_name in uname tr grep basename dirname df awk mkdir mktemp cp rm cat \
  sleep cut head sed tar gzip install mv; do
  command_path=$(command -v "$command_name") || fail "required test command is missing: $command_name"
  ln -s "$command_path" "$ONLINE_BASE_BIN/$command_name"
done
hash_tool_found=0
for command_name in sha256sum shasum; do
  if command_path=$(command -v "$command_name" 2>/dev/null); then
    ln -s "$command_path" "$ONLINE_BASE_BIN/$command_name"
    hash_tool_found=1
  fi
done
[ "$hash_tool_found" -eq 1 ] || fail "online authentication tests require sha256sum or shasum"
cat > "$ONLINE_BASE_BIN/curl" <<'EOF'
#!/bin/sh
output=""
url=""
write_status=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) write_status=1; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >> "${NETWORK_LOG:?}"
if [ "$output" = "/dev/null" ]; then
  exit 0
fi
case "$url" in
  *.minisig)
    if [ -n "${ONLINE_SIGNATURE:-}" ] && [ -f "$ONLINE_SIGNATURE" ]; then
      cp "$ONLINE_SIGNATURE" "$output"
      [ "$write_status" -eq 0 ] || printf '200'
      exit 0
    fi
    status="${ONLINE_SIGNATURE_STATUS:-404}"
    [ "$write_status" -eq 0 ] || printf '%s' "$status"
    [ "$status" = "000" ] && exit 7
    exit 22
    ;;
  *)
    [ -n "${ONLINE_ARCHIVE:-}" ] && [ -f "$ONLINE_ARCHIVE" ] || exit 22
    cp "$ONLINE_ARCHIVE" "$output"
    ;;
esac
EOF
chmod 0755 "$ONLINE_BASE_BIN/curl"

cat > "$ONLINE_MINISIGN_BIN/minisign" <<'EOF'
#!/bin/sh
archive=""
signature=""
pubkey=""
printf '%s\n' "$*" >> "${MINISIGN_LOG:?}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -Vm) archive="$2"; shift 2 ;;
    -x) signature="$2"; shift 2 ;;
    -P) pubkey="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "$pubkey" = "RWTQGPeLsnm9G7VFdFWkkcRi3wJK/PqsYxWC+oLNN74W9IjBxRU1Xu70" ] || exit 2
[ -f "$archive" ] && [ -f "$signature" ] || exit 2
expected=$(awk 'NR == 1 { print $1 }' "$signature")
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$archive" | awk '{ print $1 }')
else
  actual=$(shasum -a 256 "$archive" | awk '{ print $1 }')
fi
[ "$actual" = "$expected" ]
EOF
chmod 0755 "$ONLINE_MINISIGN_BIN/minisign"

set +e
env -u HOME "$BASH_BIN" "$INSTALLER" --help > "$TEST_TMP/help-without-home.out" 2>&1
help_without_home_rc=$?
set -e
[ "$help_without_home_rc" -eq 0 ] || fail "--help requires HOME"
assert_contains "Usage: install.sh" "$TEST_TMP/help-without-home.out"
pass "help is available when HOME is unset"

for option in --version --dest --offline --checksum; do
  name="missing-${option#--}"
  run_installer "$name" "$option"
  expect_rc 2 "$option missing operand"
  assert_contains "$option requires a value" "$LAST_OUTPUT"
  assert_no_network
done
run_installer missing-before-next-option --checksum --quiet
expect_rc 2 "missing operand before another option"
assert_contains "--checksum requires a value" "$LAST_OUTPUT"
assert_no_network
pass "value-taking options reject missing operands with exit 2"

dest="$TEST_TMP/dest-missing-checksum"
run_installer missing-checksum --offline "$FIXTURES/valid.tar.gz" --dest "$dest" --force
expect_rc 1 "missing checksum"
assert_contains "No checksum found" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
assert_no_network
pass "offline install fails closed when checksum is missing"

dest="$TEST_TMP/dest-malformed-checksum"
run_installer malformed-checksum --offline "$FIXTURES/valid.tar.gz" --checksum bad --dest "$dest" --force
expect_rc 2 "malformed checksum"
assert_contains "--checksum requires exactly 64 hexadecimal characters" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
assert_no_network
pass "malformed checksum is rejected"

dest="$TEST_TMP/dest-wrong-checksum"
run_installer wrong-checksum --offline "$FIXTURES/valid.tar.gz" \
  --checksum 0000000000000000000000000000000000000000000000000000000000000000 \
  --dest "$dest" --force
expect_rc 1 "wrong checksum"
assert_contains "Checksum verification FAILED" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
assert_no_network
pass "well-formed checksum mismatch is rejected"

colon_dest="$TEST_TMP/bin:split"
run_installer colon-destination --offline "$FIXTURES/valid.tar.gz" --checksum "$VALID_SUM" \
  --dest "$colon_dest" --force
expect_rc 2 "colon in destination"
assert_contains "--dest cannot contain ':'" "$LAST_OUTPUT"
assert_not_exists "$colon_dest/atp"
assert_no_network
pass "destinations that cannot be represented in PATH are rejected"

NO_SHA_BIN="$TEST_TMP/no-sha-bin"
mkdir -p "$NO_SHA_BIN"
for command_name in uname tr grep basename dirname df awk mkdir mktemp cp rm cat sleep; do
  ln -s "$(command -v "$command_name")" "$NO_SHA_BIN/$command_name"
done
RUN_PATH="$NO_SHA_BIN"
dest="$TEST_TMP/dest-no-sha"
run_installer no-sha-tool --offline "$FIXTURES/valid.tar.gz" --checksum "$VALID_SUM" --dest "$dest" --force
expect_rc 1 "missing SHA-256 tool"
assert_contains "No SHA-256 tool found" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
assert_no_network
pass "missing SHA-256 tool fails closed"

dest="$TEST_TMP/dest-valid"
run_installer valid-install --offline "$FIXTURES/valid.tar.gz" --checksum "$VALID_SUM" \
  --version v1.2.3 --dest "$dest" --verify --force
expect_rc 0 "valid install"
[ "$("$dest/atp" --version)" = "atp 1.2.3" ] || fail "valid binary was not installed"
assert_contains "Self-test passed" "$LAST_OUTPUT"
assert_contains "minisign signature verified" "$LAST_OUTPUT"
[ -s "$LAST_MINISIGN_LOG" ] || fail "verified offline install did not invoke minisign"
assert_no_network
pass "checksummed and signed offline archive validates and installs successfully"

dest="$TEST_TMP/dest-offline-no-minisign"
RUN_PATH="$ONLINE_BASE_BIN"
RUN_DISABLE_MINISIGN_SHIM=1
run_installer offline-no-minisign --offline "$FIXTURES/valid.tar.gz" --checksum "$VALID_SUM" \
  --version v1.2.3 --dest "$dest" --force
expect_rc 1 "offline install without minisign"
assert_contains "minisign is required to authenticate prebuilt release installs" "$LAST_OUTPUT"
assert_not_contains "minisign signature verified" "$LAST_OUTPUT"
[ ! -s "$LAST_MINISIGN_LOG" ] || fail "missing-minisign offline path invoked a verifier"
assert_not_exists "$dest/atp"
assert_no_network
pass "offline release install fails closed when minisign is unavailable"

dest="$TEST_TMP/dest-offline-no-signature"
run_installer offline-no-signature --offline "$OFFLINE_MISSING_SIGNATURE_ARCHIVE" \
  --checksum "$OFFLINE_MISSING_SIGNATURE_SUM" --version v1.2.3 --dest "$dest" --force
expect_rc 1 "offline install without signature"
assert_contains "Required offline minisign signature not found as a regular file" "$LAST_OUTPUT"
assert_not_contains "minisign signature verified" "$LAST_OUTPUT"
[ ! -s "$LAST_MINISIGN_LOG" ] || fail "missing-signature offline path invoked minisign"
assert_not_exists "$dest/atp"
assert_no_network
pass "offline release install fails closed when its sibling signature is unavailable"

dest="$TEST_TMP/dest-offline-legacy-no-signature"
run_installer offline-legacy-no-signature --offline "$OFFLINE_LEGACY_MISSING_SIGNATURE_ARCHIVE" \
  --checksum "$OFFLINE_LEGACY_MISSING_SIGNATURE_SUM" --version v0.3.7 --dest "$dest" --force
expect_rc 1 "legacy offline install without signature"
assert_contains "Required offline minisign signature not found as a regular file" "$LAST_OUTPUT"
assert_not_contains "UNAUTHENTICATED LEGACY RELEASE" "$LAST_OUTPUT"
assert_not_contains "minisign signature verified" "$LAST_OUTPUT"
[ ! -s "$LAST_MINISIGN_LOG" ] || fail "legacy offline missing-signature path invoked minisign"
assert_not_exists "$dest/atp"
assert_no_network
pass "offline verified installs remain signature-fail-closed for legacy versions"

dest="$TEST_TMP/dest-offline-tampered-signature"
run_installer offline-tampered-signature --offline "$OFFLINE_TAMPERED_SIGNATURE_ARCHIVE" \
  --checksum "$OFFLINE_TAMPERED_SIGNATURE_SUM" --version v1.2.3 --dest "$dest" --force
expect_rc 1 "offline install with tampered signature"
assert_contains "Checksum verified" "$LAST_OUTPUT"
assert_contains "minisign signature verification FAILED" "$LAST_OUTPUT"
assert_not_contains "minisign signature verified" "$LAST_OUTPUT"
[ -s "$LAST_MINISIGN_LOG" ] || fail "tampered-signature offline path did not invoke minisign"
assert_not_exists "$dest/atp"
assert_no_network
pass "offline release install rejects a tampered sibling signature"

ONLINE_URL="https://fixtures.test/valid.tar.gz"
dest="$TEST_TMP/dest-online-authenticated"
RUN_PATH="$ONLINE_MINISIGN_BIN:$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/valid.tar.gz"
RUN_ONLINE_SIGNATURE="$VALID_SIGNATURE"
run_installer online-authenticated --version v1.2.3 --checksum "$VALID_SUM" \
  --dest "$dest" --verify --force
expect_rc 0 "authenticated online install"
[ "$("$dest/atp" --version)" = "atp 1.2.3" ] || fail "authenticated online binary was not installed"
assert_contains "Checksum verified" "$LAST_OUTPUT"
assert_contains "minisign signature verified" "$LAST_OUTPUT"
[ "$(grep -Fc 'minisign signature verified' "$LAST_OUTPUT")" -eq 1 ] || \
  fail "authenticated online install did not emit exactly one signature success marker"
[ -s "$LAST_MINISIGN_LOG" ] || fail "authenticated online install did not invoke minisign"
assert_contains "RWTQGPeLsnm9G7VFdFWkkcRi3wJK/PqsYxWC+oLNN74W9IjBxRU1Xu70" "$LAST_MINISIGN_LOG"
assert_contains "${ONLINE_URL}.minisig" "$LAST_NETWORK_LOG"
pass "online release install verifies checksum and minisign before success"

dest="$TEST_TMP/dest-online-boundary-authenticated"
RUN_PATH="$ONLINE_MINISIGN_BIN:$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/release-0.3.8.tar.gz"
RUN_ONLINE_SIGNATURE="$BOUNDARY_038_SIGNATURE"
run_installer online-boundary-authenticated --version v0.3.8 --checksum "$BOUNDARY_038_SUM" \
  --dest "$dest" --force
expect_rc 0 "authenticated v0.3.8 boundary install"
[ "$("$dest/atp" --version)" = "atp 0.3.8" ] || fail "authenticated v0.3.8 binary was not installed"
assert_contains "minisign signature verified" "$LAST_OUTPUT"
assert_not_contains "UNAUTHENTICATED LEGACY RELEASE" "$LAST_OUTPUT"
[ -s "$LAST_MINISIGN_LOG" ] || fail "v0.3.8 boundary install did not invoke minisign"
pass "v0.3.8 boundary installs authenticate normally"

dest="$TEST_TMP/dest-online-legacy-unsigned"
RUN_PATH="$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/release-0.3.7.tar.gz"
RUN_ONLINE_SIGNATURE=""
RUN_DISABLE_MINISIGN_SHIM=1
run_installer online-legacy-unsigned --version v0.3.7 --checksum "$LEGACY_037_SUM" \
  --dest "$dest" --force
expect_rc 0 "unsigned legacy v0.3.7 online install"
[ "$("$dest/atp" --version)" = "atp 0.3.7" ] || fail "unsigned legacy v0.3.7 binary was not installed"
assert_contains "Checksum verified" "$LAST_OUTPUT"
assert_contains "UNAUTHENTICATED LEGACY RELEASE" "$LAST_OUTPUT"
assert_contains "publisher authenticity was NOT verified" "$LAST_OUTPUT"
assert_contains "Upgrade to v0.3.8 or newer" "$LAST_OUTPUT"
assert_not_contains "minisign signature verified" "$LAST_OUTPUT"
assert_contains "${ONLINE_URL}.minisig" "$LAST_NETWORK_LOG"
[ ! -s "$LAST_MINISIGN_LOG" ] || fail "unsigned legacy path invoked minisign"
pass "unsigned online v0.3.7 proceeds only after checksum with a clear legacy warning"

dest="$TEST_TMP/dest-online-legacy-bare-version"
RUN_PATH="$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/release-0.3.7.tar.gz"
RUN_ONLINE_SIGNATURE=""
RUN_DISABLE_MINISIGN_SHIM=1
run_installer online-legacy-bare-version --version 0.3.7 --checksum "$LEGACY_037_SUM" \
  --dest "$dest" --force
expect_rc 0 "unsigned legacy bare 0.3.7 online install"
assert_contains "UNAUTHENTICATED LEGACY RELEASE: 0.3.7" "$LAST_OUTPUT"
[ "$("$dest/atp" --version)" = "atp 0.3.7" ] || fail "bare-version legacy binary was not installed"
pass "canonical legacy versions are accepted with or without the v prefix"

dest="$TEST_TMP/dest-online-legacy-authenticated"
RUN_PATH="$ONLINE_MINISIGN_BIN:$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/release-0.3.7.tar.gz"
RUN_ONLINE_SIGNATURE="$LEGACY_037_SIGNATURE"
run_installer online-legacy-authenticated --version v0.3.7 --checksum "$LEGACY_037_SUM" \
  --dest "$dest" --force
expect_rc 0 "signed legacy v0.3.7 online install"
assert_contains "minisign signature verified" "$LAST_OUTPUT"
assert_not_contains "UNAUTHENTICATED LEGACY RELEASE" "$LAST_OUTPUT"
[ -s "$LAST_MINISIGN_LOG" ] || fail "signed legacy path did not invoke minisign"
pass "legacy online releases verify a signature whenever one is published"

dest="$TEST_TMP/dest-online-legacy-signature-no-minisign"
RUN_PATH="$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/release-0.3.7.tar.gz"
RUN_ONLINE_SIGNATURE="$LEGACY_037_SIGNATURE"
RUN_DISABLE_MINISIGN_SHIM=1
run_installer online-legacy-signature-no-minisign --version v0.3.7 \
  --checksum "$LEGACY_037_SUM" --dest "$dest" --force
expect_rc 1 "signed legacy install without minisign"
assert_contains "minisign is required to authenticate prebuilt release installs" "$LAST_OUTPUT"
assert_not_contains "UNAUTHENTICATED LEGACY RELEASE" "$LAST_OUTPUT"
assert_contains "${ONLINE_URL}.minisig" "$LAST_NETWORK_LOG"
assert_not_exists "$dest/atp"
pass "a published legacy signature cannot be bypassed when minisign is unavailable"

dest="$TEST_TMP/dest-online-legacy-tampered-signature"
RUN_PATH="$ONLINE_MINISIGN_BIN:$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/release-0.3.7.tar.gz"
RUN_ONLINE_SIGNATURE="$TAMPERED_SIGNATURE"
run_installer online-legacy-tampered-signature --version v0.3.7 \
  --checksum "$LEGACY_037_SUM" --dest "$dest" --force
expect_rc 1 "legacy install with tampered signature"
assert_contains "minisign signature verification FAILED" "$LAST_OUTPUT"
assert_not_contains "UNAUTHENTICATED LEGACY RELEASE" "$LAST_OUTPUT"
[ -s "$LAST_MINISIGN_LOG" ] || fail "tampered legacy signature did not invoke minisign"
assert_not_exists "$dest/atp"
pass "legacy online releases reject a published invalid signature"

dest="$TEST_TMP/dest-online-boundary-no-signature"
RUN_PATH="$ONLINE_MINISIGN_BIN:$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/release-0.3.8.tar.gz"
RUN_ONLINE_SIGNATURE=""
run_installer online-boundary-no-signature --version v0.3.8 --checksum "$BOUNDARY_038_SUM" \
  --dest "$dest" --force
expect_rc 1 "unsigned v0.3.8 boundary install"
assert_contains "Required minisign signature is not published" "$LAST_OUTPUT"
assert_contains "Only canonical online releases older than v0.3.8" "$LAST_OUTPUT"
assert_not_contains "UNAUTHENTICATED LEGACY RELEASE" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
pass "v0.3.8 is the strict fail-closed signature boundary"

dest="$TEST_TMP/dest-online-legacy-signature-transport-error"
RUN_PATH="$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/release-0.3.7.tar.gz"
RUN_ONLINE_SIGNATURE=""
RUN_ONLINE_SIGNATURE_STATUS="000"
RUN_DISABLE_MINISIGN_SHIM=1
run_installer online-legacy-signature-transport-error --version v0.3.7 \
  --checksum "$LEGACY_037_SUM" --dest "$dest" --force
expect_rc 1 "legacy signature transport error"
assert_contains "Could not safely retrieve the required minisign signature" "$LAST_OUTPUT"
assert_not_contains "UNAUTHENTICATED LEGACY RELEASE" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
pass "legacy bypass requires a confirmed missing signature, not a transport error"

for malformed_version in \
  v0.3 \
  v0.3.7-rc.1 \
  v00.3.7 \
  v0.3.07 \
  release-0.3.7 \
  v18446744073709551616.0.0 \
  v0.18446744073709551616.0 \
  v0.3.18446744073709551616; do
  name="online-malformed-${malformed_version//./-}"
  dest="$TEST_TMP/dest-$name"
  RUN_PATH="$ONLINE_MINISIGN_BIN:$ONLINE_BASE_BIN"
  RUN_ARTIFACT_URL="$ONLINE_URL"
  RUN_ONLINE_ARCHIVE="$FIXTURES/release-0.3.7.tar.gz"
  RUN_ONLINE_SIGNATURE=""
  run_installer "$name" --version "$malformed_version" --checksum "$LEGACY_037_SUM" \
    --dest "$dest" --force
  expect_rc 1 "malformed version $malformed_version"
  assert_contains "Required minisign signature is not published" "$LAST_OUTPUT"
  assert_not_contains "UNAUTHENTICATED LEGACY RELEASE" "$LAST_OUTPUT"
  assert_not_exists "$dest/atp"
done
dest="$TEST_TMP/dest-online-missing-version"
RUN_PATH="$ONLINE_MINISIGN_BIN:$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/release-0.3.7.tar.gz"
RUN_ONLINE_SIGNATURE=""
run_installer online-missing-version --checksum "$LEGACY_037_SUM" --dest "$dest" --force
expect_rc 1 "missing release version"
assert_contains "Required minisign signature is not published" "$LAST_OUTPUT"
assert_not_contains "UNAUTHENTICATED LEGACY RELEASE" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
pass "malformed or unknown versions never qualify for the unsigned legacy exception"

dest="$TEST_TMP/dest-online-no-minisign"
RUN_PATH="$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/valid.tar.gz"
RUN_ONLINE_SIGNATURE="$VALID_SIGNATURE"
RUN_DISABLE_MINISIGN_SHIM=1
run_installer online-no-minisign --version v1.2.3 --checksum "$VALID_SUM" --dest "$dest" --force
expect_rc 1 "online install without minisign"
assert_contains "minisign is required to authenticate prebuilt release installs" "$LAST_OUTPUT"
assert_not_contains "minisign signature verified" "$LAST_OUTPUT"
assert_contains ".minisig" "$LAST_NETWORK_LOG"
[ ! -s "$LAST_MINISIGN_LOG" ] || fail "missing-minisign path invoked a verifier"
assert_not_exists "$dest/atp"
pass "online release install discovers the sidecar then fails closed when minisign is unavailable"

dest="$TEST_TMP/dest-online-explicit-no-verify"
RUN_PATH="$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/valid.tar.gz"
RUN_ONLINE_SIGNATURE=""
RUN_DISABLE_MINISIGN_SHIM=1
run_installer online-explicit-no-verify --version v1.2.3 --no-verify --dest "$dest" --force
expect_rc 0 "explicit testing-only online verification bypass"
assert_contains "Checksum verification skipped (--no-verify)" "$LAST_OUTPUT"
assert_not_contains "minisign signature verified" "$LAST_OUTPUT"
assert_not_contains ".minisig" "$LAST_NETWORK_LOG"
[ ! -s "$LAST_MINISIGN_LOG" ] || fail "explicit --no-verify path invoked minisign"
[ "$("$dest/atp" --version)" = "atp 1.2.3" ] || fail "explicit --no-verify binary was not installed"
pass "existing testing-only --no-verify explicitly bypasses online archive verification"

dest="$TEST_TMP/dest-online-no-signature"
RUN_PATH="$ONLINE_MINISIGN_BIN:$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/valid.tar.gz"
RUN_ONLINE_SIGNATURE=""
run_installer online-no-signature --version v1.2.3 --checksum "$VALID_SUM" --dest "$dest" --force
expect_rc 1 "online install without signature"
assert_contains "Required minisign signature is not published" "$LAST_OUTPUT"
assert_not_contains "minisign signature verified" "$LAST_OUTPUT"
assert_contains "${ONLINE_URL}.minisig" "$LAST_NETWORK_LOG"
[ ! -s "$LAST_MINISIGN_LOG" ] || fail "missing-signature path invoked minisign"
assert_not_exists "$dest/atp"
pass "online release install fails closed when the signature is unavailable"

dest="$TEST_TMP/dest-online-tampered-archive"
RUN_PATH="$ONLINE_MINISIGN_BIN:$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$TAMPERED_ARCHIVE"
RUN_ONLINE_SIGNATURE="$VALID_SIGNATURE"
run_installer online-tampered-archive --version v1.2.3 --checksum "$TAMPERED_SUM" --dest "$dest" --force
expect_rc 1 "online install with tampered archive"
assert_contains "Checksum verified" "$LAST_OUTPUT"
assert_contains "minisign signature verification FAILED" "$LAST_OUTPUT"
assert_not_contains "minisign signature verified" "$LAST_OUTPUT"
[ -s "$LAST_MINISIGN_LOG" ] || fail "tampered-archive path did not invoke minisign"
assert_not_exists "$dest/atp"
pass "minisign rejects a tampered archive even when its supplied checksum matches"

dest="$TEST_TMP/dest-online-tampered-signature"
RUN_PATH="$ONLINE_MINISIGN_BIN:$ONLINE_BASE_BIN"
RUN_ARTIFACT_URL="$ONLINE_URL"
RUN_ONLINE_ARCHIVE="$FIXTURES/valid.tar.gz"
RUN_ONLINE_SIGNATURE="$TAMPERED_SIGNATURE"
run_installer online-tampered-signature --version v1.2.3 --checksum "$VALID_SUM" --dest "$dest" --force
expect_rc 1 "online install with tampered signature"
assert_contains "Checksum verified" "$LAST_OUTPUT"
assert_contains "minisign signature verification FAILED" "$LAST_OUTPUT"
assert_not_contains "minisign signature verified" "$LAST_OUTPUT"
[ -s "$LAST_MINISIGN_LOG" ] || fail "tampered-signature path did not invoke minisign"
assert_not_exists "$dest/atp"
pass "online release install rejects a tampered signature"

dest="$TEST_TMP/dest-broken-existing"
mkdir -p "$dest"
cat > "$dest/atp" <<'EOF'
#!/bin/sh
exit 42
EOF
chmod 0755 "$dest/atp"
run_installer repair-broken-existing --offline "$FIXTURES/valid.tar.gz" --checksum "$VALID_SUM" \
  --version v1.2.3 --dest "$dest" --force
expect_rc 0 "repair broken existing binary"
[ "$("$dest/atp" --version)" = "atp 1.2.3" ] || fail "broken existing binary was not replaced"
assert_no_network
pass "a broken existing executable does not abort preflight repair"

dest="$TEST_TMP/dest-directory-target"
mkdir -p "$dest/atp"
printf '%s\n' keep > "$dest/atp/sentinel"
run_installer directory-target --offline "$FIXTURES/valid.tar.gz" --checksum "$VALID_SUM" \
  --version v1.2.3 --dest "$dest" --force
expect_rc 1 "directory install target"
assert_contains "Install target is a directory" "$LAST_OUTPUT"
[ -f "$dest/atp/sentinel" ] || fail "directory target was mutated"
if compgen -G "$dest/atp/.atp.install.*" >/dev/null; then
  fail "staged binary was moved inside directory target"
fi
assert_no_network
dest="$TEST_TMP/dest-symlink-directory-target"
mkdir -p "$dest/actual-directory"
ln -s actual-directory "$dest/atp"
run_installer symlink-directory-target --offline "$FIXTURES/valid.tar.gz" --checksum "$VALID_SUM" \
  --version v1.2.3 --dest "$dest" --force
expect_rc 1 "symlink-to-directory install target"
assert_contains "Install target is a directory" "$LAST_OUTPUT"
[ -L "$dest/atp" ] || fail "symlink-to-directory target was replaced"
assert_no_network
pass "directory and symlink-to-directory install targets are rejected"

dest="$TEST_TMP/dest-already-in-path"
mkdir -p "$dest"
RUN_PATH="$dest:$NO_NETWORK_BIN:$ORIGINAL_PATH"
run_installer destination-already-in-path --offline "$FIXTURES/valid.tar.gz" --checksum "$VALID_SUM" \
  --version v1.2.3 --dest "$dest" --force
expect_rc 0 "destination already in PATH"
[ -x "$dest/atp" ] || fail "PATH-resident destination did not install"
assert_no_network
pass "PATH configuration returns success when no update is needed"

dest="$TEST_TMP/dest-no-verify"
RUN_DISABLE_MINISIGN_SHIM=1
run_installer explicit-no-verify --offline "$OFFLINE_MISSING_SIGNATURE_ARCHIVE" \
  --no-verify --dest "$dest" --force
expect_rc 0 "explicit checksum and signature bypass"
[ -x "$dest/atp" ] || fail "--no-verify did not install"
assert_contains "Checksum verification skipped (--no-verify)" "$LAST_OUTPUT"
assert_not_contains "minisign signature verified" "$LAST_OUTPUT"
[ ! -s "$LAST_MINISIGN_LOG" ] || fail "offline --no-verify path invoked minisign"
assert_no_network
pass "explicit --no-verify remains the only offline archive-verification bypass"

dest="$TEST_TMP/dest-nested"
run_installer nested-member --offline "$FIXTURES/nested.tar.gz" --checksum "$NESTED_SUM" --dest "$dest" --force
expect_rc 0 "nested archive member"
[ -x "$dest/atp" ] || fail "nested regular atp member was not installed"
assert_no_network
pass "one nested regular atp archive member is accepted"

dest="$TEST_TMP/dest-duplicate"
run_installer duplicate-member --offline "$FIXTURES/duplicate.tar.gz" --checksum "$DUPLICATE_SUM" --dest "$dest" --force
expect_rc 1 "duplicate archive members"
assert_contains "exactly one regular atp binary" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
assert_no_network
pass "archives with multiple atp members are rejected"

dest="$TEST_TMP/dest-nonregular"
run_installer nonregular-member --offline "$FIXTURES/nonregular.tar.gz" --checksum "$NONREGULAR_SUM" --dest "$dest" --force
expect_rc 1 "non-regular archive member"
assert_contains "not a regular file" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
assert_no_network
pass "non-regular atp archive member is rejected"

dest="$TEST_TMP/dest-hardlink"
run_installer hardlink-member --offline "$FIXTURES/hardlink.tar.gz" --checksum "$HARDLINK_SUM" --dest "$dest" --force
expect_rc 1 "hardlink archive member"
assert_contains "not a regular file" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
assert_no_network
if command -v busybox >/dev/null 2>&1; then
  BUSYBOX_TAR_BIN="$TEST_TMP/busybox-tar-bin"
  mkdir -p "$BUSYBOX_TAR_BIN"
  ln -s "$(command -v busybox)" "$BUSYBOX_TAR_BIN/tar"
  RUN_PATH="$BUSYBOX_TAR_BIN:$NO_NETWORK_BIN:$ORIGINAL_PATH"
  dest="$TEST_TMP/dest-hardlink-busybox"
  run_installer hardlink-member-busybox --offline "$FIXTURES/hardlink.tar.gz" \
    --checksum "$HARDLINK_SUM" --dest "$dest" --force
  expect_rc 1 "BusyBox hardlink archive member"
  assert_contains "not a regular file" "$LAST_OUTPUT"
  assert_not_exists "$dest/atp"
  assert_no_network
fi
pass "hardlink atp archive member is rejected"

dest="$TEST_TMP/dest-fifo"
run_installer fifo-member --offline "$FIXTURES/fifo.tar.gz" --checksum "$FIFO_SUM" --dest "$dest" --force
expect_rc 1 "FIFO archive member"
assert_contains "not a regular file" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
assert_no_network
pass "FIFO atp archive member is rejected"

dest="$TEST_TMP/dest-version-mismatch"
mkdir -p "$dest"
make_binary "$dest/atp" "0.9.0" 0
cp "$dest/atp" "$TEST_TMP/old-version-binary"
run_installer version-mismatch --offline "$FIXTURES/valid.tar.gz" --checksum "$VALID_SUM" \
  --version v9.9.9 --dest "$dest" --force
expect_rc 1 "version mismatch"
assert_contains "Binary version mismatch" "$LAST_OUTPUT"
cmp "$dest/atp" "$TEST_TMP/old-version-binary" >/dev/null || fail "version mismatch replaced existing binary"
assert_no_network
pass "version mismatch fails before atomic replacement"

dest="$TEST_TMP/dest-self-test-failure"
mkdir -p "$dest"
make_binary "$dest/atp" "0.9.0" 0
cp "$dest/atp" "$TEST_TMP/old-self-test-binary"
run_installer self-test-failure --offline "$FIXTURES/fail-self-test.tar.gz" \
  --checksum "$FAIL_SELF_TEST_SUM" --version v1.2.3 --dest "$dest" --verify --force
expect_rc 1 "requested self-test failure"
assert_contains "existing installation was not replaced" "$LAST_OUTPUT"
cmp "$dest/atp" "$TEST_TMP/old-self-test-binary" >/dev/null || fail "self-test failure replaced existing binary"
if compgen -G "$dest/.atp.install.*" >/dev/null; then
  fail "failed staged install left a temporary binary"
fi
assert_no_network
pass "requested self-test fails nonzero and preserves existing binary"

FAIL_MV_BIN="$TEST_TMP/fail-mv-bin"
mkdir -p "$FAIL_MV_BIN"
cat > "$FAIL_MV_BIN/mv" <<'EOF'
#!/bin/sh
exit 42
EOF
chmod 0755 "$FAIL_MV_BIN/mv"
dest="$TEST_TMP/dest-rename-failure"
mkdir -p "$dest"
make_binary "$dest/atp" "0.9.0" 0
cp "$dest/atp" "$TEST_TMP/old-rename-binary"
RUN_PATH="$FAIL_MV_BIN:$NO_NETWORK_BIN:$ORIGINAL_PATH"
run_installer rename-failure --offline "$FIXTURES/valid.tar.gz" --checksum "$VALID_SUM" \
  --version v1.2.3 --dest "$dest" --force
expect_rc 1 "atomic rename failure"
assert_contains "Could not atomically replace" "$LAST_OUTPUT"
cmp "$dest/atp" "$TEST_TMP/old-rename-binary" >/dev/null || fail "rename failure damaged existing binary"
if compgen -G "$dest/.atp.install.*" >/dev/null; then
  fail "rename failure left a temporary binary"
fi
assert_no_network
pass "atomic rename failure preserves the existing binary"

profile_home="$TEST_TMP/profile-home"
dest="$TEST_TMP/bin with space and 'quote' \$literal"
mkdir -p "$profile_home" "$dest"
cp "$FIXTURES/valid/atp" "$dest/atp"
printf '# destination note only: %s' "$dest" > "$profile_home/.bashrc"
cp "$profile_home/.bashrc" "$profile_home/.zshrc"
same_version_before=$(sha256_file "$dest/atp")
RUN_HOME="$profile_home"
run_installer same-version-path --offline "$FIXTURES/fail-self-test.tar.gz" --checksum "$FAIL_SELF_TEST_SUM" \
  --version v1.2.3 --dest "$dest" --verify --easy-mode
expect_rc 0 "same-version integration"
assert_contains "Self-test passed" "$LAST_OUTPUT"
[ "$(sha256_file "$dest/atp")" = "$same_version_before" ] || fail "same-version shortcut acquired the supplied archive"
printf -v quoted_dest '%q' "$dest"
path_line="export PATH=${quoted_dest}:\$PATH"
grep -Fqx -- "$path_line" "$profile_home/.bashrc" || fail "exact shell-quoted PATH line missing"
grep -Fqx -- "$path_line" "$profile_home/.zshrc" || fail "exact zsh PATH line missing"
HOME="$profile_home" PATH=/usr/bin:/bin "$BASH_BIN" --noprofile --norc -c \
  '. "$1"; case ":$PATH:" in *:"$2":*) exit 0 ;; *) exit 1 ;; esac' \
  _ "$profile_home/.bashrc" "$dest" || fail "profile PATH line did not evaluate to exact destination"
if command -v zsh >/dev/null 2>&1; then
  HOME="$profile_home" PATH=/usr/bin:/bin zsh -f -c \
    'source "$1"; case ":$PATH:" in *:"$2":*) exit 0 ;; *) exit 1 ;; esac' \
    _ "$profile_home/.zshrc" "$dest" || fail "zsh PATH line did not evaluate to exact destination"
fi
RUN_HOME="$profile_home"
run_installer same-version-path-repeat --offline "$FIXTURES/fail-self-test.tar.gz" --checksum "$FAIL_SELF_TEST_SUM" \
  --version v1.2.3 --dest "$dest" --verify --easy-mode
expect_rc 0 "same-version integration repeat"
[ "$(grep -Fxc -- "$path_line" "$profile_home/.bashrc")" -eq 1 ] || fail "PATH line is not idempotent"
[ "$(grep -Fxc -- "$path_line" "$profile_home/.zshrc")" -eq 1 ] || fail "zsh PATH line is not idempotent"
assert_no_network
pass "same-version path still verifies and adds one exact shell-quoted PATH line"

RUN_PATH="$NO_NETWORK_BIN:/usr/local/bin:/usr/bin:/bin"
RUN_ARTIFACT_URL="https://invalid.test/atp.tar.gz"
dest="$TEST_TMP/dest-implicit-fallback"
run_installer implicit-source-fallback --dest "$dest" --force
expect_rc 1 "implicit source fallback"
assert_contains "Refusing to install a Rust toolchain implicitly" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
[ -s "$LAST_NETWORK_LOG" ] || fail "implicit fallback did not exercise the curl failure path"
if grep -F 'sh.rustup.rs' "$LAST_NETWORK_LOG" >/dev/null 2>&1; then
  fail "implicit fallback attempted to download rustup"
fi
pass "download failure does not silently install rustup"

WINDOWS_SHELL_BIN="$TEST_TMP/windows-shell-bin"
mkdir -p "$WINDOWS_SHELL_BIN"
cat > "$WINDOWS_SHELL_BIN/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -s) printf '%s\n' MINGW64_NT-10.0 ;;
  -m) printf '%s\n' x86_64 ;;
  *) exec /usr/bin/uname "$@" ;;
esac
EOF
chmod 0755 "$WINDOWS_SHELL_BIN/uname"
RUN_PATH="$WINDOWS_SHELL_BIN:$NO_NETWORK_BIN:$ORIGINAL_PATH"
dest="$TEST_TMP/dest-native-windows-shell"
run_installer native-windows-shell --dest "$dest" --force
expect_rc 2 "native Windows Bash entry point"
assert_contains "Native Windows installs use install.ps1" "$LAST_OUTPUT"
assert_not_exists "$dest/atp"
assert_no_network
pass "native Windows shells fail early with the PowerShell installer path"

AARCH64_BIN="$TEST_TMP/aarch64-bin"
mkdir -p "$AARCH64_BIN"
cat > "$AARCH64_BIN/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -s) printf '%s\n' Linux ;;
  -m) printf '%s\n' aarch64 ;;
  *) exec /usr/bin/uname "$@" ;;
esac
EOF
chmod 0755 "$AARCH64_BIN/uname"
RUN_PATH="$AARCH64_BIN:$NO_NETWORK_BIN:$ORIGINAL_PATH"
dest="$TEST_TMP/dest-aarch64"
run_installer aarch64-musl --offline "$FIXTURES/valid.tar.gz" --checksum "$VALID_SUM" --dest "$dest" --force
expect_rc 0 "aarch64 musl selection"
assert_contains "aarch64-unknown-linux-musl" "$LAST_OUTPUT"
assert_no_network
pass "Linux aarch64 selects musl first"

AARCH64_FALLBACK_BIN="$TEST_TMP/aarch64-fallback-bin"
mkdir -p "$AARCH64_FALLBACK_BIN"
cp "$AARCH64_BIN/uname" "$AARCH64_FALLBACK_BIN/uname"
cat > "$AARCH64_FALLBACK_BIN/curl" <<'EOF'
#!/bin/sh
output=""
url=""
write_code=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) write_code=1; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >> "${NETWORK_LOG:?}"
if [ "$write_code" -eq 1 ] && [ "$output" = "/dev/null" ]; then
  case "$url" in
    *aarch64-unknown-linux-musl.tar.gz) printf '404' ;;
    *aarch64-unknown-linux-gnu.tar.gz) printf '200' ;;
    *) printf '000' ;;
  esac
  exit 0
fi
if [ "$output" = "/dev/null" ]; then
  exit 0
fi
case "$url" in
  *aarch64-unknown-linux-gnu.tar.gz.minisig)
    cp "${ONLINE_SIGNATURE:?}" "$output"
    [ "$write_code" -eq 0 ] || printf '200'
    exit 0
    ;;
  *aarch64-unknown-linux-gnu.tar.gz)
    cp "${FALLBACK_ARCHIVE:?}" "$output"
    exit 0
    ;;
esac
exit 22
EOF
chmod 0755 "$AARCH64_FALLBACK_BIN/curl"
RUN_PATH="$ONLINE_MINISIGN_BIN:$AARCH64_FALLBACK_BIN:$ORIGINAL_PATH"
RUN_FALLBACK_ARCHIVE="$FIXTURES/valid.tar.gz"
RUN_ONLINE_SIGNATURE="$VALID_SIGNATURE"
dest="$TEST_TMP/dest-aarch64-gnu-fallback"
run_installer aarch64-gnu-fallback --version v1.2.3 --checksum "$VALID_SUM" --dest "$dest" --force
expect_rc 0 "aarch64 GNU fallback"
assert_contains "using the glibc build" "$LAST_OUTPUT"
assert_contains "aarch64-unknown-linux-gnu" "$LAST_OUTPUT"
assert_contains "minisign signature verified" "$LAST_OUTPUT"
assert_contains "aarch64-unknown-linux-musl.tar.gz" "$LAST_NETWORK_LOG"
assert_contains "aarch64-unknown-linux-gnu.tar.gz" "$LAST_NETWORK_LOG"
pass "Linux aarch64 falls back from a missing musl asset to GNU"

printf 'PASS: %d installer regression groups\n' "$PASS_COUNT"
