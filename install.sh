#!/usr/bin/env bash
#
# atp installer
#
# One-liner install (with cache buster):
#   curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.sh?$(date +%s)" | bash
#
# Or without cache buster:
#   curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.sh | bash
#
# Options:
#   --version vX.Y.Z   Install specific version (default: latest release)
#   --dest DIR         Install to DIR (default: ~/.local/bin)
#   --system           Install to /usr/local/bin (requires sudo)
#   --easy-mode        Auto-update PATH in shell rc files
#   --verify           Run a post-install self-test
#   --from-source      Build from the pinned asupersync source instead of
#                      downloading a prebuilt binary (slow: full Rust build)
#   --offline TARBALL  Install from a local atp-<target>.tar.gz (no network)
#   --checksum SHA256  Expected archive SHA-256 (required for offline/custom
#                      artifacts unless --no-verify is used)
#   --quiet            Suppress non-error output
#   --no-gum           Disable gum formatting even if available
#   --no-verify        Skip checksum verification (for testing only)
#   --force            Reinstall even if the same version is present
#   --skill            Also install the atp agent skill (Claude/Codex) without asking
#   --no-skill         Never prompt for / install the agent skill
#   --uninstall-skill  Remove previously installed agent skill copies and exit
#
set -euo pipefail
umask 022
shopt -s lastpipe 2>/dev/null || true

VERSION="${VERSION:-}"
OWNER="${OWNER:-Dicklesworthstone}"
REPO="${REPO:-atp}"
UPSTREAM_OWNER="${UPSTREAM_OWNER:-Dicklesworthstone}"
UPSTREAM_REPO="${UPSTREAM_REPO:-asupersync}"
BIN_NAME="atp"
DEST="${DEST:-}"
LOCK_FILE="${TMPDIR:-/tmp}/atp-install.lock"
EASY=0
QUIET=0
VERIFY=0
FROM_SOURCE=0
FROM_SOURCE_EXPLICIT=0
SYSTEM=0
NO_GUM=0
NO_CHECKSUM=0
FORCE_INSTALL=0
OFFLINE_TARBALL=""
CHECKSUM="${CHECKSUM:-}"
ARTIFACT_URL="${ARTIFACT_URL:-}"
SKILL_MODE=""            # ""=ask (interactive only) | yes | no
UNINSTALL_SKILL=0
SKILL_INSTALLED=0
SKILL_MARKER=".installed-by-atp-installer"

# ─────────────────────────────────────────────────────────────────────────────
# Output helpers (gum with ANSI fallback)
# ─────────────────────────────────────────────────────────────────────────────

HAS_GUM=0
if command -v gum &>/dev/null && [ -t 1 ]; then
  HAS_GUM=1
fi

log() { [ "$QUIET" -eq 1 ] && return 0; echo -e "$@"; }

info() {
  [ "$QUIET" -eq 1 ] && return 0
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    gum style --foreground 39 "→ $*"
  else
    echo -e "\033[0;34m→\033[0m $*"
  fi
}

ok() {
  [ "$QUIET" -eq 1 ] && return 0
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    gum style --foreground 42 "✓ $*"
  else
    echo -e "\033[0;32m✓\033[0m $*"
  fi
}

warn() {
  [ "$QUIET" -eq 1 ] && return 0
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    gum style --foreground 214 "⚠ $*"
  else
    echo -e "\033[1;33m⚠\033[0m $*"
  fi
}

err() {
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    gum style --foreground 196 "✗ $*"
  else
    echo -e "\033[0;31m✗\033[0m $*"
  fi
}

run_with_spinner() {
  local title="$1"
  shift
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
    gum spin --spinner dot --title "$title" -- "$@"
  else
    info "$title"
    "$@"
  fi
}

