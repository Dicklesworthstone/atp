---
name: atp
description: >-
  Run, debug, and tune atp transfers (fountain-coded rsync alternative). Use
  when sending files with atp, choosing --transport or security tiers,
  reading transfer JSON reports, or benchmarking vs rsync.
dependencies:
  - "atp release binary (install.sh) — debug builds are orders of magnitude slower at RaptorQ decode"
  - "Both ends run atp; explicit tuning flags must match on both ends"
---

# atp — fountain-coded file transfer

<!-- TOC: One Rule | Boundary Card | Choose a Transport | Canonical Invocations | JSON Report | Gotchas | Failure→Fix | References -->

## One Rule

Never trade integrity for speed, and never claim a speed atp did not earn.
Every transfer is SHA-256 verified and fails closed; every performance claim
must trace to the append-only evidence ledger (see Provenance). If a transfer
did not commit (`"committed": true` in the JSON report), it did not happen.

## Boundary Card (v0.3.7, 2026-07-10)

- Latest release: **v0.3.7** (5 platform binaries + SHA256SUMS), built from
  asupersync `64ebd17d3`. Older binaries on PATH behave differently — check
  `atp --version` before trusting flag semantics below.
- Since v0.3.7 `--symbol-size` is **automatic per transport** (1400 on rq,
  1144 on quic). Pre-0.3.7 binaries require `--symbol-size 1144` by hand on
  QUIC or they fail closed at startup.
- `--rq-auth-key-hex` on `--transport quic` is ignored (QUIC's TLS 1.3 AEAD
  already authenticates datagrams); ≥0.3.7 prints a notice saying so.
- Honest losing cells (do not oversell): encrypted single huge files on
  pristine fast links (rsync-over-ssh ~1.5×, trees ~2.5×); sender RSS can
  peak ~10× rsync's on 2–10% loss links (receiver stays ≤ 18 MB).

## Choose a Transport

| Situation | Transport | Auth you must provide |
|-----------|-----------|----------------------|
| Default / delta re-sync wanted | `tcp` (default) | none |
| Lossy/latent link (Wi-Fi, WAN, cross-continent) | `rq` | `atp rq-keygen` key on both ends, or `--rq-allow-unauthenticated-lab` on both (trusted lab only) |
| Encryption required | `quic` | receiver `--server-cert/--server-key`; sender `--ca` unless the cert chains to a system root |
| "Just pick the best" | `auto` (quic→rq→tcp) | **only engages beyond TCP with `--no-delta`** (br-asupersync-dg8juf) |

Receiver `--transport` must match the sender's data plane. `rq` refuses to
run unauthenticated unless BOTH ends explicitly opt into the lab tier.

## Canonical Invocations

```bash
KEY=$(atp rq-keygen)                                   # once; or ATP_RQ_AUTH_KEY_HEX
atp recv ./inbox --listen 0.0.0.0:8472 --transport rq --once --rq-auth-key-hex "$KEY"
atp send ./dataset host:8472 --transport rq --rq-auth-key-hex "$KEY"

# Encrypted (QUIC + TLS 1.3, fail-closed cert verification, no --insecure exists)
atp recv ./inbox --listen 0.0.0.0:8472 --transport quic --once \
  --server-cert cert.pem --server-key key.pem
atp send ./dataset receiver.example.com:8472 --transport quic \
  --ca ca.pem --server-name receiver.example.com

atp send ./dataset user@host:/backups/dataset          # ssh-bootstrap one-liner
atp serve ./inbox --transport rq --rq-auth-key-hex "$KEY"   # persistent daemon
atp send ./dataset host:8472 --dry-run                 # plan JSON, sends nothing
```

## Read the JSON Report

Every transfer prints one. Check in this order:

1. `committed` — false means nothing was written to the destination.
2. `sha_ok` / `merkle_ok` — the integrity verdict (fail-closed; a false here
   with committed=true cannot happen).
3. `feedback_rounds` — 0 on clean links; growing numbers mean loss-driven
   repair rounds (expected on bad links, suspicious on a LAN).
4. `bytes_*`, wall time, `transport` — what actually ran (matters with auto).

## Remaining Gotchas (real, by design)

- **Transfers > 4 GiB**: raise `--max-bytes` on **both** ends (deliberate
  fail-closed ceiling, not a capability limit).
- **`auto` + delta**: the QUIC→RQ ladder only engages with `--no-delta`;
  otherwise auto = tcp. Explicit `--transport rq|quic` work fine with delta.
- **Delta sidecar port**: the receiver's planner listens on **listen-port+1**.
  If firewalled, transfers still work — sender warns and falls back to
  full-object transfer.
- **Explicit tuning flags must match both ends** (`--symbol-size`,
  `--max-block-size`, `--repair-overhead`). Defaults always agree; only
  explicit values can diverge.
- **`Address already in use`** right after a previous run = TIME_WAIT; wait a
  few seconds or change `--listen` port.
- Not an rsync drop-in: no `--exclude`, no `--delete`, no mirror-mode
  semantics. It moves data fast and verified; it is not a mirroring toolchain.

## Failure → Fix (fast path)

| Symptom | Cause | Fix |
|---------|-------|-----|
| `direct rq transfers require symbol authentication` | rq without key | `atp rq-keygen` → both ends, or lab flag on both |
| QUIC cert error at handshake | verification working as designed | `--ca` must sign the receiver's cert; `--server-name` must match a SAN (defaults to target host) |
| `object size exceeds limit` | 4 GiB guard | `--max-bytes N` on both ends |
| `max_datagram_size (1200) must be at least symbol_size…` | explicit oversize on quic (or pre-0.3.7 binary) | drop the flag; upgrade |
| Slow transfers, high CPU | debug build | use release binaries / install.sh |
| Connect/handshake timeout ~30–60 s | wrong port, UDP blocked, or another process on the socket pair | verify reachability; check the sidecar port too |

More: [TROUBLESHOOTING.md](references/TROUBLESHOOTING.md)

## Reference Index

| Need | Read |
|------|------|
| Full flag reference per subcommand, env vars, per-transport resolution | [CLI.md](references/CLI.md) |
| Playbooks: keys/certs, ssh bootstrap, daemon, tuning, honest benchmarking | [OPERATIONS.md](references/OPERATIONS.md) |
| Exact error strings → root cause → fix | [TROUBLESHOOTING.md](references/TROUBLESHOOTING.md) |
| Where these claims come from (ledger, beads, commits) | [PROVENANCE.md](references/PROVENANCE.md) |

Source of truth when this skill disagrees with reality: the asupersync
source at the commit pinned in this repo's `UPSTREAM_REV`, then `atp --help`
from the exact binary in use, then this skill. File a bead when they diverge.
