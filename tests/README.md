# Essential test portfolio

This repository intentionally keeps a small confidence-per-cost portfolio.
The seven Bash suites cover the highest-consequence behavior:

- `test-common-utilities.sh` — shared classification, state, scoring, and gate helpers.
- `test-install-artifacts.sh` — isolated end-to-end installation and managed artifacts.
- `test-intent-classification.sh` — user-intent and verification-command routing.
- `test-quality-gates.sh` — verification/review gate decisions.
- `test-session-resume.sh` — interrupted-session recovery and handoff.
- `test-state-io.sh` — atomic state storage and hostile-value handling.
- `test-uninstall-merge.sh` — merge-safe removal without damaging user settings.

Static Bash, Python syntax, ShellCheck, JSON-schema, and configuration
coordination checks live directly in CI rather than being wrapped by more tests.

Run the portfolio with:

```bash
bash tools/run-tests.sh
```

## Maintenance rule

Extend an existing suite when behavior changes. Add a new test file only when
the behavior is critical, no retained suite is a coherent owner, and the new
suite keeps the portfolio's under-ten-minute CI target credible. Historical tests
removed during the 2026 portfolio reset remain recoverable from Git history.