# draw_box "color" "line1" "line2" ... — double-line box with ANSI-aware width
draw_box() {
  local color="$1"
  shift
  local lines=("$@")
  local max_width=0
  local esc
  esc=$(printf '\033')
  local strip_ansi_sed="s/${esc}\\[[0-9;]*m//g"

  for line in "${lines[@]}"; do
    local stripped
    stripped=$(printf '%b' "$line" | LC_ALL=C sed "$strip_ansi_sed")
    local len=${#stripped}
    [ "$len" -gt "$max_width" ] && max_width=$len
  done

  local inner_width=$((max_width + 4))
  local border=""
  for ((i = 0; i < inner_width; i++)); do border+="═"; done

  printf "\033[%sm╔%s╗\033[0m\n" "$color" "$border"
  for line in "${lines[@]}"; do
    local stripped
    stripped=$(printf '%b' "$line" | LC_ALL=C sed "$strip_ansi_sed")
    local len=${#stripped}
    local padding=$((max_width - len))
    local pad_str=""
    for ((i = 0; i < padding; i++)); do pad_str+=" "; done
    printf "\033[%sm║\033[0m  %b%s  \033[%sm║\033[0m\n" "$color" "$line" "$pad_str" "$color"
  done
  printf "\033[%sm╚%s╝\033[0m\n" "$color" "$border"
}

usage() {
  cat <<'EOF'
atp installer

Usage: install.sh [options]

Options:
  --version vX.Y.Z   Install specific version (default: latest release)
  --dest DIR         Install to DIR (default: ~/.local/bin)
  --system           Install to /usr/local/bin (requires sudo)
  --easy-mode        Auto-update PATH in shell rc files
  --verify           Run a post-install self-test
  --from-source      Build from pinned asupersync source (slow: full Rust build)
  --offline TARBALL  Install from a local atp-<target>.tar.gz (no network)
  --checksum SHA256  Expected archive SHA-256 (offline/custom artifacts)
  --quiet            Suppress non-error output
  --no-gum           Disable gum formatting even if available
  --no-verify        Skip checksum verification (testing only)
  --force            Reinstall even if the same version is present
  --skill            Also install the atp agent skill (Claude/Codex) without asking
  --no-skill         Never prompt for / install the agent skill
  --uninstall-skill  Remove previously installed agent skill copies and exit
  -h, --help         Show this help
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Agent skill (Claude Code / Codex) install & removal
# ─────────────────────────────────────────────────────────────────────────────

skill_dest_roots() {
  printf '%s\n' "$HOME/.claude/skills" "${CODEX_HOME:-$HOME/.codex}/skills"
}

uninstall_skill_copies() {
  local removed=0 root target
  while IFS= read -r root; do
    target="$root/atp"
    if [ -d "$target" ]; then
      if [ -f "$target/$SKILL_MARKER" ]; then
        rm -rf "$target"
        ok "Removed $target"
        removed=1
      else
        warn "Skipping $target: not installed by this installer (no $SKILL_MARKER marker); remove manually if intended"
      fi
    fi
  done < <(skill_dest_roots)
  [ "$removed" -eq 1 ] || info "No installer-managed atp skill copies found."
}

locate_skill_source() {
  # Fast path: running from a repo checkout with skills/atp alongside.
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || here=""
    if [ -n "$here" ] && [ -f "$here/skills/atp/SKILL.md" ]; then
      echo "$here/skills/atp"
      return 0
    fi
  fi
  # Piped install (curl | bash): fetch the repo tarball — tiny, no Rust source.
  # Pin the skill to the resolved release tag when we have one so the skill
  # always matches the binary being installed; fall back to main for tags that
  # predate the bundled skill, or when no version was resolved (--from-source,
  # --offline, ARTIFACT_URL). Progress goes to stderr: callers capture stdout.
  [ -n "${TMP:-}" ] || return 1
  local candidate_refs="refs/heads/main" ref tarball root
  if [ -n "${VERSION:-}" ]; then
    candidate_refs="refs/tags/${VERSION} ${candidate_refs}"
  fi
  for ref in $candidate_refs; do
    tarball="$TMP/skill-repo-${ref##*/}.tar.gz"
    root="$TMP/skill-repo-${ref##*/}"
    curl -fsSL ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} \
      "https://codeload.github.com/${OWNER}/${REPO}/tar.gz/${ref}" \
      -o "$tarball" 2>/dev/null || continue
    mkdir -p "$root"
    tar -xzf "$tarball" -C "$root" --strip-components=1 2>/dev/null || continue
    if [ -f "$root/skills/atp/SKILL.md" ]; then
      if [ -n "${VERSION:-}" ] && [ "$ref" = "refs/heads/main" ]; then
        info "Agent skill: not available from the ${VERSION} tag; using main" >&2
      fi
      echo "$root/skills/atp"
      return 0
    fi
  done
  return 1
}

install_skill_copies() {
  local src
  if ! src=$(locate_skill_source) || [ -z "$src" ]; then
    warn "Could not locate the atp skill source (offline?); skipping skill install"
    warn "Add it later with: install.sh --skill"
    return 0
  fi
  local root target
  while IFS= read -r root; do
    target="$root/atp"
    if [ -d "$target" ] && [ ! -f "$target/$SKILL_MARKER" ] && [ "$FORCE_INSTALL" -eq 0 ]; then
      warn "Skipping $target: exists but was not installed by this installer (--force overwrites)"
      continue
    fi
    mkdir -p "$root"
    rm -rf "$target"
    cp -R "$src" "$target"
    : > "$target/$SKILL_MARKER"
    ok "Agent skill installed: $target"
    SKILL_INSTALLED=1
  done < <(skill_dest_roots)
}

maybe_install_skill() {
  case "$SKILL_MODE" in
    no) return 0 ;;
    yes) install_skill_copies; return 0 ;;
  esac
  # Interactive prompt only. `curl | bash` keeps stdin for the script body,
  # so ask via /dev/tty; when there is no terminal, stay silent but helpful.
  [ "$QUIET" -eq 1 ] && return 0
  # A device node can exist and pass -r/-w without this process having a
  # controlling terminal (CI and redirected test runners hit that case).
  if ! (exec 3<> /dev/tty) 2>/dev/null; then
    info "Tip: re-run with --skill to also install the atp agent skill (Claude Code / Codex)"
    return 0
  fi
  local answer=""
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    if gum confirm "Install the atp agent skill for Claude Code / Codex (~/.claude/skills + ~/.codex/skills)?" \
        < /dev/tty > /dev/tty 2>&1; then
      answer="y"
    fi
  else
    printf 'Install the atp agent skill for Claude Code / Codex (~/.claude/skills + ~/.codex/skills)? [y/N] ' > /dev/tty
    IFS= read -r answer < /dev/tty || answer=""
  fi
  case "$answer" in
    y|Y|yes|YES) install_skill_copies ;;
    *) info "Skipped agent skill (add later with: install.sh --skill)" ;;
  esac
}

