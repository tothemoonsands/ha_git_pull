# Home Assistant App: Git pull

## Installation

Follow these steps to get the app (formerly known as add-on) installed on your system:

1. In Home Assistant, go to **Settings** > **Apps** > **Install app**.
2. Find the "Git pull" app and click it.
3. Click on the "INSTALL" button.

## WARNING

The risk of complete loss is possible. Prior to starting this app, ensure a copy
of your Home Assistant configuration files exists in the Github repository. Otherwise, 
your local machine configuration folder will be overwritten with an empty configuration 
folder and you will need to restore from a backup.

## How to use

In the configuration section, set the repository field to your repository's
clone URL and check if any other fields need to be customized to work with
your repository. Next,

1. Start the app.
2. Check the app log output to see the result.

If the log doesn't end with an error, the app has successfully
accessed your git repository. Examples of logs you might see if
there were no errors are: `[Info] Nothing has changed.`,
`[Info] Something has changed, checking Home-Assistant config...`,
or `[Info] Local configuration has changed. Restart required.`.

If you made it this far, you might want to let the app automatically
check for updates by setting the `active` field (a subfield of `repeat`)
to `true` and turning on "Start on boot."

## Configuration

App configuration:

```yaml
git_branch: master
git_command: pull
git_remote: origin
git_prune: 'false'
repository: https://example.com/my_configs.git
auto_restart: false
restart_ignore:
  - ui-lovelace.yaml
  - ".gitignore"
  - exampledirectory/
repeat:
  active: false
  interval: 300
deployment_user: ''
deployment_password: ''
deployment_key:
  - "-----BEGIN RSA PRIVATE KEY-----"
  - MIIEowIBAAKCAQEAv3hUrCvqGZKpXQ5ofxTOuH6pYSOZDsCqPqmaGBdUzBFgauQM
  - xDEcoODGHIsWd7t9meAFqUtKXndeiKjfP0MMKsttnDohL1kb9mRvHre4VUqMsT5F
  - "..."
  - i3RUtnIHxGi1NqknIY56Hwa3id2yk7cEzvQGAAko/t6PCbe20AfmSQczs7wDNtBD
  - HgXRyIqIXHYk2+5w+N2eunURIBqCI9uWYK/r81TMR6V84R+XhtvM
  - "-----END RSA PRIVATE KEY-----"
deployment_key_protocol: rsa
debug: false
```

### Option: `git_remote` (required)

Name of the tracked repository. Leave this as `origin` if you are unsure.

### Option: `git_prune` (required)

`true`/`false`: If set to true, the app will clean-up branches that are deleted on the remote repository, but still have cached entries on the local machine. Leave this as `false` if you are unsure.

### Option: `git_branch` (required)

Branch name of the Git repo. If left empty, the currently checked out branch will be updated. Leave this as 'master' if you are unsure.

### Option: `git_command` (required)

`pull`/`reset`: Command to run. Leave this as `pull` if you are unsure.

- `pull`
  
  - Incorporates changes from a remote repository into the current branch. Will preserve any local changes to tracked files.

- `reset`
  
  - Will execute `git reset --hard` and overwrite any local changes to tracked files and update from the remote repository. **Warning**: Using `reset` WILL overwrite changes to tracked files. You can list all tracked files with this command: `git ls-tree -r master --name-only`.

### Option: `repository` (required)

Git URL to your repository (make sure to use double quotes).

### Option: `auto_restart` (required)

`true`/`false`: Restart Home Assistant when the configuration has changed (and is valid).

### Option: `restart_ignore` (optional)

When `auto_restart` is enabled, changes to these files will not make HA restart. Full directories to ignore can be specified.

### Option group: `repeat`

The following options are for the option group: `repeat` and configure the Git pull app to poll the repository for updates periodically automatically.

#### Option: `repeat.active` (required)

`true`/`false`: Enable/disable automatic polling.

#### Option: `repeat.interval` (required)

The interval in seconds to poll the repo for if automatic polling is enabled.

### Option: `deployment_user` (optional)

Username to use when authenticating to a repository with a username and password.

### Option: `deployment_password` (optional)

Password to use when authenticating to a repository.  Ignored if `deployment_user` is not set.

### Option: `deployment_key` (optional)

A private SSH key that will be used for communication during Git operations. This key is mandatory for ssh-accessed repositories, which are the ones with the following pattern: `<user>@<host>:<repository path>`. This key has to be created without a passphrase.

Supported formats:

