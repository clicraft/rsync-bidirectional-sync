# rsync-bidirectional-sync

Robust bidirectional file synchronization for Linux and WSL using rsync with manifest-based change tracking, conflict resolution, and safe deletion propagation.

## How It Works

Unlike simple "pull then push" approaches, this tool uses a **three-way diff** algorithm:

1. **Manifest tracking** - After each sync, a snapshot of all file metadata (path, mtime, size) is saved
2. **Change detection** - On the next run, both local and remote are compared against the previous manifest
3. **Smart classification** - Each file is classified as: new, modified, deleted, or unchanged on each side
4. **Conflict resolution** - Files modified on both sides are handled according to your configured strategy
5. **Safe deletions** - Deletions are only propagated when the file existed in the previous manifest (so new files are never accidentally deleted)
6. **Per-directory exclusions** - `.syncignore` files (rsync filter syntax) let you exclude files from sync on a per-directory basis, with rules inherited by subdirectories

## Quick Start

```bash
# 1. Install
curl -fsSL https://raw.githubusercontent.com/INS-JVidal/rsync-bidirectional-sync/main/install-remote.sh | bash

# 2. Configure
nano ~/.config/rsync-sync/config

# 3. (Optional) Create .syncignore
sync-client init-syncignore python

# 4. Set up SSH keys
ssh-copy-id user@remote-host

# 5. Test
sync-client --dry-run

# 6. Sync
sync-client
```

## Installation

### Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/INS-JVidal/rsync-bidirectional-sync/main/install-remote.sh | bash
```

### Install from source

```bash
git clone https://github.com/INS-JVidal/rsync-bidirectional-sync.git
cd rsync-bidirectional-sync
./install.sh
```

The installer:
- Copies scripts directly to `~/.local/bin/`
- Injects the git version (e.g., `v1.0.0-3-gabcdef`) into installed scripts
- Creates configuration directory at `~/.config/rsync-sync/`
- Sets up bash completion
- Adds `~/.local/bin` to PATH if needed

### Requirements

- Bash 4.0+
- rsync (on both local and remote)
- OpenSSH client (with key-based auth recommended)
- Standard Unix tools: find, stat, sort, md5sum

### Uninstall

```bash
# If installed via curl
curl -fsSL https://raw.githubusercontent.com/INS-JVidal/rsync-bidirectional-sync/main/install-remote.sh | bash -s -- --uninstall

# If installed from source
./install.sh --uninstall
```

## Configuration

Default config: `~/.config/rsync-sync/config`

```bash
# Remote connection
REMOTE_USER="user"
REMOTE_HOST="192.168.1.100"
REMOTE_PORT=22

# Sync paths
LOCAL_DIR="/home/user/projects"
REMOTE_DIR="/home/user/projects"

# Conflict resolution: newest, skip, backup, local, remote
CONFLICT_STRATEGY="newest"

# Propagate deletions to the other side
PROPAGATE_DELETES=true

# Back up files before overwriting during conflicts
BACKUP_ON_CONFLICT=true
```

See `config.example` for all available options.

### Profiles

Create named profiles for different sync targets:

```bash
# Create profile
cp ~/.config/rsync-sync/config ~/.config/rsync-sync/profiles/work.conf
nano ~/.config/rsync-sync/profiles/work.conf

# Use profile
sync-client -p work sync
```

Each profile maintains its own sync state, lock file, and logs.

### `.syncignore`

Exclude files from sync on a per-directory basis using `.syncignore` files with rsync filter syntax.

**Quick start:**

```bash
# Generate a .syncignore from a built-in template
sync-client init-syncignore python

# Edit to taste
nano .syncignore

# Verify what's excluded
sync-client --show-exclusions

# Sync as usual
sync-client
```

**Syntax:**

| Pattern | Meaning |
|---------|---------|
| `*.log` | Exclude files matching pattern |
| `+ important.log` | Force-include (override previous excludes) |
| `build/` | Exclude directory only |
| `# comment` | Comment line |

> **Note:** Unlike `.gitignore`, include syntax uses `+ pattern` not `!pattern`.

**Built-in templates:** `default`, `python`, `java`, `javascript`, `php`, `teaching`

**Configuration toggles:**

```bash
USE_SYNCIGNORE=true                # Enable .syncignore support (default: true)
SYNCIGNORE_FILENAME=".syncignore"  # Custom filename (default: .syncignore)
```

`.syncignore` files are synced to both sides by default so exclusion rules stay consistent.

## Usage

