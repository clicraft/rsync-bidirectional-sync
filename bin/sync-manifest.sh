#!/usr/bin/env bash
# sync-manifest.sh - Manifest generation and comparison for bidirectional sync
# Provides: manifest generation (local/remote), loading, saving, three-way diff
#
# Manifest format (TSV, sorted by path):
#   relative_path<TAB>mtime_epoch<TAB>size_bytes<TAB>type(f/d/l)
#
# The manifest captures the state of a directory tree at a point in time.
# Three-way diff compares: previous (last sync) vs current-local vs current-remote
# to classify each file's change status.

# ============================================================================
# MANIFEST GENERATION
# ============================================================================

# Generate manifest for a local directory
# Output: sorted TSV lines to stdout
generate_local_manifest() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
        log_error "Local directory does not exist: $dir"
        return 1
    fi

    log_debug "Generating local manifest for: $dir"

    local exclude_args=()
    if [[ -n "${EXCLUDE_PATTERNS+x}" ]]; then
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            # Convert rsync patterns to find-compatible patterns
            local clean="${pattern%/}"
            exclude_args+=(-not -path "*/${clean}" -not -path "*/${clean}/*")
        done
    fi
    # Always exclude sync internal dirs
    exclude_args+=(-not -path "*/.sync-backups" -not -path "*/.sync-backups/*")
    exclude_args+=(-not -path "*/.sync-state" -not -path "*/.sync-state/*")

    (
        cd "$dir" || return 1
        find . "${exclude_args[@]}" \( -type f -o -type l \) -print0 2>/dev/null \
            | while IFS= read -r -d '' file; do
                # Strip leading ./
                local relpath="${file#./}"

                local mtime size ftype

                if [[ -L "$file" ]]; then
                    ftype="l"
                    mtime=$(stat -c '%Y' "$file" 2>/dev/null || echo 0)
                    size=0
                else
                    ftype="f"
                    mtime=$(stat -c '%Y' "$file" 2>/dev/null || echo 0)
                    size=$(stat -c '%s' "$file" 2>/dev/null || echo 0)
                fi

                printf '%s\t%s\t%s\t%s\n' "$relpath" "$mtime" "$size" "$ftype"
            done
    ) | sort -t$'\t' -k1,1
}

# Generate manifest for a remote directory via SSH
# Output: sorted TSV lines to stdout
generate_remote_manifest() {
    local user="$1"
    local host="$2"
    local port="${3:-22}"
    local dir="$4"

    log_debug "Generating remote manifest for: ${user}@${host}:${dir}"

    local ssh_opts=()
    ssh_opts+=(-o "ConnectTimeout=${SSH_TIMEOUT:-10}")
    ssh_opts+=(-o "BatchMode=yes")
    ssh_opts+=(-o "StrictHostKeyChecking=accept-new")
    ssh_opts+=(-p "$port")

    if [[ -n "${SSH_IDENTITY:-}" ]]; then
        ssh_opts+=(-i "$SSH_IDENTITY")
    fi

    # Build exclude arguments for find on remote.
    # Escape single quotes in each pattern so they cannot break out of the
    # surrounding '...' quoting in the heredoc (defense-in-depth; primary
    # guard is validate_config rejecting unsafe patterns).
    local exclude_script=""
    if [[ -n "${EXCLUDE_PATTERNS+x}" ]]; then
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            local clean="${pattern%/}"
            local safe="${clean//\'/\'\\\'\'}"
            exclude_script+=" -not -path '*/${safe}' -not -path '*/${safe}/*'"
        done
    fi
    exclude_script+=" -not -path '*/.sync-backups' -not -path '*/.sync-backups/*'"
    exclude_script+=" -not -path '*/.sync-state' -not -path '*/.sync-state/*'"

    # Run find+stat on remote and pipe back
    # We use a heredoc-style remote script for reliability
    ssh "${ssh_opts[@]}" "${user}@${host}" bash -s <<REMOTE_SCRIPT
set -euo pipefail
if [ ! -d '$dir' ]; then
    exit 0
fi
cd '$dir'
find . $exclude_script \( -type f -o -type l \) -print0 2>/dev/null \\
    | while IFS= read -r -d '' file; do
        relpath="\${file#./}"
        if [ -L "\$file" ]; then
            ftype="l"
            mtime=\$(stat -c '%Y' "\$file" 2>/dev/null || echo 0)
            size=0
        else
            ftype="f"
            mtime=\$(stat -c '%Y' "\$file" 2>/dev/null || echo 0)
            size=\$(stat -c '%s' "\$file" 2>/dev/null || echo 0)
        fi
        printf '%s\t%s\t%s\t%s\n' "\$relpath" "\$mtime" "\$size" "\$ftype"
    done | sort -t\$'\t' -k1,1
REMOTE_SCRIPT
}

