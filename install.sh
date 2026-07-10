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
#   --quiet            Suppress non-error output
#   --no-gum           Disable gum formatting even if available
#   --no-verify        Skip checksum verification (for testing only)
#   --force            Reinstall even if the same version is present
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
DEST_DEFAULT="$HOME/.local/bin"
DEST="${DEST:-$DEST_DEFAULT}"
LOCK_FILE="${TMPDIR:-/tmp}/atp-install.lock"
EASY=0
QUIET=0
VERIFY=0
FROM_SOURCE=0
SYSTEM=0
NO_GUM=0
NO_CHECKSUM=0
FORCE_INSTALL=0
OFFLINE_TARBALL=""
CHECKSUM="${CHECKSUM:-}"
ARTIFACT_URL="${ARTIFACT_URL:-}"

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
  --quiet            Suppress non-error output
  --no-gum           Disable gum formatting even if available
  --no-verify        Skip checksum verification (testing only)
  --force            Reinstall even if the same version is present
  -h, --help         Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    --system) SYSTEM=1; DEST="/usr/local/bin"; shift ;;
    --easy-mode) EASY=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --from-source) FROM_SOURCE=1; shift ;;
    --offline) OFFLINE_TARBALL="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --no-gum) NO_GUM=1; shift ;;
    --no-verify) NO_CHECKSUM=1; shift ;;
    --force) FORCE_INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 2 ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Proxy support — pass "${PROXY_ARGS[@]}" to every curl call
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
  case "$ARCH" in
    x86_64|amd64) ARCH="x86_64" ;;
    arm64|aarch64) ARCH="aarch64" ;;
    *) warn "Unknown arch $ARCH, using as-is" ;;
  esac

  TARGET=""
  case "${OS}-${ARCH}" in
    # Linux x86_64 prefers the fully-static musl artifact so it runs on every
    # glibc generation; set_artifact_url probes and falls back to gnu if a
    # release only shipped the glibc build.
    linux-x86_64) TARGET="x86_64-unknown-linux-musl" ;;
    linux-aarch64) TARGET="aarch64-unknown-linux-gnu" ;;
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
  if ! tag=$(curl -fsSL "${PROXY_ARGS[@]}" -H "Accept: application/vnd.github.v3+json" "$latest_url" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'); then
    tag=""
  fi

  if [ -n "$tag" ]; then
    VERSION="$tag"
    info "Resolved latest version: $VERSION"
    return 0
  fi

  # Redirect-based fallback
  local redirect_url="https://github.com/${OWNER}/${REPO}/releases/latest"
  if tag=$(curl -fsSL "${PROXY_ARGS[@]}" -o /dev/null -w '%{url_effective}' "$redirect_url" 2>/dev/null | sed -E 's|.*/tag/||'); then
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
  curl -sSL "${PROXY_ARGS[@]}" -o /dev/null -w '%{http_code}' -I --max-time 10 "$1" 2>/dev/null || echo "000"
}

set_artifact_url() {
  TAR=""
  URL=""
  [ "$FROM_SOURCE" -eq 1 ] && return 0
  if [ -n "$OFFLINE_TARBALL" ]; then
    TAR=$(basename "$OFFLINE_TARBALL")
    return 0
  fi
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

  # musl-first with gnu fallback for Linux x86_64 (one HEAD probe).
  if [ "$TARGET" = "x86_64-unknown-linux-musl" ] && command -v curl >/dev/null 2>&1; then
    local code
    code=$(http_status "$URL")
    if [ "$code" != "200" ] && [ "$code" != "302" ]; then
      local gnu_target="x86_64-unknown-linux-gnu"
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
  [ ! -d "$path" ] && path=$(dirname "$path")
  if command -v df >/dev/null 2>&1; then
    local avail_kb
    avail_kb=$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}')
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
      err "Try --system with sudo, or choose a writable --dest"
      exit 1
    fi
  fi
  if [ ! -w "$DEST" ]; then
    err "No write permission to $DEST"
    err "Try --system with sudo, or choose a writable --dest"
    exit 1
  fi
}

check_existing_install() {
  INSTALLED_VERSION=""
  if [ -x "$DEST/$BIN_NAME" ]; then
    INSTALLED_VERSION=$("$DEST/$BIN_NAME" --version 2>/dev/null | head -1 || echo "")
    [ -n "$INSTALLED_VERSION" ] && info "Existing atp detected: $INSTALLED_VERSION"
  fi
}

