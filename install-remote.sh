#!/usr/bin/env bash
# install-remote.sh - Remote installer for rsync-bidirectional-sync
# Usage: curl -fsSL https://raw.githubusercontent.com/INS-JVidal/rsync-bidirectional-sync/main/install-remote.sh | bash
#
# Supports: --uninstall flag to remove installed files

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
BRANCH="${BRANCH:-main}"
BASE_URL="https://raw.githubusercontent.com/INS-JVidal/rsync-bidirectional-sync/${BRANCH}"

# Scripts to download from bin/
SCRIPTS=("sync-lib.sh" "sync-manifest.sh" "sync-engine.sh" "sync-client.sh" "setup-ssh.sh")

# Entry points that get renamed (source -> target)
declare -A ENTRY_POINTS=(
    ["sync-client.sh"]="sync-client"
    ["setup-ssh.sh"]="sync-setup-ssh"
)

# ============================================================================
# REQUIREMENT CHECKS
# ============================================================================

check_requirements() {
    step "Checking requirements"

    local errors=0

    if (( BASH_VERSINFO[0] >= 4 )); then
        info "Bash ${BASH_VERSION} (4.0+ required)"
    else
        error "Bash 4.0+ required (current: ${BASH_VERSION})"
        errors=$(( errors + 1 ))
    fi

    if command -v rsync &>/dev/null; then
        info "rsync found"
    else
        error "rsync is not installed. Install: sudo apt install rsync"
        errors=$(( errors + 1 ))
    fi

    if command -v ssh &>/dev/null; then
        info "ssh found"
    else
        error "ssh is not installed. Install: sudo apt install openssh-client"
        errors=$(( errors + 1 ))
    fi

    if ! command -v curl &>/dev/null; then
        error "curl is required for remote install"
        errors=$(( errors + 1 ))
    fi

    if (( errors > 0 )); then
        error "Requirements check failed with $errors error(s)"
        return 1
    fi

    info "All requirements satisfied"
}

# ============================================================================
# DOWNLOAD & INSTALL
# ============================================================================

install_scripts() {
    step "Downloading and installing scripts"

    mkdir -p "$BIN_DIR"

    for script in "${SCRIPTS[@]}"; do
        local url="${BASE_URL}/bin/${script}"
        local target="${BIN_DIR}/${script}"

        # Rename entry points
        if [[ -n "${ENTRY_POINTS[$script]:-}" ]]; then
            target="${BIN_DIR}/${ENTRY_POINTS[$script]}"
        fi

        info "Downloading: $script"
        if ! curl -fsSL "$url" -o "$target"; then
            error "Failed to download: $url"
            return 1
        fi
        chmod +x "$target"
        info "Installed: $target"
    done

    # Inject version into sync-lib.sh (use short commit SHA from GitHub API, fall back to branch name)
    local version
    local commit_sha
    commit_sha=$(curl -fsSL "https://api.github.com/repos/INS-JVidal/rsync-bidirectional-sync/commits/${BRANCH}" 2>/dev/null \
        | grep -m1 '"sha"' | cut -d'"' -f4 | cut -c1-7) || true
    if [[ -n "$commit_sha" ]]; then
        version="${BRANCH}-g${commit_sha}"
    else
        version="${BRANCH}"
    fi
    # Constrain to a safe charset: $BRANCH is user-supplied and would otherwise
    # break or inject into this sed replacement (the result is sourced on every
    # run).
    if ! [[ "$version" =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "Version string '$version' has unexpected characters; using 'unknown'"
        version="unknown"
    fi
    sed -i "s/^readonly SYNC_VERSION=.*/readonly SYNC_VERSION=\"$version\"/" "$BIN_DIR/sync-lib.sh"
    info "Version: $version"
}

# ============================================================================
# CONFIGURATION SETUP
# ============================================================================

setup_config() {
    step "Setting up configuration"

    mkdir -p "$CONFIG_DIR" "$CONFIG_DIR/profiles" "$CONFIG_DIR/state" "$CONFIG_DIR/logs"

    local config_file="${CONFIG_DIR}/config"
    if [[ -f "$config_file" ]]; then
        info "Configuration already exists: $config_file"
    else
        if curl -fsSL "${BASE_URL}/config.example" -o "$config_file"; then
            chmod 600 "$config_file"
            info "Created: $config_file"
            warn "Edit this file with your remote connection details!"
        else
            warn "Could not download config.example"
        fi
    fi
}

# ============================================================================
# PATH SETUP
# ============================================================================

setup_path() {
    step "Setting up PATH"

    if echo "$PATH" | tr ':' '\n' | grep -q "^${BIN_DIR}$"; then
        info "$BIN_DIR is already in PATH"
        return 0
    fi

    local path_line="export PATH=\"\$HOME/.local/bin:\$PATH\""
    local shells_updated=0

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
    for script in "${SCRIPTS[@]}"; do
        local target="${BIN_DIR}/${script}"
        if [[ -n "${ENTRY_POINTS[$script]:-}" ]]; then
            target="${BIN_DIR}/${ENTRY_POINTS[$script]}"
        fi
        if [[ -f "$target" ]]; then
            rm -f "$target"
            info "Removed: $target"
        fi
    done

    # Remove completion
    local completion="${HOME}/.local/share/bash-completion/completions/sync-client"
    if [[ -f "$completion" ]]; then
        rm -f "$completion"
        info "Removed: $completion"
    fi

    # Clean up legacy install dir if it exists
    local legacy_dir="$HOME/.local/share/rsync-sync"
    if [[ -d "$legacy_dir" ]]; then
        rm -rf "$legacy_dir"
        info "Removed legacy dir: $legacy_dir"
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
    echo -e "${BOLD}rsync-bidirectional-sync Remote Installer${RESET}"
    echo -e "${BOLD}===========================================${RESET}"
    echo ""

    if [[ "${1:-}" == "--uninstall" ]]; then
        uninstall
        exit 0
    fi

    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        echo "Usage: install-remote.sh [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --uninstall    Remove installed files"
        echo "  --help, -h     Show this help"
        echo ""
        echo "Installs to:"
        echo "  Scripts:  $BIN_DIR/"
        echo "  Config:   $CONFIG_DIR/config"
        exit 0
    fi

    check_requirements || exit 1
    install_scripts || exit 1
    setup_config
    setup_path
    setup_completion

    step "Installation complete!"
    echo ""
    echo -e "  ${BOLD}Next steps:${RESET}"
    echo -e "  1. Edit your configuration:"
    echo -e "     ${BLUE}\$ nano ~/.config/rsync-sync/config${RESET}"
    echo ""
    echo -e "  2. (Optional) Set up SSH keys:"
    echo -e "     ${BLUE}\$ sync-setup-ssh${RESET}"
    echo ""
    echo -e "  3. Test with a dry run:"
    echo -e "     ${BLUE}\$ sync-client --dry-run${RESET}"
    echo ""
    echo -e "  For help: ${BLUE}sync-client --help${RESET}"
    echo ""
}

main "$@"
