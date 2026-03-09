# Public Release Guide

This repo can be published with a cleaner history that keeps only meaningful add-on changes.

## Goal

Build a linear branch from the original plugin baseline, then cherry-pick only the important improvements from this fork.

## Included commit set

The cleanup script keeps this sequence:

1. `ddd8758` Harden auth and remote handling
2. `3892cc3` Add local key-format reproduction harness
3. `540dcd1` Document SSH/auth troubleshooting
4. `2049015` Add configurable quick reload vs restart apply mode
5. `273a030` SSH bug fix
6. `611a23f` Auth issue fix
7. `c2e8bb9` Add-on config URL fix
8. `481e8a9` HA add-on discovery fix
9. `a5f37b6` Options schema default fix
10. `a7c6bde` Config update
11. `9ff649c` Supervisor schema parsing fix for `deployment_key`

Noisy merge commits and cosmetic branding-removal churn are intentionally excluded.

## One-command branch generation

From repo root:

```bash
./scripts/create_public_history_branch.sh
```

Optional custom branch name:

```bash
./scripts/create_public_history_branch.sh codex/public-release
```

## Validate before publishing

```bash
git log --oneline --decorate --graph -n 30
```

Then test the add-on in Home Assistant using both:

- SSH auth (`deployment_key`)
- HTTPS auth (`deployment_user` + `deployment_password`)
- `config_apply_mode: restart`
- `config_apply_mode: quick_reload`

## Publish safely

Recommended: push this clean branch to a new public repo so current private history stays untouched.

```bash
git remote add public <new-public-repo-url>
git push -u public codex/public-history:master
```

If you decide to reuse the existing repo, treat that as a history rewrite and force-push with care.