check_network() {
  [ "$FROM_SOURCE" -eq 1 ] && return 0
  [ -n "$OFFLINE_TARBALL" ] && return 0
  [ -z "$URL" ] && return 0
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is required to download release artifacts"
    exit 1
  fi
  if ! curl -fsSL "${PROXY_ARGS[@]}" --connect-timeout 3 --max-time 8 -o /dev/null -I "$URL" 2>/dev/null; then
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
LOCKED=0
cleanup() {
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

verify_checksum() {
  local file="$1"

  if [ "$NO_CHECKSUM" -eq 1 ]; then
    warn "Checksum verification skipped (--no-verify)"
    return 0
  fi

  local expected="$CHECKSUM"
  if [ -z "$expected" ] && [ -n "$URL" ]; then
    # Primary: SHA256SUMS from the same release
    local sums_url="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/SHA256SUMS"
    local sums_file="$TMP/SHA256SUMS"
    if curl -fsSL "${PROXY_ARGS[@]}" "$sums_url" -o "$sums_file" 2>/dev/null; then
      expected=$(awk -v t="$TAR" '$2 == t {print $1}' "$sums_file" | head -1)
    fi
    # Fallback: per-asset .sha256 file
    if [ -z "$expected" ]; then
      local asset_sum
      if asset_sum=$(curl -fsSL "${PROXY_ARGS[@]}" "${URL}.sha256" 2>/dev/null); then
        expected=$(echo "$asset_sum" | awk '{print $1}' | head -1)
      fi
    fi
  fi

  if [ -z "$expected" ]; then
    warn "No published checksum found for $TAR; skipping verification"
    return 0
  fi

  local actual
  actual=$(sha256_of "$file")
  if [ -z "$actual" ]; then
    warn "No SHA256 tool found (sha256sum or shasum); skipping verification"
    return 0
  fi

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
    UPSTREAM_REV=$(curl -fsSL "${PROXY_ARGS[@]}" "$pin_url" 2>/dev/null | tr -d '[:space:]' || echo "")
  fi
  if [ -z "$UPSTREAM_REV" ]; then
    err "Could not resolve the pinned asupersync revision (UPSTREAM_REV)"
    exit 1
  fi
}

ensure_rust() {
  if command -v cargo >/dev/null 2>&1 && command -v rustup >/dev/null 2>&1; then
    return 0
  fi
  if [ "$EASY" -ne 1 ] && [ -t 0 ]; then
    echo -n "Building atp from source requires rustup. Install rustup now? (y/N): "
    read -r ans
    case "$ans" in y|Y) : ;; *) err "rustup is required for --from-source"; exit 1 ;; esac
  fi
  info "Installing rustup (the asupersync tree pins its own nightly toolchain)"
  curl -fsSL "${PROXY_ARGS[@]}" https://sh.rustup.rs | sh -s -- -y --profile minimal
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

# Already-installed short-circuit
if [ "$FORCE_INSTALL" -eq 0 ] && [ -n "$VERSION" ] && [ -n "$INSTALLED_VERSION" ]; then
  installed_ver="${INSTALLED_VERSION##* }"
  target_ver="${VERSION#v}"
  if [ "$installed_ver" = "$target_ver" ]; then
    ok "atp $VERSION is already installed at $DEST/$BIN_NAME"
    info "Use --force to reinstall"
    exit 0
  fi
fi

BIN=""
if [ -n "$OFFLINE_TARBALL" ]; then
  if [ ! -f "$OFFLINE_TARBALL" ]; then
    err "Offline tarball not found: $OFFLINE_TARBALL"
    exit 1
  fi
  info "Installing from offline tarball: $OFFLINE_TARBALL"
  cp "$OFFLINE_TARBALL" "$TMP/$TAR"
  verify_checksum "$TMP/$TAR" || exit 1
  tar -xzf "$TMP/$TAR" -C "$TMP"
  BIN="$TMP/atp"
elif [ "$FROM_SOURCE" -eq 1 ]; then
  build_from_source
else
  info "Downloading $TAR (${VERSION})..."
  CURL_PROGRESS=(--progress-bar)
  [ "$QUIET" -eq 1 ] && CURL_PROGRESS=(-sS)
  if ! run_with_spinner "Downloading atp ${VERSION}..." \
    curl -fSL "${PROXY_ARGS[@]}" "${CURL_PROGRESS[@]}" "$URL" -o "$TMP/$TAR"; then
    warn "Download failed; falling back to build-from-source"
    FROM_SOURCE=1
    build_from_source
  else
    if ! verify_checksum "$TMP/$TAR"; then
      exit 1
    fi
    tar -xzf "$TMP/$TAR" -C "$TMP"
    BIN="$TMP/atp"
  fi
fi

if [ ! -f "$BIN" ]; then
  err "Built/downloaded binary not found at $BIN"
  exit 1
fi

install -m 0755 "$BIN" "$DEST/$BIN_NAME"
ok "Installed $BIN_NAME to $DEST/$BIN_NAME"

INSTALLED=$("$DEST/$BIN_NAME" --version 2>/dev/null | head -1 || echo "atp (version unknown)")

# PATH handling
PATH_NOTE=""
case ":$PATH:" in
  *:"$DEST":*) : ;;
  *)
    if [ "$EASY" -eq 1 ]; then
      updated=0
      for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        if [ -e "$rc" ] && [ -w "$rc" ]; then
          if ! grep -F "$DEST" "$rc" >/dev/null 2>&1; then
            echo "export PATH=\"$DEST:\$PATH\"" >> "$rc"
          fi
          updated=1
        fi
      done
      if [ "$updated" -eq 1 ]; then
        PATH_NOTE="PATH updated in shell rc files; restart your shell"
      else
        PATH_NOTE="Add $DEST to your PATH"
      fi
    else
      PATH_NOTE="Add $DEST to your PATH (or re-run with --easy-mode)"
    fi
    ;;
esac
[ -n "$PATH_NOTE" ] && warn "$PATH_NOTE"

# Self-test
SELF_TEST="skipped"
if [ "$VERIFY" -eq 1 ]; then
  info "Running post-install self-test"
  if "$DEST/$BIN_NAME" --version >/dev/null 2>&1 && \
     "$DEST/$BIN_NAME" rq-keygen >/dev/null 2>&1; then
    SELF_TEST="passed"
    ok "Self-test passed (--version + rq-keygen)"
  else
    SELF_TEST="FAILED"
    err "Self-test failed — the binary may not work on this platform"
  fi
fi

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
  draw_box "0;32" "${summary_lines[@]}"
fi