# Generate checksum for a local file (for conflict verification)
local_file_checksum() {
    local filepath="$1"
    if [[ -f "$filepath" ]]; then
        md5sum "$filepath" 2>/dev/null | cut -d' ' -f1
    else
        echo ""
    fi
}

# Generate checksum for a remote file
remote_file_checksum() {
    local user="$1"
    local host="$2"
    local port="${3:-22}"
    local filepath="$4"

    local ssh_opts=()
    ssh_opts+=(-o "ConnectTimeout=${SSH_TIMEOUT:-10}")
    ssh_opts+=(-o "BatchMode=yes")
    ssh_opts+=(-p "$port")

    if [[ -n "${SSH_IDENTITY:-}" ]]; then
        ssh_opts+=(-i "$SSH_IDENTITY")
    fi

    ssh "${ssh_opts[@]}" "${user}@${host}" "md5sum '$filepath' 2>/dev/null | cut -d' ' -f1" 2>/dev/null || echo ""
}

# ============================================================================
# MANIFEST FILE I/O
# ============================================================================

# Save manifest to a file
save_manifest() {
    local manifest_content="$1"
    local output_file="$2"

    local output_dir
    output_dir=$(dirname "$output_file")
    mkdir -p "$output_dir"

    echo "$manifest_content" > "$output_file"
    log_debug "Manifest saved: $output_file ($(echo "$manifest_content" | wc -l) entries)"
}

# Load manifest from a file
# Returns content via stdout, empty string if file doesn't exist
load_manifest() {
    local input_file="$1"

    if [[ -f "$input_file" ]]; then
        cat "$input_file"
        log_debug "Manifest loaded: $input_file"
    else
        log_debug "No previous manifest found: $input_file"
        echo ""
    fi
}

# Get manifest file path for a profile
manifest_path() {
    local profile="${1:-default}"
    local state_dir="${STATE_DIR:-$HOME/.config/rsync-sync/state}"
    echo "${state_dir}/${profile}.manifest"
}

# ============================================================================
# THREE-WAY DIFF
# ============================================================================

# Parse a manifest into an associative array
# Usage: parse_manifest "manifest_content" ARRAY_NAME
# Stores: ARRAY_NAME[relative_path]="mtime<TAB>size<TAB>type"
parse_manifest() {
    local content="$1"
    local -n _target_array=$2

    while IFS=$'\t' read -r path mtime size ftype; do
        [[ -z "$path" ]] && continue
        _target_array["$path"]="${mtime}${_FIELD_SEP}${size}${_FIELD_SEP}${ftype}"
    done <<< "$content"
}

# Internal field separator (unlikely to appear in data)
readonly _FIELD_SEP=$'\x1f'

# Extract mtime from a manifest entry value
entry_mtime() {
    echo "${1%%${_FIELD_SEP}*}"
}

# Extract size from a manifest entry value
entry_size() {
    local rest="${1#*${_FIELD_SEP}}"
    echo "${rest%%${_FIELD_SEP}*}"
}

# Check if a file entry has changed between two manifests
entry_changed() {
    local entry_a="$1"
    local entry_b="$2"

    if [[ "$entry_a" != "$entry_b" ]]; then
        return 0  # changed
    fi
    return 1  # unchanged
}

