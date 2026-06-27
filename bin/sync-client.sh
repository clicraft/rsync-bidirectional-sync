#!/usr/bin/env bash
# sync-client.sh - Main entry point for rsync-bidirectional-sync
# Usage: sync-client [OPTIONS]
#
# Orchestrates bidirectional file synchronization between local and remote
# machines using rsync, with manifest-based change tracking, conflict
# resolution, and safe deletion propagation.

set -euo pipefail

# ============================================================================
# RESOLVE SCRIPT LOCATION
# ============================================================================

# Find where our scripts live (handle symlinks)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ============================================================================
# SOURCE LIBRARIES
# ============================================================================

source "${SCRIPT_DIR}/sync-lib.sh"
source "${SCRIPT_DIR}/sync-manifest.sh"
source "${SCRIPT_DIR}/sync-engine.sh"

# ============================================================================
# DEFAULTS
# ============================================================================

PROFILE_NAME="default"
DRY_RUN="false"
VERBOSE="false"
FORCE="false"
ACTION="sync"   # sync, status, reset-state, delete-backups
DELETE_NOW="false"
KEEP_BACKUPS_OVERRIDE=""

# ============================================================================
# USAGE / HELP
# ============================================================================

usage() {
    echo -e "${C_BOLD}rsync-bidirectional-sync ${SYNC_VERSION}${C_RESET}
Robust bidirectional file synchronization using rsync

${C_BOLD}USAGE:${C_RESET}
    sync-client [OPTIONS] [COMMAND]

${C_BOLD}COMMANDS:${C_RESET}
    sync            Run bidirectional sync (default)
    status          Show what would change without syncing
    reset-state     Clear sync state (next sync treated as first sync)
    delete-backups  Delete backups older than BACKUP_MAX_AGE_DAYS (--now for all)

${C_BOLD}OPTIONS:${C_RESET}
    -p, --profile NAME         Use named profile (default: \"default\")
    -n, --dry-run              Show what would happen without making changes
    -v, --verbose              Enable verbose output (DEBUG log level)
    -f, --force                Skip confirmation prompts
    -c, --config FILE          Use specific config file
        --keep-backups DAYS    Override BACKUP_MAX_AGE_DAYS from config
    -h, --help                 Show this help message
    -V, --version              Show version information

${C_BOLD}EXAMPLES:${C_RESET}
    sync-client                       # Run sync with default profile
    sync-client status                # Check what needs syncing
    sync-client --dry-run             # Preview sync without changes
    sync-client -p work sync         # Sync using \"work\" profile
    sync-client --verbose --dry-run   # Detailed preview
    sync-client reset-state           # Reset sync state

${C_BOLD}CONFIGURATION:${C_RESET}
    Default config:  ~/.config/rsync-sync/config
    Named profiles:  ~/.config/rsync-sync/profiles/<name>.conf
    Sync state:      ~/.config/rsync-sync/state/
    Logs:            ~/.config/rsync-sync/logs/

${C_BOLD}CONFLICT STRATEGIES:${C_RESET}
    newest    Keep the version with the most recent modification time
    skip      Leave conflicting files untouched
    backup    Back up both versions, apply newest
    local     Always prefer local version
    remote    Always prefer remote version

For more information, see: docs/USAGE.md"
}

version() {
    echo "rsync-bidirectional-sync ${SYNC_VERSION}"
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

CONFIG_FILE=""

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -p|--profile)
                if [[ -z "${2:-}" ]]; then
                    log_error "--profile requires a name"
                    exit 1
                fi
                if ! [[ "${2}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                    log_error "--profile name must contain only letters, digits, dash, or underscore: ${2}"
                    exit 1
                fi
                PROFILE_NAME="$2"
                shift 2
                ;;

            -n|--dry-run)
                DRY_RUN="true"
                shift
                ;;

            -v|--verbose)
                VERBOSE="true"
                shift
                ;;

            -f|--force)
                FORCE="true"
                shift
                ;;

            -c|--config)
                if [[ -z "${2:-}" ]]; then
                    log_error "--config requires a file path"
                    exit 1
                fi
                CONFIG_FILE="$2"
                shift 2
                ;;

            --keep-backups)
                if [[ -z "${2:-}" ]]; then
                    log_error "--keep-backups requires a number of days"
                    exit 1
                fi
                if ! [[ "${2}" =~ ^[0-9]+$ ]]; then
                    log_error "--keep-backups value must be a non-negative integer: ${2}"
                    exit 1
                fi
                KEEP_BACKUPS_OVERRIDE="$2"
                shift 2
                ;;

            -h|--help)
                usage
                exit 0
                ;;

            -V|--version)
                version
                exit 0
                ;;

            sync)
                ACTION="sync"
                shift
                ;;

            status)
                ACTION="status"
                shift
                ;;

            reset-state)
                ACTION="reset-state"
                shift
                ;;

            --delete-backups|delete-backups)
                ACTION="delete-backups"
                shift
                ;;

            --now)
                DELETE_NOW="true"
                shift
                ;;

            -*)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;

            *)
                log_error "Unknown command: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# ============================================================================
