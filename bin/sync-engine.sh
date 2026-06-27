#!/usr/bin/env bash
# sync-engine.sh - Core sync orchestration engine
# Coordinates: manifest generation, three-way diff, conflict resolution,
# file transfers, deletion propagation, and state management

# ============================================================================
# SYNC COUNTERS
# ============================================================================

SYNC_PUSHED=0
SYNC_PULLED=0
SYNC_DELETED_LOCAL=0
SYNC_DELETED_REMOTE=0
SYNC_CONFLICTS=0
SYNC_SKIPPED=0
SYNC_ERRORS=0

reset_counters() {
    SYNC_PUSHED=0
    SYNC_PULLED=0
    SYNC_DELETED_LOCAL=0
    SYNC_DELETED_REMOTE=0
    SYNC_CONFLICTS=0
    SYNC_SKIPPED=0
    SYNC_ERRORS=0
}

# ============================================================================
# CONFLICT RESOLUTION
# ============================================================================

# Resolve a conflict based on configured strategy
# Returns: "push", "pull", "skip", or "error"
resolve_conflict() {
    local path="$1"
    local local_entry="$2"
    local remote_entry="$3"
    local strategy="${CONFLICT_STRATEGY:-newest}"

    log_warn "Conflict detected: $path"

    local local_mtime remote_mtime
    local_mtime=$(entry_mtime "$local_entry")
    remote_mtime=$(entry_mtime "$remote_entry")

    case "$strategy" in
        newest)
            if (( local_mtime >= remote_mtime )); then
                log_info "  Conflict resolution (newest): keeping local (mtime: $local_mtime >= $remote_mtime)"
                echo "push"
            else
                log_info "  Conflict resolution (newest): keeping remote (mtime: $remote_mtime > $local_mtime)"
                echo "pull"
            fi
            ;;

        local)
            log_info "  Conflict resolution (local-wins): keeping local"
            echo "push"
            ;;

        remote)
            log_info "  Conflict resolution (remote-wins): keeping remote"
            echo "pull"
            ;;

        skip)
            log_info "  Conflict resolution (skip): leaving both versions unchanged"
            echo "skip"
            ;;

        backup)
            # Backup both, then apply newest
            log_info "  Conflict resolution (backup): backing up both versions"
            if [[ "${DRY_RUN:-false}" != "true" ]]; then
                backup_local_file "$path"
                backup_remote_file "$path"
            fi
            if (( local_mtime >= remote_mtime )); then
                log_info "  Applying newest (local) after backup"
                echo "push"
            else
                log_info "  Applying newest (remote) after backup"
                echo "pull"
            fi
            ;;

        *)
            log_error "  Unknown conflict strategy: $strategy"
            echo "skip"
            ;;
    esac
}

# Verify conflict with checksums when CHECKSUM_VERIFY is enabled
# Returns 0 if files are actually different, 1 if identical
verify_conflict_with_checksum() {
    local path="$1"

    if [[ "${CHECKSUM_VERIFY:-false}" != "true" ]]; then
        return 0  # Assume different (skip verification)
    fi

    log_debug "Verifying conflict with checksums: $path"

    local local_checksum remote_checksum
    local_checksum=$(local_file_checksum "${LOCAL_DIR}/${path}")
    remote_checksum=$(remote_file_checksum "$REMOTE_USER" "$REMOTE_HOST" "${REMOTE_PORT:-22}" "${REMOTE_DIR}/${path}")

    if [[ -n "$local_checksum" ]] && [[ "$local_checksum" == "$remote_checksum" ]]; then
        log_info "  Checksum match - files are identical despite different metadata: $path"
        return 1  # Not actually different
    fi

    return 0  # Truly different
}

# ============================================================================
# ACTION EXECUTION
# ============================================================================

