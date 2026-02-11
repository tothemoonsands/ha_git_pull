#!/usr/bin/with-contenv bashio
# vim: ft=bash
# shellcheck shell=bash

# shellcheck disable=SC2034
CONFIG_PATH=/data/options.json
HOME=~

DEPLOYMENT_KEY_PROTOCOL=$(bashio::config 'deployment_key_protocol')
DEPLOYMENT_USER=$(bashio::config 'deployment_user')
DEPLOYMENT_PASSWORD=$(bashio::config 'deployment_password')
GIT_BRANCH=$(bashio::config 'git_branch')
GIT_COMMAND=$(bashio::config 'git_command')
GIT_REMOTE=$(bashio::config 'git_remote')
GIT_PRUNE=$(bashio::config 'git_prune')
REPOSITORY=$(bashio::config 'repository')
AUTO_RESTART=$(bashio::config 'auto_restart')
RESTART_IGNORED_FILES=$(bashio::config 'restart_ignore | join(" ")')
REPEAT_ACTIVE=$(bashio::config 'repeat.active')
REPEAT_INTERVAL=$(bashio::config 'repeat.interval')
DEBUG_MODE=$(bashio::config 'debug')
CONFIG_APPLY_MODE=$(bashio::config 'config_apply_mode')

SSH_PERSIST_DIR="/data/ssh"
SSH_RUNTIME_DIR="${HOME}/.ssh"
SSH_KEY_PATH="${SSH_PERSIST_DIR}/id_${DEPLOYMENT_KEY_PROTOCOL}"
SSH_KNOWN_HOSTS_PATH="${SSH_PERSIST_DIR}/known_hosts"
ASKPASS_SCRIPT="/tmp/git-askpass.sh"

REPO_PROTOCOL=""
REPO_HOST=""
REPO_PATH=""

