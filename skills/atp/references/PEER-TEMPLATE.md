# Peer profile template

Copy to `~/.config/atp/peers/<host>.md` after the first verified transfer to
a new machine. Reuse the saved command verbatim next time — no rediscovery.

```markdown
# Peer profile: <host> (<user>@<ip>)

Last verified: <date> — <size/what>, <transport>, committed, sha_ok,
<N> feedback rounds, <wall time>. Both ends atp <version>.

## Known-good send (quic — DEFAULT for this peer)

    atp send SRC <user>@<host>:DEST \
      --data-host <ip> --transport quic \
      --ca ~/.config/atp/<host>-ca.pem --server-name <san-name>

Why each non-default flag:
- --data-host <ip>: "<host>" is an ssh-config alias only; atp uses the
  target host for BOTH ssh and the direct data connection, so the data
  plane needs the resolvable IP.
- --ca / --server-name: receiver's cert lives at <remote path>, CA trust
  anchor copied locally to ~/.config/atp/<host>-ca.pem; SAN = <names>;
  expires <date>.

## Fallback (rq, if QUIC/UDP 443-style blocking appears)

    KEY=$(atp rq-keygen)   # share via <secrets channel>
    atp send SRC <user>@<host>:DEST --data-host <ip> --transport rq \
      --rq-auth-key-hex "$KEY"

## Quirks

- <firewall notes, sidecar port+1 status, --max-bytes needs, MTU, etc.>
```
