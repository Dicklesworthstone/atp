# atp CLI Reference (v0.3.7)

Subcommands: `send`, `recv`, `serve`, `rq-keygen`. All transfers print one
JSON report to stdout; diagnostics go to stderr (`[atp] …` lines).

## atp send SOURCE TARGET

`TARGET` is `host:port` (direct) or `user@host:/path` (ssh bootstrap — spawns
`atp recv --once` on the remote via ssh, generates a per-transfer auth key,
then streams directly; needs `atp` on the remote PATH).

| Flag | Semantics |
|------|-----------|
| `--transport auto\|tcp\|rq\|quic` | default `tcp`. `auto` ladder = quic→rq→tcp, but only with `--no-delta`; with delta enabled auto stays on tcp |
| `--rq-auth-key-hex HEX` / env `ATP_RQ_AUTH_KEY_HEX` | 32-byte hex key for per-symbol HMAC (rq tier). Ignored on quic (TLS AEAD covers it; ≥0.3.7 prints a notice) |
| `--rq-allow-unauthenticated-lab` | lab tier: explicitly disable symbol auth; required on BOTH ends |
| `--ca PATH` | PEM chain that must sign the receiver's cert (quic). Omit when the receiver's cert chains to a system trust root |
| `--server-name NAME` | must match a SAN in the receiver's cert; defaults to the target host |
| `--bwlimit BYTES_PER_SEC` | hard pacing cap (quic/auto). Side effect worth knowing: any bwlimit routes QUIC transfers onto the datagram-spray tier instead of the reliable source stream |
| `--max-bytes N` | transfer ceiling, default 4 GiB, fail-closed, must be raised on both ends |
| `--workers N` | local runtime worker threads (default 4) |
| `--symbol-size N` | optional since 0.3.7. Defaults per transport: 1400 (rq), 1144 (quic = 1200-byte datagram − 56-byte auth envelope). Explicit values win and fail closed if they cannot fit; forwarded to an ssh-bootstrapped remote only when explicit |
| `--max-block-size N\|auto\|0` | RaptorQ source-block size; `auto` normalizes per transport; must match sender/receiver when explicit |
| `--repair-overhead X` | proactive repair factor ≥ 1.0 (1.1 = +10% repair symbols) |
| `--rq-round0-loss-pct P` | size round-0 repair for an expected loss rate; also enables loss-matched pacing behavior |
| `--streams N` | UDP fan-out sockets for the rq symbol spray |
| `--data-host HOST` | ssh-bootstrap mode: override the host/IP the DATA plane dials after ssh setup. Required when the ssh target is a config alias (e.g. `Host trj`) that DNS cannot resolve — atp otherwise uses the same name for both ssh and the direct data connection |
| `--remote-listen ADDR:PORT` | ssh-bootstrap mode: where the spawned remote receiver binds (default `0.0.0.0:8472`) |
| `--dry-run` | print the transfer plan JSON (file list, sizes, Merkle root); no connection |
| `--no-delta` | force whole-object transfer; also the switch that lets `auto` climb past tcp |

## atp recv DEST / atp serve DEST

`recv --once` handles one transfer and exits; `serve` loops forever.

| Flag | Semantics |
|------|-----------|
| `--listen ADDR:PORT` | default `0.0.0.0:8472`. The delta-planning sidecar binds **PORT+1**; if blocked, sender warns and falls back to full-object |
| `--transport tcp\|rq\|quic` | must match the sender's data plane |
| `--server-cert PATH --server-key PATH` | required for quic (PEM chain + key; any serverAuth-EKU leaf works — step-ca, mkcert, internal CA) |
| `--rq-auth-key-hex HEX` | must match the sender's key |
| `--max-bytes / --workers / --symbol-size / --max-block-size / --repair-overhead` | as on the sender; explicit values must match. Defaults agree automatically |

## atp rq-keygen

Prints a fresh 32-byte hex key. Distribute via your secrets manager; pass as
`--rq-auth-key-hex` or `ATP_RQ_AUTH_KEY_HEX` on both ends.

## Per-transport resolution rules (0.3.7+)

- symbol size: explicit → used verbatim (fail-closed downstream if unfit);
  omitted → 1400 on rq/tcp paths, 1144 on quic. Each rung of `auto` resolves
  its own default, so omitted flags stay consistent across the ladder and
  across an ssh-bootstrapped pair.
- security posture is never silently downgraded: rq without a key and without
  the lab flag refuses to run; quic has no skip-verify option at all.

## Env vars

| Var | Effect |
|-----|--------|
| `ATP_RQ_AUTH_KEY_HEX` | same as `--rq-auth-key-hex` |
| `ATP_QUIC_TRACE` | per-frame QUIC diagnostics on stderr (verbose) |
| `ATP_RQ_TRACE` | RaptorQ sender/receiver round diagnostics on stderr |
