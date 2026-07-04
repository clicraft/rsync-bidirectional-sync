#!/usr/bin/env bash
# install.sh - Local installer for rsync-bidirectional-sync
# Copies scripts directly to ~/.local/bin/, sets up config and completion

set -euo pipefail

# ============================================================================
# COLORS
# ============================================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

info()  { printf "${GREEN}[INFO]${RESET}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
error() { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
step()  { printf "\n${BOLD}${BLUE}>> %s${RESET}\n" "$*"; }

# ============================================================================
# CONFIGURATION
# ============================================================================

BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/rsync-sync"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# REQUIREMENT CHECKS
# ============================================================================

check_requirements() {
    step "Checking requirements"

    local errors=0

    # Bash version
    if (( BASH_VERSINFO[0] >= 4 )); then
        info "Bash ${BASH_VERSION} (4.0+ required)"
    else
        error "Bash 4.0+ required (current: ${BASH_VERSION})"
        errors=$(( errors + 1 ))
    fi

    # rsync
    if command -v rsync &>/dev/null; then
        local rsync_ver
        rsync_ver=$(rsync --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        info "rsync $rsync_ver found"
    else
        error "rsync is not installed. Install: sudo apt install rsync"
        errors=$(( errors + 1 ))
    fi

    # ssh
    if command -v ssh &>/dev/null; then
        info "ssh found"
    else
        error "ssh is not installed. Install: sudo apt install openssh-client"
        errors=$(( errors + 1 ))
    fi

    # md5sum (for checksum verification)
    if command -v md5sum &>/dev/null; then
        info "md5sum found"
    else
        warn "md5sum not found - checksum verification will be unavailable"
    fi

    # find, stat, sort
    for cmd in find stat sort; do
        if command -v "$cmd" &>/dev/null; then
            info "$cmd found"
        else
            error "$cmd is not installed"
            errors=$(( errors + 1 ))
        fi
    done

    if (( errors > 0 )); then
        error "Requirements check failed with $errors error(s)"
        return 1
    fi

    info "All requirements satisfied"
    return 0
}

# ============================================================================
# DIRECTORY CREATION
# ============================================================================

create_directories() {
    step "Creating directories"

    local dirs=(
        "$BIN_DIR"
        "$CONFIG_DIR"
        "$CONFIG_DIR/profiles"
        "$CONFIG_DIR/state"
        "$CONFIG_DIR/logs"
    )

    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            info "Exists: $dir"
        else
            mkdir -p "$dir"
            info "Created: $dir"
        fi
    done
}

# ============================================================================
# FILE INSTALLATION
# ============================================================================

install_files() {
    step "Installing scripts"

    # Library scripts (keep original names)
    local lib_scripts=("sync-lib.sh" "sync-manifest.sh" "sync-engine.sh")

    for script in "${lib_scripts[@]}"; do
        local src="${SCRIPT_DIR}/bin/${script}"
        local dst="${BIN_DIR}/${script}"

        if [[ ! -f "$src" ]]; then
            error "Source file not found: $src"
            return 1
        fi

        cp "$src" "$dst"
        chmod +x "$dst"
        info "Installed: $dst"
    done

    # Inject git version into sync-lib.sh.
    # Constrain to a safe charset first: the value comes from a git tag/branch
    # ref, which can legitimately contain characters ("/`;$) that would break or
    # inject into this sed replacement and end up executed on every future run
    # (sync-lib.sh is sourced each invocation).
    local version
    version=$(git describe --tags --always --dirty 2>/dev/null || echo "unknown")
    if ! [[ "$version" =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "Version string '$version' has unexpected characters; using 'unknown'"
        version="unknown"
    fi
    sed -i "s/^readonly SYNC_VERSION=.*/readonly SYNC_VERSION=\"$version\"/" "$BIN_DIR/sync-lib.sh"
    info "Version: $version"

    # Entry points (rename, drop .sh)
    local -A entry_points=(
        ["sync-client.sh"]="sync-client"
        ["setup-ssh.sh"]="sync-setup-ssh"
    )

    for src_name in "${!entry_points[@]}"; do
        local dst_name="${entry_points[$src_name]}"
        local src="${SCRIPT_DIR}/bin/${src_name}"
        local dst="${BIN_DIR}/${dst_name}"

        if [[ ! -f "$src" ]]; then
            error "Source file not found: $src"
            return 1
        fi

        cp "$src" "$dst"
        chmod +x "$dst"
        info "Installed: $dst"
    done

    # Clean up legacy install dir if it exists
    local legacy_dir="$HOME/.local/share/rsync-sync"
    if [[ -d "$legacy_dir" ]]; then
        rm -rf "$legacy_dir"
        info "Removed legacy dir: $legacy_dir"
    fi
}

# ============================================================================
# CONFIGURATION SETUP
# ============================================================================

setup_config() {
    step "Setting up configuration"

    local config_file="${CONFIG_DIR}/config"

    if [[ -f "$config_file" ]]; then
        info "Configuration already exists: $config_file"
        info "Skipping (not overwriting existing config)"
    else
        cp "${SCRIPT_DIR}/config.example" "$config_file"
        chmod 600 "$config_file"
        info "Created: $config_file"
        warn "Edit this file with your remote connection details!"
    fi
}

# ============================================================================
# PATH SETUP
# ============================================================================

setup_path() {
    step "Setting up PATH"

    # Check if BIN_DIR is already in PATH
    if echo "$PATH" | tr ':' '\n' | grep -q "^${BIN_DIR}$"; then
        info "$BIN_DIR is already in PATH"
        return 0
    fi

    local path_line="export PATH=\"\$HOME/.local/bin:\$PATH\""
    local shells_updated=0

    # Try each shell config
    for rc_file in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [[ -f "$rc_file" ]]; then
            if grep -q '.local/bin' "$rc_file" 2>/dev/null; then
                info "PATH already configured in $rc_file"
            else
                echo "" >> "$rc_file"
                echo "# Added by rsync-bidirectional-sync installer" >> "$rc_file"
                echo "$path_line" >> "$rc_file"
                info "Updated: $rc_file"
                shells_updated=$(( shells_updated + 1 ))
            fi
        fi
    done

    if (( shells_updated > 0 )); then
        warn "Restart your shell or run: source ~/.bashrc"
    fi
}

# ============================================================================
# BASH COMPLETION
# ============================================================================

setup_completion() {
    step "Setting up bash completion"

    local completion_dir="$HOME/.local/share/bash-completion/completions"
    mkdir -p "$completion_dir"

    cat > "${completion_dir}/sync-client" <<'COMPLETION'
# Bash completion for sync-client
_sync_client() {
    local cur prev opts commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    commands="sync status reset-state show-exclusions init-syncignore"
    opts="-p --profile -n --dry-run -v --verbose -f --force -c --config --show-exclusions --init-syncignore -h --help -V --version"

    case "$prev" in
        -p|--profile)
            # Complete with available profiles
            local config_dir="$HOME/.config/rsync-sync/profiles"
            if [[ -d "$config_dir" ]]; then
                local profiles
                profiles=$(find "$config_dir" -name '*.conf' -exec basename {} .conf \; 2>/dev/null)
                COMPREPLY=( $(compgen -W "$profiles default" -- "$cur") )
            else
                COMPREPLY=( $(compgen -W "default" -- "$cur") )
            fi
            return 0
            ;;
        -c|--config)
            COMPREPLY=( $(compgen -f -- "$cur") )
            return 0
            ;;
        --init-syncignore|init-syncignore)
            COMPREPLY=( $(compgen -W "default python java javascript php teaching" -- "$cur") )
            return 0
            ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    else
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    fi
}
complete -F _sync_client sync-client
COMPLETION

    info "Created: ${completion_dir}/sync-client"

    # Source it in bashrc if not already
    local bashrc="$HOME/.bashrc"
    if [[ -f "$bashrc" ]] && ! grep -q 'bash-completion/completions/sync-client' "$bashrc" 2>/dev/null; then
        echo "" >> "$bashrc"
        echo "# rsync-sync bash completion" >> "$bashrc"
        echo '[ -f "$HOME/.local/share/bash-completion/completions/sync-client" ] && source "$HOME/.local/share/bash-completion/completions/sync-client"' >> "$bashrc"
        info "Completion added to $bashrc"
    fi
}

# ============================================================================
# UNINSTALL
# ============================================================================

uninstall() {
    step "Uninstalling rsync-bidirectional-sync"

    # Remove scripts from BIN_DIR
    local files=("sync-lib.sh" "sync-manifest.sh" "sync-engine.sh" "sync-client" "sync-setup-ssh")

    for f in "${files[@]}"; do
        local target="${BIN_DIR}/${f}"
        if [[ -f "$target" ]] || [[ -L "$target" ]]; then
            rm -f "$target"
            info "Removed: $target"
        fi
    done

    # Remove legacy install dir if it exists
    local legacy_dir="$HOME/.local/share/rsync-sync"
    if [[ -d "$legacy_dir" ]]; then
        rm -rf "$legacy_dir"
        info "Removed legacy dir: $legacy_dir"
    fi

    # Remove completion
    local completion="${HOME}/.local/share/bash-completion/completions/sync-client"
    if [[ -f "$completion" ]]; then
        rm -f "$completion"
        info "Removed: $completion"
    fi

    warn "Configuration preserved at: $CONFIG_DIR"
    warn "To remove config and state: rm -rf $CONFIG_DIR"
    info "Uninstall complete"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    echo ""
    echo -e "${BOLD}rsync-bidirectional-sync Installer${RESET}"
    echo -e "${BOLD}====================================${RESET}"
    echo ""

    # Handle uninstall flag
    if [[ "${1:-}" == "--uninstall" ]]; then
        uninstall
        exit 0
    fi

    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        echo "Usage: install.sh [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --uninstall    Remove installed files"
        echo "  --help, -h     Show this help"
        echo ""
        echo "Installs to:"
        echo "  Scripts:  $BIN_DIR/"
        echo "  Config:   $CONFIG_DIR/config"
        echo "  State:    $CONFIG_DIR/state/"
        echo "  Logs:     $CONFIG_DIR/logs/"
        exit 0
    fi

    # Run installation steps
    check_requirements || exit 1
    create_directories
    install_files
    setup_config
    setup_path
    setup_completion

    # Final message
    step "Installation complete!"
    echo ""
    echo -e "  ${BOLD}Next steps:${RESET}"
    echo -e "  1. Run the guided SSH setup wizard:"
    echo -e "     ${BLUE}\$ sync-setup-ssh${RESET}"
    echo ""
    echo -e "  2. Edit sync paths in your configuration:"
    echo -e "     ${BLUE}\$ nano ~/.config/rsync-sync/config${RESET}"
    echo ""
    echo -e "  3. Test with a dry run:"
    echo -e "     ${BLUE}\$ sync-client --dry-run${RESET}"
    echo ""
    echo -e "  4. Run your first sync:"
    echo -e "     ${BLUE}\$ sync-client${RESET}"
    echo ""
    echo -e "  5. Check status anytime:"
    echo -e "     ${BLUE}\$ sync-client status${RESET}"
    echo ""
    echo -e "  For help: ${BLUE}sync-client --help${RESET}"
    echo ""
}

main "$@"