require_option_value() {
  # $1 = flag name, $2 = number of args remaining, $3 = candidate value
  if [ "$2" -ge 2 ] && [ -n "${3:-}" ]; then
    case "$3" in
      -*) : ;;
      *) return 0 ;;
    esac
  fi
  err "$1 requires a value"
  usage >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) require_option_value "$1" $# "${2:-}"; VERSION="$2"; shift 2 ;;
    --dest) require_option_value "$1" $# "${2:-}"; DEST="$2"; shift 2 ;;
    --system) SYSTEM=1; DEST="/usr/local/bin"; shift ;;
    --easy-mode) EASY=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --from-source) FROM_SOURCE=1; FROM_SOURCE_EXPLICIT=1; shift ;;
    --offline) require_option_value "$1" $# "${2:-}"; OFFLINE_TARBALL="$2"; shift 2 ;;
    --checksum) require_option_value "$1" $# "${2:-}"; CHECKSUM="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --no-gum) NO_GUM=1; shift ;;
    --no-verify) NO_CHECKSUM=1; shift ;;
    --force) FORCE_INSTALL=1; shift ;;
    --skill) SKILL_MODE="yes"; shift ;;
    --no-skill) SKILL_MODE="no"; shift ;;
    --uninstall-skill) UNINSTALL_SKILL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 2 ;;
  esac
done

if [ "$UNINSTALL_SKILL" -eq 1 ]; then
  uninstall_skill_copies
  exit 0
fi

if [ -z "$DEST" ]; then
  if [ -z "${HOME:-}" ]; then
    err "HOME is not set; provide an explicit --dest"
    exit 2
  fi
  DEST="$HOME/.local/bin"
fi
if [ -z "${HOME:-}" ] && { [ "$EASY" -eq 1 ] || [ "$FROM_SOURCE" -eq 1 ]; }; then
  err "HOME is required by --easy-mode and --from-source"
  exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# Proxy support — passed to every curl call. NOTE: expanded everywhere with the
# ${arr[@]+"${arr[@]}"} idiom because macOS ships bash 3.2, where expanding an
# empty array under `set -u` is a fatal "unbound variable" error.
# ─────────────────────────────────────────────────────────────────────────────

PROXY_ARGS=()
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  PROXY_ARGS=(--proxy "$HTTPS_PROXY")
elif [[ -n "${HTTP_PROXY:-}" ]]; then
  PROXY_ARGS=(--proxy "$HTTP_PROXY")
fi

# ─────────────────────────────────────────────────────────────────────────────
# Platform detection
# ─────────────────────────────────────────────────────────────────────────────

detect_platform() {
  OS=$(uname -s | tr 'A-Z' 'a-z')
  ARCH=$(uname -m)

  case "$OS" in
    mingw*|msys*|cygwin*)
      err "Native Windows installs use install.ps1 (PowerShell 5.1 or newer)"
      exit 2
      ;;
  esac

  case "$ARCH" in
    x86_64|amd64) ARCH="x86_64" ;;
    arm64|aarch64) ARCH="aarch64" ;;
    *) warn "Unknown arch $ARCH, using as-is" ;;
  esac

  TARGET=""
  case "${OS}-${ARCH}" in
    # Linux prefers fully-static musl artifacts; set_artifact_url probes and
    # falls back to gnu when a release did not ship musl for that architecture.
    linux-x86_64) TARGET="x86_64-unknown-linux-musl" ;;
    linux-aarch64) TARGET="aarch64-unknown-linux-musl" ;;
    darwin-x86_64) TARGET="x86_64-apple-darwin" ;;
    darwin-aarch64) TARGET="aarch64-apple-darwin" ;;
    *) : ;;
  esac

  if [[ "$OS" == "linux" ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    warn "WSL detected — atp works, but benchmark-grade UDP behavior depends on the Windows network stack"
  fi

  if [ -z "$TARGET" ] && [ "$FROM_SOURCE" -eq 0 ] && [ -z "$ARTIFACT_URL" ] && [ -z "$OFFLINE_TARBALL" ]; then
    warn "No prebuilt artifact for ${OS}/${ARCH}; falling back to build-from-source"
    FROM_SOURCE=1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Version + artifact resolution
# ─────────────────────────────────────────────────────────────────────────────

resolve_version() {
  if [ -n "$VERSION" ]; then return 0; fi
  if [ "$FROM_SOURCE" -eq 1 ] || [ -n "$ARTIFACT_URL" ] || [ -n "$OFFLINE_TARBALL" ]; then return 0; fi

  info "Resolving latest version..."
  local latest_url="https://api.github.com/repos/${OWNER}/${REPO}/releases/latest"
  local tag
  if ! tag=$(curl -fsSL ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} -H "Accept: application/vnd.github.v3+json" "$latest_url" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'); then
    tag=""
  fi

  if [ -n "$tag" ]; then
    VERSION="$tag"
    info "Resolved latest version: $VERSION"
    return 0
  fi

  # Redirect-based fallback
  local redirect_url="https://github.com/${OWNER}/${REPO}/releases/latest"
  if tag=$(curl -fsSL ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} -o /dev/null -w '%{url_effective}' "$redirect_url" 2>/dev/null | sed -E 's|.*/tag/||'); then
    if [ -n "$tag" ] && [[ "$tag" =~ ^v[0-9] ]] && [[ "$tag" != *"/"* ]]; then
      VERSION="$tag"
      info "Resolved latest version via redirect: $VERSION"
      return 0
    fi
  fi
  err "Could not resolve latest release. Re-run with --version vX.Y.Z or --from-source."
  exit 1
}

http_status() {
  curl -sSL ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} -o /dev/null -w '%{http_code}' -I --max-time 10 "$1" 2>/dev/null || echo "000"
}

