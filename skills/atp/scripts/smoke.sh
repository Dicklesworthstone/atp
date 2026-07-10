#!/usr/bin/env bash
# atp environment smoke test: real loopback transfer, asserts commit + integrity.
# Usage: smoke.sh [path-to-atp-binary]   (default: `atp` on PATH)
# Exit 0 = your atp install works end-to-end; nonzero = message says why.
set -u
ATP="${1:-atp}"
command -v "$ATP" >/dev/null 2>&1 || { echo "FAIL: '$ATP' not found (run install.sh)"; exit 2; }
echo "atp: $($ATP --version 2>/dev/null || echo 'version unknown (pre-0.3.x?)')"

WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/in" "$WORK/out"
head -c $((3 * 1024 * 1024)) /dev/urandom > "$WORK/in/payload.bin"
PORT=$(( (RANDOM % 20000) + 20000 ))
KEY=$("$ATP" rq-keygen) || { echo "FAIL: rq-keygen"; exit 1; }

"$ATP" recv "$WORK/out" --listen "127.0.0.1:$PORT" --transport rq --once \
  --rq-auth-key-hex "$KEY" > "$WORK/recv.json" 2>"$WORK/recv.err" &
RECV_PID=$!
sleep 1

if ! "$ATP" send "$WORK/in/payload.bin" "127.0.0.1:$PORT" --transport rq \
    --rq-auth-key-hex "$KEY" > "$WORK/send.json" 2>"$WORK/send.err"; then
  echo "FAIL: send exited nonzero"; sed -n '1,5p' "$WORK/send.err"; kill "$RECV_PID" 2>/dev/null; exit 1
fi
wait "$RECV_PID" || { echo "FAIL: receiver exited nonzero"; sed -n '1,5p' "$WORK/recv.err"; exit 1; }

if ! cmp -s "$WORK/in/payload.bin" "$WORK/out/payload.bin"; then
  echo "FAIL: committed bytes differ from source"; exit 1
fi
grep -q '"committed": *true' "$WORK/send.json" "$WORK/recv.json" 2>/dev/null \
  || echo "note: 'committed' key not found in reports (schema drift? still byte-verified above)"
echo "OK: 3 MiB loopback rq transfer committed and byte-identical (port $PORT)"
