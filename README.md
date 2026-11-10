# sysdash

**A comprehensive, privacy-aware, and highly customizable terminal dashboard for server statistics.**

<img width="2532" height="1185" alt="image" src="https://github.com/user-attachments/assets/0efe4ab5-f231-4342-9aee-1aedd7d2c74b" />


`sysdash` is a single-file Bash script that generates a beautiful, TUI-based dashboard of your system's hardware, network, and service status. It features smart process classification, a background collector for historical uptime tracking, and a powerful plugin system that supports high-framerate animations.

## Features

- **Hardware & Resource Monitoring**: CPU, RAM, Swap, Storage, and Network traffic with sparkline history graphs.
- **Smart Process Tracking**: Top processes by CPU usage, automatically classified with custom icons (Docker, Kubernetes, Web, Database, Minecraft, etc.).
- **Network Visibility**: Open ports, listening services, and inbound TCP connections categorized by origin (Internet, LAN, Local).
- **Historical Uptime Tracking**: A background collector monitors Internet connectivity and Power state (AC/Battery) transitions, logging outages and streaks.
- **Privacy-First Showcase Mode**: Redact sensitive information (IPs, usernames, hostnames) for safe public screenshots and streams.
- **Extensible Plugin API**: Install community plugins or write your own. Supports static panels and animated panels (up to 30 FPS in `live` mode).
- **Zero-Config Setup**: Automatically detects your OS and package manager, gracefully degrading or auto-installing missing optional dependencies.
- **Cross-Platform**: Works on Linux, macOS, and BSD.

---

## Quick Start

Download and run the script directly:

```bash
curl -O https://raw.githubusercontent.com/yourusername/sysdash/main/sysdash.sh
chmod +x sysdash.sh
./sysdash.sh
```

*Note: `sysdash` will attempt to install optional dependencies (like `tuptime`, `iproute2`, `procps`) if they are missing and you have sudo privileges.*

---

## Usage

```bash
./sysdash.sh                         # One-shot dashboard
./sysdash.sh watch [N]               # Live view, refresh every N seconds (default 5)
./sysdash.sh live                    # Live view, 0.5s data refresh; animated plugins up to 30 fps
./sysdash.sh showcase [FLAGS]        # Privacy-safe dashboard for screenshots
./sysdash.sh help [COMMAND]          # Show general or command-specific help
```

### Showcase Mode (Privacy)
When sharing screenshots or streaming, use `showcase` mode to hide sensitive data. By default, **all** identity fields are hidden. You can explicitly allow specific categories using flags:

```bash
./sysdash.sh showcase default live   # Shorthand for allowing safe defaults
```

**Available Flags:**
| Flag | Description | Flag | Description |
|------|-------------|------|-------------|
| `un` | Self username | `oun` | Other usernames |
| `sn` | Self system name | `osn` | Other system names |
| `g` | Self groups | `og` | Other groups |
| `s` | Self session | `os` | Other sessions |
| `em` / `oem` | Email | `pn` / `opn` | Phone |
| `eip` / `oeip` | External IP | `iip` | Internal IPs |
| `default` | *Shorthand for: `sn osn g og pn opn oeip iip`* | | |

---

## Plugin System

`sysdash` supports installable plugins for custom panels (e.g., OS logos, Tailscale, aria2, Jellyfin).

### Managing Plugins
```bash
./sysdash.sh i <URL>                 # Install a trusted plugin from a raw URL
./sysdash.sh list                    # List installed plugins and their states
./sysdash.sh toggle <NAME> [on|off]  # Enable or disable a plugin
./sysdash.sh reorder <NAME> up|down  # Change plugin display order
./sysdash.sh swap <NAME> <NAME>      # Swap two plugin positions
./sysdash.sh rm <NAME>               # Remove a plugin
./sysdash.sh update <NAME> <URL>     # Update an installed plugin
```

### API Keys
Plugins can securely store and use API keys (e.g., for external APIs). Keys are stored locally with `600` permissions.
```bash
./sysdash.sh keys list               # List stored key names (values are never printed)
./sysdash.sh keys set <KEY> <VALUE>  # Store an API key
./sysdash.sh keys get <KEY>          # Print a key's value
./sysdash.sh keys unset <KEY>        # Remove a key
```

### Plugin API
Create your own panels by defining metadata and a renderer function.
```bash
SYSDASH_PLUGIN_ID="my_plugin"
SYSDASH_PLUGIN_NAME="My Custom Panel"
SYSDASH_PLUGIN_SPAN="auto" # auto, half, or full width

sysdash_plugin_my_plugin() {
  local width=$1
  box_line "Hello from my plugin!"
}
```
*For animated plugins in `live` mode, define `SYSDASH_PLUGIN_FPS="30"` and a `sysdash_plugin_<id>_frame W N MS` function.*

---

## Background Collector

To track historical Internet and Power uptime, `sysdash` runs a lightweight background collector.
- **Internet**: Pings `1.1.1.1`, `8.8.8.8`, and `9.9.9.9` every 20 seconds to log online/offline transitions.
- **Power**: Reads `/sys/class/power_supply` (Linux) or `pmset` (macOS) to log AC/Battery transitions.

The collector starts automatically on the first run and installs a cron job to ensure it survives reboots.
```bash
./sysdash.sh no-daemon               # Run without starting/installing the collector
./sysdash.sh uninstall               # Stop collector, remove cron entries & history
```

---

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SYSDASH_ASCII=1` | Force ASCII-only characters (no Unicode box drawing). |
| `SYSDASH_EMOJI=1` | Use emoji icons for process classification instead of text badges. |
| `NO_COLOR=1` | Disable all ANSI colors. |
| `SYSDASH_COLS` / `SYSDASH_ROWS` | Override the detected terminal window size. |
| `SYSDASH_ARIA2_*` | Configure aria2 RPC connection for plugins. |
| `SYSDASH_JELLYFIN_*` | Configure Jellyfin API connection for plugins. |

---

## Dependencies

`sysdash` is written in pure Bash (3.2+) and uses standard POSIX utilities. It will gracefully degrade if optional tools are missing, but installing them unlocks full functionality:

- **Required**: `bash`, `awk`, `ps`, `df`
- **Highly Recommended**: `tuptime` (system uptime history), `ss` or `netstat` (network ports), `iproute2`
- **Optional**: `nvidia-smi` (GPU stats), `docker` / `kubectl` (container badges), `curl` / `wget` (external IP & plugin installation)

---

## License

MIT License. Feel free to fork, modify, and distribute.
