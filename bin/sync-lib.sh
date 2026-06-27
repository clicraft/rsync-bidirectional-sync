#!/usr/bin/env bash
# sync-lib.sh - Shared utility library for rsync-bidirectional-sync
# Provides: logging, connectivity, rsync wrappers, config, locking, signal handling

set -euo pipefail

# ============================================================================
# VERSION
# ============================================================================

readonly SYNC_VERSION="1.0.0" # placeholder — overwritten at install time

# ============================================================================
# COLOR DEFINITIONS
# ============================================================================

if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    readonly C_RED='\033[0;31m'
    readonly C_GREEN='\033[0;32m'
    readonly C_YELLOW='\033[0;33m'
    readonly C_BLUE='\033[0;34m'
    readonly C_MAGENTA='\033[0;35m'
    readonly C_CYAN='\033[0;36m'
    readonly C_BOLD='\033[1m'
    readonly C_RESET='\033[0m'
else
    readonly C_RED=''
    readonly C_GREEN=''
    readonly C_YELLOW=''
    readonly C_BLUE=''
    readonly C_MAGENTA=''
    readonly C_CYAN=''
    readonly C_BOLD=''
    readonly C_RESET=''
fi

# ============================================================================
# GLOBAL STATE
# ============================================================================

LOCK_FILE=""
LOG_FILE=""
_CLEANUP_DONE=0

# Dedicated file descriptor for the flock-based lock (fixed number rather than
# a {var}-assigned FD for bash 4.0 compatibility). LOCK_USES_FLOCK is set to 1
# while a flock-based lock is held, so release_lock knows which path to take.
readonly LOCK_FD=200
LOCK_USES_FLOCK=0

# ============================================================================
# LOGGING
# ============================================================================

# Log level constants
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3

_log_level_to_int() {
    case "${1^^}" in
        DEBUG) echo $LOG_LEVEL_DEBUG ;;
        INFO)  echo $LOG_LEVEL_INFO ;;
        WARN)  echo $LOG_LEVEL_WARN ;;
        ERROR) echo $LOG_LEVEL_ERROR ;;
        *)     echo $LOG_LEVEL_INFO ;;
    esac
}

_should_log() {
    local msg_level="$1"
    local configured_level="${LOG_LEVEL:-INFO}"
    local msg_int configured_int
    msg_int=$(_log_level_to_int "$msg_level")
    configured_int=$(_log_level_to_int "$configured_level")
    (( msg_int >= configured_int ))
}

# Replace control bytes (ESC, CR, NL, BEL, etc.) with '?' so attacker-
# controlled strings such as file names or remote output cannot inject
# terminal escape sequences into our output or persist them into log files
# (where they would re-fire whenever the log is later `cat`ed). Writes the
# cleaned value into the variable named by $1 (no subshell/fork).
sanitize_for_terminal() {
    printf -v "$1" '%s' "${2//[[:cntrl:]]/?}"
}

_log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="$*"

    if ! _should_log "$level"; then
        return 0
    fi

    # Strip control characters from the (possibly attacker-influenced) message
    # before it reaches the terminal or the log file.
    local safe_message
    sanitize_for_terminal safe_message "$message"

    local color=""
    case "$level" in
        DEBUG) color="$C_CYAN" ;;
        INFO)  color="$C_GREEN" ;;
        WARN)  color="$C_YELLOW" ;;
        ERROR) color="$C_RED" ;;
    esac

    # Print to stderr (so stdout stays clean for machine-readable output)
    printf "${color}[%s] [%-5s]${C_RESET} %s\n" "$timestamp" "$level" "$safe_message" >&2

    # Append to log file if set
    if [[ -n "${LOG_FILE:-}" ]] && [[ -d "$(dirname "$LOG_FILE")" ]]; then
        printf "[%s] [%-5s] %s\n" "$timestamp" "$level" "$safe_message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log_debug() { _log "DEBUG" "$@"; }
log_info()  { _log "INFO" "$@"; }
log_warn()  { _log "WARN" "$@"; }
log_error() { _log "ERROR" "$@"; }

# ============================================================================
# LOG MANAGEMENT
# ============================================================================

init_logging() {
    local log_dir="${LOG_DIR:-$HOME/.config/rsync-sync/logs}"
    local profile="${PROFILE_NAME:-default}"

    mkdir -p "$log_dir"

    LOG_FILE="${log_dir}/sync-${profile}-$(date '+%Y%m%d_%H%M%S').log"
    touch "$LOG_FILE"

    log_debug "Log file initialized: $LOG_FILE"
}