function trim {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

function lower {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

function redact-secrets {
    local input="$1"
    printf '%s' "$input" \
        | sed -E 's#(https?://)[^/@:]+:[^@/]+@#\1***:***@#g; s#(https?://)[^/@]+@#\1***@#g'
}

function log-debug {
    if [ "$DEBUG_MODE" = "true" ]; then
        bashio::log.info "[Debug] $1"
    fi
}

function parse-repository-url {
    local url
    local rest
    local host_path
    local at_part
    local host_part
    local path_part

    url=$(trim "$1")
    REPO_PROTOCOL=""
    REPO_HOST=""
    REPO_PATH=""

    if [[ "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://(.+)$ ]]; then
        REPO_PROTOCOL=$(lower "${BASH_REMATCH[1]}")
        rest="${BASH_REMATCH[2]}"
        rest="${rest#*@}"
        host_path="${rest%%\?*}"
        REPO_HOST="${host_path%%/*}"
        REPO_PATH="${host_path#*/}"
    elif [[ "$url" =~ ^([^@]+@)?([^:]+):(.+)$ ]]; then
        REPO_PROTOCOL="ssh"
        at_part="${BASH_REMATCH[1]}"
        host_part="${BASH_REMATCH[2]}"
        path_part="${BASH_REMATCH[3]}"
        REPO_HOST="${host_part}"
        REPO_PATH="${path_part}"
        if [ -n "$at_part" ]; then
            REPO_HOST="${host_part}"
        fi
    fi

    REPO_HOST=$(lower "${REPO_HOST}")
    REPO_PATH="${REPO_PATH#/}"
    REPO_PATH="${REPO_PATH%.git}"
    REPO_PATH="${REPO_PATH%/}"
}

function normalize-repository-url {
    local url="$1"
    parse-repository-url "$url"

    if [ -n "$REPO_HOST" ] && [ -n "$REPO_PATH" ]; then
        printf '%s/%s' "$REPO_HOST" "$(lower "$REPO_PATH")"
        return
    fi

    printf '%s' "$(lower "$(trim "$url")")"
}

function ensure-ssh-layout {
    mkdir -p "$SSH_PERSIST_DIR" "$SSH_RUNTIME_DIR"
    chmod 700 "$SSH_PERSIST_DIR" "$SSH_RUNTIME_DIR"

    touch "$SSH_KNOWN_HOSTS_PATH"
    chmod 600 "$SSH_KNOWN_HOSTS_PATH"
    ln -sf "$SSH_KNOWN_HOSTS_PATH" "${SSH_RUNTIME_DIR}/known_hosts"

    (
        echo "Host *"
        echo "    BatchMode yes"
        echo "    StrictHostKeyChecking yes"
        echo "    UserKnownHostsFile ${SSH_KNOWN_HOSTS_PATH}"
    ) > "${SSH_RUNTIME_DIR}/config"
    chmod 600 "${SSH_RUNTIME_DIR}/config"
}

function get-deployment-key-raw {
    local key_type
    local key_length
    local key_value

    key_type=$(bashio::config 'deployment_key | type')

    case "$key_type" in
        array)
            key_length=$(bashio::config 'deployment_key | length')
            if [ "$key_length" -eq 0 ]; then
                return
            fi
            key_value=$(bashio::config 'deployment_key | join("\n")')
            printf '%s' "$key_value"
            ;;
        string)
            key_value=$(bashio::config 'deployment_key')
            key_value=$(trim "$key_value")
            if [ -n "$key_value" ]; then
                printf '%s' "$key_value"
            fi
            ;;
        *)
            ;;
    esac
}

function normalize-deployment-key {
    local raw="$1"
    local cleaned
    local begin_marker
    local end_marker
    local body
    local compact_body
    local wrapped_body

    raw=$(trim "$raw")
    if [ -z "$raw" ]; then
        return 1
    fi

    cleaned=$(printf '%s' "$raw" | tr -d '\r')
    cleaned=$(printf '%s' "$cleaned" \
        | sed -E 's/(-----BEGIN [A-Z0-9 ]+ PRIVATE KEY-----)/\n\1\n/g; s/(-----END [A-Z0-9 ]+ PRIVATE KEY-----)/\n\1\n/g')

    begin_marker=$(printf '%s\n' "$cleaned" | grep -m1 -E '^-----BEGIN [A-Z0-9 ]+ PRIVATE KEY-----$')
    end_marker=$(printf '%s\n' "$cleaned" | grep -m1 -E '^-----END [A-Z0-9 ]+ PRIVATE KEY-----$')

    if [ -z "$begin_marker" ] || [ -z "$end_marker" ]; then
        return 1
    fi

    body=$(printf '%s\n' "$cleaned" \
        | awk '
            /^-----BEGIN [A-Z0-9 ]+ PRIVATE KEY-----$/ { in_body=1; next }
            /^-----END [A-Z0-9 ]+ PRIVATE KEY-----$/ { in_body=0; next }
            in_body { print }
        ')

    compact_body=$(printf '%s' "$body" | tr -d ' \t\n')
    if [ -z "$compact_body" ]; then
        return 1
    fi

    if ! printf '%s' "$compact_body" | grep -Eq '^[A-Za-z0-9+/=]+$'; then
        return 1
    fi

    wrapped_body=$(printf '%s' "$compact_body" | fold -w 70)
    printf '%s\n%s\n%s\n' "$begin_marker" "$wrapped_body" "$end_marker"
}

function ensure-known-host-entry {
    local host="$1"
    local scan_types="ed25519"
    local tmp_file

    if [ -z "$host" ]; then
        return
    fi

    if ssh-keygen -F "$host" -f "$SSH_KNOWN_HOSTS_PATH" >/dev/null 2>&1; then
        log-debug "known_hosts already has entry for ${host}"
        return
    fi

    if [ "$host" = "github.com" ]; then
        scan_types="ed25519,rsa,ecdsa"
    fi

    bashio::log.info "[Info] Fetching SSH host key for ${host}"
    if ! ssh-keyscan -T 15 -t "$scan_types" "$host" >> "$SSH_KNOWN_HOSTS_PATH" 2>/dev/null; then
        bashio::exit.nok "[Error] Unable to fetch SSH host key for ${host}. Add it manually to ${SSH_KNOWN_HOSTS_PATH} and retry."
    fi

    tmp_file=$(mktemp)
    sort -u "$SSH_KNOWN_HOSTS_PATH" > "$tmp_file"
    mv "$tmp_file" "$SSH_KNOWN_HOSTS_PATH"
    chmod 600 "$SSH_KNOWN_HOSTS_PATH"
}

function setup-ssh-auth {
    local raw_key
    local normalized_key
    local tmp_key

    parse-repository-url "$REPOSITORY"
    if [ "$REPO_PROTOCOL" != "ssh" ]; then
        unset GIT_SSH_COMMAND
        return
    fi

    ensure-ssh-layout

    raw_key=$(get-deployment-key-raw)
    if [ -z "$raw_key" ]; then
        bashio::exit.nok "[Error] SSH repository detected but deployment_key is empty. Configure deployment_key as a list of lines or a block string."
    fi

    normalized_key=$(normalize-deployment-key "$raw_key") || {
        bashio::exit.nok "[Error] deployment_key format is invalid. Use BEGIN/END private key markers and preserve the key body as list lines or block scalar text."
    }

    tmp_key=$(mktemp)
    printf '%s' "$normalized_key" > "$tmp_key"
    chmod 600 "$tmp_key"

    if ! ssh-keygen -y -f "$tmp_key" >/dev/null 2>&1; then
        rm -f "$tmp_key"
        bashio::exit.nok "[Error] deployment_key failed validation (ssh-keygen). Ensure Home Assistant did not fold or alter key formatting."
    fi

    mv "$tmp_key" "$SSH_KEY_PATH"
    chmod 600 "$SSH_KEY_PATH"
    ln -sf "$SSH_KEY_PATH" "${SSH_RUNTIME_DIR}/id_${DEPLOYMENT_KEY_PROTOCOL}"

    ensure-known-host-entry "$REPO_HOST"

    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${SSH_KNOWN_HOSTS_PATH} -o IdentitiesOnly=yes -i ${SSH_KEY_PATH}"
}

function setup-https-auth {
    if [ -f "$ASKPASS_SCRIPT" ]; then
        rm -f "$ASKPASS_SCRIPT"
    fi
    unset GIT_ASKPASS GIT_TERMINAL_PROMPT GIT_ASKPASS_USERNAME GIT_ASKPASS_PASSWORD

    parse-repository-url "$REPOSITORY"
    if [ "$REPO_PROTOCOL" != "https" ] && [ "$REPO_PROTOCOL" != "http" ]; then
        return
    fi

    if [ -z "$DEPLOYMENT_USER" ] || [ -z "$DEPLOYMENT_PASSWORD" ]; then
        bashio::log.info "[Info] HTTPS repository detected without deployment_user/deployment_password; using git default credential flow."
        return
    fi

    cat > "$ASKPASS_SCRIPT" << 'EOF'
#!/usr/bin/env sh
case "$1" in
  *sername*) printf '%s\n' "$GIT_ASKPASS_USERNAME" ;;
  *assword*) printf '%s\n' "$GIT_ASKPASS_PASSWORD" ;;
  *) printf '\n' ;;
