# Provenance — where this skill's claims come from

Evidence-first: every operational rule above traces to one of these anchors.
When source and skill disagree, source wins; file a bead.

## Primary sources (trust order)

1. asupersync source at the commit pinned in this repo's `UPSTREAM_REV`
   (CLI: `src/bin/atp.rs`; transports: `src/net/atp/transport_{tcp,rq,quic}`).
2. `atp --help` / `--version` from the exact binary in use.
3. asupersync Beads (`br show <id> --json`) for feature/limitation status.
4. This repo's `README.md` (narrative; can lag source).

## Anchors for specific claims

| Claim | Anchor |
|-------|--------|
| Symbol-size auto-default (1400 rq / 1144 quic), explicit-only ssh forwarding, ignored-key notice on quic | asupersync `64ebd17d3`, bead `asupersync-iz269u`, `QUIC_DEFAULT_SYMBOL_SIZE` honesty test in `transport_quic/mod.rs` |
| 1144 = 1200-byte datagram − 56-byte authenticated envelope | `QuicConfig::validate` in `transport_quic/mod.rs` |
| `auto` ladder restricted to tcp while delta planning is enabled | bead `asupersync-dg8juf` (open); README Limitations |
| Fail-closed QUIC cert verification, no skip-verify | `quic_cli_client_config` / handshake driver; README Troubleshooting |
| 4 GiB `--max-bytes` fail-closed default | `DEFAULT_MAX_TRANSFER_BYTES`, README |
| Delta sidecar on listen-port+1 with warn+full-object fallback | README ports note; `src/bin/atp.rs` delta planner |
| FastCDC chunker (shift-add gear, top-15-bit mask); mixed-version chunking degrades gracefully | asupersync `64ebd17d3` (chunker fix rationale in commit message + bead `asupersync-iz269u` comments) |
| Benchmark integrity standard + scoreboard numbers | `docs/atp_bench_matrix_spec.md`, `docs/atp_rq_beat_rsync_ledger.md` (append-only, MATRIX-1…232+), README Benchmarks |
| Encrypted clean-large losing cell (~1.5×/~2.5×) | ledger MATRIX-232 era entries; README Limitations |
| Sender RSS ~10× on 2–10% loss; receiver ≤ 18 MB | ledger lossy-cell RSS columns; README Limitations |
| Bounded feedback rounds, `NeedMore` trace fields | `ATP_RQ_TRACE` output paths in `transport_quic`/`transport_rq` |
| Release-build requirement | README Troubleshooting; bench spec ("release atp build required") |

## Skill authorship

Distilled 2026-07-10 by SapphireHill from: three working sessions inside the
asupersync ATP codebase (MATRIX-222…232 performance campaign, ejgdqe red-test
forensics, iz269u footgun-automation release), the evidence ledger, and the
v0.3.7 release. Method: operationalizing-expertise Track C (session mining) —
rules stated as trigger → action → why, each anchored above.
