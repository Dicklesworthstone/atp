# atp Troubleshooting — exact error → cause → fix

Errors are fail-closed by design; most "failures" below are the tool refusing
to do something unsafe. Fix the condition, don't look for a bypass flag —
for the security errors, none exists.

## Startup / config errors

**`direct rq transfers require symbol authentication`**
rq tier without a key. Fix: `atp rq-keygen` → `--rq-auth-key-hex` on both
ends, or (trusted lab links only) `--rq-allow-unauthenticated-lab` on both.

**`max_datagram_size (1200) must be at least symbol_size (N) + the 56-byte authenticated envelope header`**
Only reachable when `--symbol-size` > 1144 is passed **explicitly** with
`--transport quic` (or on a pre-0.3.7 binary where 1400 was the blanket
default). Fix: drop the flag (auto-sizing picks 1144) or pass ≤ 1144 on both
ends. On old binaries: upgrade.

**`atp recv --transport quic requires --server-cert <PEM chain>` / `--server-key`**
The encrypted tier has no anonymous mode. Provide a cert; any
serverAuth-EKU leaf works (mkcert/step-ca/internal CA).

**`round0_loss_target … must be finite and in [0.0, 1.0)` / `repair_overhead … must be >= 1.0`**
Out-of-range tuning values; they validate before any connection.

## Transfer-time errors

**QUIC handshake fails with a certificate error**
Verification working as intended: chain, hostname, and validity are all
checked and there is no skip-verify option. Ensure `--ca` points at the CA
that signed the receiver's cert (or the cert chains to a system root) and
`--server-name` matches a SAN (it defaults to the target host — dialing an
IP usually needs it set).

**`object size exceeds limit` / rejected at 4 GiB**
Deliberate ceiling. Raise `--max-bytes` on **both** ends
(e.g. `--max-bytes 6442450944` for 6 GiB).

**Connect / accept / handshake timeout (~30–60 s)**
In order of likelihood: wrong host/port; UDP blocked by a firewall (rq and
quic are UDP — allow the listen port); receiver not yet listening (ssh
bootstrap has `--ssh-ready-timeout-secs`); two transfers sharing the same
socket pair (serialize them). Symptom signature `connect timeout + zero
packets received` = the path is black-holed, not slow.

**`Address already in use` immediately after a previous run**
TIME_WAIT on the old socket. Wait a few seconds or change `--listen`.

**Sender warns about the delta sidecar / falls back to full-object**
listen-port+1 is unreachable (firewall). Transfers still complete correctly;
open the port to restore delta re-sync savings.

## Performance symptoms

**Everything is slow, CPU pegged, decode dominates**
Debug build. RaptorQ decode in debug profile is orders of magnitude slower
at large block counts. Use the release binaries (install.sh) or
`scripts/build-atp.sh`.

**`feedback_rounds` > 0 on a link that should be clean**
Real loss where you expected none (Wi-Fi power save, shaper drops, MTU
blackhole fragmenting datagrams). Confirm with `ATP_RQ_TRACE=1` — receiver
`NeedMore` lines show per-round observed/accepted/loss-fraction.

**Encrypted large-file transfer loses to rsync-over-ssh on a pristine gigabit link**
Known honest losing cell (userspace QUIC vs kernel TCP; ~1.5× single files,
~2.5× big trees). Active work upstream; plaintext/authenticated tiers do not
have this gap. Don't burn time "fixing" your config.

**Sender RSS balloons on a lossy link**
Expected: forward-repair encoder state peaks ~10× rsync's RSS at 2–10% loss.
Receiver stays ≤ 18 MB. Budget for it or lower `--repair-overhead`.

## Diagnostics

```bash
ATP_RQ_TRACE=1  atp send …   # RaptorQ round-by-round symbol accounting
ATP_QUIC_TRACE=1 atp send …  # per-frame QUIC events (verbose)
atp send … --dry-run         # plan only: files, sizes, Merkle root
```

The JSON report is the ground truth: `committed`, `sha_ok`, `merkle_ok`,
`feedback_rounds`, transport actually used, wall time.
