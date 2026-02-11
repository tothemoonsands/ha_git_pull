# Reproduction Harness

Use this to reproduce the key-format issue and verify the normalization fix locally.

## Run

```bash
./scripts/repro.sh
```

Optional custom temp directory:

```bash
./scripts/repro.sh /tmp/git_pull_repro
```

## What it tests

1. `deployment_key` represented as list-of-lines (current behavior: valid)
2. `deployment_key` represented as folded scalar / single-line body (current behavior: invalid)
3. empty or missing key (invalid)

For each case it writes:

- `*.current`: legacy write behavior from upstream script
- `*.fixed`: normalized write behavior from this patch

Validation command:

```bash
ssh-keygen -y -f <key_file>
```

It also simulates runtime vs persistent `known_hosts` storage to show why `/data/ssh/known_hosts` survives container recreation.
