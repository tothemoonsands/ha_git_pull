#!/usr/bin/env bash
# shellcheck shell=bash

AUTOMATION_EQUIVALENCE_HELPER="$(dirname "${BASH_SOURCE[0]}")/automation-equivalent.py"

function tracked-changes-match {
    local target="$1" source="$2" path
    shift 2
    local -a revisions=("$target")
    if [ "$source" != "--worktree" ]; then
        revisions+=("$source")
    fi
    for path in "$@"; do
        if git diff --quiet --no-ext-diff --no-textconv "${revisions[@]}" -- "$path"; then
            continue
        fi
        if [ "$path" != ':(literal)automations.yaml' ] \
            || ! python3 "$AUTOMATION_EQUIVALENCE_HELPER" "$target" "$source"; then
            return 1
        fi
    done
}

# Keep recovery snapshots reachable even after ordinary stash reflogs expire.
function preserve-reconciliation-stash {
    local snapshot="$1"
    local recovery_ref="refs/git-pull/recovery/${snapshot}"
    git update-ref "$recovery_ref" "$snapshot" || return 1
    bashio::log.warning "[Warn] Recovery snapshot retained at ${recovery_ref}"
}

function restore-reconciliation-stash {
    local snapshot="$1"
    if git stash apply --index "$snapshot"; then
        bashio::log.warning "[Warn] Pull deferred; restored the saved local edits. Recovery snapshot retained."
    else
        bashio::log.error "[Error] Local edits could not be restored automatically. Do not reset or clean this checkout; recover from ${snapshot}."
    fi
    return 1
}

function git-pull-fetched {
    local target="$1"
    local reconcile="${2:-true}"
    local original_head marker path previous_stash snapshot untracked dirty
    local -a dirty_paths=()

    target=$(git rev-parse --verify "${target}^{commit}") || return 1
    original_head=$(git rev-parse HEAD) || return 1
    for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer index.lock; do
        if [ -e "$(git rev-parse --git-path "$marker")" ]; then
            bashio::log.error "[Error] Git operation or lock in progress (${marker}); leaving the checkout unchanged."
            return 1
        fi
    done
    if ! git symbolic-ref -q HEAD >/dev/null; then
        bashio::log.error "[Error] Detached HEAD; select a branch before pulling."
        return 1
    fi
    if ! git merge-base --is-ancestor "$original_head" "$target"; then
        bashio::log.error "[Error] Fetched branch cannot fast-forward this checkout; local commits are preserved."
        return 1
    fi

    # Merge the pinned fetch result: no second network fetch or implicit rebase/autostash.
    if git merge --ff-only --no-autostash --no-overwrite-ignore "$target"; then
        return 0
    fi
    if [ "$reconcile" != "true" ]; then
        bashio::log.error "[Error] Pull failed; automatic reconciliation is disabled."
        return 1
    fi
    if [ "$(git rev-parse HEAD)" != "$original_head" ] || ! git diff --cached --quiet; then
        bashio::log.error "[Error] Pull deferred; HEAD changed or staged changes need manual review."
        return 1
    fi

    # NUL-delimited literal paths also handle spaces, newlines and pathspec characters.
    while IFS= read -r -d '' path; do
        dirty_paths+=(":(literal)${path}")
    done < <(git diff --name-only --no-renames -z)
    if [ "${#dirty_paths[@]}" -eq 0 ]; then
        bashio::log.error "[Error] Pull failed without reconcilable tracked edits; check untracked files and Git errors above."
        return 1
    fi
    if ! tracked-changes-match "$target" --worktree "${dirty_paths[@]}"; then
        bashio::log.warning "[Warn] Local tracked edits differ from the fetched commit; preserving them and deferring the pull. Publish or resolve the local edits; unchanged polling cannot resolve this difference."
        return 1
    fi

    # Stash restores HEAD paths internally. Refuse if that would replace an
    # untracked file/directory (including ignored files) with a tracked path.
    while IFS= read -r -d '' untracked; do
        for path in "${dirty_paths[@]}"; do
            dirty="${path#:(literal)}"
            if [[ "$untracked" == "$dirty" || "$untracked" == "$dirty/"* \
                || "$dirty" == "$untracked/"* ]]; then
                bashio::log.warning "[Warn] An untracked or ignored path obstructs reconciliation; leaving files unchanged."
                return 1
            fi
        done
    done < <(git ls-files --others -z)

    bashio::log.warning "[Warn] Local tracked edits match the fetched commit (allowing equivalent automation YAML); saving them before retrying."
    previous_stash=$(git rev-parse -q --verify refs/stash || true)
    if ! git stash push -m "git-pull reconciliation before ${target}"; then
        snapshot=$(git rev-parse -q --verify refs/stash || true)
        if [ -n "$snapshot" ] && [ "$snapshot" != "$previous_stash" ]; then
            preserve-reconciliation-stash "$snapshot" || true
            restore-reconciliation-stash "$snapshot"
        fi
        bashio::log.error "[Error] Could not save local edits; reconciliation stopped."
        return 1
    fi
    snapshot=$(git rev-parse --verify refs/stash) || return 1
    if [ "$snapshot" = "$previous_stash" ]; then
        bashio::log.error "[Error] No new recovery snapshot was created; reconciliation stopped."
        return 1
    fi
    if ! preserve-reconciliation-stash "$snapshot"; then
        restore-reconciliation-stash "$snapshot"
        return 1
    fi

    # Recheck the actual saved snapshot, including any edits made during preflight.
    dirty_paths=()
    while IFS= read -r -d '' path; do
        dirty_paths+=(":(literal)${path}")
    done < <(git diff --name-only --no-renames -z "${snapshot}^1" "$snapshot")
    if [ "$(git rev-parse HEAD)" != "$original_head" ] \
        || [ "$(git rev-parse "${snapshot}^1")" != "$original_head" ] \
        || ! git diff --quiet "${snapshot}^1" "${snapshot}^2" \
        || ! tracked-changes-match "$target" "$snapshot" "${dirty_paths[@]}" \
        || ! git diff --quiet HEAD \
        || ! git diff --cached --quiet; then
        bashio::log.warning "[Warn] Checkout changed during reconciliation; cancelling the retry."
        restore-reconciliation-stash "$snapshot"
        return 1
    fi

    if git merge --ff-only --no-autostash --no-overwrite-ignore "$target"; then
        bashio::log.info "[Info] Reconciled matching direct edits and fast-forwarded to ${target}."
        return 0
    fi
    restore-reconciliation-stash "$snapshot"
    return 1
}
