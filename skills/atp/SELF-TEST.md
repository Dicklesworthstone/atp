# atp skill — trigger & behavior self-test

## Should trigger

- "send this directory to the backup server with atp"
- "why did my atp transfer fail with a certificate error?"
- "atp says 'direct rq transfers require symbol authentication'"
- "is atp actually faster than rsync here?"
- "transfer 20 GB over a lossy WAN link"
- "read this atp JSON report — did it work?"

## Should NOT trigger

- generic rsync/scp questions with no atp mention
- ATP (adenosine triphosphate), ATP tennis
- asupersync runtime internals unrelated to file transfer (Cx, regions)

## Behavior checks (spot-test after edits)

1. Auth error on rq → agent must propose `rq-keygen`, NOT the lab flag.
2. Cert failure → agent must fix chain/SAN, never search for skip-verify.
3. >4 GiB transfer → agent raises `--max-bytes` on BOTH ends.
4. Success judgment → agent uses exit code / check-report.sh, not vibes from
   stderr, and treats `committed:false` as nothing-written.
5. Env sanity ask → agent runs `scripts/smoke.sh` before deeper debugging.
6. Old binary (`atp --version` < 0.3.7) → agent applies boundary card
   (manual `--symbol-size 1144` on QUIC) instead of current defaults.

## Validation

```bash
# any writing-skills validator install works; adjust the path to yours
validate-skill.py skills/atp/
bash -n skills/atp/scripts/smoke.sh && bash -n skills/atp/scripts/check-report.sh
skills/atp/scripts/smoke.sh          # real loopback transfer must pass
```