rotate_logs() {
    local log_dir="${LOG_DIR:-$HOME/.config/rsync-sync/logs}"
    local max_files="${MAX_LOG_FILES:-10}"
    local max_size="${MAX_LOG_SIZE:-10485760}"

    if [[ ! -d "$log_dir" ]]; then
        return 0
    fi

    # Remove logs exceeding max size
    while IFS= read -r -d '' logfile; do
        local size
        size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
        if (( size > max_size )); then
            log_debug "Removing oversized log: $logfile ($size bytes)"
            rm -f "$logfile"
        fi
    done < <(find "$log_dir" -name 'sync-*.log' -print0 2>/dev/null)

    # Keep only the most recent N logs
    local count
    count=$(find "$log_dir" -name 'sync-*.log' 2>/dev/null | wc -l)
    if (( count > max_files )); then
        find "$log_dir" -name 'sync-*.log' -printf '%T@ %p\n' 2>/dev/null \
            | sort -n \
            | head -n $(( count - max_files )) \
            | cut -d' ' -f2- \
            | while IFS= read -r old_log; do
                log_debug "Rotating old log: $old_log"
                rm -f "$old_log"
            done
    fi
}

# ============================================================================
# CONFIGURATION
# ============================================================================

load_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        return 1
    fi

    # Warn if the "others" octal digit (the last one) grants read (4-7).
    # Anchored to the last digit so e.g. 640 (group-only) is not falsely flagged;
    # the old [67] test also missed others-read modes 4 (r--) and 5 (r-x).
    if [[ "$(stat -c%a "$config_file" 2>/dev/null)" =~ [4-7]$ ]]; then
        log_warn "Config file $config_file is world-readable. Consider: chmod 600 $config_file"
    fi

    # shellcheck source=/dev/null
    source "$config_file"
    log_debug "Loaded configuration from: $config_file"
}

