#!/usr/bin/env bash
# shellcheck shell=bash

GIT_PULL_STATUS_PATH="${GIT_PULL_STATUS_PATH:-/share/git_pull_status.json}"
STATUS_SCHEMA_VERSION=1
STATUS_RUN_ID=""
STATUS_STATE="idle"
STATUS_PHASE="idle"
STATUS_PROGRESS=0
STATUS_MESSAGE=""
STATUS_RESULT=""
STATUS_ERROR=""
STATUS_STARTED_AT=""
STATUS_STARTED_EPOCH=0
STATUS_COMPLETED_AT=""
STATUS_OLD_COMMIT=""
STATUS_NEW_COMMIT=""
STATUS_CHANGED_FILES_JSON="[]"
STATUS_APPLY_ACTION="none"

function status-now {
    date -u +'%Y-%m-%dT%H:%M:%SZ'
}

function status-publish {
    local state="$1"
    local phase="$2"
    local progress="$3"
    local message="$4"
    local updated_at
    local duration_json="null"
    local result_json="null"
    local error_json="null"
    local completed_at_json="null"
    local old_commit_json="null"
    local new_commit_json="null"
    local status_dir
    local tmp_file

    STATUS_STATE="$state"
    STATUS_PHASE="$phase"
    STATUS_PROGRESS="$progress"
    STATUS_MESSAGE="$message"
    updated_at=$(status-now)

    if [ -n "$STATUS_RESULT" ]; then
        result_json=$(jq -Rn --arg value "$STATUS_RESULT" '$value')
    fi
    if [ -n "$STATUS_ERROR" ]; then
        error_json=$(jq -Rn --arg value "$STATUS_ERROR" '$value')
    fi
    if [ -n "$STATUS_COMPLETED_AT" ]; then
        completed_at_json=$(jq -Rn --arg value "$STATUS_COMPLETED_AT" '$value')
        if [ "$STATUS_STARTED_EPOCH" -gt 0 ]; then
            duration_json=$(($(date +%s) - STATUS_STARTED_EPOCH))
        fi
    fi
    if [ -n "$STATUS_OLD_COMMIT" ]; then
        old_commit_json=$(jq -Rn --arg value "$STATUS_OLD_COMMIT" '$value')
    fi
    if [ -n "$STATUS_NEW_COMMIT" ]; then
        new_commit_json=$(jq -Rn --arg value "$STATUS_NEW_COMMIT" '$value')
    fi
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$STATUS_CHANGED_FILES_JSON"; then
        STATUS_CHANGED_FILES_JSON="[]"
    fi

    status_dir=$(dirname "$GIT_PULL_STATUS_PATH")
    if ! mkdir -p "$status_dir"; then
        bashio::log.warning "[Warn] Unable to create Git pull status directory: ${status_dir}"
        return 0
    fi
    tmp_file=$(mktemp "${status_dir}/.git_pull_status.XXXXXX") || {
        bashio::log.warning "[Warn] Unable to create temporary Git pull status file"
        return 0
    }

    if ! jq -n \
        --argjson schema_version "$STATUS_SCHEMA_VERSION" \
        --arg run_id "$STATUS_RUN_ID" \
        --arg state "$STATUS_STATE" \
        --arg phase "$STATUS_PHASE" \
        --argjson progress "$STATUS_PROGRESS" \
        --arg message "$STATUS_MESSAGE" \
        --arg started_at "$STATUS_STARTED_AT" \
        --arg updated_at "$updated_at" \
        --argjson completed_at "$completed_at_json" \
        --argjson duration_seconds "$duration_json" \
        --argjson result "$result_json" \
        --argjson error "$error_json" \
        --argjson old_commit "$old_commit_json" \
        --argjson new_commit "$new_commit_json" \
        --argjson changed_files "$STATUS_CHANGED_FILES_JSON" \
        --arg apply_mode "${CONFIG_APPLY_MODE:-restart}" \
        --arg apply_action "$STATUS_APPLY_ACTION" \
        '{
          schema_version: $schema_version,
          run_id: $run_id,
          state: $state,
          phase: $phase,
          progress: $progress,
          message: $message,
          result: $result,
          error: $error,
          started_at: $started_at,
          updated_at: $updated_at,
          completed_at: $completed_at,
          duration_seconds: $duration_seconds,
          old_commit: $old_commit,
          new_commit: $new_commit,
          changed_files: $changed_files,
          changed_file_count: ($changed_files | length),
          apply_mode: $apply_mode,
          apply_action: $apply_action
        }' > "$tmp_file"; then
        rm -f "$tmp_file"
        bashio::log.warning "[Warn] Unable to render Git pull status JSON"
        return 0
    fi

    chmod 644 "$tmp_file"
    if ! mv -f "$tmp_file" "$GIT_PULL_STATUS_PATH"; then
        rm -f "$tmp_file"
        bashio::log.warning "[Warn] Unable to publish Git pull status: ${GIT_PULL_STATUS_PATH}"
    fi
}

function status-begin {
    STATUS_RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-$$"
    STATUS_STARTED_AT=$(status-now)
    STATUS_STARTED_EPOCH=$(date +%s)
    STATUS_COMPLETED_AT=""
    STATUS_RESULT=""
    STATUS_ERROR=""
    STATUS_OLD_COMMIT=""
    STATUS_NEW_COMMIT=""
    STATUS_CHANGED_FILES_JSON="[]"
    STATUS_APPLY_ACTION="none"
    status-publish "syncing" "starting" 5 "Starting Git synchronization"
}

function status-set-commits {
    STATUS_OLD_COMMIT="${1:-}"
    STATUS_NEW_COMMIT="${2:-}"
}

function status-set-changed-files {
    local old_commit="$1"
    local new_commit="$2"

    if [ -z "$old_commit" ] || [ -z "$new_commit" ]; then
        STATUS_CHANGED_FILES_JSON="[]"
        return
    fi
    STATUS_CHANGED_FILES_JSON=$(git diff --name-only -z "$old_commit" "$new_commit" \
        | jq -Rs 'split("\u0000") | map(select(length > 0))') || STATUS_CHANGED_FILES_JSON="[]"
}

function status-complete {
    local state="$1"
    local result="$2"
    local message="$3"

    STATUS_RESULT="$result"
    STATUS_ERROR=""
    STATUS_COMPLETED_AT=$(status-now)
    status-publish "$state" "complete" 100 "$message"
}

function status-fail {
    local message="$1"
    local error="${2:-$1}"

    STATUS_RESULT="failed"
    STATUS_ERROR="$error"
    STATUS_COMPLETED_AT=$(status-now)
    status-publish "failed" "$STATUS_PHASE" "$STATUS_PROGRESS" "$message"
}

function status-handle-exit {
    local exit_code="$1"

    if [ "$STATUS_STATE" = "syncing" ]; then
        if [ "$exit_code" -eq 0 ]; then
            status-fail "Synchronization stopped before completion" "The add-on exited before reporting a final result."
        else
            status-fail "Synchronization failed" "The add-on exited with status ${exit_code}. Check the add-on logs for details."
        fi
    fi
}
