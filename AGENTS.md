# AGENTS.md — atp (standalone distribution repo)

> Guidelines for AI coding agents working in this repository.

---

## What This Repo Is (and Is Not)

This is the **standalone product/distribution repo** for the `atp` CLI — the
fountain-coded file-transfer tool. It contains **no Rust source code** and it
never should. It holds:

| File | Purpose |
|------|---------|
| `README.md` | The product documentation for `atp` |
| `install.sh` | Prebuilt-binary installer (curl-one-liner entry point) |
| `UPSTREAM_REV` | The exact asupersync commit releases are built from |
| `scripts/build-atp.sh` | Local/pinned build helper |
| `.github/workflows/release.yml` | Cross-platform release builds + GitHub release |
| `upstream` (symlink, gitignored) | Local convenience link to the asupersync checkout |

**The canonical ATP source lives in
[`Dicklesworthstone/asupersync`](https://github.com/Dicklesworthstone/asupersync)**
(locally: `/data/projects/asupersync`, symlinked here as `./upstream`):

- CLI binary: `src/bin/atp.rs` (feature `atp-cli`)
- Control/application layer: `src/atp/` (manifest, delta, verify, proof, daemon)
- Wire/transport layer: `src/net/atp/` (`transport_tcp`, `transport_rq`, `transport_quic`)
- RaptorQ codec: `src/raptorq/` (RFC 6330)
- Benchmarks vs rsync: `scripts/atp_bench/`, spec `docs/atp_bench_matrix_spec.md`,
  append-only evidence ledger `docs/atp_rq_beat_rsync_ledger.md`

**Never copy ATP source files into this repo.** If the code needs changing, do
the work in asupersync (its own `AGENTS.md` governs that work), land it on
asupersync `main`, then bump `UPSTREAM_REV` here.

---

## Ground Rules (inherited from the asupersync project)

1. **NO FILE DELETION** without express permission from the user.
2. **No destructive git/filesystem commands** (`git reset --hard`, `git clean -fd`,
   `rm -rf`, force-pushes) without the user supplying the exact command and
   explicit consent in the same message.
3. **`main` is the only branch.** No feature branches, no worktrees, no PRs from
   agents. Commit directly to `main`.
4. **No script-based bulk edits** of files in this repo; make changes manually.
5. Keep this repo tiny. The bar for adding new files is high.

---

## Release Process — dsr ONLY (GitHub Actions is DISABLED)

**USER DIRECTIVE (2026-07-10): GitHub Actions must not be used for ANYTHING in
this repo.** Both workflows are `disabled_manually` via `gh workflow disable`;
the YAML files remain in-tree as reference build recipes only. Never re-enable
them. Releases are built and published with
[dsr](https://github.com/Dicklesworthstone/doodlestein_self_releaser) from the
config in `~/.config/dsr/repos.d/atp.yaml`, which builds from the `UPSTREAM_REV`
pin via `scripts/build-atp.sh --pinned` (never from the shared asupersync
working tree).

```bash
set -euo pipefail
VERSION=0.3.8
TAG=v$VERSION

# 0. Preflight. repos.d/atp.yaml is authoritative; `dsr repos info atp`
#    reads the legacy three-target registry and is not a release gate.
export DSR_CONFIG_DIR="$HOME/.config/dsr"
assert_actions_disabled() {
  local states
  states=$(gh api repos/Dicklesworthstone/atp/actions/workflows \
    --jq '.workflows[].state')
  test -n "$states"
  test -z "$(printf '%s\n' "$states" | grep -vx disabled_manually || true)"
}
wlap_ps() {
  local engine="$1" script="$2" encoded
  encoded=$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  ssh wlap "$engine -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
}
command -v iconv >/dev/null
command -v base64 >/dev/null
command -v minisign >/dev/null
dsr doctor
dsr health check trj --no-cache
dsr health check mmini --no-cache
dsr health check wlap --no-cache
ssh trj 'command -v minisign >/dev/null'
ssh mmini 'test "$(command -v minisign)" = /opt/homebrew/bin/minisign && minisign -v'
wlap_ps powershell.exe "Get-Command minisign.exe -CommandType Application -ErrorAction Stop | Out-Null"
yq -e '.act_job_map == null and (.targets | length == 7)' \
  "$DSR_CONFIG_DIR/repos.d/atp.yaml"
assert_actions_disabled

# 1. Pick the asupersync commit to ship (must be pushed to origin/main there)
git -C upstream fetch origin main
UPSTREAM_SHA=$(git -C upstream rev-parse origin/main)
test "${#UPSTREAM_SHA}" -eq 40
test -z "${UPSTREAM_SHA//[0-9a-f]/}"
git -C upstream merge-base --is-ancestor "$UPSTREAM_SHA" origin/main

# 2. Update the pin, run the distribution gates, stage exactly this release's
#    intended files, commit, assert a clean tree, and push main + master.
printf '%s\n' "$UPSTREAM_SHA" > UPSTREAM_REV
bash -n install.sh scripts/build-atp.sh scripts/test-install.sh scripts/test-build-atp.sh
shellcheck -S warning install.sh scripts/build-atp.sh scripts/test-install.sh scripts/test-build-atp.sh
bash scripts/test-install.sh
bash scripts/test-build-atp.sh
RELEASE_FILES=(
  AGENTS.md
  README.md
  UPSTREAM_REV
  install.ps1
  install.sh
  scripts/test-install.ps1
  scripts/test-install.sh
  skills/atp/references/OPERATIONS.md
)
EXPECTED_RELEASE_FILES=$(printf '%s\n' "${RELEASE_FILES[@]}" | sort)
git add -- "${RELEASE_FILES[@]}"
test "$(git diff --cached --name-only | sort)" = "$EXPECTED_RELEASE_FILES"
test -z "$(git diff --name-only)"
git diff --cached --check
git commit -m "chore(release): prepare ATP $VERSION"
test -z "$(git status --porcelain)"
assert_actions_disabled
RELEASE_SHA=$(git rev-parse HEAD)
PRE_RELEASE_RUN_IDS=$(gh api -X GET repos/Dicklesworthstone/atp/actions/runs \
  -f head_sha="$RELEASE_SHA" -f per_page=100 --jq '.workflow_runs[].id' | sort -n)
git push origin main
git push origin main:master
sleep 30
assert_actions_disabled
test "$(gh api -X GET repos/Dicklesworthstone/atp/actions/runs \
  -f head_sha="$RELEASE_SHA" -f per_page=100 --jq '.workflow_runs[].id' | sort -n)" = \
  "$PRE_RELEASE_RUN_IDS"
test "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$RELEASE_SHA"
test "$(git ls-remote origin refs/heads/master | awk '{print $1}')" = "$RELEASE_SHA"

# 3. Build every declared target serially. Do not add --parallel, --resume,
#    --allow-dirty, or --no-sync. Linux builds on trj, both macOS targets build
#    natively on mmini (x86_64 via the Apple toolchain), and Windows builds
#    natively with MSVC on wlap.
dsr build atp --version "$VERSION" \
  --target linux/x86_64-unknown-linux-gnu \
  --target linux/x86_64-unknown-linux-musl \
  --target linux/aarch64-unknown-linux-gnu \
  --target linux/aarch64-unknown-linux-musl \
  --target darwin/aarch64-apple-darwin \
  --target darwin/x86_64-apple-darwin \
  --target windows/x86_64-pc-windows-msvc

# 4. Verify the build before creating an immutable tag. The manifest must be
#    successful, name all seven archives, point at the current atp commit, and
#    every archive binary must execute on its native host or the named QEMU/
#    Rosetta runner, report exactly `atp X.Y.Z`, and pass `rq-keygen`.
ART="$HOME/.local/state/dsr/artifacts/atp-$TAG"
EXPECTED_ARCHIVES=(
  atp-x86_64-unknown-linux-gnu.tar.gz
  atp-x86_64-unknown-linux-musl.tar.gz
  atp-aarch64-unknown-linux-gnu.tar.gz
  atp-aarch64-unknown-linux-musl.tar.gz
  atp-aarch64-apple-darwin.tar.gz
  atp-x86_64-apple-darwin.tar.gz
  atp-x86_64-pc-windows-msvc.zip
)
EXPECTED_ARCHIVES_JSON=$(printf '%s\n' "${EXPECTED_ARCHIVES[@]}" | jq -R . | jq -s 'sort')
jq -e --arg sha "$(git rev-parse HEAD)" --arg version "$VERSION" --arg tag "$TAG" \
  --argjson expected "$EXPECTED_ARCHIVES_JSON" \
  '.status == "success" and .git_sha == $sha and
   (.version == $version or .version == $tag) and
   ([.artifacts[] |
      select(.archive_format == "tar.gz" or .archive_format == "zip") |
      .name] | sort) == $expected' \
  "$ART/atp-$TAG-manifest.json"
test "$(find "$ART" -maxdepth 1 -type f \
  \( -name 'atp-*.tar.gz' -o -name 'atp-*.zip' \) | wc -l)" -eq 7
for name in "${EXPECTED_ARCHIVES[@]}"; do
  archive="$ART/$name"
  test -s "$archive"
  expected_sha=$(jq -er --arg name "$name" '
    [.artifacts[] |
      select(.name == $name and
             (.archive_format == "tar.gz" or .archive_format == "zip"))] |
    if length == 1 and (.[0].sha256 | test("^[0-9a-f]{64}$"))
    then .[0].sha256
    else error("manifest must contain one valid archive hash for " + $name)
    end' "$ART/atp-$TAG-manifest.json")
  actual_sha=$(sha256sum "$archive" | awk '{print $1}')
  test "$actual_sha" = "$expected_sha"
  case "$archive" in
    *.tar.gz)
      test "$(tar -tzf "$archive" | sed 's#^\./##' | sort)" = $'LICENSE\natp'
      ;;
    *.zip)
      test "$(unzip -Z1 "$archive" | sed 's#^\./##' | sort)" = $'LICENSE\natp.exe'
      ;;
  esac
done
verify_atp() {
  test "$("$@" --version)" = "atp $VERSION"
  key=$("$@" rq-keygen)
  test "${#key}" -eq 64
  test -z "${key//[0-9a-f]/}"
}
command -v qemu-aarch64 >/dev/null
test -d /usr/aarch64-linux-gnu
for name in \
  atp-x86_64-unknown-linux-gnu.tar.gz \
  atp-x86_64-unknown-linux-musl.tar.gz \
  atp-aarch64-unknown-linux-gnu.tar.gz \
  atp-aarch64-unknown-linux-musl.tar.gz; do
  linux_dir=$(mktemp -d)
  tar -xzf "$ART/$name" -C "$linux_dir"
  case "$name" in
    atp-x86_64-*) verify_atp "$linux_dir/atp" ;;
    atp-aarch64-unknown-linux-gnu.tar.gz)
      verify_atp qemu-aarch64 -L /usr/aarch64-linux-gnu "$linux_dir/atp"
      ;;
    atp-aarch64-unknown-linux-musl.tar.gz)
      verify_atp qemu-aarch64 "$linux_dir/atp"
      ;;
  esac
done

# DSR excludes .git while syncing its source-only Windows tree. Bind every
# tracked distribution input to the local release commit by comparing its hash,
# then run both supported PowerShell editions through EncodedCommand. Windows
# OpenSSH starts commands through cmd.exe, whose quoting rules are not
# PowerShell's quoting rules.
while IFS= read -r rel; do
  local_sha=$(sha256sum "$rel" | awk '{print $1}')
  win_rel=${rel//\//\\}
  remote_sha=$(wlap_ps powershell.exe \
    "(Get-FileHash -LiteralPath 'C:\\Users\\jeffr\\atp_dsr_git\\$win_rel' -Algorithm SHA256).Hash.ToLowerInvariant()" |
    tr -d '\r')
  test "$remote_sha" = "$local_sha"
done < <(git ls-files)
wlap_ps powershell.exe "& 'C:\\Users\\jeffr\\atp_dsr_git\\scripts\\test-install.ps1'"
wlap_ps pwsh.exe "& 'C:\\Users\\jeffr\\atp_dsr_git\\scripts\\test-install.ps1'"

# Execute both macOS archive binaries on their native host (Intel through
# Rosetta), not merely `file`/archive inspection.
MAC_GATE_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
MAC_STAGE="/tmp/atp-$TAG-pretag-$MAC_GATE_ID"
MAC_ARM_SHA=$(sha256sum "$ART/atp-aarch64-apple-darwin.tar.gz" | awk '{print $1}')
MAC_X86_SHA=$(sha256sum "$ART/atp-x86_64-apple-darwin.tar.gz" | awk '{print $1}')
ssh mmini "mkdir -p '$MAC_STAGE'"
scp "$ART/atp-aarch64-apple-darwin.tar.gz" \
    "$ART/atp-x86_64-apple-darwin.tar.gz" "mmini:$MAC_STAGE/"
ssh mmini bash -s -- \
  "$VERSION" "$MAC_STAGE" "$MAC_ARM_SHA" "$MAC_X86_SHA" <<'ATP_MAC_VERIFY'
set -euo pipefail
version="$1"
stage="$2"
arm_archive_sha="$3"
x86_archive_sha="$4"
command -v shasum >/dev/null
test "$(shasum -a 256 "$stage/atp-aarch64-apple-darwin.tar.gz" | awk '{print $1}')" = \
  "$arm_archive_sha"
test "$(shasum -a 256 "$stage/atp-x86_64-apple-darwin.tar.gz" | awk '{print $1}')" = \
  "$x86_archive_sha"
arm_dir=$(mktemp -d)
x86_dir=$(mktemp -d)
tar -xzf "$stage/atp-aarch64-apple-darwin.tar.gz" -C "$arm_dir"
tar -xzf "$stage/atp-x86_64-apple-darwin.tar.gz" -C "$x86_dir"
test "$("$arm_dir/atp" --version)" = "atp $version"
arm_key=$("$arm_dir/atp" rq-keygen)
test "${#arm_key}" -eq 64 && test -z "${arm_key//[0-9a-f]/}"
test "$(arch -x86_64 "$x86_dir/atp" --version)" = "atp $version"
x86_key=$(arch -x86_64 "$x86_dir/atp" rq-keygen)
test "${#x86_key}" -eq 64 && test -z "${x86_key//[0-9a-f]/}"
ATP_MAC_VERIFY

# 5. Sign and verify every installer archive with the DSR key whose public key
#    is embedded in install.sh. minisign may prompt for the private-key password.
for name in "${EXPECTED_ARCHIVES[@]}"; do
  archive="$ART/$name"
  dsr signing sign "$archive" -t "atp $TAG $(basename "$archive")"
  dsr signing verify "$archive"
done

# Still before tagging, exercise the signed Windows archive itself and perform
# real offline installs under Windows PowerShell 5.1 and PowerShell 7. The
# installer must discover minisign.exe, verify the sibling signature, run the
# installed binary, and leave bytes identical to the ZIP member.
WIN_GATE_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
WIN_STAGE="C:/atp-release-gate/$TAG-$WIN_GATE_ID"
WIN_STAGE_PS="C:\\atp-release-gate\\$TAG-$WIN_GATE_ID"
WIN_ZIP="atp-x86_64-pc-windows-msvc.zip"
WIN_SHA=$(sha256sum "$ART/$WIN_ZIP" | awk '{print $1}')
wlap_ps powershell.exe "New-Item -ItemType Directory -Path '$WIN_STAGE_PS' -ErrorAction Stop | Out-Null; Get-Command minisign.exe -CommandType Application -ErrorAction Stop | Out-Null"
scp "$ART/$WIN_ZIP" "$ART/$WIN_ZIP.minisig" "wlap:$WIN_STAGE/"
wlap_ps powershell.exe "
  \$copied=(Get-FileHash -LiteralPath '$WIN_STAGE_PS\\$WIN_ZIP' -Algorithm SHA256).Hash.ToLowerInvariant()
  if (\$copied -cne '$WIN_SHA') { throw 'copied Windows archive hash mismatch' }
  Expand-Archive -LiteralPath '$WIN_STAGE_PS\\$WIN_ZIP' -DestinationPath '$WIN_STAGE_PS\\raw' -ErrorAction Stop
  if ((& '$WIN_STAGE_PS\\raw\\atp.exe' --version) -cne 'atp $VERSION') { throw 'raw Windows version mismatch' }
  if ((& '$WIN_STAGE_PS\\raw\\atp.exe' rq-keygen) -notmatch '^[0-9a-f]{64}$') { throw 'raw Windows rq-keygen mismatch' }
"
WIN_PS51_OUTPUT=$(wlap_ps powershell.exe "& 'C:\\Users\\jeffr\\atp_dsr_git\\install.ps1' -Offline '$WIN_STAGE_PS\\$WIN_ZIP' -Checksum '$WIN_SHA' -Version '$TAG' -Dest '$WIN_STAGE_PS\\install-ps51' -Verify -Force" | tr -d '\r')
printf '%s\n' "$WIN_PS51_OUTPUT"
printf '%s\n' "$WIN_PS51_OUTPUT" | grep -F 'minisign signature verified'
WIN_PWSH7_OUTPUT=$(wlap_ps pwsh.exe "& 'C:\\Users\\jeffr\\atp_dsr_git\\install.ps1' -Offline '$WIN_STAGE_PS\\$WIN_ZIP' -Checksum '$WIN_SHA' -Version '$TAG' -Dest '$WIN_STAGE_PS\\install-pwsh7' -Verify -Force" | tr -d '\r')
printf '%s\n' "$WIN_PWSH7_OUTPUT"
printf '%s\n' "$WIN_PWSH7_OUTPUT" | grep -F 'minisign signature verified'
wlap_ps powershell.exe "\$raw=(Get-FileHash -LiteralPath '$WIN_STAGE_PS\\raw\\atp.exe' -Algorithm SHA256).Hash; foreach(\$installed in @('$WIN_STAGE_PS\\install-ps51\\atp.exe','$WIN_STAGE_PS\\install-pwsh7\\atp.exe')) { if ((Get-FileHash -LiteralPath \$installed -Algorithm SHA256).Hash -cne \$raw) { throw ('installed hash mismatch: '+\$installed) }; if ((& \$installed --version) -cne 'atp $VERSION') { throw ('installed version mismatch: '+\$installed) }; if ((& \$installed rq-keygen) -notmatch '^[0-9a-f]{64}$') { throw ('installed rq-keygen mismatch: '+\$installed) } }"

# 6. Reconfirm that both workflows are disabled, then tag exactly the manifest
#    commit. Pushing this tag must not start GitHub Actions.
assert_actions_disabled
test "$(jq -r .git_sha "$ART/atp-$TAG-manifest.json")" = "$(git rev-parse HEAD)"
test "$(git rev-parse HEAD)" = "$RELEASE_SHA"
git tag -a "$TAG" -m "atp $TAG"
git push origin "$TAG"
sleep 30
test "$(gh api -X GET repos/Dicklesworthstone/atp/actions/runs \
  -f head_sha="$RELEASE_SHA" -f per_page=100 --jq '.workflow_runs[].id' | sort -n)" = \
  "$PRE_RELEASE_RUN_IDS"
test "$(gh run list --repo Dicklesworthstone/atp --branch "$TAG" \
  --limit 100 --json databaseId --jq 'length')" -eq 0

# 7. Create a draft through DSR only. --no-dispatch prevents downstream
#    automation. An existing release is a hard collision; never let DSR reuse
#    or mutate one. Nothing is public until the complete draft passes step 8.
if gh release view "$TAG" --repo Dicklesworthstone/atp >/dev/null 2>&1; then
  printf 'release collision: %s already exists\n' "$TAG" >&2
  exit 1
fi
dsr release atp "$VERSION" --draft --verify-tag --no-dispatch
dsr release verify atp "$VERSION" --verify-checksums
assert_actions_disabled
test "$(gh api -X GET repos/Dicklesworthstone/atp/actions/runs \
  -f head_sha="$RELEASE_SHA" -f per_page=100 --jq '.workflow_runs[].id' | sort -n)" = \
  "$PRE_RELEASE_RUN_IDS"
test "$(gh run list --repo Dicklesworthstone/atp --branch "$TAG" \
  --limit 100 --json databaseId --jq 'length')" -eq 0

# 8. Verify the exact complete draft, then publish it with one atomic release
#    edit. DSR uploads the seven archives, their seven Minisign signatures,
#    seven per-archive checksum sidecars, the combined SHA256SUMS, and the build
#    manifest: exactly 23 assets. Extra, missing, duplicate, malformed, or
#    unverifiable assets abort publication.
EXPECTED_DRAFT_ASSETS=(
  "atp-$TAG-manifest.json"
  SHA256SUMS
)
for name in "${EXPECTED_ARCHIVES[@]}"; do
  EXPECTED_DRAFT_ASSETS+=("$name" "$name.minisig" "$name.sha256")
done
EXPECTED_DRAFT_ASSET_NAMES=$(printf '%s\n' "${EXPECTED_DRAFT_ASSETS[@]}" | sort)
EXPECTED_ARCHIVE_NAMES=$(printf '%s\n' "${EXPECTED_ARCHIVES[@]}" | sort)
DRAFT_JSON=$(gh release view "$TAG" --repo Dicklesworthstone/atp \
  --json tagName,isDraft,isPrerelease,publishedAt,assets)
jq -e --arg tag "$TAG" '
  .tagName == $tag and .isDraft == true and .isPrerelease == false and
  .publishedAt == null
' <<<"$DRAFT_JSON"
test "$(jq -r '.assets[].name' <<<"$DRAFT_JSON" | sort)" = \
  "$EXPECTED_DRAFT_ASSET_NAMES"

VERIFY_DIR=$(mktemp -d)
gh release download "$TAG" --repo Dicklesworthstone/atp --dir "$VERIFY_DIR"
test "$(find "$VERIFY_DIR" -maxdepth 1 -type f -printf '%f\n' | sort)" = \
  "$EXPECTED_DRAFT_ASSET_NAMES"
cmp "$ART/atp-$TAG-manifest.json" "$VERIFY_DIR/atp-$TAG-manifest.json"
test "$(awk 'NF == 2 { print $2 }' "$VERIFY_DIR/SHA256SUMS" | sort)" = \
  "$EXPECTED_ARCHIVE_NAMES"
test "$(wc -l < "$VERIFY_DIR/SHA256SUMS")" -eq 7
for name in "${EXPECTED_ARCHIVES[@]}"; do
  expected=$(awk -v name="$name" '$2 == name { print $1 }' "$VERIFY_DIR/SHA256SUMS")
  test "$(printf '%s' "$expected" | wc -w)" -eq 1
  test "${#expected}" -eq 64
  test -z "${expected//[0-9a-f]/}"
  actual=$(sha256sum "$VERIFY_DIR/$name" | awk '{ print $1 }')
  test "$actual" = "$expected"
  test "$(cat "$VERIFY_DIR/$name.sha256")" = "$expected  $name"
  minisign -Vm "$VERIFY_DIR/$name" -x "$VERIFY_DIR/$name.minisig" \
    -P RWTQGPeLsnm9G7VFdFWkkcRi3wJK/PqsYxWC+oLNN74W9IjBxRU1Xu70
done

gh release edit "$TAG" --repo Dicklesworthstone/atp \
  --draft=false --latest --verify-tag
PUBLISHED_JSON=$(gh release view "$TAG" --repo Dicklesworthstone/atp \
  --json tagName,isDraft,isPrerelease,publishedAt,assets)
jq -e --arg tag "$TAG" '
  .tagName == $tag and .isDraft == false and .isPrerelease == false and
  .publishedAt != null
' <<<"$PUBLISHED_JSON"
test "$(jq -r '.assets[].name' <<<"$PUBLISHED_JSON" | sort)" = \
  "$EXPECTED_DRAFT_ASSET_NAMES"
assert_actions_disabled
test "$(gh api -X GET repos/Dicklesworthstone/atp/actions/runs \
  -f head_sha="$RELEASE_SHA" -f per_page=100 --jq '.workflow_runs[].id' | sort -n)" = \
  "$PRE_RELEASE_RUN_IDS"
test "$(gh run list --repo Dicklesworthstone/atp --branch "$TAG" \
  --limit 100 --json databaseId --jq 'length')" -eq 0

# 9. Use the immutable tagged installers online on every supported host/shell.
#    Each install must report real Minisign verification and leave executable
#    bytes identical to the corresponding member of the published archive.
LINUX_MEMBER_DIR=$(mktemp -d)
MAC_MEMBER_DIR=$(mktemp -d)
WIN_MEMBER_DIR=$(mktemp -d)
tar -xzf "$VERIFY_DIR/atp-x86_64-unknown-linux-musl.tar.gz" -C "$LINUX_MEMBER_DIR"
tar -xzf "$VERIFY_DIR/atp-aarch64-apple-darwin.tar.gz" -C "$MAC_MEMBER_DIR"
unzip -q "$VERIFY_DIR/atp-x86_64-pc-windows-msvc.zip" -d "$WIN_MEMBER_DIR"
LINUX_MEMBER_SHA=$(sha256sum "$LINUX_MEMBER_DIR/atp" | awk '{print $1}')
MAC_MEMBER_SHA=$(sha256sum "$MAC_MEMBER_DIR/atp" | awk '{print $1}')
WIN_MEMBER_SHA=$(sha256sum "$WIN_MEMBER_DIR/atp.exe" | awk '{print $1}')

ssh trj /bin/bash -s -- "$TAG" "$VERSION" "$LINUX_MEMBER_SHA" <<'ATP_LINUX_INSTALL'
set -euo pipefail
tag="$1"
version="$2"
expected_sha="$3"
command -v minisign >/dev/null
output=$(curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/atp/$tag/install.sh" |
  /bin/bash -s -- --version "$tag" --dest "$HOME/.local/bin" --verify --force \
    --no-skill --no-gum 2>&1)
printf '%s\n' "$output"
printf '%s\n' "$output" | grep -F 'minisign signature verified'
installed="$HOME/.local/bin/atp"
test "$(sha256sum "$installed" | awk '{print $1}')" = "$expected_sha"
test "$("$installed" --version)" = "atp $version"
key=$("$installed" rq-keygen)
test "${#key}" -eq 64 && test -z "${key//[0-9a-f]/}"
ATP_LINUX_INSTALL

ssh mmini /bin/bash -s -- "$TAG" "$VERSION" "$MAC_MEMBER_SHA" <<'ATP_MAC_INSTALL'
set -euo pipefail
tag="$1"
version="$2"
expected_sha="$3"
test "$(command -v minisign)" = /opt/homebrew/bin/minisign
test "$(minisign -v 2>&1 | head -n 1)" = 'minisign 0.12'
output=$(curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/atp/$tag/install.sh" |
  /bin/bash -s -- --version "$tag" --dest "$HOME/.local/bin" --verify --force \
    --no-skill --no-gum 2>&1)
printf '%s\n' "$output"
printf '%s\n' "$output" | grep -F 'minisign signature verified'
installed="$HOME/.local/bin/atp"
test "$(shasum -a 256 "$installed" | awk '{print $1}')" = "$expected_sha"
test "$("$installed" --version)" = "atp $version"
key=$("$installed" rq-keygen)
test "${#key}" -eq 64 && test -z "${key//[0-9a-f]/}"
ATP_MAC_INSTALL

for engine in powershell.exe pwsh.exe; do
  WIN_INSTALL_SCRIPT="
    \$ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Get-Command minisign.exe -CommandType Application -ErrorAction Stop | Out-Null
    \$installerContent = [string](Invoke-RestMethod -Uri \
      'https://raw.githubusercontent.com/Dicklesworthstone/atp/$TAG/install.ps1' \
      -TimeoutSec 30 -Headers @{ 'User-Agent' = 'atp-release-gate' })
    & ([scriptblock]::Create(\$installerContent)) -Version '$TAG' \
      -Dest 'C:\Users\jeffr\.local\bin' -Verify -Force
    \$installed = 'C:\Users\jeffr\.local\bin\atp.exe'
    \$installedSha = (Get-FileHash -LiteralPath \$installed -Algorithm SHA256).Hash.ToLowerInvariant()
    if (\$installedSha -cne '$WIN_MEMBER_SHA') { throw 'installed Windows hash does not match published ZIP member' }
    if ((& \$installed --version) -cne 'atp $VERSION') { throw 'installed Windows version mismatch' }
    if ((& \$installed rq-keygen) -notmatch '^[0-9a-f]{64}$') { throw 'installed Windows rq-keygen mismatch' }
  "
  WIN_INSTALL_OUTPUT=$(wlap_ps "$engine" "$WIN_INSTALL_SCRIPT" | tr -d '\r')
  printf '%s\n' "$WIN_INSTALL_OUTPUT"
  printf '%s\n' "$WIN_INSTALL_OUTPUT" | grep -F 'minisign signature verified'
done

assert_actions_disabled
test "$(gh api -X GET repos/Dicklesworthstone/atp/actions/runs \
  -f head_sha="$RELEASE_SHA" -f per_page=100 --jq '.workflow_runs[].id' | sort -n)" = \
  "$PRE_RELEASE_RUN_IDS"
test "$(gh run list --repo Dicklesworthstone/atp --branch "$TAG" \
  --limit 100 --json databaseId --jq 'length')" -eq 0
```

Notes:

- dsr builds run `scripts/build-atp.sh --pinned`, i.e.
  `cargo build --release --locked --bin atp --features atp-cli`
  (plus `--target <triple>` per matrix leg) under the nightly toolchain pinned
  by asupersync's `rust-toolchain.toml`.
- `--features atp-cli` is the full-featured binary — it already includes `tls`,
  which the encrypted QUIC/TLS-1.3 tier requires. Do not add feature flags
  without checking asupersync's `Cargo.toml`.
- Publication is draft-first and fail-closed: `dsr release ... --draft
  --verify-tag --no-dispatch` must create exactly 23 assets (seven archives,
  seven `.minisig` signatures, seven `.sha256` sidecars, `SHA256SUMS`, and the
  build manifest). Download and verify that exact set while it is still private;
  `dsr release verify --verify-checksums` spot-checks at most three assets and
  does not replace this full check. Publish only with the single atomic
  `gh release edit "$TAG" --draft=false --latest --verify-tag` call, then prove
  the asset set did not change.
- Run both x86_64 Linux archives natively on trj, both aarch64 Linux archives
  with `qemu-aarch64` (and the GNU sysroot where required), both macOS archives
  on mmini (using Rosetta for x86_64), and the MSVC archive on wlap. Verify
  `atp --version`, a 64-hex-character `atp rq-keygen` result,
  archive/executable SHA-256 identity, and the installer-selected asset on every
  host before calling the release complete.
- Release inputs are immutable contracts: `UPSTREAM_REV` is a lowercase 40-hex
  commit on upstream `main`, the release tag resolves to one exact atp-repo
  commit, and an existing tag or release is a hard collision rather than
  something to overwrite.
- Keep tag versions in lockstep with the `atp --version` output of the pinned
  rev; if they drift, say so in the release notes.
- DSR publishes ATP to its GitHub Release. ATP has no R2 release URL or bucket
  contract, and this direct DSR path does not create GitHub build-provenance
  attestations. Do not claim either without a separately configured and
  verified publication step.
- Installer authentication is mandatory for every v0.3.8+ online release and
  every verified offline install. Only a canonical online version below v0.3.8
  may continue after a confirmed missing signature, mandatory SHA-256, and the
  explicit `UNAUTHENTICATED LEGACY RELEASE` warning. A signature that exists
  must verify even for legacy releases; malformed/unknown versions and
  inconclusive signature fetches remain fail-closed.
- After publication, use the exact assets already downloaded from the verified
  draft, install the tagged release with `install.sh` on Linux/macOS and
  `install.ps1` under both Windows PowerShell 5.1 and PowerShell 7, require the
  deterministic `minisign signature verified` marker, compare every installed
  executable to its published archive member, then reconfirm both workflows
  remain `disabled_manually` and no Actions run was created for the tag.

## Testing the Installer

```bash
bash -n install.sh                       # syntax
shellcheck -S warning install.sh         # lint
bash scripts/test-install.sh             # deterministic installer contracts
bash scripts/test-build-atp.sh           # deterministic pinned-build contracts
# Real online installs are release step 9, after the verified draft is published.
for engine in powershell.exe pwsh.exe; do
  script='$ErrorActionPreference = "Stop"; & "C:\Users\jeffr\atp_dsr_git\scripts\test-install.ps1"'
  encoded=$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  ssh wlap "$engine -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
done
```

The installer must keep working when piped from curl (no reliance on
`BASH_SOURCE` being a file, except as an optional fast path).

## Docs Discipline

- Performance claims in `README.md` must trace back to the asupersync bench
  ledger (`docs/atp_rq_beat_rsync_ledger.md`) — matrix-cell medians vs *tuned*
  rsync only, SHA-verified, rate-capped links. Never invent or extrapolate
  numbers; quote the ledger's cells and keep the honest losses visible.
- When `UPSTREAM_REV` moves far enough that CLI flags or benchmark results
  change, re-verify the README examples against `atp --help` from a fresh build.