esac
EOF
    chmod 700 "$ASKPASS_SCRIPT"

    export GIT_ASKPASS="$ASKPASS_SCRIPT"
    export GIT_TERMINAL_PROMPT=0
    export GIT_ASKPASS_USERNAME="$DEPLOYMENT_USER"
    export GIT_ASKPASS_PASSWORD="$DEPLOYMENT_PASSWORD"
}

function log-debug-state {
    local remote_lines
    local line
    local key_valid="false"
    local host_status="missing"

    if [ "$DEBUG_MODE" != "true" ]; then
        return
    fi

    parse-repository-url "$REPOSITORY"
    log-debug "Repository protocol: ${REPO_PROTOCOL:-unknown}"
    log-debug "Repository host: ${REPO_HOST:-unknown}"
    log-debug "Repository path: ${REPO_PATH:-unknown}"
    log-debug "SSH key path: ${SSH_KEY_PATH}"

    if [ -f "$SSH_KEY_PATH" ] && ssh-keygen -y -f "$SSH_KEY_PATH" >/dev/null 2>&1; then
        key_valid="true"
    fi
    log-debug "SSH key validates: ${key_valid}"

    if [ -n "$REPO_HOST" ] && [ -f "$SSH_KNOWN_HOSTS_PATH" ] \
        && ssh-keygen -F "$REPO_HOST" -f "$SSH_KNOWN_HOSTS_PATH" >/dev/null 2>&1; then
        host_status="present"
    fi
    log-debug "known_hosts entry for host: ${host_status}"

    if git rev-parse --is-inside-work-tree &>/dev/null; then
        remote_lines=$(git remote -v 2>/dev/null || true)
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            log-debug "git remote: $(redact-secrets "$line")"
        done <<< "$remote_lines"
    fi
}