# Perform three-way diff between previous, local, and remote manifests
# Outputs action lines to stdout:
#   PUSH<TAB>relative_path       (local -> remote)
#   PULL<TAB>relative_path       (remote -> local)
#   DELETE_LOCAL<TAB>relative_path
#   DELETE_REMOTE<TAB>relative_path
#   CONFLICT<TAB>relative_path
#   UNCHANGED<TAB>relative_path
three_way_diff() {
    local prev_content="$1"
    local local_content="$2"
    local remote_content="$3"

    # Parse manifests into associative arrays
    declare -A prev_map=()
    declare -A local_map=()
    declare -A remote_map=()

    parse_manifest "$prev_content" prev_map
    parse_manifest "$local_content" local_map
    parse_manifest "$remote_content" remote_map

    # Collect all unique paths
    declare -A all_paths=()
    local path
    for path in "${!prev_map[@]}"; do all_paths["$path"]=1; done
    for path in "${!local_map[@]}"; do all_paths["$path"]=1; done
    for path in "${!remote_map[@]}"; do all_paths["$path"]=1; done

    # Classify each path
    for path in $(echo "${!all_paths[@]}" | tr ' ' '\n' | sort); do
        local in_prev=0 in_local=0 in_remote=0
        [[ -n "${prev_map[$path]+x}" ]] && in_prev=1
        [[ -n "${local_map[$path]+x}" ]] && in_local=1
        [[ -n "${remote_map[$path]+x}" ]] && in_remote=1

        local prev_entry="${prev_map[$path]:-}"
        local local_entry="${local_map[$path]:-}"
        local remote_entry="${remote_map[$path]:-}"

        if (( in_prev && in_local && in_remote )); then
            # File exists in all three
            local local_changed=0 remote_changed=0
            entry_changed "$local_entry" "$prev_entry" && local_changed=1
            entry_changed "$remote_entry" "$prev_entry" && remote_changed=1

            if (( !local_changed && !remote_changed )); then
                printf 'UNCHANGED\t%s\n' "$path"
            elif (( local_changed && !remote_changed )); then
                printf 'PUSH\t%s\n' "$path"
            elif (( !local_changed && remote_changed )); then
                printf 'PULL\t%s\n' "$path"
            else
                # Both changed - check if they changed identically
                if [[ "$local_entry" == "$remote_entry" ]]; then
                    printf 'UNCHANGED\t%s\n' "$path"
                else
                    printf 'CONFLICT\t%s\n' "$path"
                fi
            fi

        elif (( !in_prev && in_local && in_remote )); then
            # New on both sides
            if [[ "$local_entry" == "$remote_entry" ]]; then
                printf 'UNCHANGED\t%s\n' "$path"
            else
                printf 'CONFLICT\t%s\n' "$path"
            fi

        elif (( !in_prev && in_local && !in_remote )); then
            # New locally only
            printf 'PUSH\t%s\n' "$path"

        elif (( !in_prev && !in_local && in_remote )); then
            # New remotely only
            printf 'PULL\t%s\n' "$path"

        elif (( in_prev && in_local && !in_remote )); then
            # Was in prev and local, gone from remote -> deleted remotely
            if [[ "${PROPAGATE_DELETES:-true}" == "true" ]]; then
                printf 'DELETE_LOCAL\t%s\n' "$path"
            else
                # Don't delete, push local version back
                printf 'PUSH\t%s\n' "$path"
            fi

        elif (( in_prev && !in_local && in_remote )); then
            # Was in prev and remote, gone from local -> deleted locally
            if [[ "${PROPAGATE_DELETES:-true}" == "true" ]]; then
                printf 'DELETE_REMOTE\t%s\n' "$path"
            else
                # Don't delete, pull remote version back
                printf 'PULL\t%s\n' "$path"
            fi

        elif (( in_prev && !in_local && !in_remote )); then
            # Deleted on both sides - no action needed
            log_debug "Deleted on both sides: $path"

        fi
    done
}

# ============================================================================
# FIRST SYNC DETECTION
# ============================================================================

# On first sync (no previous manifest), we merge both sides
# New files on either side get synced, identical files are unchanged
# Different files with same name are conflicts
first_sync_diff() {
    local local_content="$1"
    local remote_content="$2"

    # With no previous manifest, treat it as empty
    three_way_diff "" "$local_content" "$remote_content"
}

# ============================================================================
# MANIFEST MERGE
# ============================================================================

# Create a merged manifest from local and remote after successful sync
# This becomes the "previous" manifest for the next run
merge_manifests() {
    local local_content="$1"
    local remote_content="$2"
    local actions="$3"

    # Start with the local manifest as base
    declare -A merged=()
    parse_manifest "$local_content" merged

    # Apply remote-only entries
    while IFS=$'\t' read -r path mtime size ftype; do
        [[ -z "$path" ]] && continue
        if [[ -z "${merged[$path]+x}" ]]; then
            merged["$path"]="${mtime}${_FIELD_SEP}${size}${_FIELD_SEP}${ftype}"
        fi
    done <<< "$remote_content"

    # Remove entries that were deleted
    while IFS=$'\t' read -r action path; do
        [[ -z "$action" ]] && continue
        case "$action" in
            DELETE_LOCAL|DELETE_REMOTE)
                unset "merged[$path]" 2>/dev/null || true
                ;;
        esac
    done <<< "$actions"

    # Output merged manifest
    for path in $(echo "${!merged[@]}" | tr ' ' '\n' | sort); do
        local entry="${merged[$path]}"
        local mtime="${entry%%${_FIELD_SEP}*}"
        local rest="${entry#*${_FIELD_SEP}}"
        local size="${rest%%${_FIELD_SEP}*}"
        local ftype="${rest#*${_FIELD_SEP}}"
        printf '%s\t%s\t%s\t%s\n' "$path" "$mtime" "$size" "$ftype"
    done
}
