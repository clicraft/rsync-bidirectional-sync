#!/usr/bin/env bash
# setup-ssh.sh - Guided SSH key setup for rsync-bidirectional-sync
# Walks the user through generating keys and authorizing both sides
# for passwordless bidirectional sync.

set -euo pipefail

# ============================================================================
# COLORS & HELPERS
# ============================================================================

if [[ -t 1 ]]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RESET='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''
fi

info()    { printf "${C_GREEN}  [OK]${C_RESET}    %s\n" "$*"; }
warn()    { printf "${C_YELLOW}  [WARN]${C_RESET}  %s\n" "$*"; }
error()   { printf "${C_RED}  [ERROR]${C_RESET} %s\n" "$*" >&2; }
# Strip control bytes from remote-supplied strings before display, so a
# malicious/compromised remote can't inject terminal escape sequences.
sanitize() { printf -v "$1" '%s' "${2//[[:cntrl:]]/?}"; }
step()    { printf "\n${C_BOLD}${C_BLUE}  STEP %s: %s${C_RESET}\n\n" "$1" "$2"; }
banner()  { printf "\n${C_BOLD}%s${C_RESET}\n" "$*"; }
dim()     { printf "${C_DIM}%s${C_RESET}" "$*"; }
ask()     {
    local prompt="$1" default="${2:-}"
    if [[ -n "$default" ]]; then
        printf "  ${C_CYAN}%s${C_RESET} [${C_DIM}%s${C_RESET}]: " "$prompt" "$default"
    else
        printf "  ${C_CYAN}%s${C_RESET}: " "$prompt"
    fi
    read -r REPLY
    [[ -z "$REPLY" ]] && REPLY="$default"
}

ask_yn() {
    local prompt="$1" default="${2:-y}"
    local hint="Y/n"
    [[ "$default" == "n" ]] && hint="y/N"
    printf "  ${C_CYAN}%s${C_RESET} [%s]: " "$prompt" "$hint"
    read -r REPLY
    [[ -z "$REPLY" ]] && REPLY="$default"
    [[ "${REPLY,,}" == "y" || "${REPLY,,}" == "yes" ]]
}

separator() {
    echo ""
    printf "  ${C_DIM}%.0s─${C_RESET}" {1..50}
    echo ""
}

press_enter() {
    printf "\n  ${C_DIM}Press Enter to continue...${C_RESET}"
    read -r
}

# ============================================================================
# CONFIG LOADING
# ============================================================================

CONFIG_DIR="$HOME/.config/rsync-sync"

load_config_values() {
    local config_file="${CONFIG_DIR}/config"

    REMOTE_USER=""
    REMOTE_HOST=""
    REMOTE_PORT=22
    SSH_IDENTITY=""

    if [[ -f "$config_file" ]]; then
        # Source config in a subshell to extract values safely
        eval "$(grep -E '^(REMOTE_USER|REMOTE_HOST|REMOTE_PORT|SSH_IDENTITY)=' "$config_file" 2>/dev/null)" || true
    fi
}

# ============================================================================
# SSH KEY MANAGEMENT
# ============================================================================

detect_local_keys() {
    local keys=()
    for keyfile in "$HOME/.ssh"/id_*.pub; do
        [[ -f "$keyfile" ]] && keys+=("${keyfile%.pub}")
    done
    echo "${keys[@]:-}"
}

display_local_keys() {
    local keys
    keys=$(detect_local_keys)

    if [[ -z "$keys" ]]; then
        warn "No SSH keys found in ~/.ssh/"
        return 1
    fi

    info "Found existing SSH key(s):"
    for key in $keys; do
        local type
        type=$(ssh-keygen -l -f "$key" 2>/dev/null | awk '{print $4}' || echo "unknown")
        local bits
        bits=$(ssh-keygen -l -f "$key" 2>/dev/null | awk '{print $1}' || echo "?")
        printf "       ${C_DIM}%-40s${C_RESET} %s (%s bits)\n" "$key" "$type" "$bits"
    done
    return 0
}

generate_ssh_key() {
    local key_type="$1"
    local key_path="$HOME/.ssh/id_${key_type}"

    if [[ -f "$key_path" ]]; then
        warn "Key already exists: $key_path"
        if ! ask_yn "Overwrite it?" "n"; then
            info "Keeping existing key: $key_path"
            SELECTED_KEY="$key_path"
            return 0
        fi
    fi

    echo ""
    info "Generating $key_type key..."
    printf "  ${C_DIM}You can set a passphrase for extra security, or leave empty for no passphrase.${C_RESET}\n"
    echo ""

    case "$key_type" in
        ed25519)
            ssh-keygen -t ed25519 -f "$key_path" -C "${USER}@$(hostname)-sync"
            ;;
        rsa)
            ssh-keygen -t rsa -b 4096 -f "$key_path" -C "${USER}@$(hostname)-sync"
            ;;
    esac

    if [[ -f "$key_path" ]]; then
        info "Key generated: $key_path"
        SELECTED_KEY="$key_path"
    else
        error "Key generation failed"
        return 1
    fi
}