function git-clone {
    local backup_location

    backup_location="/tmp/config-$(date +%Y-%m-%d_%H-%M-%S)"
    bashio::log.info "[Info] Backup configuration to ${backup_location}"

    mkdir "$backup_location" || bashio::exit.nok "[Error] Creation of backup directory failed"
    cp -rf /config/* "$backup_location" || bashio::exit.nok "[Error] Copy files to backup directory failed"

    rm -rf /config/{,.[!.],..?}* || bashio::exit.nok "[Error] Clearing /config failed"

    bashio::log.info "[Info] Start git clone"
    git clone "$REPOSITORY" /config || bashio::exit.nok "[Error] Git clone failed for $(redact-secrets "$REPOSITORY")"

    cp "${backup_location}" "!(*.yaml)" /config 2>/dev/null
    cp "${backup_location}/secrets.yaml" /config 2>/dev/null
}

function git-synchronize {
    local current_git_remote_url
    local current_normalized
    local desired_normalized

    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        bashio::log.warning "[Warn] Git repository doesn't exist"
        git-clone
        return
    fi

    bashio::log.info "[Info] Local git repository exists"

    current_git_remote_url=$(git remote get-url --all "$GIT_REMOTE" | head -n 1)
    if [ -z "$current_git_remote_url" ]; then
        bashio::exit.nok "[Error] Unable to read git remote ${GIT_REMOTE}"
    fi

    current_normalized=$(normalize-repository-url "$current_git_remote_url")
    desired_normalized=$(normalize-repository-url "$REPOSITORY")

    if [ "$current_normalized" != "$desired_normalized" ]; then
        bashio::log.warning "[Warn] git remote mismatch detected"
        bashio::log.warning "[Warn] current: $(redact-secrets "$current_git_remote_url")"
        bashio::log.warning "[Warn] desired: $(redact-secrets "$REPOSITORY")"
        bashio::log.info "[Info] Attempting to update remote ${GIT_REMOTE} to desired repository"
        git remote set-url "$GIT_REMOTE" "$REPOSITORY" \
            || bashio::exit.nok "[Error] Failed to update remote ${GIT_REMOTE}. Please verify repository settings."
    else
        bashio::log.info "[Info] Git origin is correctly set to $(redact-secrets "$REPOSITORY")"
    fi

    OLD_COMMIT=$(git rev-parse HEAD)

    bashio::log.info "[Info] Start git fetch..."
    if [ -z "$GIT_BRANCH" ]; then
        git fetch "$GIT_REMOTE" || bashio::exit.nok "[Error] Git fetch failed"
    else
        git fetch "$GIT_REMOTE" "$GIT_BRANCH" || bashio::exit.nok "[Error] Git fetch failed"
    fi

    if [ "$GIT_PRUNE" == "true" ]; then
        bashio::log.info "[Info] Start git prune..."
        git prune || bashio::exit.nok "[Error] Git prune failed"
    fi

    GIT_CURRENT_BRANCH=$(git rev-parse --symbolic-full-name --abbrev-ref HEAD)
    if [ -z "$GIT_BRANCH" ] || [ "$GIT_BRANCH" == "$GIT_CURRENT_BRANCH" ]; then
        bashio::log.info "[Info] Staying on currently checked out branch: $GIT_CURRENT_BRANCH..."
    else
        bashio::log.info "[Info] Switching branches - start git checkout of branch $GIT_BRANCH..."
        git checkout "$GIT_BRANCH" || bashio::exit.nok "[Error] Git checkout failed"
        GIT_CURRENT_BRANCH=$(git rev-parse --symbolic-full-name --abbrev-ref HEAD)
    fi

    case "$GIT_COMMAND" in
        pull)
            bashio::log.info "[Info] Start git pull..."
            git pull || bashio::exit.nok "[Error] Git pull failed"
            ;;
        reset)
            bashio::log.info "[Info] Start git reset..."
            git reset --hard "$GIT_REMOTE"/"$GIT_CURRENT_BRANCH" || bashio::exit.nok "[Error] Git reset failed"
            ;;
        *)
            bashio::exit.nok "[Error] Git command is not set correctly. Should be either 'reset' or 'pull'"
            ;;
    esac
}

function apply-homeassistant-config {
    case "$CONFIG_APPLY_MODE" in
        quick_reload)
            bashio::log.info "[Info] Apply mode is quick_reload; triggering homeassistant.reload_all"
            if ! bashio::api.supervisor POST "/core/api/services/homeassistant/reload_all" >/dev/null 2>&1; then
                bashio::exit.nok "[Error] Quick reload failed (homeassistant.reload_all). Set config_apply_mode to restart to use a full restart."
            fi
            ;;
        restart|*)
            bashio::log.info "[Info] Apply mode is restart; restarting Home-Assistant"
            bashio::core.restart
            ;;
    esac
}

function validate-config {
    local changed_files
    local changed_file
    local restart_ignored_file
    local restart_required_file

    bashio::log.info "[Info] Checking if something has changed..."
    NEW_COMMIT=$(git rev-parse HEAD)
    if [ "$NEW_COMMIT" == "$OLD_COMMIT" ]; then
        bashio::log.info "[Info] Nothing has changed."
        return
    fi
    bashio::log.info "[Info] Something has changed, checking Home-Assistant config..."
    if ! bashio::core.check; then
        bashio::log.error "[Error] Configuration updated but it does not pass the config check. Do not restart until this is fixed!"
        return
    fi
    if [ "$AUTO_RESTART" != "true" ]; then
        bashio::log.info "[Info] Local configuration has changed. Restart required."
        return
    fi
    DO_RESTART="false"
    changed_files=$(git diff "$OLD_COMMIT" "$NEW_COMMIT" --name-only)
    bashio::log.info "Changed Files: $changed_files"
    if [ -n "$RESTART_IGNORED_FILES" ]; then
        for changed_file in $changed_files; do
            restart_required_file=""
            for restart_ignored_file in $RESTART_IGNORED_FILES; do
                bashio::log.info "[Info] Checking: $changed_file for $restart_ignored_file"
                if [ -d "$restart_ignored_file" ]; then
                    set +e
                    restart_required_file=$(echo "${changed_file}" | grep "^${restart_ignored_file}")
                    set -e
                else
                    set +e
                    restart_required_file=$(echo "${changed_file}" | grep "^${restart_ignored_file}$")
                    set -e
                fi
                if [ -n "$restart_required_file" ]; then
                    break
                fi
            done
            if [ -z "$restart_required_file" ]; then
                DO_RESTART="true"
                bashio::log.info "[Info] Detected restart-required file: $changed_file"
            else
                bashio::log.info "[Info] Detected ignored file: $changed_file"
            fi
        done
    else
        DO_RESTART="true"
    fi

    if [ "$DO_RESTART" == "true" ]; then
        apply-homeassistant-config
    else
        bashio::log.info "[Info] No Restart Required, only ignored changes detected"
    fi
}

cd /config || bashio::exit.nok "[Error] Failed to cd into /config"

while true; do
    setup-ssh-auth
    setup-https-auth
    log-debug-state
    if git-synchronize; then
        validate-config
    fi
    if [ "$REPEAT_ACTIVE" != "true" ]; then
        exit 0
    fi
    sleep "$REPEAT_INTERVAL"
done
