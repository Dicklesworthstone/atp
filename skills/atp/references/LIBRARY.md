# atp as a Rust library

ATP is not a separate crate: it is the file-transfer subsystem of
[`asupersync`](https://crates.io/crates/asupersync). Embedding it gives a
Rust project built-in fountain-coded, SHA-verified transfer capability.

```toml
[dependencies]
asupersync = { version = "0.3.7", features = ["quic", "tls"] }  # rq/tcp need no extra features
```

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
| `asupersync::net::atp::transport_tcp` | `send_path` / `receive_on_endpoint`, `TransferConfig`, `SendReport`/`ReceiveReport` — the default reliable tier, delta-capable |
| `asupersync::net::atp::transport_rq` | RaptorQ-over-UDP tier: `RqConfig` (symbol size, repair overhead, round-0 loss target, auth key), same report shapes |
| `asupersync::net::atp::transport_quic` | encrypted tier (features `quic`,`tls`): `QuicConfig`, `send_path`, `receive_on_endpoint`/`serve_path`, `QuicClientTls`/`QuicServerTls`; `QUIC_DEFAULT_SYMBOL_SIZE` for datagram-fitting symbols |
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

## Choosing CLI vs library

Embed the library when transfers are part of your product's data plane
(replication, artifact distribution, ingest). Shell out to the `atp` binary
when transfers are operational plumbing — you get process isolation, the
JSON report contract, and version pinning via install.sh for free, and the
skill's CLI guidance applies unchanged.
