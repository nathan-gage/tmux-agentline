# tmux-agentline

A tmux plugin that displays real-time AI agent status indicators in your status line and window list.

## Features

- Shows when an agent is **running** (actively working)
- Alerts when an agent needs **attention** (permission prompts)
- Indicates when an agent is **done** (finished or idle)
- Per-window status indicators in the window list
- Aggregated status in the status bar
- Automatic cleanup when panes are closed
- Customizable icons and colors

## Requirements

- tmux 2.1+
- [jq](https://stedolan.github.io/jq/) for JSON parsing
- [Claude Code](https://claude.ai/code) CLI

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm)

Add to your `~/.tmux.conf`:

```tmux
set -g @plugin 'nathan-gage/tmux-agentline'
```

Press `prefix + I` to install.

### Manual Installation

```bash
git clone https://github.com/nathan-gage/tmux-agentline ~/.tmux/plugins/tmux-agentline
```

Add to `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-agentline/tmux-agentline.tmux
```

### Configure Claude Code Hooks

Run the installer to set up Claude Code hooks:

```bash
~/.tmux/plugins/tmux-agentline/scripts/install-hooks.sh
```

This adds the necessary hooks to `~/.claude/settings.json`.

## Usage

### Status Bar

Add `#{claude_status}` to your status line:

```tmux
set -g status-right "#{claude_status} %H:%M"
```

### Window List

Add per-window indicators:

```tmux
set -g window-status-format '#I:#W#(~/.tmux/plugins/tmux-agentline/scripts/window-status.sh #{window_id})'
set -g window-status-current-format '#I:#W#(~/.tmux/plugins/tmux-agentline/scripts/window-status.sh #{window_id})'
```

Reload tmux configuration:

```bash
tmux source ~/.tmux.conf
```

## Status Indicators

| Icon | Color | Meaning |
|------|-------|---------|
| ● | Yellow | Agent is actively working |
| ! | Red | Agent needs your attention |
| ✓ | Green | Agent has finished |

When multiple panes have the same status, a count is shown (e.g., `●2`).

Priority order: attention > running > done

## Customization

### Icons

```tmux
set -g @claude_status_icon_running "●"
set -g @claude_status_icon_attention "!"
set -g @claude_status_icon_done "✓"
```

### Colors/Styles

```tmux
set -g @claude_status_running "#[fg=yellow]"
set -g @claude_status_attention "#[fg=red,bold]"
set -g @claude_status_done "#[fg=green]"
```

## How It Works

1. Claude Code hooks trigger on events (tool use, permission requests, etc.)
2. Hook scripts update state files in `~/.claude/tmux-stat/`
3. Status scripts read state files and output indicators
4. tmux refreshes to show the current state
5. State files are automatically cleaned up when panes close

## Uninstallation

Remove hooks from Claude settings:

```bash
~/.tmux/plugins/tmux-agentline/scripts/install-hooks.sh uninstall
```

Then remove the plugin from your `~/.tmux.conf`.

## Troubleshooting

### Status not updating

1. Verify hooks are installed: `cat ~/.claude/settings.json | jq '.hooks'`
2. Check state directory exists: `ls ~/.claude/tmux-stat/`
3. Ensure scripts are executable: `ls -la ~/.tmux/plugins/tmux-agentline/scripts/`

### jq not found

Install jq:
- macOS: `brew install jq`
- Ubuntu/Debian: `apt install jq`
- Fedora: `dnf install jq`

## License

MIT
