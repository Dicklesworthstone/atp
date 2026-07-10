#!/usr/bin/env bash
# Deterministic verdict on an atp transfer JSON report.
# Usage: atp send … | check-report.sh     or: check-report.sh report.json
# Exit 0 = committed+verified. Exit 1 = failed/uncommitted. Exit 2 = not a report.
set -u
INPUT=$(cat "${1:-/dev/stdin}") || exit 2
python3 - "$INPUT" <<'PY'
import json, sys
try:
    r = json.loads(sys.argv[1])
except Exception:
    print("VERDICT: not JSON (did you capture stderr instead of stdout?)"); sys.exit(2)
def walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values(): yield from walk(v)
committed = sha = None; rounds = None
for d in walk(r):
    committed = d.get("committed", committed)
    sha = d.get("sha_ok", sha)
    rounds = d.get("feedback_rounds", rounds)
if committed is True and sha is False:
    print("VERDICT: FAIL — committed=true but sha_ok=false (should be impossible; investigate)"); sys.exit(1)
if committed is True:
    extra = f", feedback_rounds={rounds}" if rounds is not None else ""
    extra += ", sha_ok=true" if sha else ""
    print(f"VERDICT: PASS — committed{extra}"); sys.exit(0)
if committed is None:
    print("VERDICT: UNKNOWN — no 'committed' key found (not a transfer report?)"); sys.exit(2)
print(f"VERDICT: FAIL — committed={committed!r} (fail-closed: nothing was written)"); sys.exit(1)
PY