validate_config() {
    local errors=0

    # Required fields
    if [[ -z "${REMOTE_USER:-}" ]]; then
        log_error "REMOTE_USER is not set"
        errors=$(( errors + 1 ))
    fi

    if [[ -z "${REMOTE_HOST:-}" ]]; then
        log_error "REMOTE_HOST is not set"
        errors=$(( errors + 1 ))
    fi

    if [[ -z "${LOCAL_DIR:-}" ]]; then
        log_error "LOCAL_DIR is not set"
        errors=$(( errors + 1 ))
    fi

    if [[ -z "${REMOTE_DIR:-}" ]]; then
        log_error "REMOTE_DIR is not set"
        errors=$(( errors + 1 ))
    fi

    # --- Security: reject shell-unsafe characters in values used in SSH commands ---

    # REMOTE_USER is interpolated into "user@host" passed to ssh. Restrict to a
    # valid Unix username and forbid a leading dash so it cannot be parsed as an
    # ssh option.
    if [[ -n "${REMOTE_USER:-}" ]] && ! [[ "$REMOTE_USER" =~ ^[a-zA-Z0-9_][a-zA-Z0-9._-]*$ ]]; then
        log_error "REMOTE_USER is not a valid username (letters/digits/dot/dash/underscore, no leading dash): $REMOTE_USER"
        errors=$(( errors + 1 ))
    fi

    # REMOTE_HOST flows into ssh, rsync targets, ping, and /dev/tcp. Restrict to
    # hostname / IPv4 / IPv6 characters and forbid a leading dash so it cannot be
    # parsed as a command-line option (e.g. `ping -f`).
    if [[ -n "${REMOTE_HOST:-}" ]] && ! [[ "$REMOTE_HOST" =~ ^[a-zA-Z0-9_]([a-zA-Z0-9._:-]*)?$ ]]; then
        log_error "REMOTE_HOST is not a valid hostname/IP (no leading dash, no shell metacharacters): $REMOTE_HOST"
        errors=$(( errors + 1 ))
    fi

    # REMOTE_DIR is embedded in single-quoted remote shell commands like
    # "test -d '$REMOTE_DIR'". A single quote in the value breaks that quoting
    # and allows arbitrary remote command injection.
    if [[ -n "${REMOTE_DIR:-}" ]] && [[ "$REMOTE_DIR" == *"'"* ]]; then
        log_error "REMOTE_DIR must not contain single quotes"
        errors=$(( errors + 1 ))
    fi

    # SSH_IDENTITY is appended unquoted to the ssh command string that is later
    # word-split and glob-expanded. A value with whitespace could inject extra
    # SSH options (e.g. -oProxyCommand=...) enabling full MITM, and a glob could
    # expand to multiple arguments. Restrict to a plain file path.
    if [[ -n "${SSH_IDENTITY:-}" ]] && ! [[ "$SSH_IDENTITY" =~ ^[A-Za-z0-9._/~-]+$ ]]; then
        log_error "SSH_IDENTITY must be a plain file path (letters/digits/._/~- only): $SSH_IDENTITY"
        errors=$(( errors + 1 ))
    fi

    # Validate local directory exists
    if [[ -n "${LOCAL_DIR:-}" ]] && [[ ! -d "$LOCAL_DIR" ]]; then
        log_error "LOCAL_DIR does not exist: $LOCAL_DIR"
        errors=$(( errors + 1 ))
    fi

    # Validate conflict strategy
    case "${CONFLICT_STRATEGY:-newest}" in
        newest|skip|backup|local|remote) ;;
        *)
            log_error "Invalid CONFLICT_STRATEGY: $CONFLICT_STRATEGY (must be: newest, skip, backup, local, remote)"
            errors=$(( errors + 1 ))
            ;;
    esac

    # Validate port
    if [[ -n "${REMOTE_PORT:-}" ]] && ! [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]]; then
        log_error "REMOTE_PORT must be a number: $REMOTE_PORT"
        errors=$(( errors + 1 ))
    fi

    # Validate log level
    case "${LOG_LEVEL:-INFO}" in
        DEBUG|INFO|WARN|ERROR) ;;
        *)
            log_error "Invalid LOG_LEVEL: $LOG_LEVEL (must be: DEBUG, INFO, WARN, ERROR)"
            errors=$(( errors + 1 ))
            ;;
    esac

    # BACKUP_DIR is joined to LOCAL_DIR/REMOTE_DIR and is the target of
    # destructive `find ... -delete` during backup rotation. A value of '.',
    # '..', an absolute path, or one containing '..' would point the deletion at
    # the sync tree itself (or outside it) and destroy real data. Require a
    # simple relative directory name.
    if [[ -n "${BACKUP_DIR:-}" ]]; then
        if [[ "$BACKUP_DIR" == /* || "$BACKUP_DIR" == "." || "$BACKUP_DIR" == ".." || "$BACKUP_DIR" == *".."* ]]; then
            log_error "BACKUP_DIR must be a simple relative path inside the sync dir (no '.', '..', or absolute path): $BACKUP_DIR"
            errors=$(( errors + 1 ))
        fi
    fi

    # EXCLUDE_PATTERNS entries are embedded inside single-quoted strings in a
    # remote shell heredoc. A pattern containing a single quote or semicolon
    # breaks that quoting and can execute arbitrary commands on the remote host.
    if [[ -n "${EXCLUDE_PATTERNS+x}" ]]; then
        local p
        for p in "${EXCLUDE_PATTERNS[@]}"; do
            if [[ "$p" == *"'"* || "$p" == *";"* || "$p" == *'`'* || "$p" == *'$'* ]]; then
                log_error "EXCLUDE_PATTERNS entry contains shell-unsafe characters (', ;, \`, \$): $p"
                errors=$(( errors + 1 ))
            fi
        done
    fi

    if (( errors > 0 )); then
        log_error "Configuration validation failed with $errors error(s)"
        return 1
    fi

    log_debug "Configuration validated successfully"
    return 0
}

# ============================================================================
# CONNECTIVITY
# ============================================================================

check_connectivity() {
    local host="$1"
    local timeout="${2:-5}"

    log_debug "Checking network connectivity to $host..."

    if ping -c 1 -W "$timeout" "$host" &>/dev/null; then
        log_debug "Host $host is reachable"
        return 0
    fi

    # Ping might be blocked, try TCP connection to SSH port
    local port="${REMOTE_PORT:-22}"
    if timeout "$timeout" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        log_debug "Host $host is reachable on port $port"
        return 0
    fi

    log_error "Cannot reach host: $host"
    return 1
}

check_ssh() {
    local user="$1"
    local host="$2"
    local port="${3:-22}"
    local timeout="${SSH_TIMEOUT:-10}"

    log_debug "Checking SSH connection to ${user}@${host}:${port}..."

    local ssh_opts=()
    ssh_opts+=(-o "ConnectTimeout=$timeout")
    ssh_opts+=(-o "BatchMode=yes")
    ssh_opts+=(-o "StrictHostKeyChecking=accept-new")
    ssh_opts+=(-p "$port")

    if [[ -n "${SSH_IDENTITY:-}" ]]; then
        ssh_opts+=(-i "$SSH_IDENTITY")
    fi

    if ssh "${ssh_opts[@]}" "${user}@${host}" "echo ok" &>/dev/null; then
        log_debug "SSH connection successful"
        return 0
    fi

    log_error "SSH connection failed to ${user}@${host}:${port}"
    log_error "Ensure SSH key is set up: ssh-copy-id -p $port ${user}@${host}"
    return 1
}

check_remote_rsync() {
    local user="$1"
    local host="$2"
    local port="${3:-22}"

    log_debug "Checking rsync availability on remote..."

    local ssh_opts=()
    ssh_opts+=(-o "ConnectTimeout=${SSH_TIMEOUT:-10}")
    ssh_opts+=(-o "BatchMode=yes")
    ssh_opts+=(-p "$port")

    if [[ -n "${SSH_IDENTITY:-}" ]]; then
        ssh_opts+=(-i "$SSH_IDENTITY")
    fi

    if ssh "${ssh_opts[@]}" "${user}@${host}" "command -v rsync" &>/dev/null; then
        log_debug "rsync is available on remote"
        return 0
    fi

    log_error "rsync is not installed on ${host}. Install it: sudo apt install rsync"
    return 1
}

check_remote_dir() {
    local user="$1"
    local host="$2"
    local port="${3:-22}"
    local remote_dir="$4"

    log_debug "Checking remote directory: $remote_dir"

    local ssh_opts=()
    ssh_opts+=(-o "ConnectTimeout=${SSH_TIMEOUT:-10}")
    ssh_opts+=(-o "BatchMode=yes")
    ssh_opts+=(-p "$port")

    if [[ -n "${SSH_IDENTITY:-}" ]]; then
        ssh_opts+=(-i "$SSH_IDENTITY")
    fi

    if ssh "${ssh_opts[@]}" "${user}@${host}" "test -d $(shquote "$remote_dir")"; then
        log_debug "Remote directory exists: $remote_dir"
        return 0
    fi

    log_warn "Remote directory does not exist: $remote_dir"
    log_info "It will be created during the first sync"
    return 0
}

# ============================================================================
# SSH HELPER
# ============================================================================

# Emit a string as a single-quoted token that is safe to embed in a remote
# POSIX shell command, regardless of its contents. Each embedded single quote
# is rewritten as '\'' (close, escaped-quote, reopen). This neutralizes shell
# metacharacters in attacker-controllable values such as file names, which
# flow from the manifest/diff into remote `rm`/`mkdir`/`cp`/`md5sum` commands.
shquote() {
    local s=${1//\'/\'\\\'\'}
    printf "'%s'" "$s"
}

build_ssh_cmd() {
    local port="${REMOTE_PORT:-22}"
    local timeout="${SSH_TIMEOUT:-10}"

    local ssh_cmd="ssh -o ConnectTimeout=$timeout -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p $port"

    if [[ -n "${SSH_IDENTITY:-}" ]]; then
        ssh_cmd+=" -i $SSH_IDENTITY"
    fi

    echo "$ssh_cmd"
}

# ============================================================================
# RSYNC WRAPPERS
# ============================================================================

build_rsync_opts() {
    local opts=()

    opts+=(-a)                    # archive mode
    opts+=(-s)                    # protect-args: no remote shell expansion of paths
    opts+=(--partial)             # keep partial files for resume
    opts+=(--progress)            # show progress
    opts+=(--human-readable)      # human readable sizes
    opts+=(--timeout="${RSYNC_TIMEOUT:-30}")

    if [[ -n "${BANDWIDTH_LIMIT:-}" ]]; then
        opts+=(--bwlimit="$BANDWIDTH_LIMIT")
    fi

    if [[ -n "${MAX_FILE_SIZE:-}" ]]; then
        opts+=(--max-size="$MAX_FILE_SIZE")
    fi

    if [[ "${VERBOSE:-false}" == "true" ]]; then
        opts+=(-v --itemize-changes)
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        opts+=(--dry-run)
    fi

    echo "${opts[@]}"
}

build_exclusions() {
    local exclusions=()

    if [[ -n "${EXCLUDE_PATTERNS+x}" ]]; then
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            exclusions+=(--exclude="$pattern")
        done
    fi

    # Always exclude the state/backup dirs
    exclusions+=(--exclude=".sync-backups/")
    exclusions+=(--exclude=".sync-state/")

    echo "${exclusions[@]}"
}

robust_rsync() {
    local src="$1"
    local dst="$2"
    local max_retries="${MAX_RETRIES:-3}"
    local retry_delay="${RETRY_DELAY:-5}"
    local attempt=0

    local rsync_opts
    rsync_opts=$(build_rsync_opts)

    local exclusions
    exclusions=$(build_exclusions)

    while (( attempt < max_retries )); do
        (( attempt++ ))

        if (( attempt > 1 )); then
            log_warn "Retry attempt $attempt/$max_retries (waiting ${retry_delay}s)..."
            sleep "$retry_delay"
        fi

        local ssh_cmd
        ssh_cmd=$(build_ssh_cmd)

        log_debug "rsync $rsync_opts $exclusions ${RSYNC_EXTRA_OPTS:-} $src $dst"

        # shellcheck disable=SC2086
        if rsync $rsync_opts $exclusions ${RSYNC_EXTRA_OPTS:-} -e "$ssh_cmd" "$src" "$dst"; then
            log_debug "rsync completed successfully"
            return 0
        fi

        local exit_code=$?
        log_warn "rsync failed with exit code $exit_code (attempt $attempt/$max_retries)"
    done

    log_error "rsync failed after $max_retries attempts"
    return 1
}

# Transfer a single file to remote
rsync_push_file() {
    local local_path="$1"
    local remote_relative="$2"
    local remote_dest="${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/${remote_relative}"

    local rsync_opts
    rsync_opts=$(build_rsync_opts)

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)

    log_debug "Pushing: $remote_relative"

    # Ensure remote parent directory exists.
    # remote_relative comes from the file tree and may contain shell
    # metacharacters; quote it for the remote shell.
    local remote_parent
    remote_parent=$(dirname "${REMOTE_DIR}/${remote_relative}")
    ssh -o "BatchMode=yes" -p "${REMOTE_PORT:-22}" \
        ${SSH_IDENTITY:+-i "$SSH_IDENTITY"} \
        "${REMOTE_USER}@${REMOTE_HOST}" \
        "mkdir -p $(shquote "$remote_parent")" 2>/dev/null || true

    # shellcheck disable=SC2086
    rsync $rsync_opts -e "$ssh_cmd" "$local_path" "$remote_dest"
}

# Transfer a single file from remote
rsync_pull_file() {
    local remote_relative="$1"
    local local_path="$2"
    local remote_src="${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/${remote_relative}"

    local rsync_opts
    rsync_opts=$(build_rsync_opts)

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)

    log_debug "Pulling: $remote_relative"

    # Ensure local parent directory exists
    local local_parent
    local_parent=$(dirname "$local_path")
    mkdir -p "$local_parent"

    # shellcheck disable=SC2086
    rsync $rsync_opts -e "$ssh_cmd" "$remote_src" "$local_path"
}

# Delete a file on remote
remote_delete_file() {
    local remote_relative="$1"

    log_debug "Deleting remote: $remote_relative"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Would delete remote: $remote_relative"
        return 0
    fi

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)

    # remote_relative is attacker-influenceable (it is just a file name);
    # quote the full path for the remote shell to prevent command injection.
    local remote_target
    remote_target=$(shquote "${REMOTE_DIR}/${remote_relative}")

    # shellcheck disable=SC2086
    $ssh_cmd "${REMOTE_USER}@${REMOTE_HOST}" \
        "rm -rf $remote_target" 2>/dev/null
}

# Delete a local file
local_delete_file() {
    local relative_path="$1"
    local local_path="${LOCAL_DIR}/${relative_path}"

    log_debug "Deleting local: $relative_path"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "[DRY-RUN] Would delete local: $relative_path"
        return 0
    fi

    rm -rf "$local_path"
}

# ============================================================================
# BACKUP
# ============================================================================

backup_local_file() {
    local relative_path="$1"
    local local_path="${LOCAL_DIR}/${relative_path}"
    local backup_base="${LOCAL_DIR}/${BACKUP_DIR:-.sync-backups}"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')

    if [[ ! -e "$local_path" ]]; then
        return 0
    fi

    local backup_path="${backup_base}/${relative_path}.${timestamp}"
    local backup_dir
    backup_dir=$(dirname "$backup_path")

    mkdir -p "$backup_dir"
    cp -a "$local_path" "$backup_path"
    log_debug "Backed up local: $relative_path -> $backup_path"
}

backup_remote_file() {
    local relative_path="$1"
    local backup_base="${REMOTE_DIR}/${BACKUP_DIR:-.sync-backups}"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)

    local backup_path="${backup_base}/${relative_path}.${timestamp}"

    # relative_path / backup_path embed a file name; quote every path for the
    # remote shell to prevent command injection.
    local q_backup_parent q_source q_backup
    q_backup_parent=$(shquote "$(dirname "$backup_path")")
    q_source=$(shquote "${REMOTE_DIR}/${relative_path}")
    q_backup=$(shquote "$backup_path")

    # shellcheck disable=SC2086
    $ssh_cmd "${REMOTE_USER}@${REMOTE_HOST}" \
        "mkdir -p $q_backup_parent && cp -a $q_source $q_backup" 2>/dev/null || true

    log_debug "Backed up remote: $relative_path"
}

rotate_backups() {
    local max_age="${BACKUP_MAX_AGE_DAYS:-30}"
    local backup_dir="${LOCAL_DIR}/${BACKUP_DIR:-.sync-backups}"

    if [[ "$max_age" -le 0 ]] || [[ ! -d "$backup_dir" ]]; then
        return 0
    fi

    local count=0
    while IFS= read -r -d '' file; do
        rm -f "$file"
        count=$(( count + 1 ))
    done < <(find "$backup_dir" -type f -mtime +"$max_age" -print0 2>/dev/null)

    # Remove empty directories left behind
    find "$backup_dir" -mindepth 1 -type d -empty -delete 2>/dev/null || true

    if (( count > 0 )); then
        log_info "Cleaned up $count backup(s) older than $max_age days"
    fi
}

# ============================================================================
# LOCK FILE MANAGEMENT
# ============================================================================

acquire_lock() {
    local profile="${PROFILE_NAME:-default}"
    local state_dir="${STATE_DIR:-$HOME/.config/rsync-sync/state}"

    mkdir -p "$state_dir"
    LOCK_FILE="${state_dir}/${profile}.lock"

    # Preferred: kernel advisory lock via flock. The lock lives on an open file
    # descriptor held for the whole run, so the kernel releases it automatically
    # if the process dies. This means there is no check-then-act race and no
    # stale lock files to reason about.
    if command -v flock >/dev/null 2>&1; then
        # Append-open (does not truncate a lock another process may hold).
        exec 200>>"$LOCK_FILE"
        if ! flock -n "$LOCK_FD"; then
            local lock_pid
            lock_pid=$(head -1 "$LOCK_FILE" 2>/dev/null || echo "")
            log_error "Another sync is already running${lock_pid:+ (PID: $lock_pid)}"
            exec 200>&- 2>/dev/null || true
            return 1
        fi
        LOCK_USES_FLOCK=1
        # We exclusively hold the lock; safe to record our PID for diagnostics.
        printf '%s\n' "$$" >| "$LOCK_FILE"
        log_debug "Lock acquired via flock: $LOCK_FILE (PID $$)"
        return 0
    fi

    # Fallback (no flock available): best-effort PID lock.
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")

        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log_error "Another sync is already running (PID: $lock_pid)"
            log_error "If this is stale, remove: $LOCK_FILE"
            return 1
        fi

        log_warn "Removing stale lock file (PID ${lock_pid:-unknown} is not running)"
        rm -f "$LOCK_FILE"
    fi

    # Atomic creation: noclobber makes the redirect fail if the file already
    # exists, closing the TOCTOU window between the check above and the write.
    if ! ( set -o noclobber; echo $$ > "$LOCK_FILE" ) 2>/dev/null; then
        log_error "Failed to acquire lock (another sync may have just started): $LOCK_FILE"
        return 1
    fi

    log_debug "Lock acquired: $LOCK_FILE (PID $$)"
    return 0
}

release_lock() {
    if (( LOCK_USES_FLOCK )); then
        # Closing the descriptor releases the kernel lock. Deliberately do NOT
        # unlink the file: removing it while holding flock can let two processes
        # acquire locks on different inodes for the same path.
        exec 200>&- 2>/dev/null || true
        LOCK_USES_FLOCK=0
        log_debug "Lock released (flock): ${LOCK_FILE:-}"
        return 0
    fi

    if [[ -n "${LOCK_FILE:-}" ]] && [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
        log_debug "Lock released: $LOCK_FILE"
    fi
}

# ============================================================================
# SIGNAL HANDLING
# ============================================================================

cleanup() {
    if (( _CLEANUP_DONE )); then
        return 0
    fi
    _CLEANUP_DONE=1

    log_info "Cleaning up..."
    release_lock
    log_info "Cleanup complete"
}

setup_signal_handlers() {
    trap cleanup EXIT
    trap 'log_warn "Interrupted by user"; cleanup; exit 130' INT
    trap 'log_warn "Terminated"; cleanup; exit 143' TERM
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Check if a command exists
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: $cmd"
        return 1
    fi
}

# Check all prerequisites
check_prerequisites() {
    local errors=0

    require_command rsync || (( errors++ ))
    require_command ssh || (( errors++ ))
    require_command find || (( errors++ ))
    require_command stat || (( errors++ ))
    require_command sort || (( errors++ ))

    # Check bash version (need 4+ for associative arrays)
    if (( BASH_VERSINFO[0] < 4 )); then
        log_error "Bash 4.0+ is required (current: ${BASH_VERSION})"
        (( errors++ ))
    fi

    if (( errors > 0 )); then
        return 1
    fi

    log_debug "All prerequisites satisfied"
    return 0
}

# Print a formatted summary
print_summary() {
    local pushed="${1:-0}"
    local pulled="${2:-0}"
    local deleted_local="${3:-0}"
    local deleted_remote="${4:-0}"
    local conflicts="${5:-0}"
    local skipped="${6:-0}"
    local errors="${7:-0}"
    local elapsed="${8:-0}"

    echo ""
    echo -e "${C_BOLD}═══════════════════════════════════════${C_RESET}"
    echo -e "${C_BOLD}  Sync Summary${C_RESET}"
    echo -e "${C_BOLD}═══════════════════════════════════════${C_RESET}"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo -e "  ${C_YELLOW}(DRY RUN - no changes made)${C_RESET}"
    fi

    echo -e "  ${C_GREEN}Pushed:${C_RESET}          $pushed file(s)"
    echo -e "  ${C_BLUE}Pulled:${C_RESET}          $pulled file(s)"
    echo -e "  ${C_RED}Deleted local:${C_RESET}   $deleted_local file(s)"
    echo -e "  ${C_RED}Deleted remote:${C_RESET}  $deleted_remote file(s)"

    if (( conflicts > 0 )); then
        echo -e "  ${C_YELLOW}Conflicts:${C_RESET}       $conflicts file(s)"
    fi

    if (( skipped > 0 )); then
        echo -e "  ${C_MAGENTA}Skipped:${C_RESET}         $skipped file(s)"
    fi

    if (( errors > 0 )); then
        echo -e "  ${C_RED}Errors:${C_RESET}          $errors"
    fi

    echo -e "  ${C_CYAN}Elapsed:${C_RESET}         ${elapsed}s"
    echo -e "${C_BOLD}═══════════════════════════════════════${C_RESET}"

    if (( errors > 0 )); then
        echo -e "  ${C_RED}Sync completed with errors${C_RESET}"
    else
        echo -e "  ${C_GREEN}Sync completed successfully${C_RESET}"
    fi

    echo ""
}

# Format bytes to human readable
format_bytes() {
    local bytes="$1"
    if (( bytes >= 1073741824 )); then
        printf "%.1fG" "$(echo "$bytes / 1073741824" | bc -l)"
    elif (( bytes >= 1048576 )); then
        printf "%.1fM" "$(echo "$bytes / 1048576" | bc -l)"
    elif (( bytes >= 1024 )); then
        printf "%.1fK" "$(echo "$bytes / 1024" | bc -l)"
    else
        printf "%dB" "$bytes"
    fi
}