1. List of lines (recommended and historically supported):

```yaml
deployment_key:
  - "-----BEGIN OPENSSH PRIVATE KEY-----"
  - b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAA...
  - "-----END OPENSSH PRIVATE KEY-----"
```

2. Block scalar string (now supported and normalized safely):

```yaml
deployment_key: |-
  -----BEGIN OPENSSH PRIVATE KEY-----
  b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAA...
  -----END OPENSSH PRIVATE KEY-----
```

The app validates the normalized key with `ssh-keygen` before writing it, and fails with an actionable error if the key is malformed.

### Option: `deployment_key_protocol` (optional)

The key protocol. Default is `rsa`. Valid protocols are:

- dsa
- ecdsa
- ed25519
- rsa

The protocol is typically known by the suffix of the private key --e.g., a key file named `id_rsa` will be a private key using `rsa` protocol.

### Option: `debug` (optional)

`true`/`false`: Enable extra diagnostics with secrets redacted. Includes:

- detected repo protocol/host/path
- key storage location and validation status
- known_hosts host-entry status
- `git remote -v` values with credentials redacted

## SSH persistence and host verification

SSH state is persisted under `/data/ssh`:

- `/data/ssh/id_<deployment_key_protocol>`
- `/data/ssh/known_hosts`

At startup, the app ensures `/root/.ssh` exists and links runtime files to the persistent data. For SSH repositories, host keys are loaded into `/data/ssh/known_hosts` using `ssh-keyscan` (with GitHub key types preselected for `github.com`).

Host checking is explicit and safe by default:

- `StrictHostKeyChecking yes`
- non-interactive/batch mode enabled
- no interactive trust prompt required

## HTTPS authentication (without token in URL)

For HTTPS repositories, set:

- `deployment_user`
- `deployment_password` (use your PAT here for GitHub)

The app uses `GIT_ASKPASS` so credentials are supplied non-interactively without embedding secrets in the repository URL.

Recommended:

```yaml
repository: "https://github.com/<org>/<repo>.git"
deployment_user: "x-access-token"
deployment_password: "<github_pat>"
```

Not recommended:

```yaml
repository: "https://x-access-token:<github_pat>@github.com/<org>/<repo>.git"
```

## Origin/remote matching behavior

Remote comparison now normalizes common equivalent forms:

- SSH vs HTTPS host/path equivalence
- with/without `.git`
- case normalization

If a non-equivalent mismatch is detected, the app logs both current and desired values (redacted where needed), attempts to update the configured remote URL, and continues safely if successful.

## Troubleshooting

### `Load key "/root/.ssh/id_ed25519": error in libcrypto`

- Cause: malformed private key content (often from folded YAML coercion).
- Fix:
1. Paste the key as list-of-lines or a `|-` block scalar.
2. Ensure BEGIN/END markers are intact.
3. Avoid passphrase-protected keys.
4. Enable `debug: true` and confirm `SSH key validates: true`.

### `Host key verification failed`

- Cause: missing host entry in `known_hosts`.
- Fix:
1. Use SSH repo URL and restart app so host key is scanned into `/data/ssh/known_hosts`.
2. Verify `debug` log shows `known_hosts entry for host: present`.
3. If your network blocks `ssh-keyscan`, add host keys manually to `/data/ssh/known_hosts`.

### `Permission denied (publickey)`

- Cause: wrong key, wrong protocol, or missing repo access.
- Fix:
1. Set `deployment_key_protocol` to match your key type (for example `ed25519`).
2. Verify deploy key/public key is attached to the repository.
3. Confirm repository URL host/path matches the key's target repo.

### Origin mismatch warnings

- Cause: local remote URL and configured `repository` differ in a meaningful way.
- Behavior:
1. App logs current and desired remotes (with credentials redacted).
2. App attempts `git remote set-url <remote> <repository>`.
3. If update fails, app exits with a clear error.

## Support

Got questions?

You have several options to get them answered:

- The [Home Assistant Discord Chat Server][discord].
- The Home Assistant [Community Forum][forum].
- Join the [Reddit subreddit][reddit] in [/r/homeassistant][reddit]

In case you've found a bug, please [open an issue on our GitHub][issue].

[discord]: https://discord.gg/c5DvZ4e
[forum]: https://community.home-assistant.io
[issue]: https://github.com/home-assistant/addons/issues
[reddit]: https://reddit.com/r/homeassistant
[repository]: https://github.com/hassio-addons/repository
