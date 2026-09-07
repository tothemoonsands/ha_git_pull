# Home Assistant App: Git pull

Load and update configuration files for Home Assistant from a Git repository.

![Supports aarch64 Architecture][aarch64-shield] ![Supports amd64 Architecture][amd64-shield] ![Supports armhf Architecture][armhf-shield] ![Supports armv7 Architecture][armv7-shield] ![Supports i386 Architecture][i386-shield]

You can use this app (formerly known as add-on) to `git pull` updates to your Home Assistant configuration files from a Git
repository.

Recent authentication and reliability improvements include:

- resilient `deployment_key` parsing for list-of-lines and block-scalar input
- persistent SSH material in `/data/ssh` (key + `known_hosts`) across container recreation
- HTTPS auth via `deployment_user` + `deployment_password` (no token required in URL)
- remote URL normalization and auto-repair for benign origin mismatches
- optional `debug` mode with credential redaction
- safe reconciliation of matching direct deployments with retained recovery snapshots
- recovery from equivalent `automations.yaml` formatting and syntax rewrites by the automation editor
- continued polling when a pull is blocked by conflicting local edits
- configurable apply mode: full restart or Home Assistant quick reload (`homeassistant.reload_all`)

Local reproduction steps and Git recovery regression tests are in `REPRO.md`.

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
[armhf-shield]: https://img.shields.io/badge/armhf-yes-green.svg
[armv7-shield]: https://img.shields.io/badge/armv7-yes-green.svg
[i386-shield]: https://img.shields.io/badge/i386-yes-green.svg