select_or_create_key() {
    local existing_keys
    existing_keys=$(detect_local_keys)

    if [[ -n "$existing_keys" ]]; then
        echo ""
        display_local_keys
        echo ""

        if ask_yn "Use an existing key?" "y"; then
            # If multiple keys, let user pick
            local keys_arr=($existing_keys)
            if (( ${#keys_arr[@]} == 1 )); then
                SELECTED_KEY="${keys_arr[0]}"
                info "Using: $SELECTED_KEY"
                return 0
            fi

            echo ""
            local i=1
            for key in "${keys_arr[@]}"; do
                printf "    ${C_BOLD}%d)${C_RESET} %s\n" "$i" "$key"
                (( i++ ))
            done
            echo ""
            ask "Select key number" "1"
            local idx=$((REPLY - 1))
            if (( idx >= 0 && idx < ${#keys_arr[@]} )); then
                SELECTED_KEY="${keys_arr[$idx]}"
                info "Using: $SELECTED_KEY"
                return 0
            else
                error "Invalid selection"
                return 1
            fi
        fi
    fi

    # Generate new key
    echo ""
    printf "    ${C_BOLD}1)${C_RESET} ed25519  ${C_DIM}(recommended - modern, fast, secure)${C_RESET}\n"
    printf "    ${C_BOLD}2)${C_RESET} rsa      ${C_DIM}(wider compatibility, 4096-bit)${C_RESET}\n"
    echo ""
    ask "Select key type" "1"

    case "$REPLY" in
        1|ed25519) generate_ssh_key "ed25519" ;;
        2|rsa)     generate_ssh_key "rsa" ;;
        *)         error "Invalid selection"; return 1 ;;
    esac
}

# ============================================================================
# REMOTE OPERATIONS
# ============================================================================

test_ssh_password() {
    local user="$1" host="$2" port="$3"

    # Test if we can reach the host at all
    if ! timeout 5 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        error "Cannot reach $host on port $port"
        error "Ensure the remote machine is on, SSH server is running, and no firewall is blocking"
        return 1
    fi

    info "Port $port is open on $host"
    return 0
}

test_ssh_key_auth() {
    local user="$1" host="$2" port="$3" key="$4"

    if ssh -o ConnectTimeout=10 \
           -o BatchMode=yes \
           -o StrictHostKeyChecking=accept-new \
           -i "$key" \
           -p "$port" \
           "${user}@${host}" "echo ok" &>/dev/null; then
        return 0
    fi
    return 1
}

copy_key_to_remote() {
    local user="$1" host="$2" port="$3" key="$4"

    info "Copying public key to ${user}@${host}..."
    echo ""
    printf "  ${C_YELLOW}You will be prompted for the password of ${user}@${host}${C_RESET}\n"
    printf "  ${C_DIM}(This is the last time you'll need the password)${C_RESET}\n"
    echo ""

    if ssh-copy-id -i "${key}.pub" -p "$port" "${user}@${host}"; then
        info "Key copied successfully!"
        return 0
    else
        error "Failed to copy key"
        echo ""
        printf "  ${C_YELLOW}Manual alternative:${C_RESET}\n"
        printf "  ${C_DIM}Copy this line and paste it into ${user}@${host}:~/.ssh/authorized_keys${C_RESET}\n"
        echo ""
        printf "  ${C_CYAN}"
        cat "${key}.pub"
        printf "${C_RESET}\n"
        return 1
    fi
}

setup_remote_ssh_server() {
    local user="$1" host="$2" port="$3" key="$4"

    echo ""
    printf "  ${C_DIM}Checking remote SSH server configuration...${C_RESET}\n"

    # Check if PubkeyAuthentication is enabled
    local remote_sshd_config
    remote_sshd_config=$(ssh -i "$key" -p "$port" "${user}@${host}" \
        "cat /etc/ssh/sshd_config 2>/dev/null | grep -i '^PubkeyAuthentication' || echo 'PubkeyAuthentication yes'" 2>/dev/null || echo "")

    if echo "$remote_sshd_config" | grep -qi "no"; then
        warn "PubkeyAuthentication is disabled on the remote server"
        echo ""
        printf "  ${C_YELLOW}To fix, run on the remote machine:${C_RESET}\n"
        printf "  ${C_CYAN}  sudo sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config${C_RESET}\n"
        printf "  ${C_CYAN}  sudo systemctl restart sshd${C_RESET}\n"
    else
        info "PubkeyAuthentication is enabled on remote"
    fi
}

# ============================================================================
# REVERSE DIRECTION SETUP
# ============================================================================

setup_reverse_direction() {
    local user="$1" host="$2" port="$3" key="$4"
    local local_user local_host

    local_user=$(whoami)
    local_host=$(hostname)

    banner "  Setting up reverse direction (${user}@${host} -> ${local_user}@${local_host})"
    echo ""
    printf "  ${C_DIM}For bidirectional sync, the remote machine also needs to connect back.${C_RESET}\n"
    printf "  ${C_DIM}This step generates an SSH key on the remote and authorizes it locally.${C_RESET}\n"
    echo ""

    # Check if local SSH server is running
    if ! timeout 3 bash -c "echo >/dev/tcp/localhost/22" 2>/dev/null; then
        warn "No SSH server detected on this machine (port 22)"
        echo ""
        printf "  ${C_YELLOW}To install and start SSH server:${C_RESET}\n"
        printf "  ${C_CYAN}  sudo apt install openssh-server${C_RESET}\n"
        printf "  ${C_CYAN}  sudo systemctl enable --now ssh${C_RESET}\n"
        echo ""

        if ! ask_yn "Continue anyway? (you can set up the SSH server later)" "y"; then
            return 0
        fi
    else
        info "Local SSH server is running"
    fi

    # Get the IP/hostname the remote should use to reach us
    echo ""
    local default_ip
    default_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    ask "IP/hostname the remote machine should use to reach THIS machine" "$default_ip"
    local local_reachable_host="$REPLY"

    ask "SSH port on this machine" "22"
    local local_port="$REPLY"

    echo ""
    info "Generating SSH key on remote and setting up authorization..."
    echo ""

    # Generate key on remote if it doesn't exist, and get the public key
    local remote_pubkey
    remote_pubkey=$(ssh -i "$key" -p "$port" "${user}@${host}" bash -s <<'REMOTE_KEYGEN'
set -euo pipefail
KEY_PATH="$HOME/.ssh/id_ed25519"
if [ ! -f "$KEY_PATH" ]; then
    ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "${USER}@$(hostname)-sync" >/dev/null 2>&1
    echo "GENERATED"
fi
cat "${KEY_PATH}.pub"
REMOTE_KEYGEN
    )

    if [[ -z "$remote_pubkey" ]]; then
        error "Failed to get public key from remote"
        return 1
    fi

    # Check if the first line says GENERATED
    if echo "$remote_pubkey" | head -1 | grep -q "GENERATED"; then
        info "Generated new SSH key on remote"
        remote_pubkey=$(echo "$remote_pubkey" | tail -1)
    else
        info "Using existing SSH key from remote"
        remote_pubkey=$(echo "$remote_pubkey" | tail -1)
    fi

    # Add remote's public key to local authorized_keys
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"

    if grep -qF "$remote_pubkey" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
        info "Remote key is already authorized locally"
    else
        echo "$remote_pubkey" >> "$HOME/.ssh/authorized_keys"
        info "Remote key added to local authorized_keys"
    fi

    # Test reverse connection
    echo ""
    printf "  ${C_DIM}Testing reverse connection: ${user}@${host} -> ${local_user}@${local_reachable_host}:${local_port}${C_RESET}\n"

    local reverse_ok
    reverse_ok=$(ssh -i "$key" -p "$port" "${user}@${host}" \
        "ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p $local_port ${local_user}@${local_reachable_host} 'echo ok'" 2>/dev/null || echo "fail")

    if [[ "$reverse_ok" == "ok" ]]; then
        info "Reverse SSH connection works!"
    else
        warn "Reverse connection test failed"
        echo ""
        printf "  ${C_YELLOW}Possible causes:${C_RESET}\n"
        printf "    - SSH server not running on this machine\n"
        printf "    - Firewall blocking port $local_port\n"
        printf "    - Wrong IP address (${local_reachable_host} not reachable from remote)\n"
        printf "    - WSL networking requires port forwarding\n"
        echo ""
        printf "  ${C_DIM}You can fix this later and test with:${C_RESET}\n"
        printf "  ${C_CYAN}  ssh -p $port ${user}@${host} \"ssh -p $local_port ${local_user}@${local_reachable_host} 'echo ok'\"${C_RESET}\n"
    fi
}

# ============================================================================
# UPDATE CONFIG
# ============================================================================

update_sync_config() {
    local user="$1" host="$2" port="$3" key="$4"
    local config_file="${CONFIG_DIR}/config"

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    if ! ask_yn "Update sync config ($config_file) with these connection details?" "y"; then
        return 0
    fi

    # Update values in config file
    sed -i "s|^REMOTE_USER=.*|REMOTE_USER=\"$user\"|" "$config_file"
    sed -i "s|^REMOTE_HOST=.*|REMOTE_HOST=\"$host\"|" "$config_file"
    sed -i "s|^REMOTE_PORT=.*|REMOTE_PORT=$port|" "$config_file"

    if [[ "$key" != "$HOME/.ssh/id_ed25519" ]] && [[ "$key" != "$HOME/.ssh/id_rsa" ]]; then
        sed -i "s|^SSH_IDENTITY=.*|SSH_IDENTITY=\"$key\"|" "$config_file"
    fi

    info "Config updated: $config_file"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    banner "  ╔══════════════════════════════════════════════╗"
    banner "  ║   SSH Key Setup for Bidirectional Sync       ║"
    banner "  ╚══════════════════════════════════════════════╝"
    echo ""
    printf "  ${C_DIM}This wizard will guide you through setting up passwordless SSH${C_RESET}\n"
    printf "  ${C_DIM}authentication between this machine and a remote machine.${C_RESET}\n"
    printf "  ${C_DIM}${C_RESET}\n"
    printf "  ${C_DIM}What we'll do:${C_RESET}\n"
    printf "  ${C_DIM}  1. Create/select an SSH key on this machine${C_RESET}\n"
    printf "  ${C_DIM}  2. Copy it to the remote machine${C_RESET}\n"
    printf "  ${C_DIM}  3. Test the connection${C_RESET}\n"
    printf "  ${C_DIM}  4. (Optional) Set up the reverse direction${C_RESET}\n"
    printf "  ${C_DIM}  5. Update your sync config${C_RESET}\n"

    # Load existing config values as defaults
    load_config_values

    # ── STEP 1: Remote details ──────────────────────────────────────────

    step "1" "Remote machine details"

    ask "Remote username" "${REMOTE_USER:-$USER}"
    local remote_user="$REPLY"

    ask "Remote hostname or IP" "${REMOTE_HOST:-}"
    local remote_host="$REPLY"

    if [[ -z "$remote_host" ]]; then
        error "Hostname is required"
        exit 1
    fi

    ask "SSH port" "${REMOTE_PORT:-22}"
    local remote_port="$REPLY"

    # Validate before these values reach a `bash -c ".../dev/tcp/$host/$port"`
    # connectivity probe and a `sed` that writes them into the config file
    # (which is later sourced as bash). Without this, a value like
    # '22;touch ~/pwned;#' would execute now and/or persist as a backdoor that
    # runs on every future sync. Mirrors sync-lib.sh validate_config().
    if ! [[ "$remote_user" =~ ^[a-zA-Z0-9_][a-zA-Z0-9._-]*$ ]]; then
        error "Invalid username (letters/digits/dot/dash/underscore, no leading dash): $remote_user"
        exit 1
    fi
    if ! [[ "$remote_host" =~ ^[a-zA-Z0-9_]([a-zA-Z0-9._:-]*)?$ ]]; then
        error "Invalid hostname/IP (no leading dash or shell metacharacters): $remote_host"
        exit 1
    fi
    if ! [[ "$remote_port" =~ ^[0-9]+$ ]]; then
        error "SSH port must be a number: $remote_port"
        exit 1
    fi

    separator

    printf "  ${C_BOLD}Connection:${C_RESET} ${remote_user}@${remote_host}:${remote_port}\n"

    # ── STEP 2: Check connectivity ──────────────────────────────────────

    step "2" "Check connectivity"

    if ! test_ssh_password "$remote_user" "$remote_host" "$remote_port"; then
        echo ""
        error "Cannot reach the remote machine. Please check:"
        printf "    - Is the machine powered on?\n"
        printf "    - Is SSH server running? ${C_CYAN}sudo systemctl start ssh${C_RESET}\n"
        printf "    - Is the firewall open? ${C_CYAN}sudo ufw allow $remote_port${C_RESET}\n"
        printf "    - Is the IP/hostname correct?\n"
        exit 1
    fi

    # Check if key auth already works
    local existing_keys
    existing_keys=$(detect_local_keys)
    local already_authed=0

    for k in $existing_keys; do
        if test_ssh_key_auth "$remote_user" "$remote_host" "$remote_port" "$k"; then
            info "Key auth already works with: $k"
            SELECTED_KEY="$k"
            already_authed=1
            break
        fi
    done

    # ── STEP 3: SSH key ─────────────────────────────────────────────────

    step "3" "SSH key (this machine -> remote)"

    if (( already_authed )); then
        info "SSH key authentication is already configured!"
        info "Key: $SELECTED_KEY"

        if ! ask_yn "Skip to next step?" "y"; then
            already_authed=0
        fi
    fi

    if (( !already_authed )); then
        SELECTED_KEY=""
        select_or_create_key

        if [[ -z "${SELECTED_KEY:-}" ]]; then
            error "No key selected"
            exit 1
        fi

        separator

        # Copy key to remote
        step "3b" "Copy key to remote"

        copy_key_to_remote "$remote_user" "$remote_host" "$remote_port" "$SELECTED_KEY"
    fi

    # ── STEP 4: Test ────────────────────────────────────────────────────

    step "4" "Test SSH key authentication"

    printf "  ${C_DIM}Testing: ssh -i ${SELECTED_KEY} -p ${remote_port} ${remote_user}@${remote_host}${C_RESET}\n"
    echo ""

    if test_ssh_key_auth "$remote_user" "$remote_host" "$remote_port" "$SELECTED_KEY"; then
        info "Passwordless SSH works!"

        # Also verify rsync is available
        local rsync_check
        rsync_check=$(ssh -o BatchMode=yes -i "$SELECTED_KEY" -p "$remote_port" \
            "${remote_user}@${remote_host}" "command -v rsync && rsync --version 2>/dev/null | head -1" 2>/dev/null || echo "")

        if [[ -n "$rsync_check" ]]; then
            local rsync_ver
            sanitize rsync_ver "$(echo "$rsync_check" | tail -1)"
            info "rsync is available on remote: $rsync_ver"
        else
            warn "rsync not found on remote. Install it:"
            printf "    ${C_CYAN}ssh -p $remote_port ${remote_user}@${remote_host} 'sudo apt install rsync'${C_RESET}\n"
        fi
    else
        error "Key authentication failed!"
        echo ""
        printf "  ${C_YELLOW}Troubleshooting:${C_RESET}\n"
        printf "    - Check remote ~/.ssh/authorized_keys has your public key\n"
        printf "    - Check remote permissions: ~/.ssh (700), authorized_keys (600)\n"
        printf "    - Check /var/log/auth.log on remote for details\n"
        printf "    - Ensure PubkeyAuthentication is enabled in /etc/ssh/sshd_config\n"
    fi

    # ── STEP 5: Reverse direction ───────────────────────────────────────

    step "5" "Reverse direction (optional)"

    printf "  ${C_DIM}For the remote machine to generate manifests and connect back,${C_RESET}\n"
    printf "  ${C_DIM}it also needs SSH access to this machine.${C_RESET}\n"
    printf "  ${C_DIM}(This is optional - the sync tool connects outward by default.)${C_RESET}\n"
    echo ""

    if ask_yn "Set up reverse SSH (remote -> this machine)?" "n"; then
        setup_reverse_direction "$remote_user" "$remote_host" "$remote_port" "$SELECTED_KEY"
    else
        info "Skipping reverse direction setup"
    fi

    # ── STEP 6: Update config ───────────────────────────────────────────

    step "6" "Update sync configuration"

    update_sync_config "$remote_user" "$remote_host" "$remote_port" "$SELECTED_KEY"

    # ── Done ────────────────────────────────────────────────────────────

    echo ""
    banner "  ╔══════════════════════════════════════════════╗"
    banner "  ║   Setup Complete!                            ║"
    banner "  ╚══════════════════════════════════════════════╝"
    echo ""
    printf "  ${C_BOLD}Summary:${C_RESET}\n"
    printf "    Local key:   ${C_CYAN}%s${C_RESET}\n" "$SELECTED_KEY"
    printf "    Remote:      ${C_CYAN}%s@%s:%s${C_RESET}\n" "$remote_user" "$remote_host" "$remote_port"
    echo ""
    printf "  ${C_BOLD}Next steps:${C_RESET}\n"
    printf "    1. Edit sync paths in config:  ${C_CYAN}nano ~/.config/rsync-sync/config${C_RESET}\n"
    printf "    2. Test with dry run:          ${C_CYAN}sync-client --dry-run${C_RESET}\n"
    printf "    3. Run first sync:             ${C_CYAN}sync-client${C_RESET}\n"
    echo ""
}

main "$@"
