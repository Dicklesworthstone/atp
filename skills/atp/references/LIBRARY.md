# atp as a Rust library

ATP is not a separate crate: it is the file-transfer subsystem of
[`asupersync`](https://crates.io/crates/asupersync). Embedding it gives a
Rust project built-in fountain-coded, SHA-verified transfer capability.

```toml
[dependencies]
# Precise form — pin the exact commit this repo's UPSTREAM_REV names:
asupersync = { git = "https://github.com/Dicklesworthstone/asupersync", rev = "<UPSTREAM_REV>", features = ["quic", "tls"] }
# crates.io may lag the git head; check the published version before using
# `version = "…"`. rq/tcp tiers need no extra features; quic needs quic+tls.
# (Library consumers pick features; the atp BINARY always has QUIC/TLS —
# its required atp-cli feature bundles them.)
```

Toolchain: asupersync's default features require the **nightly** toolchain
pinned by its `rust-toolchain.toml` (an audited stable lane exists with
default-features off; see its AGENTS.md).

## The one thing to internalize first

asupersync is its **own async runtime** (no tokio anywhere in the crate).
Every ATP entry point takes `&Cx` (the capability context) as its first
argument — you cannot call these from a tokio executor. Either your project
already runs on asupersync, or you bridge at the edge:

```rust
use asupersync::cx::Cx;
// inside an asupersync runtime task you already have a Cx;
// from sync code, drive a transfer to completion on the asupersync runtime
// and hand the resulting report back to the rest of your app.
```

## API surface (module map)

| Module | What you get |
|--------|---------------|
| `asupersync::net::atp::transport_tcp` | `send_path` / `send_path_filtered`, `receive_once` / `receive_connection` / `serve`, `TransferConfig`, `SendReport`/`ReceiveReport` — default reliable tier, delta-capable |
| `asupersync::net::atp::transport_rq` | RaptorQ-over-UDP tier: `send_path`, `receive_once` / `receive_connection`, `RqConfig` (symbol size, repair overhead, round-0 loss target, auth key) |
| `asupersync::net::atp::transport_quic` | encrypted tier (features `quic`,`tls`): `QuicConfig`, `send_path`, `receive_path` / `receive_once` / `serve`, `native_link::receive_on_endpoint`, `QuicClientTls`/`QuicServerTls`, `QUIC_DEFAULT_SYMBOL_SIZE` |
| `asupersync::net::atp::transport_common` | shared pieces: `plan_transfer`, `FilterSet`, `TransferProgress`, manifest/delta types |

Start from `artifacts/api_surface_map_v1.json` in the asupersync repo for
the blessed public entry points; the CLI (`src/bin/atp.rs`) is the canonical
worked example of wiring configs → transfers → reports.

## Semantics you inherit (same as the CLI)

- Fail-closed everywhere: configs `validate()` before any I/O; receivers
  stage → SHA-256/Merkle-verify → commit; a failed transfer writes nothing.
- Reports are data, not logs: check `receipt.committed` / `sha_ok` exactly
  as the CLI section describes.
- Security posture is explicit in the config (`with_symbol_auth`,
  `use_transport_authenticated_symbols`, lab opt-in) — there is no ambient
  default credential and no skip-verify TLS path.
- Cancellation is a protocol (asupersync invariant): dropping/cancelling a
  transfer region drains cleanly; no partial files leak into DEST.

## Bonding — multi-donor fountain (pull one object from N machines at once)

`asupersync::net::atp::bonding`: every donor holding a byte-identical copy
sprays a **residue-disjoint slice of the same RaptorQ fountain** (`esi` module
partitions ESIs per donor), so any-K-symbols-from-any-mix reconstructs each
block, loss on one donor is repaired by another, and aggregate goodput scales
with donor count. The invariant everything rests on: donors and receiver
prove agreement on the exact object (`BondTransferDescriptor` + merkle
holding-proofs) so an `(sbn, esi)` pair means the same bytes everywhere.

Key surface today: `descriptor` (shared transfer descriptor + donor proofs),
`esi` (partition/disjointness), `assignment` (`DonorAssignment`, spray/repair
window scheduling, per-symbol auth verdicts, `MAX_BONDING_DONORS`),
`handshake` (versioned capability negotiation, `BondingReceiverControlPlane`),
`receiver` (`BondedReceiverSymbolSet`, bounded `BondedReceiverRetentionPolicy`,
per-donor ingress stats, feedback plans, `ATP_BOND_TRACE`).

**Status honesty**: the type system, scheduling, handshake, and bounded
receiver are real and tested; the end-to-end data path and the CLI surface
(`atp bond-recv` / `bond-donate` / `bond-pull` orchestrator) are in active
development upstream (epic z01bbr, phases C/F). Do not claim or invent CLI
bonding flags — check `atp --help` for `bond-` subcommands; when they exist,
this section and the boundary card need updating.

## Choosing CLI vs library

Embed the library when transfers are part of your product's data plane
(replication, artifact distribution, ingest). Shell out to the `atp` binary
when transfers are operational plumbing — you get process isolation, the
JSON report contract, and version pinning via install.sh for free, and the
skill's CLI guidance applies unchanged.
