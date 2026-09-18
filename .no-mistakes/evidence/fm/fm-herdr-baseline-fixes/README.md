# Live validation evidence - fm/fm-herdr-baseline-fixes

Host: macOS, Herdr **0.9.0** (protocol 22) running live. CI pins Herdr **0.7.4**
(`.github/workflows/ci.yml:278`), so two pre-existing assertions in the Herdr lane
fail on this host on the **base commit too** - both depend on the 0.7.4
`workspace.move` wire protocol that 0.9.0 no longer answers. They are recorded here
as pre-existing, not as regressions.

| File | What it shows |
|---|---|
| `serial-shard-balance.txt` | Base vs target serial-shard partitions scored with the same current-truth measurements. |
| `focus-flash-partC-target.log` | Part C (the changed assertion) driven live on the real Herdr lab: passes, including the new sampler-liveness guard. |
| `focus-flash-partC-sampler-liveness-adversarial.log` | Dead sampler injected: target fails loudly, base silently claims a pass with zero observations. |
| `focus-flash-partC-flaky-witness-arm.log` | Defective-release arm forced: base fails on the sampler race (the flake), target passes while still asserting exact restoration. |
| `presentation-lock-62s-hold-base-vs-target.txt` | Real `fm spawn` against a 62 s peer hold on the session presentation lock: base refuses and falls back flat, target waits and projects. |
| `presentation-e2e-target.log` / `presentation-e2e-base.log` | Full real-Herdr presentation e2e on both commits; identical pre-existing failure point. |
| `focus-flash-e2e-target.log` / `focus-flash-e2e-base.log` | Unmodified focus-flash e2e on both commits; identical pre-existing Part B failure point. |
| `fm-test-run-unit.log` | `tests/fm-test-run.test.sh` - shard cover, balance, and hint-ordering contracts. |
