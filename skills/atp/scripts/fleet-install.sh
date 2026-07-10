#!/usr/bin/env bash
# Install/update atp on ssh-config hosts, non-interactively and idempotently.
#
#   fleet-install.sh --list            # print eligible Host entries, one per line
#   fleet-install.sh host1 host2 …     # install/update atp on these hosts
#   fleet-install.sh --all             # install/update on every eligible host
#
# Eligible = concrete Host entries in ~/.ssh/config (no wildcards/negations).
# Uses BatchMode ssh (never hangs on a password prompt); per-host verdicts on
# stdout as `HOST<TAB>STATUS<TAB>DETAIL`. Exit 0 = every attempted host OK.
set -u
INSTALL_URL="https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.sh"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

list_hosts() {
  awk 'tolower($1)=="host"{for(i=2;i<=NF;i++) if ($i !~ /[*?!]/) print $i}' \
    ~/.ssh/config 2>/dev/null | sort -u
}

case "${1:-}" in
  --list) list_hosts; exit 0 ;;
  --all) mapfile -t HOSTS < <(list_hosts) ;;
  "") echo "usage: fleet-install.sh --list | --all | HOST…" >&2; exit 2 ;;
  *) HOSTS=("$@") ;;
esac

FAILED=0
for h in "${HOSTS[@]}"; do
  if ! ssh "${SSH_OPTS[@]}" "$h" 'true' 2>/dev/null; then
    printf '%s\tUNREACHABLE\tssh BatchMode connect failed\n' "$h"; FAILED=1; continue
  fi
  os=$(ssh "${SSH_OPTS[@]}" "$h" 'uname -s 2>/dev/null' 2>/dev/null || echo unknown)
  case "$os" in
    Linux|Darwin) ;;
    *) printf '%s\tSKIPPED\tnon-POSIX remote (%s) — use install.ps1 on Windows\n' "$h" "$os"; continue ;;
  esac
  if out=$(ssh "${SSH_OPTS[@]}" "$h" \
      "curl -fsSL '$INSTALL_URL' | bash -s -- --quiet --no-skill && \
       (command -v atp || echo \"\$HOME/.local/bin/atp\") >/dev/null; \
       \"\$HOME/.local/bin/atp\" --version 2>/dev/null || atp --version 2>/dev/null" 2>&1); then
    ver=$(printf '%s\n' "$out" | grep -m1 '^atp ' || echo 'installed (version unread)')
    printf '%s\tOK\t%s\n' "$h" "$ver"
  else
    printf '%s\tFAILED\t%s\n' "$h" "$(printf '%s' "$out" | tail -1)"; FAILED=1
  fi
done
exit "$FAILED"