set_artifact_url() {
  TAR=""
  URL=""
  # Offline wins over --from-source (main dispatch checks offline first, so
  # TAR must be populated for that path even when both flags are passed).
  if [ -n "$OFFLINE_TARBALL" ]; then
    TAR=$(basename "$OFFLINE_TARBALL")
    return 0
  fi
  [ "$FROM_SOURCE" -eq 1 ] && return 0
  if [ -n "$ARTIFACT_URL" ]; then
    TAR=$(basename "$ARTIFACT_URL")
    URL="$ARTIFACT_URL"
    return 0
  fi
  if [ -z "$TARGET" ]; then
    warn "No prebuilt artifact for this platform; falling back to build-from-source"
    FROM_SOURCE=1
    return 0
  fi

  TAR="atp-${TARGET}.tar.gz"
  URL="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/${TAR}"

  # musl-first with gnu fallback for both Linux architectures (one HEAD probe).
  if [[ "$TARGET" == *-unknown-linux-musl ]] && command -v curl >/dev/null 2>&1; then
    local code
    code=$(http_status "$URL")
    if [ "$code" != "200" ] && [ "$code" != "302" ]; then
      local gnu_target="${TARGET%musl}gnu"
      local gnu_url="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/atp-${gnu_target}.tar.gz"
      local gnu_code
      gnu_code=$(http_status "$gnu_url")
      if [ "$gnu_code" = "200" ] || [ "$gnu_code" = "302" ]; then
        warn "No musl artifact for ${VERSION}; using the glibc build (needs a reasonably recent glibc)"
        TARGET="$gnu_target"
        TAR="atp-${TARGET}.tar.gz"
        URL="$gnu_url"
      fi
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────────────────────

check_disk_space() {
  local min_kb=51200
  local path="$DEST"
  # Walk up to the nearest existing ancestor so `df` has a real path to stat
  # (a fresh nested --dest would otherwise silently kill the script under
  # set -e/pipefail when df exits non-zero).
  while [ ! -d "$path" ] && [ "$path" != "/" ]; do
    path=$(dirname "$path")
  done
  if command -v df >/dev/null 2>&1; then
    local avail_kb
    avail_kb=$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}') || avail_kb=""
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$min_kb" ]; then
      err "Insufficient disk space in $path (need at least 50MB)"
      exit 1
    fi
  fi
}

check_write_permissions() {
  if [ ! -d "$DEST" ]; then
    if ! mkdir -p "$DEST" 2>/dev/null; then
      err "Cannot create $DEST (insufficient permissions)"
      err "Try re-running with sudo (for a system-wide install), or choose a writable --dest"
      exit 1
    fi
  fi
  if [ ! -w "$DEST" ]; then
    err "No write permission to $DEST"
    err "Try re-running with sudo (for a system-wide install), or choose a writable --dest"
    exit 1
  fi
}

check_existing_install() {
  INSTALLED_VERSION=""
  if [ -x "$DEST/$BIN_NAME" ]; then
    INSTALLED_VERSION=$("$DEST/$BIN_NAME" --version 2>/dev/null | head -1 || echo "")
    if [ -n "$INSTALLED_VERSION" ]; then
      info "Existing atp detected: $INSTALLED_VERSION"
    fi
  fi
  return 0
}

check_network() {
  [ "$FROM_SOURCE" -eq 1 ] && return 0
  [ -n "$OFFLINE_TARBALL" ] && return 0
  [ -z "$URL" ] && return 0
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is required to download release artifacts"
    exit 1
  fi
  if ! curl -fsSL ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} --connect-timeout 3 --max-time 8 -o /dev/null -I "$URL" 2>/dev/null; then
    warn "Network preflight failed for $URL"
    warn "Continuing; the download may still fail"
  fi
}

preflight_checks() {
  info "Running preflight checks"
  check_disk_space
  check_write_permissions
  check_existing_install
  check_network
}

# ─────────────────────────────────────────────────────────────────────────────
# Locking + temp workspace
# ─────────────────────────────────────────────────────────────────────────────