```bash
# Basic sync
sync-client

# Check what would change
sync-client status

# Preview without making changes
sync-client --dry-run

# Verbose output
sync-client --verbose

# Use a profile
sync-client --profile work

# Reset sync state (next sync = first sync)
sync-client reset-state

# Combine options
sync-client -p work -v -n
```

### Commands

| Command | Description |
|---------|-------------|
| `sync` | Run bidirectional sync (default) |
| `status` | Show pending changes without syncing |
| `reset-state` | Clear manifest, treat next sync as first sync |
| `show-exclusions` | Show all active exclusion rules |
| `init-syncignore [TPL]` | Create `.syncignore` from template |

### Options

| Option | Description |
|--------|-------------|
| `-p, --profile NAME` | Use named profile |
| `-n, --dry-run` | No changes, just show what would happen |
| `-v, --verbose` | DEBUG-level logging |
| `-f, --force` | Skip confirmation prompts |
| `-c, --config FILE` | Use specific config file |
| `--show-exclusions` | Show all active exclusion rules and exit |
| `--init-syncignore [TPL]` | Create `.syncignore` (templates: default, python, java, javascript, php, teaching) |
| `-h, --help` | Show help |
| `-V, --version` | Show version |

## Conflict Resolution Strategies

| Strategy | Behavior |
|----------|----------|
| `newest` | Keep the version with the most recent mtime (default) |
| `skip` | Leave both versions untouched, report the conflict |
| `backup` | Back up both versions, then apply newest |
| `local` | Always prefer the local version |
| `remote` | Always prefer the remote version |

## Safety Features

- **Lock files** - Prevents concurrent sync runs (with stale lock detection)
- **Signal handling** - Clean shutdown on Ctrl+C or SIGTERM
- **Manifest-based deletions** - Only propagates intentional deletes
- **Backup on conflict** - Optional backup before overwriting
- **Dry-run mode** - Preview all changes safely
- **Partial transfer resume** - rsync `--partial` flag for interrupted transfers
- **`.syncignore` delete protection** - Files matching `.syncignore` rules are protected from deletion propagation
- **State preservation on error** - Manifest only saved after full success
- **Retry logic** - Configurable retries with backoff for network issues
- **Version mismatch detection** - Pre-flight checks warn if local and remote run different versions (cached daily)

## Security

### SSH host key verification (recommended hardening)

By default the tool connects with `StrictHostKeyChecking=accept-new`, which
**automatically trusts a host the first time it is seen**. This keeps first-time
setup frictionless, but it means a machine-in-the-middle present during that
first connection (e.g. via DNS or ARP spoofing) can have its rogue host key
silently accepted. From then on it controls the remote manifest, the
transferred files, and remote command execution.

To close this window, pin the remote host key **before** your first sync and
switch SSH to strict checking:

```bash
# 1. Record the real remote host key (run on a trusted network)
ssh-keyscan -p 22 -H remote-host >> ~/.ssh/known_hosts

# 2. Verify the fingerprint out-of-band against the remote machine:
#    on the remote, run:  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
#    and confirm it matches what ssh-keyscan recorded.

# 3. Force strict checking for this host in ~/.ssh/config
cat >> ~/.ssh/config <<'EOF'
Host remote-host
    StrictHostKeyChecking yes
EOF
```

With the key pinned and `StrictHostKeyChecking yes`, any future host-key change
(a real MITM, or a re-imaged server) causes the connection to **fail loudly**
instead of being trusted silently.

### Configuration values are trusted code

Config and profile files are **sourced as Bash**, so anything in them runs with
your privileges. Keep them private (`chmod 600`) and never sync a config file
from an untrusted source. Connection-related values (`REMOTE_USER`,
`REMOTE_HOST`, `REMOTE_DIR`, `SSH_IDENTITY`, `BACKUP_DIR`, `EXCLUDE_PATTERNS`)
are additionally validated at startup and rejected if they contain shell
metacharacters, so a templated or shared config cannot smuggle commands into the
SSH/rsync calls. File names with embedded shell metacharacters are also quoted
safely before reaching any remote command.

## File Structure

```
~/.config/rsync-sync/
├── config                    # Default configuration
├── profiles/
│   └── work.conf             # Named profile configs
├── state/
│   ├── default.manifest      # Sync state for default profile
│   └── default.lock          # Lock file
└── logs/
    └── sync-default-*.log    # Sync logs
```

## Automation

### Cron

```bash
# Sync every 30 minutes
*/30 * * * * $HOME/.local/bin/sync-client 2>&1 >> /tmp/sync-cron.log
```

### Systemd Timer

See `docs/USAGE.md` for systemd timer setup instructions.

## Documentation

- [Usage Guide](docs/USAGE.md) - Detailed usage examples and automation
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions

## License

MIT
