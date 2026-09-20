# Portable parallel shard job wall times, measured from the GitHub Actions API

Source: `GET repos/kunchenguid/firstmate/actions/runs/<id>/jobs`, fields `started_at`/`completed_at`.
These are the six runs cited in the `.github/workflows/ci.yml` shard-1 comment.

| Run | Job | Conclusion | started_at | completed_at | Wall time |
|---|---|---|---|---|---|
| 35521389413 | Behavior portable parallel 1 | success | 2026-09-20T18:22:27Z | 2026-09-20T18:32:10Z | **9m43s** |
| 35522119589 | Behavior portable parallel 1 | success | 2026-09-20T16:15:07Z | 2026-09-20T16:22:16Z | **7m09s** |
| 35525714064 | Behavior portable parallel 1 | success | 2026-09-20T17:23:34Z | 2026-09-20T17:33:32Z | **9m58s** |
| 35527851430 | Behavior portable parallel 1 | success | 2026-09-20T18:04:01Z | 2026-09-20T18:14:01Z | **10m00s** |
| 35530147547 | Behavior portable parallel 1 | success | 2026-09-20T18:46:37Z | 2026-09-20T18:53:51Z | **7m14s** |
| 35530818396 | Behavior portable parallel 1 | success | 2026-09-20T18:59:40Z | 2026-09-20T19:09:18Z | **9m38s** |
| 35521389413 | Behavior portable parallel 2 | success | 2026-09-20T18:18:46Z | 2026-09-20T18:26:52Z | **8m06s** |
| 35522119589 | Behavior portable parallel 2 | success | 2026-09-20T16:15:07Z | 2026-09-20T16:23:29Z | **8m22s** |
| 35525714064 | Behavior portable parallel 2 | success | 2026-09-20T17:23:33Z | 2026-09-20T17:31:43Z | **8m10s** |
| 35527851430 | Behavior portable parallel 2 | success | 2026-09-20T18:04:02Z | 2026-09-20T18:10:31Z | **6m29s** |
| 35530147547 | Behavior portable parallel 2 | success | 2026-09-20T18:46:37Z | 2026-09-20T18:54:50Z | **8m13s** |
| 35530818396 | Behavior portable parallel 2 | success | 2026-09-20T18:59:41Z | 2026-09-20T19:07:52Z | **8m11s** |

## Behavior portable parallel 1

- measured range: 7m09s .. 10m00s (slowest run 35527851430)
- against the OLD 10-minute cap: peak/cap = 1.00x  -> AT OR OVER THE CAP: a passing run would be killed with no verdict
- against the cap this change ships (15 minutes): peak/cap = 0.67x headroom margin 5m00s

## Behavior portable parallel 2

- measured range: 6m29s .. 8m22s (slowest run 35522119589)
- against the OLD 10-minute cap: peak/cap = 0.84x  -> under cap
- against the cap this change ships (10 minutes): peak/cap = 0.84x headroom margin 1m38s

## Scan of every non-green CI run on 2026-09-20 for a shard-1 kill

26 CI runs that day concluded `failure` or `cancelled`. Only two had a non-success
`Behavior portable parallel 1` job, and neither is a `timeout-minutes` kill:

| Run | Conclusion | Wall time | What the step record shows |
|---|---|---|---|
| 35531220948 | cancelled | 7m19s | cancelled well under cap; same-PR supersession by a newer head |
| 35527309684 | failure | 9m32s | step 7 failed, steps 8-17 still ran to success - an ordinary test failure, not a kill |

So the live record does not contain a shard-1 timeout kill. What it does contain is
run 35527851430: a **passing** shard-1 job at exactly **10m00s against a 10-minute
cap** - 1.00x, i.e. a hang tripwire sitting on the edge of ordinary green runs.
That is what the 15-minute cap moves away from, and it is the claim the shipped
`ci.yml` comment actually makes.