acquire_lock() {
  local tries=0
  while ! mkdir "$LOCK_FILE" 2>/dev/null; do
    # mkdir can fail for reasons other than contention (stray regular file at
    # the lock path, unwritable TMPDIR) — fail fast with the right message
    # instead of spinning 30s and blaming a concurrent install.
    if [ ! -d "$LOCK_FILE" ] && [ -e "$LOCK_FILE" ]; then
      err "Lock path $LOCK_FILE exists but is not a directory; remove it and retry"
      exit 1
    fi
    if [ ! -e "$LOCK_FILE" ]; then
      err "Cannot create lock at $LOCK_FILE (is ${TMPDIR:-/tmp} writable?)"
      exit 1
    fi
    if [ -f "$LOCK_FILE/pid" ]; then
      local lock_pid
      lock_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        warn "Removing stale install lock (pid $lock_pid)"
        rm -rf "$LOCK_FILE"
        continue
      fi
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
      err "Another atp install appears to be running (lock: $LOCK_FILE)"
      exit 1
    fi
    sleep 1
  done
  echo $$ > "$LOCK_FILE/pid"
  LOCKED=1
}

TMP=""
STAGED_INSTALL=""
LOCKED=0
cleanup() {
  if [ -n "$STAGED_INSTALL" ]; then rm -f "$STAGED_INSTALL"; fi
  if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
  if [ "$LOCKED" -eq 1 ]; then rm -rf "$LOCK_FILE"; fi
  return 0
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Checksum verification
# ─────────────────────────────────────────────────────────────────────────────

sha256_of() {
  local file="$1"
  if command -v sha256sum &>/dev/null; then
    sha256sum "$file" | cut -d' ' -f1
  elif command -v shasum &>/dev/null; then
    shasum -a 256 "$file" | cut -d' ' -f1
  else
    echo ""
  fi
}

is_sha256() {
  local value="$1"
  [ "${#value}" -eq 64 ] || return 1
  case "$value" in
    *[!0-9A-Fa-f]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_commit_sha() {
  local value="$1"
  [ "${#value}" -eq 40 ] || return 1
  case "$value" in
    *[!0-9A-Fa-f]*) return 1 ;;
    *) return 0 ;;
  esac
}

verify_checksum() {
  local file="$1"

  if [ "$NO_CHECKSUM" -eq 1 ]; then
    warn "Checksum verification skipped (--no-verify)"
    return 0
  fi

  local expected="$CHECKSUM"
  # Offline installs: accept a sibling <tarball>.sha256 file if present.
  if [ -z "$expected" ] && [ -n "$OFFLINE_TARBALL" ] && [ -f "${OFFLINE_TARBALL}.sha256" ]; then
    expected=$(awk '{print $1; exit}' "${OFFLINE_TARBALL}.sha256")
  fi
  if [ -z "$expected" ] && [ -n "$URL" ]; then
    # Primary: SHA256SUMS from the same release (GitHub-Actions-era releases)
    if [ -n "$VERSION" ]; then
      local sums_url="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/SHA256SUMS"
      local sums_file="$TMP/SHA256SUMS"
      if curl -fsSL ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} "$sums_url" -o "$sums_file" 2>/dev/null; then
        expected=$(awk -v t="$TAR" '$2 == t {print $1}' "$sums_file" | head -1)
      fi
    fi
    # dsr-built releases publish {tool}-{version}-checksums.sha256 instead
    if [ -z "$expected" ] && [ -n "$VERSION" ]; then
      local dsr_sums_url="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/atp-${VERSION}-checksums.sha256"
      local dsr_sums_file="$TMP/dsr-checksums.sha256"
      if curl -fsSL ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} "$dsr_sums_url" -o "$dsr_sums_file" 2>/dev/null; then
        expected=$(awk -v t="$TAR" '$2 == t {print $1}' "$dsr_sums_file" | head -1)
      fi
    fi
    # Fallback: per-asset .sha256 file
    if [ -z "$expected" ]; then
      local asset_sum
      if asset_sum=$(curl -fsSL ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} "${URL}.sha256" 2>/dev/null); then
        expected=$(echo "$asset_sum" | awk '{print $1}' | head -1)
      fi
    fi
  fi

  if [ -z "$expected" ]; then
    err "No checksum found for $TAR; refusing an unverified install"
    err "Provide --checksum SHA256 (or use --no-verify only for testing)"
    return 1
  fi

  if ! is_sha256 "$expected"; then
    err "Invalid SHA-256 checksum for $TAR (expected exactly 64 hexadecimal characters)"
    return 1
  fi
  expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')

  local actual
  actual=$(sha256_of "$file") || actual=""
  if [ -z "$actual" ]; then
    err "No SHA-256 tool found (need sha256sum or shasum); refusing an unverified install"
    return 1
  fi
  if ! is_sha256 "$actual"; then
    err "SHA-256 tool returned malformed output; refusing to install"
    return 1
  fi
  actual=$(printf '%s' "$actual" | tr 'A-F' 'a-f')

  if [ "$actual" != "$expected" ]; then
    err "Checksum verification FAILED for $TAR"
    err "Expected: $expected"
    err "Got:      $actual"
    err "The downloaded file may be corrupted or tampered with."
    rm -f "$file"
    return 1
  fi

  ok "Checksum verified: ${actual:0:16}..."
  return 0
}

# dsr-built releases sign every asset with minisign. Verification is
# best-effort: skipped when minisign isn't installed or the release has no
# signature (pre-dsr releases), but a PRESENT signature that fails to verify
# aborts the install.
MINISIGN_PUBKEY="RWTQGPeLsnm9G7VFdFWkkcRi3wJK/PqsYxWC+oLNN74W9IjBxRU1Xu70"