execute_push() {
    local path="$1"

    log_info "PUSH: $path"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "  [DRY-RUN] Would push: $path"
        (( SYNC_PUSHED++ ))
        return 0
    fi

    if [[ "${BACKUP_ON_CONFLICT:-false}" == "true" ]] && [[ "${_IS_CONFLICT:-0}" == "1" ]]; then
        backup_remote_file "$path"
    fi

    if rsync_push_file "${LOCAL_DIR}/${path}" "$path"; then
        (( SYNC_PUSHED++ ))
        log_debug "  Push successful: $path"
    else
        log_error "  Push failed: $path"
        (( SYNC_ERRORS++ ))
    fi
}

execute_pull() {
    local path="$1"

    log_info "PULL: $path"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "  [DRY-RUN] Would pull: $path"
        (( SYNC_PULLED++ ))
        return 0
    fi

    if [[ "${BACKUP_ON_CONFLICT:-false}" == "true" ]] && [[ "${_IS_CONFLICT:-0}" == "1" ]]; then
        backup_local_file "$path"
    fi

    if rsync_pull_file "$path" "${LOCAL_DIR}/${path}"; then
        (( SYNC_PULLED++ ))
        log_debug "  Pull successful: $path"
    else
        log_error "  Pull failed: $path"
        (( SYNC_ERRORS++ ))
    fi
}

execute_delete_local() {
    local path="$1"

    log_info "DELETE LOCAL: $path"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "  [DRY-RUN] Would delete local: $path"
        (( SYNC_DELETED_LOCAL++ ))
        return 0
    fi

    if [[ "${BACKUP_ON_CONFLICT:-true}" == "true" ]]; then
        backup_local_file "$path"
    fi

    local_delete_file "$path"
    (( SYNC_DELETED_LOCAL++ ))
    log_debug "  Local delete successful: $path"
}

execute_delete_remote() {
    local path="$1"

    log_info "DELETE REMOTE: $path"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "  [DRY-RUN] Would delete remote: $path"
        (( SYNC_DELETED_REMOTE++ ))
        return 0
    fi

    if [[ "${BACKUP_ON_CONFLICT:-true}" == "true" ]]; then
        backup_remote_file "$path"
    fi

    remote_delete_file "$path"
    (( SYNC_DELETED_REMOTE++ ))
    log_debug "  Remote delete successful: $path"
}

# ============================================================================
# MAIN SYNC ENGINE
# ============================================================================

