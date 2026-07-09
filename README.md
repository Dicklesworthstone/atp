<!-- illustration placeholder: drop atp_illustration.webp here and uncomment
<p align="center">
  <img src="atp_illustration.webp" alt="atp — fountain-coded file transfer" width="800">
</p>
-->

# atp

<div align="center">

[![License: MIT+Rider](https://img.shields.io/badge/License-MIT%2BOpenAI%2FAnthropic%20Rider-blue.svg)](./LICENSE)
[![Release](https://img.shields.io/github/v/release/Dicklesworthstone/atp)](https://github.com/Dicklesworthstone/atp/releases/latest)
[![Rust](https://img.shields.io/badge/Rust-nightly-orange.svg)](https://www.rust-lang.org/)
[![Platforms](https://img.shields.io/badge/Platforms-Linux%20%7C%20macOS-lightgrey.svg)](#installation)
[![Source](https://img.shields.io/badge/Source-asupersync-8A2BE2.svg)](https://github.com/Dicklesworthstone/asupersync)

**Fountain-coded file transfer that outruns tuned rsync on real networks.**

RaptorQ erasure coding over raw UDP or QUIC — loss becomes a repair budget instead of
a retransmit stall. Every transfer is SHA-256 verified end-to-end and fails closed.

<h3>Quick Install</h3>

```bash
curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.sh | bash
```

</div>

---

## TL;DR

**The Problem**: Every classic transfer tool — rsync, scp, sftp — rides a single TCP
stream. TCP interprets packet loss as congestion and collapses its window, so on real
links (WAN latency, Wi-Fi loss, congested paths, cross-continent hops) throughput
degrades roughly with `1/(RTT·√loss)`. A 2% loss rate on an 80 ms link doesn't slow a
TCP transfer down by 2% — it can slow it down by 10× or stall it entirely. And every
lost packet costs at least a round trip to repair, because TCP must re-send *exactly
the bytes that were lost*.

**The Solution**: `atp` encodes each file into **RaptorQ fountain symbols (RFC 6330)**.
Any K(+ε) of the N symbols sprayed at the receiver reconstruct the data — no symbol is
special, so *which* packets got lost doesn't matter, only *how many*. Loss stops being
a latency problem (round trips per lost packet) and becomes a bandwidth line item
(a few percent of repair symbols). Feedback is a small number of bounded rounds, not
a per-packet ACK conversation. On clean links atp detects the conditions and switches
to a paced reliable stream, so you never pay the FEC tax when you don't need it.

### Why atp?

| Feature | What It Means |
|---------|---------------|
| **Loss-immune data plane** | RaptorQ symbols over UDP/QUIC: 10% packet loss ≈ 10% extra bandwidth, not a stalled pipe. On the harshest benchmark regime (10% loss + reorder + dup + 200 ms RTT), atp is **~1.9× faster than tuned rsync** across the board |
| **Fail-closed verification** | SHA-256 over every file (and a Merkle-committed manifest for trees). Bytes are staged, verified, then committed — a failed transfer never leaves partially-written garbage in the destination |
| **Fast on clean links too** | Adaptive path: a BBR-style delivery-rate-sampled, gain-cycled stream on clean links (~946 Mbit/s on a 1 Gbit path), fountain spray under loss. atp beats tuned rsync on large clean transfers as well (500 MB: 4.52 s vs 5.13 s) |
| **Small files & trees** | Trees are packed (2,000 small files → 1 wire entry) and Merkle-verified. 500 KB transfers run 3–5× faster than rsync at every loss rate |
| **Real security tiers** | From lab-plaintext to per-symbol HMAC to full QUIC TLS 1.3 with certificate verification *plus* per-symbol auth — chosen explicitly, never silently downgraded |
| **rsync-like delta re-sync** | Content-defined chunking (FastCDC) + IBLT set reconciliation + sub-chunk rolling-checksum diffs move only what changed — and the reconstruction is still hash-verified, so a checksum collision can never commit wrong bytes |
| **1-RTT startup** | QUIC handshake instead of ssh session setup: encrypted 500 KB transfers are **3–5× faster** than rsync-over-ssh |

---

## Quick Example

```bash
# 0. One-time: generate a shared symbol-authentication key (32 bytes, hex)
KEY=$(atp rq-keygen)

# 1. On the receiving machine
atp recv ./inbox --listen 0.0.0.0:8472 --transport rq --once --rq-auth-key-hex "$KEY"

# 2. On the sending machine — file or directory, fountain-coded over UDP
atp send ./dataset receiver.example.com:8472 --transport rq --rq-auth-key-hex "$KEY"

# rsync-style one-liner: SSH-bootstrap a remote receiver, then stream directly
atp send ./dataset user@receiver.example.com:/backups/dataset

# Long-running receive daemon (accepts transfer after transfer)
atp serve ./inbox --transport rq --rq-auth-key-hex "$KEY"

# See exactly what would be sent (file list, sizes, Merkle root) without connecting
atp send ./dataset receiver.example.com:8472 --dry-run
```

Every transfer prints a JSON report: bytes moved, wall time, throughput, transport
used, feedback rounds, and verification status.

---

## Benchmarks: atp vs rsync

These numbers come from a fail-closed benchmark harness with an integrity standard
designed so that a false win is structurally impossible. The full method, every
result, and — just as importantly — every *refuted* optimization hypothesis are
logged in the append-only
[evidence ledger](https://github.com/Dicklesworthstone/asupersync/blob/main/docs/atp_rq_beat_rsync_ledger.md)
(231 numbered experiments and counting).

### The method (summarized)

- **Opponent**: rsync with its optimal flags (`--whole-file --inplace --no-compress`)
  on its fastest transport — the plaintext rsync daemon for the no-crypto tier, ssh
  with `aes128-gcm` for the encrypted tier. Never a strawman.
- **Crypto-symmetric**: atp's plaintext tier races the rsync daemon; atp's TLS 1.3
  tier races rsync-over-ssh. Mixing tiers is treated as an invalid experiment.
- **SHA-256 verification of every single transfer** (per-file digests; sorted digest
  sets for trees). A timeout, error, or hash mismatch is recorded as a failure and
  excluded from medians — a failure can never be scored as a win.
- **Rate-capped links only**: each cell runs in a hermetic network namespace with
  `netem` rate + delay + jitter + loss applied symmetrically on both ends.
- **Medians of ≥3–5 reps** with coefficient-of-variation reported; noisy cells are
  flagged, not hidden. Peak/average RSS is recorded on both ends.
- **The whole matrix is reported** — including the cells atp loses.

Link regimes: **perfect** (1 Gbit, 2 ms), **good** (200 Mbit, 25 ms, 0.1% loss),
**bad** (50 Mbit, 80±20 ms, 2% loss), **broken** (10 Mbit, 200±50 ms, 10% loss +
5% reorder + 1% duplication).

### Scoreboard — plaintext tier (atp vs tuned rsync daemon)

Wall-clock ratio = atp median ÷ rsync median (lower is better; **< 1.0 = atp wins**).
Current HEAD (atp 0.3.5), all cells SHA-verified:

| Workload | perfect | good | bad | broken |
|----------|---------|------|-----|--------|
| 500 KB file | **0.21** (4.8×) | **0.34** (2.9×) | **0.31** (3.2×) | **0.21** (4.8×) |
| 50 MB file | **0.45** (2.2×) | **0.72** (1.4×) | **0.71** (1.4×) | **0.83** (1.2×) |
| 500 MB file | **0.88** (4.52 s vs 5.13 s) | — | **0.98** (parity) | **0.93** (converges 3/3) |
| 5 GB file | **0.99** (46.0 s vs 46.6 s) | — | — | — |
| tree (2,000 files) | 1.09 (loss, noisy) | **0.95** | **0.79** | **0.68** |
| tree (400 files, large) | **0.60** (1.7×) | **0.67** (1.5×) | **0.62** (1.6×) | **0.41** (2.5×) |

Per-regime geometric means: **perfect 0.50 · good 0.63 · bad 0.64 · broken 0.54** —
atp is roughly 1.6–2× faster than tuned rsync across the matrix, and nearly 2× faster
on the *worst* links, which is exactly where a transfer tool earns its keep. The
authenticated tier (per-symbol HMAC vs rsync-over-ssh) tracks these results.

The headline cell: **500 MB over a 10%-loss, 200 ms, 10 Mbit link — atp 564.8 s vs
rsync 574.5 s**, with atp's *worst* rep beating rsync's *best* rep. Before the
congestion-control campaign, atp timed out entirely on that cell (900 s+); TCP-based
tools survive it only because TCP grinds; fountain coding wins it.

The one plaintext loss: the tiny-tree-on-perfect-link cell (2,000 small files on a
1 Gbit/2 ms LAN), where rsync is ~8.6% faster and the result is within noise. That
cell is a fixed handshake-round-trip floor, not a throughput gap.

### Scoreboard — encrypted tier (atp QUIC/TLS 1.3 vs rsync-over-ssh)

Honestly mixed, reported in full:

| Cell | Result |
|------|--------|
| 500 KB, perfect / good | **atp wins 3.0× / 5.0×** (QUIC 1-RTT vs ssh session setup) |
| 50 MB, good | **atp wins** (marginal, 0.98) |
| tree (2,000 files), good | parity (1.00) |
| 50 MB, perfect | rsync wins (1.48, noisy) |
| 500 MB, perfect | rsync wins (1.47 — atp ~74 MB/s vs ssh ~108 MB/s) |
| trees, perfect | rsync wins (1.2–2.5×) |
| bad / broken, large | currently gated by known issues (tracked in the ledger) |

Encrypted good-regime geomean **0.70 (atp wins)**; perfect-regime **1.10 (rsync
wins ~10%)**. The encrypted clean-large gap is a hand-rolled-QUIC-stack vs
kernel-TCP throughput frontier — architectural, known, and being worked. If your
encrypted workload is huge single files on pristine gigabit links, rsync-over-ssh
is still the faster tool today; atp will tell you so rather than hide it.

### Memory footprint

atp's receiver runs bounded: **≤ 18 MB RSS at every file size** (a 5 GB encrypted
receive used to peak at 882 MB; it now runs at ~12 MB). The honest trade-off is on
the *sender* during lossy-tier fountain coding: peak RSS can reach ~10× rsync's on
2–10% loss cells — that memory is the forward-repair machinery that buys convergence
where TCP tools stall.

### The negative-evidence ledger

Most performance READMEs list the optimizations that worked. The atp campaign also
kept every one that *didn't*, with the mechanism of failure — so nobody re-chases
them and so the numbers above have provenance. A sample of refuted hypotheses from
the ledger:

- Receipt-clocked flow-control credit — refuted **four times** (final attempt: 2×
  payload re-sent, congestion collapse); settled with a written mechanism.
- "Receiver ACKs too slowly (~30 ms)" — refuted by direct measurement (ACKs flow
  every ~1.3 ms; the latency was repair-episode smearing).
- BDP-based in-flight caps — refuted twice (the transport's RTT estimator was being
  fed by a synthetic clock; the "evidence" was manufactured by a sample clamp).
- SIMD GF(256) kernels for decode — zero benefit (the wall was the serial symbol
  intake pump, not the field arithmetic).
- Bigger flow windows — refuted in both directions (2 MiB is a measured optimum:
  4 MiB improved delivery rate but exploded repair traffic 39 → 289 MB).
- Sender "spray faster" — refuted three times (you cannot outrun the receiver's
  drain rate).

Each landed improvement — the delivery-rate sampler, PROBE_BW-style gain cycling,
the bounded receive window, zero-copy receive, packed trees, the source-stream fast
path — survived a deterministic lab gate *and* a same-day A/B against its parent
commit before it was believed.

---

## How It Works

### Two planes: reliable control, fungible data

```
  SENDER                                                RECEIVER
  ──────                                                ────────
  manifest (files, chunk plan,           control plane (reliable, ordered)
  Merkle root, coding params)   ───────────────────────►  validate manifest
                                 QUIC bidi stream / TCP    stage entries
                                                           │
  RaptorQ symbol spray                data plane (unordered, loss-tolerant)
  src symbols + repair symbols ───────────────────────►  decode per entry:
  (fresh repair each round)      QUIC DATAGRAMs / UDP     any K of N symbols
                                                           │
                          ◄───────  NeedMore(entries)  ───┘  (bounded rounds)
                          ────────  fresh repair batch ──►
                                                           │
                          ◄───────  Proof (verified)  ────┘
                                                       SHA-256 verify → commit
```

- **Control plane** (QUIC bidirectional stream, or TCP): handshake, manifest,
  `NeedMore` feedback, final verified-proof receipt. Reliable and ordered.
- **Data plane** (QUIC DATAGRAMs, or raw UDP across N sockets): RaptorQ source and
  repair symbols. Unordered, unacknowledged per-packet, loss-absorbed by coding.
  Because RaptorQ is *rateless*, every repair round generates brand-new symbols —
  the sender never needs to know which packets were lost.

This split is the core design decision: TCP-style reliability never fights the
fountain code, and the fountain code never has to reimplement ordering for the
metadata that genuinely needs it.

### The adaptive path

The FEC spray is not always the right tool, and atp knows it:

- **Clean links** → a reliable, paced *source stream*: BBR-style delivery-rate
  sampling (per-packet delivered counters, wall-clock intervals), a PROBE_BW-style
  gain cycle (1.25 probe / 0.75 drain / 6× cruise per RTprop), and a bounded 2 MiB
  receive window advertised loss-proof on every ACK. Measured at ~946 Mbit/s on a
  1 Gbit path — effectively line rate.
- **Lossy links** → the RaptorQ spray with proactive repair overhead sized from the
  observed loss rate, arrival-driven pacing, and bounded feedback rounds.
- **Small trees** → consecutive small files are packed into single wire entries
  (2,000-file tree → 1 entry) so tiny files don't each pay a coding + round-trip
  floor; the Merkle commitment is still over the logical files on both sides.
- `--transport auto` tries QUIC → RaptorQ/UDP → TCP and records each attempt in the
  transfer report.

### Verification is structural, not optional

Every entry is staged, hash-verified (SHA-256 per chunk and per file, Merkle root
per transfer), and only then committed to the destination. There is no flag to skip
verification. A transfer that cannot verify **fails closed** — partial or corrupt
data never lands in your destination path, and interrupted transfers never expose
partially-verified output.

### Delta re-sync

For re-syncing changed files, atp uses a two-level delta codec:

1. **Chunk level**: content-defined chunking (FastCDC) with a content-addressed
   store and IBLT set reconciliation — the endpoints discover *which chunks differ*
   with communication proportional to the delta, not the file size.
2. **Sub-chunk level**: within a changed chunk, a classic rolling-checksum diff
   (64-byte sub-blocks, weak rolling hash + truncated SHA-256 strong hash) emits
   copy/literal ops so a small edit inside a large chunk doesn't reship the chunk.

Reconstructed chunks are re-verified against the manifest hash, so even a
strong-checksum collision cannot commit wrong bytes. Delta is on by default for
re-syncs; `--no-delta` forces whole-object transfer.

---

## Security Model

Three explicit tiers — you always choose; nothing silently downgrades:

| Tier | Flags | What you get |
|------|-------|--------------|
| **Lab / plaintext** | `--rq-allow-unauthenticated-lab` (both ends) | No crypto. For benchmarks, airgapped labs, and trusted links only. The flag name is deliberately embarrassing to type in production |
| **Authenticated** | `--rq-auth-key-hex <64-hex>` (both ends, or env `ATP_RQ_AUTH_KEY_HEX`) | Per-symbol HMAC on every UDP symbol — forged or replayed symbols are rejected before they touch the decoder. Generate keys with `atp rq-keygen` |
| **Encrypted** | `--transport quic` + receiver `--server-cert/--server-key`, sender `--ca/--server-name` (+ the auth key) | Full TLS 1.3 with real X.509 verification (chain, hostname, signature — fail-closed, no `--insecure` escape hatch), 1-RTT AEAD on every packet, *plus* per-symbol auth |

Details that matter (from the
[threat model](https://github.com/Dicklesworthstone/asupersync/blob/main/docs/quic_atp_threat_model.md)):

- The QUIC handshake uses a real rustls-backed TLS 1.3 driver with in-handshake
  certificate chain, hostname, signature, and time checks. Untrusted roots, wrong
  hostnames, and expired certs fail closed. There is **no insecure skip-verify mode**.
- Replay windows, anti-amplification limits (3× envelope), and bounded datagram
  queues are on by default.
- Honest boundaries: the encrypted tier's data plane uses an asupersync-specific
  short header (it is not generic-QUIC wire-interoperable), and the plain TCP
  transport authenticates content against the manifest but has no per-symbol auth.
  The full threat model documents exactly what is and is not claimed.

---

## Installation

### Quick install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.sh | bash
```

The installer detects your platform, downloads the right prebuilt binary from the
latest GitHub release, verifies its SHA-256 against the published `SHA256SUMS`, and
installs to `~/.local/bin`. Useful variants:

```bash
# Auto-add ~/.local/bin to your PATH
curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.sh | bash -s -- --easy-mode

# Specific version, with a post-install self-test
curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.sh | bash -s -- --version v0.3.5 --verify

# System-wide
curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.sh | sudo bash -s -- --system

# Build from the pinned source instead of downloading a binary
curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.sh | bash -s -- --from-source
```

### Prebuilt binaries

Each [release](https://github.com/Dicklesworthstone/atp/releases) ships tarballs +
`SHA256SUMS`:

| Platform | Artifact |
|----------|----------|
| Linux x86_64 (static, any glibc) | `atp-x86_64-unknown-linux-musl.tar.gz` |
| Linux x86_64 (glibc) | `atp-x86_64-unknown-linux-gnu.tar.gz` |
| Linux aarch64 | `atp-aarch64-unknown-linux-gnu.tar.gz` |
| macOS Apple Silicon | `atp-aarch64-apple-darwin.tar.gz` |
| macOS Intel | `atp-x86_64-apple-darwin.tar.gz` |

### From source

The canonical source lives in the
[asupersync](https://github.com/Dicklesworthstone/asupersync) repository (`atp` is
its standalone transfer CLI). The tree pins its own nightly toolchain via
`rust-toolchain.toml`, so with `rustup` installed:

```bash
# Direct cargo install from the canonical repo
cargo install --git https://github.com/Dicklesworthstone/asupersync asupersync \
  --bin atp --features atp-cli

# Or a release-identical build at this repo's pinned upstream commit
git clone https://github.com/Dicklesworthstone/atp && cd atp
scripts/build-atp.sh --pinned          # → dist/atp
```

`--features atp-cli` is the complete binary — it includes the TLS support the
encrypted QUIC tier requires. Expect a substantial compile (it builds the full
asupersync runtime).

---

## Command Reference

`atp` has four subcommands. Run any of them with `--help` for the full flag list.

### `atp send <SOURCE> <TARGET>`

Send a file or directory tree. `TARGET` is `host:port` (a listening `atp recv`/
`atp serve`) or `user@host:/path` (SSH bootstrap: atp starts a remote receiver over
ssh, then streams over the chosen transport).

```
--transport auto|tcp|rq|quic   Transport (default tcp; rq = RaptorQ/UDP; auto = quic→rq→tcp)
--rq-auth-key-hex HEX          Per-symbol auth key (or ATP_RQ_AUTH_KEY_HEX)
--rq-allow-unauthenticated-lab Lab tier: explicitly disable symbol auth
--ca PATH --server-name NAME   QUIC: verify the receiver's TLS certificate
--bwlimit BYTES_PER_SEC        Hard pacing cap
--max-bytes N                  Transfer size ceiling (default 4 GiB — raise for bigger)
--workers N                    Parallel workers (default 4)
--symbol-size N                RaptorQ symbol size (default 1200; ≤1144 with auth envelope on QUIC)
--repair-overhead X            Proactive repair factor (e.g. 1.1 = +10% repair symbols)
--rq-round0-loss-pct P         Size round-0 repair for an expected loss rate
--streams N                    UDP fan-out sockets for the symbol spray
--dry-run                      Print the transfer plan as JSON; send nothing
--no-delta                     Force whole-object transfer (skip delta re-sync)
```

### `atp recv <DEST>` / `atp serve <DEST>`

Receive into `DEST`. `recv --once` handles a single transfer and exits; `serve` is
the persistent daemon-style form of the same thing.

```
--listen ADDR:PORT             Bind address (default 0.0.0.0:8472)
--transport tcp|rq|quic        Must match the sender's data plane
--once                         Exit after one transfer (recv)
--server-cert PATH --server-key PATH   QUIC: TLS certificate + key to present
--rq-auth-key-hex HEX          Per-symbol auth key (must match sender)
--max-bytes N / --workers N / --symbol-size N   As on the sender
```

### `atp rq-keygen`

Print a fresh 32-byte symbol-authentication key as hex. Share it with both ends
(e.g. via your secrets manager) and pass it as `--rq-auth-key-hex` or
`ATP_RQ_AUTH_KEY_HEX`.

### Encrypted-tier example (QUIC + TLS 1.3 + symbol auth)

```bash
KEY=$(atp rq-keygen)

# Receiver: present a TLS certificate (any serverAuth-EKU leaf works — e.g. step-ca,
# mkcert, or your internal CA)
atp recv ./inbox --listen 0.0.0.0:8472 --transport quic --once \
  --symbol-size 1141 --rq-auth-key-hex "$KEY" \
  --server-cert cert.pem --server-key key.pem

# Sender: verify that certificate — fail-closed, no skip-verify option
atp send ./dataset receiver.example.com:8472 --transport quic \
  --symbol-size 1141 --rq-auth-key-hex "$KEY" \
  --ca ca.pem --server-name receiver.example.com
```

---

## Limitations

Honesty section — read before deploying:

- **Encrypted clean-large is rsync's turf today.** On pristine gigabit links moving
  huge single files, rsync-over-ssh beats atp's QUIC tier by ~1.5× (and ~2.5× on
  big trees). This is a known architectural frontier (userspace QUIC vs kernel TCP)
  with active work; the plaintext/authenticated tiers do not have this gap.
- **Sender memory on lossy links.** The fountain encoder's forward-repair state can
  peak at ~10× rsync's RSS on 2–10% loss cells. Receiver memory stays bounded
  (≤ 18 MB). If your sender is memory-starved *and* your link is lossy, budget for it.
- **Linux is the primary platform.** The benchmark matrix and production hardening
  are Linux (epoll/io_uring). macOS builds and runs (kqueue) but has not been through
  the same benchmark gauntlet. No Windows support.
- **Not an rsync drop-in.** No `--exclude` filters, no `--delete`, no permissions-
  preserving mirror mode semantics beyond what the manifest carries. atp moves data
  fast and verified; it is not (yet) a full mirroring toolchain.
- **Transfers above 4 GiB need `--max-bytes`** raised explicitly (a deliberate
  fail-closed default).
- **Delta re-sync currently pins the fallback chain to TCP** (delta + fountain
  spray composition is future work); use `--no-delta` when you want the rq/quic
  data plane for a re-sync.
- **Nightly Rust for source builds.** Prebuilt binaries don't care, but building
  from source uses the nightly toolchain pinned by the asupersync tree.

---

## Troubleshooting

### "direct rq transfers require symbol authentication"

The RaptorQ/UDP transport refuses to run unauthenticated unless you explicitly opt
into the lab tier. Either share a key (`atp rq-keygen` → `--rq-auth-key-hex` on both
ends) or — on a trusted lab link only — pass `--rq-allow-unauthenticated-lab` on
both ends.

### QUIC handshake fails with a certificate error

That's the point — the sender verifies the receiver's certificate chain, hostname,
and validity, and there is no `--insecure` bypass. Make sure `--ca` points at the CA
that signed the receiver's `--server-cert`, and `--server-name` matches a SAN in
that certificate.

### "object size exceeds limit" / transfer rejected at 4 GiB

Raise `--max-bytes` on **both** ends (e.g. `--max-bytes 6442450944` for a 6 GiB
ceiling). The default is a fail-closed guard, not a hard capability limit.

### QUIC + symbol auth rejects my `--symbol-size`

With the 56-byte authenticated envelope, symbols must fit a 1200-byte datagram:
use `--symbol-size 1144` or smaller (the benchmark suite uses 1141).

### Transfers are slow in a debug build

Always use release binaries. Debug-profile RaptorQ decode is orders of magnitude
slower at large block counts; the released artifacts and
`scripts/build-atp.sh` are release builds.

### `Address already in use` right after a previous run

The previous socket is in TIME_WAIT. Wait a few seconds or bind a different
`--listen` port.

---

## FAQ

### What does "atp" stand for?

Asupersync Transfer Protocol. It began as the file-transfer subsystem of the
[asupersync](https://github.com/Dicklesworthstone/asupersync) async runtime and
earned a standalone CLI.

### Why is it faster than rsync? Really?

On lossy/latent links: fountain coding converts loss from a round-trip problem into
a bandwidth problem, and a purpose-built congestion controller (delivery-rate
sampling + gain cycling) keeps the pipe full without collapsing it. On clean links:
a paced reliable stream at line rate, 1-RTT setup, and packed small-file trees. The
[benchmark section](#benchmarks-atp-vs-rsync) links the full evidence ledger — every
number is a SHA-verified median against optimally-flagged rsync, and the cells rsync
still wins are listed right next to the ones it doesn't.

### When should I still use rsync?

Encrypted transfers of huge single files over pristine fast links (atp's honest
losing cell today); workflows that need rsync's filter/delete/mirror semantics; or
anywhere you can't run an atp binary on both ends.

### Is my data verified even on the lab tier?

Yes. SHA-256 verification and fail-closed commit are structural and apply on every
tier. The tiers change who can *tamper in transit undetected on the wire* (lab: an
active MITM could; auth: symbols are HMAC'd; encrypted: everything is TLS 1.3 AEAD
+ certificate-verified), not whether corruption is detected before commit.

### Does it work over the public internet?

Yes — any UDP-reachable `host:port`, or the `user@host:/path` SSH bootstrap which
needs only ssh access to start the remote end. NAT-traversal machinery (STUN,
rendezvous, relays) exists in the underlying stack but isn't wired into the CLI yet;
today you need a reachable address or ssh.

### Why does the sender use more memory than rsync on lossy links?

That memory *is* the product: outstanding fountain-repair state that lets atp
converge (and win) at 10% loss where single-stream TCP grinds. Receiver memory is
bounded at ~18 MB regardless of file size.

### Where do I file bugs?

https://github.com/Dicklesworthstone/atp/issues (CLI/distribution issues) or the
[asupersync issue tracker](https://github.com/Dicklesworthstone/asupersync/issues)
for protocol/engine internals. Bug reports are genuinely welcome.

---

## Relationship to asupersync

This repository is the **product/distribution home** for the `atp` CLI: README,
installer, release automation, and a pin (`UPSTREAM_REV`) of the exact
[asupersync](https://github.com/Dicklesworthstone/asupersync) commit each release is
built from. The canonical source — `src/bin/atp.rs`, `src/atp/`, `src/net/atp/`,
`src/raptorq/`, the benchmark harness, and the evidence ledger — lives in asupersync
and is developed there. Release binaries here contain *only* the `atp` tool, built
with `cargo build --release --locked --bin atp --features atp-cli`.

atp inherits asupersync's engineering discipline: structured concurrency (every
transfer task is owned by a region that closes to quiescence), cancel-correctness
(an interrupted transfer drains cleanly and never exposes unverified output), and
deterministic lab testing (the congestion-controller changes above were gated by a
deterministic network lab before ever touching a wire).

---

## Contributing

> *About Contributions:* Please don't take this the wrong way, but I do not accept outside contributions for any of my projects. I simply don't have the mental bandwidth to review anything, and it's my name on the thing, so I'm responsible for any problems it causes; thus, the risk-reward is highly asymmetric from my perspective. I'd also have to worry about other "stakeholders," which seems unwise for tools I mostly make for myself for free. Feel free to submit issues, and even PRs if you want to illustrate a proposed fix, but know I won't merge them directly. Instead, I'll have Claude or Codex review submissions via `gh` and independently decide whether and how to address them. Bug reports in particular are welcome. Sorry if this offends, but I want to avoid wasted time and hurt feelings. I understand this isn't in sync with the prevailing open-source ethos that seeks community contributions, but it's the only way I can move at this velocity and keep my sanity.

---

## License

MIT License (with OpenAI/Anthropic Rider). See [`LICENSE`](./LICENSE).
