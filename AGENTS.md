# AGENTS.md — atp (standalone distribution repo)

> Guidelines for AI coding agents working in this repository.

---

## What This Repo Is (and Is Not)

This is the **standalone product/distribution repo** for the `atp` CLI — the
fountain-coded file-transfer tool. It contains **no Rust source code** and it
never should. It holds:

| File | Purpose |
|------|---------|
| `README.md` | The product documentation for `atp` |
| `install.sh` | Prebuilt-binary installer (curl-one-liner entry point) |
| `UPSTREAM_REV` | The exact asupersync commit releases are built from |
| `scripts/build-atp.sh` | Local/pinned build helper |
| `.github/workflows/release.yml` | Cross-platform release builds + GitHub release |
| `upstream` (symlink, gitignored) | Local convenience link to the asupersync checkout |

**The canonical ATP source lives in
[`Dicklesworthstone/asupersync`](https://github.com/Dicklesworthstone/asupersync)**
(locally: `/data/projects/asupersync`, symlinked here as `./upstream`):

- CLI binary: `src/bin/atp.rs` (feature `atp-cli`)
- Control/application layer: `src/atp/` (manifest, delta, verify, proof, daemon)
- Wire/transport layer: `src/net/atp/` (`transport_tcp`, `transport_rq`, `transport_quic`)
- RaptorQ codec: `src/raptorq/` (RFC 6330)
- Benchmarks vs rsync: `scripts/atp_bench/`, spec `docs/atp_bench_matrix_spec.md`,
  append-only evidence ledger `docs/atp_rq_beat_rsync_ledger.md`

**Never copy ATP source files into this repo.** If the code needs changing, do
the work in asupersync (its own `AGENTS.md` governs that work), land it on
asupersync `main`, then bump `UPSTREAM_REV` here.

---

## Ground Rules (inherited from the asupersync project)

1. **NO FILE DELETION** without express permission from the user.
2. **No destructive git/filesystem commands** (`git reset --hard`, `git clean -fd`,
   `rm -rf`, force-pushes) without the user supplying the exact command and
   explicit consent in the same message.
3. **`main` is the only branch.** No feature branches, no worktrees, no PRs from
   agents. Commit directly to `main`.
4. **No script-based bulk edits** of files in this repo; make changes manually.
5. Keep this repo tiny. The bar for adding new files is high.

---

## Release Process — dsr ONLY (GitHub Actions is DISABLED)

**USER DIRECTIVE (2026-07-10): GitHub Actions must not be used for ANYTHING in
this repo.** Both workflows are `disabled_manually` via `gh workflow disable`;
the YAML files remain in-tree as reference build recipes only. Never re-enable
them. Releases are built and published with
[dsr](https://github.com/Dicklesworthstone/doodlestein_self_releaser) from the
config in `~/.config/dsr/repos.d/atp.yaml`, which builds from the `UPSTREAM_REV`
pin via `scripts/build-atp.sh --pinned` (never from the shared asupersync
working tree).

```bash
# 0. One-time sanity
dsr doctor && dsr health all && dsr repos validate

# 1. Pick the asupersync commit to ship (must be pushed to origin/main there)
git -C upstream fetch origin main
git -C upstream rev-parse origin/main        # -> the new pin

# 2. Update the pin
echo "<sha>" > UPSTREAM_REV
git add UPSTREAM_REV && git commit -m "chore: bump upstream pin to <sha-short>"
git push

# 3. Tag and push (version = the `atp --version` the pinned rev reports,
#    i.e. asupersync's Cargo.toml package version). Pushing the tag triggers
#    nothing (Actions disabled) — it just pins the release commit.
git tag vX.Y.Z && git push origin vX.Y.Z

# 4. Build all targets (linux/amd64 locally, darwin/arm64 on mmini) and publish
dsr build atp -V vX.Y.Z --parallel
dsr release atp vX.Y.Z
dsr release verify atp vX.Y.Z
```

Notes:

- dsr builds run `scripts/build-atp.sh --pinned`, i.e.
  `cargo build --release --locked --bin atp --features atp-cli`
  (plus `--target <triple>` per matrix leg) under the nightly toolchain pinned
  by asupersync's `rust-toolchain.toml`.
- `--features atp-cli` is the full-featured binary — it already includes `tls`,
  which the encrypted QUIC/TLS-1.3 tier requires. Do not add feature flags
  without checking asupersync's `Cargo.toml`.
- Matrix legs run with `fail-fast: false` so every platform reports its result,
  but publication is fail-closed: all six declared tarballs must exist before a
  release is created. A partial matrix is never promoted as `latest`.
- Release inputs are immutable contracts: `UPSTREAM_REV` is a lowercase 40-hex
  commit on upstream `main`, the release tag resolves to one exact atp-repo
  commit, existing releases are not overwritten, and published assets receive
  GitHub build-provenance attestations.
- Keep tag versions in lockstep with the `atp --version` output of the pinned
  rev; if they drift, say so in the release notes.

## Testing the Installer

```bash
bash -n install.sh                       # syntax
shellcheck -S warning install.sh         # lint
bash scripts/test-install.sh             # deterministic installer contracts
bash scripts/test-build-atp.sh           # deterministic pinned-build contracts
bash install.sh --no-gum --dest /tmp/atp-test-bin --verify   # real install
bash install.sh --quiet --dest /tmp/atp-test-bin --force     # quiet path
```

The installer must keep working when piped from curl (no reliance on
`BASH_SOURCE` being a file, except as an optional fast path).

## Docs Discipline

- Performance claims in `README.md` must trace back to the asupersync bench
  ledger (`docs/atp_rq_beat_rsync_ledger.md`) — matrix-cell medians vs *tuned*
  rsync only, SHA-verified, rate-capped links. Never invent or extrapolate
  numbers; quote the ledger's cells and keep the honest losses visible.
- When `UPSTREAM_REV` moves far enough that CLI flags or benchmark results
  change, re-verify the README examples against `atp --help` from a fresh build.