# Run the full sync process
# Returns 0 on success, 1 on failure
run_sync() {
    local profile="${PROFILE_NAME:-default}"
    local start_time
    start_time=$(date +%s)

    reset_counters

    log_info "Starting bidirectional sync (profile: $profile)"
    log_info "Local:  $LOCAL_DIR"
    log_info "Remote: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "*** DRY RUN MODE - no changes will be made ***"
    fi

    # Step 1: Generate current manifests
    log_info "Scanning local files..."
    local local_manifest
    local_manifest=$(generate_local_manifest "$LOCAL_DIR")
    local local_count
    local_count=$(echo "$local_manifest" | grep -c '[^[:space:]]' || true)
    log_info "  Found $local_count local files"

    log_info "Scanning remote files..."
    local remote_manifest
    remote_manifest=$(generate_remote_manifest "$REMOTE_USER" "$REMOTE_HOST" "${REMOTE_PORT:-22}" "$REMOTE_DIR")
    local remote_count
    remote_count=$(echo "$remote_manifest" | grep -c '[^[:space:]]' || true)
    log_info "  Found $remote_count remote files"

    # Step 2: Load previous manifest
    local manifest_file
    manifest_file=$(manifest_path "$profile")
    local prev_manifest
    prev_manifest=$(load_manifest "$manifest_file")

    local is_first_sync=0
    if [[ -z "$prev_manifest" ]]; then
        is_first_sync=1
        log_info "First sync detected - will merge both sides"
    fi

    # Step 3: Compute three-way diff
    log_info "Computing differences..."
    local actions
    actions=$(three_way_diff "$prev_manifest" "$local_manifest" "$remote_manifest")

    # Count actions
    local push_count pull_count delete_local_count delete_remote_count conflict_count unchanged_count
    push_count=$(echo "$actions" | grep -c '^PUSH' || true)
    pull_count=$(echo "$actions" | grep -c '^PULL' || true)
    delete_local_count=$(echo "$actions" | grep -c '^DELETE_LOCAL' || true)
    delete_remote_count=$(echo "$actions" | grep -c '^DELETE_REMOTE' || true)
    conflict_count=$(echo "$actions" | grep -c '^CONFLICT' || true)
    unchanged_count=$(echo "$actions" | grep -c '^UNCHANGED' || true)

    log_info "  Push: $push_count | Pull: $pull_count | Del local: $delete_local_count | Del remote: $delete_remote_count | Conflicts: $conflict_count | Unchanged: $unchanged_count"

    # If nothing to do, save manifest and exit
    if (( push_count == 0 && pull_count == 0 && delete_local_count == 0 && delete_remote_count == 0 && conflict_count == 0 )); then
        log_info "Everything is in sync - nothing to do"

        # Still save manifest on first sync
        if (( is_first_sync )); then
            local merged
            merged=$(merge_manifests "$local_manifest" "$remote_manifest" "$actions")
            save_manifest "$merged" "$manifest_file"
        fi

        local end_time
        end_time=$(date +%s)
        print_summary 0 0 0 0 0 0 0 $(( end_time - start_time ))
        return 0
    fi

    # Step 4: Execute actions
    log_info "Executing sync actions..."

    # Process each action
    while IFS=$'\t' read -r action path; do
        [[ -z "$action" ]] && continue

        case "$action" in
            PUSH)
                execute_push "$path"
                ;;

            PULL)
                execute_pull "$path"
                ;;

            DELETE_LOCAL)
                execute_delete_local "$path"
                ;;

            DELETE_REMOTE)
                execute_delete_remote "$path"
                ;;

            CONFLICT)
                (( SYNC_CONFLICTS++ ))

                # Get entries for resolution
                declare -A _tmp_local=()
                declare -A _tmp_remote=()
                parse_manifest "$local_manifest" _tmp_local
                parse_manifest "$remote_manifest" _tmp_remote

                local local_entry="${_tmp_local[$path]:-}"
                local remote_entry="${_tmp_remote[$path]:-}"

                # Verify it's a real conflict (checksum check if enabled)
                if ! verify_conflict_with_checksum "$path"; then
                    log_info "  Conflict resolved: files are identical (checksum match)"
                    unset _tmp_local _tmp_remote
                    continue
                fi

                # Resolve conflict
                local resolution
                _IS_CONFLICT=1
                resolution=$(resolve_conflict "$path" "$local_entry" "$remote_entry")
                _IS_CONFLICT=0

                case "$resolution" in
                    push) execute_push "$path" ;;
                    pull) execute_pull "$path" ;;
                    skip)
                        (( SYNC_SKIPPED++ ))
                        log_info "  Skipped: $path"
                        ;;
                esac

                unset _tmp_local _tmp_remote
                ;;

            UNCHANGED)
                # No action needed
                ;;
        esac
    done <<< "$actions"

    # Step 5: Save updated manifest (only if no errors and not dry-run)
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        if (( SYNC_ERRORS == 0 )); then
            log_info "Saving sync state..."
            # Re-scan both sides after sync to get accurate state
            local post_local_manifest post_remote_manifest
            post_local_manifest=$(generate_local_manifest "$LOCAL_DIR")
            post_remote_manifest=$(generate_remote_manifest "$REMOTE_USER" "$REMOTE_HOST" "${REMOTE_PORT:-22}" "$REMOTE_DIR")
            local merged
            merged=$(merge_manifests "$post_local_manifest" "$post_remote_manifest" "$actions")
            save_manifest "$merged" "$manifest_file"
            log_info "Sync state saved"
        else
            log_warn "Sync completed with errors - state NOT saved (will retry changed files next run)"
        fi
    fi

    # Step 6: Print summary
    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    print_summary "$SYNC_PUSHED" "$SYNC_PULLED" "$SYNC_DELETED_LOCAL" "$SYNC_DELETED_REMOTE" "$SYNC_CONFLICTS" "$SYNC_SKIPPED" "$SYNC_ERRORS" "$elapsed"

    # Step 6b: Rotate old backups
    if [[ "${BACKUP_ON_CONFLICT:-false}" == "true" ]]; then
        rotate_backups
    fi

    # Step 7: Run notification hooks
    # Intentionally word-split ON_FAILURE/ON_COMPLETE so users can write
    # "notify-send -u critical" (command + flags), with the message appended.
    # No eval: the message text is always passed as a single quoted argument,
    # so it cannot inject additional shell commands.
    if (( SYNC_ERRORS > 0 )); then
        if [[ -n "${ON_FAILURE:-}" ]]; then
            # shellcheck disable=SC2086
            $ON_FAILURE "Sync completed with $SYNC_ERRORS error(s)" 2>/dev/null || true
        fi
        return 1
    else
        if [[ -n "${ON_COMPLETE:-}" ]]; then
            # shellcheck disable=SC2086
            $ON_COMPLETE "Sync complete: pushed=$SYNC_PUSHED pulled=$SYNC_PULLED" 2>/dev/null || true
        fi
        return 0
    fi
}

