# atp Operations Playbooks

## Security tiers (choose explicitly, never downgraded silently)

| Tier | Wire | Integrity | Confidentiality | Setup cost |
|------|------|-----------|-----------------|------------|
| lab (`--rq-allow-unauthenticated-lab`) | rq/UDP | SHA-256 end-to-end (always) | none | zero — trusted links only, both ends must opt in |
| authenticated (`--rq-auth-key-hex`) | rq/UDP | SHA-256 + per-symbol HMAC | none | one `atp rq-keygen`, shared secret |
| encrypted (`--transport quic`) | QUIC | SHA-256 + TLS 1.3 AEAD | full | receiver cert/key; sender trusts via `--ca` or system roots |

SHA-256 verification of every file (and a Merkle-committed manifest for
trees) runs on ALL tiers — the tiers differ in wire authentication and
confidentiality, never in end-to-end integrity. Bytes are staged, verified,
then committed: a failed transfer never leaves partial garbage in DEST.

## Certificates for the QUIC tier

- Receiver presents any serverAuth-EKU leaf: internal CA, step-ca, mkcert all
  work. Sender verifies chain + hostname + validity, fail-closed; there is no
  `--insecure` and no way to add one from the CLI.
- `--server-name` defaults to the target host — set it only when dialing an
  IP or a CNAME that differs from the cert SAN.
- Publicly-trusted or OS-installed CA? Omit `--ca` entirely (system roots).

## ssh bootstrap mode (`atp send SRC user@host:/path`)

What it does: ssh to host, start `atp recv --once --listen <remote-listen>`
with a generated per-transfer auth key, wait for readiness, then transfer
directly over the chosen transport (NOT through the ssh tunnel). Tuning flags
are forwarded to the remote only when you set them explicitly — omitted flags
resolve to matching defaults on both sides. Needs `atp` on the remote PATH;
`--ssh-option` may be repeated for raw OpenSSH options.

## Delta re-sync

Content-defined chunking (FastCDC gear) + IBLT set reconciliation + sub-chunk
rolling diffs move only changed regions; reconstruction is hash-verified, so
a checksum collision cannot commit wrong bytes. Behavior notes:

- First transfer to an empty DEST is automatically full-object.
- The planner runs on listen-port+1; when unreachable the sender logs a
  warning and sends full-object (correctness unaffected).
- Mixed atp versions across the pair may chunk differently — matching
  degrades toward full-object; never wrong bytes.
- `--no-delta` skips planning entirely (and unlocks `auto`'s ladder).

## Tuning that actually matters

- `--repair-overhead 1.1` and/or `--rq-round0-loss-pct <expected-loss%>` on
  known-lossy links: sizes round-0 repair so most transfers finish without
  feedback rounds. Watch `feedback_rounds` in the report to calibrate.
- `--streams N` (rq): more UDP sockets for the spray; helps on high-BDP paths.
- `--bwlimit` (quic): hard cap; also forces the datagram-spray tier instead
  of the reliable stream — expect different pacing characteristics.
- Memory: sender forward-repair state peaks ~10× rsync RSS at 2–10% loss;
  receiver stays ≤ 18 MB. Budget sender memory on lossy links.

## Benchmarking honestly (the ledger method)

Never quote a number that violates these — the project treats a false win as
worse than a loss:

1. Opponent is rsync **optimally flagged** (`-aW --inplace --no-compress`;
   `-c aes128-gcm@openssh.com` over ssh) — never a strawman.
2. Crypto-symmetric: atp plaintext vs rsync daemon; atp QUIC/TLS vs
   rsync-over-ssh. Mixed tiers = invalid experiment.
3. SHA-verify every transfer; failures are excluded from medians, never
   scored as slow wins.
4. Rate-capped links only (netem, symmetric both ends); an uncapped netns is
   an unreal ∞-bandwidth cell that flatters rsync.
5. Medians of ≥3 reps with cv%; report the whole matrix including cells atp
   loses; release builds only.

Full spec + every result and refuted hypothesis: the asupersync repo's
`docs/atp_bench_matrix_spec.md` and `docs/atp_rq_beat_rsync_ledger.md`
(append-only, 230+ numbered experiments).

## Platform notes

Linux is the benchmarked, production-hardened platform (epoll/io_uring).
The seven-target release matrix beginning with v0.3.8 also includes macOS
(Apple Silicon and Intel) and native Windows x64 (MSVC). These supported
non-Linux targets have not been through the same benchmark gauntlet.

Prebuilt releases v0.3.8 and newer require Minisign on `PATH`. `install.sh` and
`install.ps1` verify the selected archive against `SHA256SUMS` and then
authenticate its `<archive>.minisig` with ATP's embedded release key before
extraction. Missing Minisign, missing signatures, checksum mismatches, and
invalid signatures all fail closed. On macOS, install the supported verifier
with `brew install minisign`; Windows requires `minisign.exe` on `PATH`.

The only normal-install exception is for a canonical online release version
strictly older than v0.3.8, especially the unsigned v0.3.7 release. When the
signature endpoint is confirmed absent, the installer may proceed only after
mandatory SHA-256 verification and must print `UNAUTHENTICATED LEGACY RELEASE`.
This is integrity-only compatibility, not publisher authentication. A published
legacy signature must still be verified; a bad signature, a missing verifier
when a signature exists, an unknown/malformed version, or an inconclusive
signature download fails closed.

Offline installs require the signature beside the archive under its exact
published name, for example `atp-x86_64-pc-windows-msvc.zip.minisig` or
`atp-aarch64-apple-darwin.tar.gz.minisig`, plus the explicit/published SHA-256
checksum. The legacy online exception never applies offline, regardless of the
requested version. `--no-verify` on the Unix installer is a testing-only escape
hatch, not a production installation mode. On Windows PowerShell 5.1, enable
TLS 1.2 before fetching the installer:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Dicklesworthstone/atp/main/install.ps1)))
```