verify_minisign() {
  local file="$1"

  [ "$NO_CHECKSUM" -eq 1 ] && return 0
  [ -z "$URL" ] && return 0
  if ! command -v minisign >/dev/null 2>&1; then
    return 0
  fi

  local sig_file
  sig_file="$TMP/$(basename "$file").minisig"
  if ! curl -fsSL ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} "${URL}.minisig" -o "$sig_file" 2>/dev/null; then
    info "No minisign signature published for $TAR; relying on SHA-256 verification"
    return 0
  fi

  if minisign -Vm "$file" -x "$sig_file" -P "$MINISIGN_PUBKEY" >/dev/null 2>&1; then
    ok "minisign signature verified"
    return 0
  fi
  err "minisign signature verification FAILED for $TAR"
  err "The downloaded file may be corrupted or tampered with."
  rm -f "$file"
  return 1
}

extract_atp_archive() {
  local archive="$1"
  local members_file="$TMP/archive-members"
  local candidate_member=""
  local candidate_count=0
  local member normalized

  if ! tar -tzf "$archive" > "$members_file"; then
    err "Could not list archive: $TAR"
    return 1
  fi

  while IFS= read -r member; do
    normalized="$member"
    while [ "${normalized#./}" != "$normalized" ]; do
      normalized="${normalized#./}"
    done
    [ -z "$normalized" ] && continue
    case "$normalized" in
      /*|../*|*/../*|*/..)
        err "Archive contains an unsafe path: $member"
        return 1
        ;;
    esac
    case "$normalized" in
      atp|*/atp)
        candidate_member="$member"
        candidate_count=$((candidate_count + 1))
        ;;
    esac
  done < "$members_file"

  if [ "$candidate_count" -ne 1 ]; then
    err "Archive must contain exactly one regular atp binary (found $candidate_count)"
    return 1
  fi

  local verbose type_char
  if ! verbose=$(tar -tvzf "$archive" -- "$candidate_member" 2>/dev/null); then
    err "Could not inspect atp archive member: $candidate_member"
    return 1
  fi
  type_char="${verbose:0:1}"
  if [ "$type_char" != "-" ]; then
    err "Archive atp member is not a regular file: $candidate_member"
    return 1
  fi
  case "$verbose" in
    *" -> "*|*" link to "*)
      err "Archive atp member is not a regular file: $candidate_member"
      return 1
      ;;
  esac
  local extract_root="$TMP/archive-extract"
  mkdir -p "$extract_root"
  if ! tar -xzf "$archive" -C "$extract_root" -- "$candidate_member"; then
    err "Could not extract atp archive member: $candidate_member"
    return 1
  fi

  BIN="$extract_root/$candidate_member"
  if [ ! -f "$BIN" ] || [ -L "$BIN" ]; then
    err "Extracted atp member is not a regular file: $candidate_member"
    return 1
  fi
}

VALIDATED_VERSION_OUTPUT=""
SELF_TEST="skipped"

validate_binary() {
  local binary="$1"
  local output first actual expected

  if ! output=$("$binary" --version 2>/dev/null); then
    err "Installed candidate failed to run: $binary --version"
    return 1
  fi
  first="${output%%$'\n'*}"
  case "$first" in
    "atp "*) actual="${first#atp }" ;;
    *)
      err "Installed candidate returned an unexpected version string: ${first:-<empty>}"
      return 1
      ;;
  esac
  actual="${actual%% *}"
  if [ -z "$actual" ]; then
    err "Installed candidate did not report a version"
    return 1
  fi

  if [ -n "$VERSION" ]; then
    expected="${VERSION#v}"
    if [ "$actual" != "$expected" ]; then
      err "Binary version mismatch: requested $expected, candidate reports $actual"
      return 1
    fi
  fi

  VALIDATED_VERSION_OUTPUT="$first"
}

run_requested_self_test() {
  local binary="$1"
  [ "$VERIFY" -eq 1 ] || return 0

  info "Running post-install self-test"
  if "$binary" rq-keygen >/dev/null 2>&1; then
    SELF_TEST="passed"
    ok "Self-test passed (--version + rq-keygen)"
    return 0
  fi

  SELF_TEST="FAILED"
  err "Self-test failed; the existing installation was not replaced"
  return 1
}

atomic_install() {
  local source_binary="$1"
  local final_binary="$DEST/$BIN_NAME"

  if [ -d "$final_binary" ]; then
    err "Install target is a directory and cannot be atomically replaced: $final_binary"
    return 1
  fi

  if ! STAGED_INSTALL=$(mktemp "$DEST/.${BIN_NAME}.install.XXXXXX"); then
    err "Could not create an install staging file in $DEST"
    return 1
  fi
  if ! install -m 0755 "$source_binary" "$STAGED_INSTALL"; then
    err "Could not stage $BIN_NAME in $DEST"
    return 1
  fi
  validate_binary "$STAGED_INSTALL" || return 1
  run_requested_self_test "$STAGED_INSTALL" || return 1
  if [ -d "$final_binary" ]; then
    err "Install target became a directory before replacement: $final_binary"
    return 1
  fi
  if ! mv -f "$STAGED_INSTALL" "$final_binary"; then
    err "Could not atomically replace $final_binary"
    return 1
  fi
  STAGED_INSTALL=""
  ok "Installed $BIN_NAME to $DEST/$BIN_NAME"
}