# ============================================================================
# STATUS CHECK (no changes, just report)
# ============================================================================

run_status() {
    local profile="${PROFILE_NAME:-default}"

    log_info "Checking sync status (profile: $profile)"
    log_info "Local:  $LOCAL_DIR"
    log_info "Remote: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"

    # Generate current manifests
    log_info "Scanning local files..."
    local local_manifest
    local_manifest=$(generate_local_manifest "$LOCAL_DIR")

    log_info "Scanning remote files..."
    local remote_manifest
    remote_manifest=$(generate_remote_manifest "$REMOTE_USER" "$REMOTE_HOST" "${REMOTE_PORT:-22}" "$REMOTE_DIR")

    # Load previous manifest
    local manifest_file
    manifest_file=$(manifest_path "$profile")
    local prev_manifest
    prev_manifest=$(load_manifest "$manifest_file")

    if [[ -z "$prev_manifest" ]]; then
        log_info "No previous sync state found - this would be a first sync"
    fi

    # Compute diff
    local actions
    actions=$(three_way_diff "$prev_manifest" "$local_manifest" "$remote_manifest")

    # Display results
    local has_changes=0

    echo ""
    echo -e "${C_BOLD}Sync Status${C_RESET}"
    echo -e "${C_BOLD}══════════════════════════════════${C_RESET}"

    while IFS=$'\t' read -r action path; do
        [[ -z "$action" ]] && continue
        [[ "$action" == "UNCHANGED" ]] && continue

        has_changes=1

        case "$action" in
            PUSH)          echo -e "  ${C_GREEN}→ PUSH${C_RESET}          $path" ;;
            PULL)          echo -e "  ${C_BLUE}← PULL${C_RESET}          $path" ;;
            DELETE_LOCAL)  echo -e "  ${C_RED}✗ DEL LOCAL${C_RESET}     $path" ;;
            DELETE_REMOTE) echo -e "  ${C_RED}✗ DEL REMOTE${C_RESET}    $path" ;;
            CONFLICT)      echo -e "  ${C_YELLOW}⚡ CONFLICT${C_RESET}     $path" ;;
        esac
    done <<< "$actions"

    if (( !has_changes )); then
        echo -e "  ${C_GREEN}Everything is in sync${C_RESET}"
    fi

    echo ""
}

# ============================================================================
# STATE RESET
# ============================================================================

reset_state() {
    local profile="${PROFILE_NAME:-default}"
    local manifest_file
    manifest_file=$(manifest_path "$profile")

    if [[ -f "$manifest_file" ]]; then
        rm -f "$manifest_file"
        log_info "Sync state reset for profile: $profile"
        log_info "Next sync will be treated as a first sync"
    else
        log_info "No sync state found for profile: $profile"
    fi
}