# CONFIGURATION RESOLUTION
# ============================================================================

resolve_config() {
    local config_dir="$HOME/.config/rsync-sync"

    # If explicit config file specified, use it
    if [[ -n "$CONFIG_FILE" ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            log_error "Config file not found: $CONFIG_FILE"
            exit 1
        fi
        return
    fi

    # Try profile-specific config first
    if [[ "$PROFILE_NAME" != "default" ]]; then
        local profile_config="${config_dir}/profiles/${PROFILE_NAME}.conf"
        if [[ -f "$profile_config" ]]; then
            CONFIG_FILE="$profile_config"
            return
        fi
    fi

    # Fall back to default config
    local default_config="${config_dir}/config"
    if [[ -f "$default_config" ]]; then
        CONFIG_FILE="$default_config"
        return
    fi

    log_error "No configuration file found"
    log_error "Expected: ${config_dir}/config"
    log_error "Run 'install.sh' or copy config.example to ${config_dir}/config"
    exit 1
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

preflight_checks() {
    log_info "Running pre-flight checks..."

    # Check prerequisites
    if ! check_prerequisites; then
        log_error "Pre-flight checks failed: missing prerequisites"
        return 1
    fi

    # Check connectivity
    if ! check_connectivity "$REMOTE_HOST"; then
        log_error "Pre-flight checks failed: cannot reach $REMOTE_HOST"
        return 1
    fi

    # Check SSH
    if ! check_ssh "$REMOTE_USER" "$REMOTE_HOST" "${REMOTE_PORT:-22}"; then
        log_error "Pre-flight checks failed: SSH connection failed"
        return 1
    fi

    # Check remote rsync
    if ! check_remote_rsync "$REMOTE_USER" "$REMOTE_HOST" "${REMOTE_PORT:-22}"; then
        log_error "Pre-flight checks failed: rsync not available on remote"
        return 1
    fi

    # Check remote directory
    check_remote_dir "$REMOTE_USER" "$REMOTE_HOST" "${REMOTE_PORT:-22}" "$REMOTE_DIR"

    # Check version mismatch with remote (cached: once per day per profile)
    local version_cache_dir="${STATE_DIR:-$HOME/.config/rsync-sync/state}"
    local version_cache_file="${version_cache_dir}/${PROFILE_NAME:-default}.remote-version"
    local check_version=true

    if [[ -f "$version_cache_file" ]]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -c%Y "$version_cache_file" 2>/dev/null || echo 0) ))
        if (( cache_age < 86400 )); then
            check_version=false
            local cached_remote_version
            cached_remote_version=$(cat "$version_cache_file")
            local local_version
            local_version=$(version)
            if [[ "$cached_remote_version" != "$local_version" ]]; then
                log_warn "Version mismatch: local=$local_version remote=$cached_remote_version (cached)"
            else
                log_debug "Version match: $local_version (cached)"
            fi
        fi
    fi

    if [[ "$check_version" == true ]]; then
        local ssh_cmd
        ssh_cmd=$(build_ssh_cmd)
        # shellcheck disable=SC2086
        local remote_version
        remote_version=$($ssh_cmd "${REMOTE_USER}@${REMOTE_HOST}" "sync-client --version 2>/dev/null" 2>/dev/null || echo "unknown")
        local local_version
        local_version=$(version)
        if [[ "$remote_version" == "unknown" ]]; then
            log_warn "Could not determine remote sync-client version"
        elif [[ "$remote_version" != "$local_version" ]]; then
            log_warn "Version mismatch: local=$local_version remote=$remote_version"
        else
            log_debug "Version match: $local_version"
        fi
        # Cache the result
        mkdir -p "$version_cache_dir"
        echo "$remote_version" > "$version_cache_file"
    fi

    log_info "Pre-flight checks passed"
    return 0
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    # Parse command-line arguments
    parse_args "$@"

    # Override log level if verbose
    if [[ "$VERBOSE" == "true" ]]; then
        LOG_LEVEL="DEBUG"
    fi

    # Setup signal handlers early
    setup_signal_handlers

    # Resolve and load configuration
    resolve_config
    load_config "$CONFIG_FILE"

    # CLI flag overrides config value (must come after load_config)
    if [[ -n "$KEEP_BACKUPS_OVERRIDE" ]]; then
        BACKUP_MAX_AGE_DAYS="$KEEP_BACKUPS_OVERRIDE"
        log_debug "Backup retention overridden by --keep-backups: ${BACKUP_MAX_AGE_DAYS} days"
    fi

    # Override log level again after config (CLI takes precedence)
    if [[ "$VERBOSE" == "true" ]]; then
        LOG_LEVEL="DEBUG"
    fi

    # Export key variables for subshells
    export DRY_RUN VERBOSE PROFILE_NAME

    # Initialize logging
    init_logging

    # Validate configuration
    if ! validate_config; then
        exit 1
    fi

    # Rotate old logs
    rotate_logs

    log_debug "Action: $ACTION"
    log_debug "Profile: $PROFILE_NAME"
    log_debug "Config: $CONFIG_FILE"
    log_debug "Dry run: $DRY_RUN"
    log_debug "Verbose: $VERBOSE"

    case "$ACTION" in
        sync)
            # Acquire lock
            if ! acquire_lock; then
                exit 1
            fi

            # Run pre-flight checks
            if ! preflight_checks; then
                exit 1
            fi

            # Run sync
            if run_sync; then
                exit 0
            else
                exit 1
            fi
            ;;

        status)
            # Pre-flight (lighter check for status)
            if ! check_prerequisites; then
                exit 1
            fi

            if ! check_ssh "$REMOTE_USER" "$REMOTE_HOST" "${REMOTE_PORT:-22}"; then
                exit 1
            fi

            run_status
            ;;

        reset-state)
            reset_state
            ;;

        delete-backups)
            if [[ "$DELETE_NOW" == "true" ]]; then
                local backup_dir="${LOCAL_DIR}/${BACKUP_DIR:-.sync-backups}"
                if [[ ! -d "$backup_dir" ]]; then
                    log_info "No backup directory found: $backup_dir"
                    exit 0
                fi
                local count
                count=$(find "$backup_dir" -type f 2>/dev/null | wc -l)
                if (( count == 0 )); then
                    log_info "No backups to delete"
                    exit 0
                fi
                if [[ "$FORCE" != "true" ]]; then
                    echo "This will delete $count backup file(s) in $backup_dir"
                    read -r -p "Continue? [y/N] " confirm
                    if [[ "$confirm" != [yY] ]]; then
                        log_info "Aborted"
                        exit 0
                    fi
                fi
                find "$backup_dir" -type f -delete 2>/dev/null
                find "$backup_dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true
                log_info "Deleted $count backup file(s)"
            else
                rotate_backups
            fi
            ;;

        *)
            log_error "Unknown action: $ACTION"
            exit 1
            ;;
    esac
}

# Run main with all arguments
main "$@"