configure_path() {
  PATH_NOTE=""
  local in_current_path=0
  case ":$PATH:" in
    *:"$DEST":*) in_current_path=1 ;;
  esac

  if [ "$EASY" -eq 1 ]; then
    local quoted_dest path_line rc last_byte
    local profile_count=0
    local changed_count=0
    local configured_count=0
    printf -v quoted_dest '%q' "$DEST"
    path_line="export PATH=${quoted_dest}:\$PATH"

    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
      if [ -e "$rc" ] && [ -w "$rc" ]; then
        profile_count=$((profile_count + 1))
        if grep -Fqx -- "$path_line" "$rc" >/dev/null 2>&1; then
          configured_count=$((configured_count + 1))
          continue
        fi
        last_byte=""
        if [ -s "$rc" ]; then
          last_byte=$(tail -c 1 "$rc" 2>/dev/null || true)
        fi
        if [ -n "$last_byte" ]; then
          printf '\n' >> "$rc"
        fi
        if printf '%s\n' "$path_line" >> "$rc"; then
          changed_count=$((changed_count + 1))
        else
          warn "Could not update PATH in $rc"
        fi
      fi
    done

    if [ "$changed_count" -gt 0 ]; then
      PATH_NOTE="PATH updated in shell rc files; restart your shell"
    elif [ "$profile_count" -gt 0 ] && [ "$configured_count" -eq "$profile_count" ]; then
      PATH_NOTE="PATH is already configured in shell rc files"
    else
      PATH_NOTE="Add $DEST to your PATH"
    fi
  elif [ "$in_current_path" -eq 0 ]; then
    PATH_NOTE="Add $DEST to your PATH (or re-run with --easy-mode)"
  fi

  if [ -n "$PATH_NOTE" ]; then
    warn "$PATH_NOTE"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Build from source (pinned asupersync rev)
# ─────────────────────────────────────────────────────────────────────────────

resolve_upstream_rev() {
  UPSTREAM_REV=""
  # If running from a checkout of the atp repo, prefer the local pin.
  local script_dir=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  fi
  if [ -n "$script_dir" ] && [ -f "$script_dir/UPSTREAM_REV" ]; then
    UPSTREAM_REV=$(tr -d '[:space:]' < "$script_dir/UPSTREAM_REV")
  fi
  if [ -z "$UPSTREAM_REV" ]; then
    local ref="${VERSION:-main}"
    local pin_url="https://raw.githubusercontent.com/${OWNER}/${REPO}/${ref}/UPSTREAM_REV"
    UPSTREAM_REV=$(curl -fsSL ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} "$pin_url" 2>/dev/null | tr -d '[:space:]' || echo "")
  fi
  if [ -z "$UPSTREAM_REV" ]; then
    err "Could not resolve the pinned asupersync revision (UPSTREAM_REV)"
    exit 1
  fi
  if ! is_commit_sha "$UPSTREAM_REV"; then
    err "Pinned asupersync revision must be one 40-hex commit ID"
    exit 1
  fi
}

ensure_rust() {
  if command -v cargo >/dev/null 2>&1 && command -v rustup >/dev/null 2>&1; then
    return 0
  fi
  if [ "$FROM_SOURCE_EXPLICIT" -eq 0 ]; then
    err "Prebuilt download failed and source fallback requires cargo + rustup"
    err "Refusing to install a Rust toolchain implicitly; install rustup or re-run with --from-source"
    exit 1
  fi
  if [ "$EASY" -ne 1 ] && [ -t 0 ]; then
    echo -n "Building atp from source requires rustup. Install rustup now? (y/N): "
    read -r ans
    case "$ans" in y|Y) : ;; *) err "rustup is required for --from-source"; exit 1 ;; esac
  fi
  info "Installing rustup (the asupersync tree pins its own nightly toolchain)"
  curl -fsSL ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} https://sh.rustup.rs | sh -s -- -y --profile minimal
  export PATH="$HOME/.cargo/bin:$PATH"
}

build_from_source() {
  info "Building atp from source (this compiles the full asupersync runtime; expect 10-40 minutes)"
  if ! command -v git >/dev/null 2>&1; then
    err "git is required for --from-source"
    exit 1
  fi
  ensure_rust
  resolve_upstream_rev
  info "Pinned asupersync revision: $UPSTREAM_REV"

  local src="$TMP/asupersync"
  git init -q "$src"
  git -C "$src" remote add origin "https://github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}"
  run_with_spinner "Fetching asupersync @ ${UPSTREAM_REV:0:12}..." \
    git -C "$src" fetch -q --depth 1 origin "$UPSTREAM_REV"
  git -C "$src" checkout -q FETCH_HEAD

  info "Compiling atp (release, --features atp-cli)..."
  (cd "$src" && cargo build --release --locked --bin atp --features atp-cli)
  BIN="$src/target/release/atp"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

if [ "$NO_CHECKSUM" -eq 0 ] && [ -n "$CHECKSUM" ] && ! is_sha256 "$CHECKSUM"; then
  err "--checksum requires exactly 64 hexadecimal characters"
  exit 2
fi
case "$DEST" in
  *:*)
    err "--dest cannot contain ':' because PATH uses it as an entry separator"
    exit 2
    ;;
