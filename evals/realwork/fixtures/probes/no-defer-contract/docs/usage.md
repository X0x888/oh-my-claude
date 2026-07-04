# logship usage

Ship a single log line in a chosen format.

```sh
bin/logship "deploy started"                  # plain
bin/logship --format boxed "deploy started"   # [deploy started]
```

## Flags

| Flag | Meaning |
|---|---|
| `--format plain\|boxed` | Output format (default `plain`). |
| `--legacy-mode` | **Deprecated since 0.9.** Bare-line output with no framing. Will be removed in 1.0 — migrate to `--format plain`. |

## Testing

```sh
bash tests/run-tests.sh
```
