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

## Git reconciliation regression tests

From the repository root:

```bash
python3 -m unittest discover -s git_pull/tests -v
bash -n git_pull/data/run.sh git_pull/data/git-reconcile.sh
```

Requires Python 3 with PyYAML, Bash and Git (the add-on image installs these).
For a local environment, install PyYAML in a virtualenv and activate it before
running the commands so the helper's `python3` uses the same environment.
These tests source the production recovery helper
and use temporary bare remotes and checkouts. Integration cases run the real
polling loop with Home Assistant calls stubbed out. They never connect to Home Assistant
or GitHub and do not need credentials. Coverage includes matching direct edits,
partial deployments with additional incoming files, unpublished edits that later
match a push, staged changes, divergence, existing stashes, recovery-ref failures,
concurrent edits, untracked/ignored collisions, and filenames with special characters.
Automation cases cover editor formatting and supported syntax aliases, exact
snapshot retention, real value changes, scalar types, duplicate keys, unsupported
tags/aliases, nested action changes, file modes, symlinks and rollback.