esac

if [ "$QUIET" -eq 0 ]; then
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    gum style \
      --border normal --border-foreground 39 \
      --padding "0 1" --margin "1 0" \
      "$(gum style --foreground 42 --bold 'atp installer')" \
      "$(gum style --foreground 245 'Fountain-coded file transfer that outruns rsync on real networks')"
  else
    echo -e "\033[1;32matp installer\033[0m"
    echo -e "\033[0;90mFountain-coded file transfer that outruns rsync on real networks\033[0m"
  fi
fi

detect_platform
resolve_version
set_artifact_url
preflight_checks
acquire_lock

TMP=$(mktemp -d "${TMPDIR:-/tmp}/atp-install.XXXXXX")

# Same-version installs skip acquisition, but still honor --verify and
# --easy-mode below.
SKIP_INSTALL=0
if [ "$FORCE_INSTALL" -eq 0 ] && [ -n "$VERSION" ] && [ -n "$INSTALLED_VERSION" ]; then
  installed_ver=""
  case "$INSTALLED_VERSION" in
    "atp "*) installed_ver="${INSTALLED_VERSION#atp }"; installed_ver="${installed_ver%% *}" ;;
  esac
  target_ver="${VERSION#v}"
  if [ "$installed_ver" = "$target_ver" ]; then
    ok "atp $VERSION is already installed at $DEST/$BIN_NAME"
    info "Use --force to reinstall"
    SKIP_INSTALL=1
  fi
fi

BIN=""
if [ "$SKIP_INSTALL" -eq 1 ]; then
  validate_binary "$DEST/$BIN_NAME" || exit 1
  run_requested_self_test "$DEST/$BIN_NAME" || exit 1
else
  if [ -n "$OFFLINE_TARBALL" ]; then
    if [ ! -f "$OFFLINE_TARBALL" ]; then
      err "Offline tarball not found: $OFFLINE_TARBALL"
      exit 1
    fi
    info "Installing from offline tarball: $OFFLINE_TARBALL"
    cp "$OFFLINE_TARBALL" "$TMP/$TAR"
    verify_checksum "$TMP/$TAR" || exit 1
    extract_atp_archive "$TMP/$TAR" || exit 1
  elif [ "$FROM_SOURCE" -eq 1 ]; then
    build_from_source
  else
    info "Downloading $TAR${VERSION:+ (${VERSION})}..."
    CURL_PROGRESS=(--progress-bar)
    # Suppress curl's own bar when quiet, or when gum's spinner is already
    # providing progress (both at once garbles the terminal).
    if [ "$QUIET" -eq 1 ] || { [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; }; then
      CURL_PROGRESS=(-sS)
    fi
    if ! run_with_spinner "Downloading atp ${VERSION:-artifact}..." \
      curl -fSL ${PROXY_ARGS[@]+"${PROXY_ARGS[@]}"} "${CURL_PROGRESS[@]}" "$URL" -o "$TMP/$TAR"; then
      warn "Download failed; falling back to build-from-source"
      FROM_SOURCE=1
      build_from_source
    else
      verify_checksum "$TMP/$TAR" || exit 1
      verify_minisign "$TMP/$TAR" || exit 1
      extract_atp_archive "$TMP/$TAR" || exit 1
    fi
  fi

  if [ ! -f "$BIN" ] || [ -L "$BIN" ]; then
    err "Built/downloaded binary is not a regular file: $BIN"
    exit 1
  fi
  atomic_install "$BIN" || exit 1
fi

INSTALLED="$VALIDATED_VERSION_OUTPUT"
configure_path
maybe_install_skill

# Final summary
if [ "$QUIET" -eq 0 ]; then
  summary_lines=(
    "\033[1;32matp installed\033[0m"
    ""
    "Version:   $INSTALLED"
    "Binary:    $DEST/$BIN_NAME"
    "Platform:  ${OS}/${ARCH}${TARGET:+ ($TARGET)}"
  )
  [ "$SYSTEM" -eq 1 ] && summary_lines+=("Scope:     system-wide")
  [ "$VERIFY" -eq 1 ] && summary_lines+=("Self-test: $SELF_TEST")
  summary_lines+=(
    ""
    "Quick start:"
    "  atp rq-keygen                          # generate a shared auth key"
    "  atp recv ./inbox --transport rq --once --rq-auth-key-hex <KEY>"
    "  atp send ./data host:8472 --transport rq --rq-auth-key-hex <KEY>"
    ""
    "Docs:      https://github.com/${OWNER}/${REPO}"
    "Uninstall: rm $DEST/$BIN_NAME"
  )
  [ "$SKILL_INSTALLED" -eq 1 ] && summary_lines+=(
    "Skill:     ~/.claude/skills/atp + ~/.codex/skills/atp"
    "           remove with: install.sh --uninstall-skill"
  )
  draw_box "0;32" "${summary_lines[@]}"
fi
