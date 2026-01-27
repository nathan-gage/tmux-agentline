# tmux-stat

A tmux plugin that displays real-time Claude Code status indicators in your status line.

## Features

- Shows when Claude is **running** (actively working)
- Alerts when Claude needs **attention** (permission prompts, waiting for input)
- Indicates when Claude is **done** (finished responding)
- Aggregates status across all tmux panes running Claude
- Customizable icons and colors

## Requirements

- tmux 2.1+
- [jq](https://stedolan.github.io/jq/) for JSON parsing
- [Claude Code](https://claude.ai/claude-code) CLI
- A [Nerd Font](https://www.nerdfonts.com/) for default icons (or customize your own)

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm) (recommended)

Add to your `~/.tmux.conf`:

```tmux
set -g @plugin 'ngage/tmux-stat'
```

Press `prefix + I` to install.

### Manual Installation

```bash
git clone https://github.com/ngage/tmux-stat ~/.tmux/plugins/tmux-stat
```

Add to `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-stat/tmux-stat.tmux
```

### Configure Claude Code Hooks

Run the installer to set up Claude Code hooks:

```bash
~/.tmux/plugins/tmux-stat/scripts/install-hooks.sh
```

This adds the necessary hooks to `~/.claude/settings.json`.

## Usage

Add `#{claude_status}` to your status line:

```tmux
set -g status-right "#{claude_status} | %H:%M"
```

Reload tmux configuration:

```bash
tmux source ~/.tmux.conf
```

## Status Indicators

| Icon | Color | Meaning |
|------|-------|---------|
|  | Yellow | Claude is actively working |
|  | Red | Claude needs your attention |
|  | Green | Claude has finished |

When multiple panes have the same status, a count is shown (e.g., ` 3`).

Priority order: attention > running > done

## Customization

### Icons

```tmux
set -g @claude_status_icon_running ""
set -g @claude_status_icon_attention ""
set -g @claude_status_icon_done ""
```

### Colors/Styles

```tmux
set -g @claude_status_running "#[fg=yellow]"
set -g @claude_status_attention "#[fg=red,bold]"
set -g @claude_status_done "#[fg=green]"
```

## How It Works

1. Claude Code hooks trigger on various events (tool use, permission requests, etc.)
2. Hook scripts update state files in `~/.claude/tmux-stat/`
3. The status script reads state files and outputs the appropriate indicator
4. tmux refreshes the status line to show the current state

### State Files

State is tracked per-pane in `~/.claude/tmux-stat/<pane_id>.state`:

```json
{
  "status": "running",
  "timestamp": 1706000000,
  "session_id": "abc123",
  "tmux_window": "@1",
  "message": "Using tool: Read"
}
```

Stale states (>5 minutes old) are automatically cleaned up.

## Uninstallation

Remove hooks from Claude settings:

```bash
~/.tmux/plugins/tmux-stat/scripts/install-hooks.sh uninstall
```

Then remove the plugin from your `~/.tmux.conf`.

## Troubleshooting

### Status not updating

1. Verify hooks are installed: `cat ~/.claude/settings.json | jq '.hooks'`
2. Check state directory exists: `ls ~/.claude/tmux-stat/`
3. Ensure scripts are executable: `ls -la ~/.tmux/plugins/tmux-stat/scripts/`

### Icons not displaying

Install a [Nerd Font](https://www.nerdfonts.com/) and configure your terminal to use it, or customize the icons to use standard Unicode or ASCII characters.

### jq not found

Install jq:
- macOS: `brew install jq`
- Ubuntu/Debian: `apt install jq`
- Fedora: `dnf install jq`

## License

MIT
