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

## Supported Agents

- [Claude Code](https://claude.ai/code) CLI (full support via hooks)
- [OpenAI Codex CLI](https://github.com/openai/codex) (via OTEL integration)

## Requirements

- tmux 2.1+
- [jq](https://stedolan.github.io/jq/) for JSON parsing
- Python 3.8+ (for Codex OTEL integration)

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

### Configure Agent Hooks

Run the installer to set up hooks:

```bash
# Install both Claude Code and Codex CLI hooks
~/.tmux/plugins/tmux-agentline/scripts/install-hooks.sh

# Or install individually:
~/.tmux/plugins/tmux-agentline/scripts/install-hooks.sh install-claude      # Claude Code only
~/.tmux/plugins/tmux-agentline/scripts/install-hooks.sh install-codex-otel  # Codex CLI (OTEL)
```

This adds the necessary hooks to `~/.claude/settings.json` and/or `~/.codex/config.toml`.

### Codex CLI Setup

For Codex CLI, use the wrapper script to enable status tracking:

```bash
# Add to your shell config (~/.bashrc or ~/.zshrc)
alias codex='~/.tmux/plugins/tmux-agentline/scripts/codex-wrapper.sh'
```

The wrapper automatically:
- Starts the OTEL receiver if not running
- Registers your tmux pane for status tracking
- Cleans up on exit

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

### Claude Code

1. Claude Code hooks trigger on events (tool use, permission requests, etc.)
2. Hook scripts update state files in `~/.claude/tmux-stat/`
3. Status scripts read state files and output indicators
4. tmux refreshes to show the current state
5. State files are automatically cleaned up when panes close

### Codex CLI (OTEL)

```
┌─────────────────┐    Registration    ┌──────────────────────┐
│ codex-wrapper.sh│◄──────────────────►│  otel-receiver.py    │
│ (sets PANE_ID)  │                    │  (localhost:4319)    │
└────────┬────────┘                    └──────────┬───────────┘
         │                                        │
         │ exec codex                   OTEL HTTP POST
         ▼                                        │
┌─────────────────┐                              │
│   Codex CLI     │──────────────────────────────┘
└─────────────────┘                    ┌──────────────────────┐
                                       │ ~/.claude/tmux-stat/ │
                                       │   <pane>.state       │
                                       └──────────────────────┘
```

1. Wrapper script registers the tmux pane with the OTEL receiver
2. Codex CLI sends OpenTelemetry events to the receiver
3. Receiver maps events to states and writes state files
4. Receiver auto-shuts down after 5 minutes of inactivity

#### Codex Event Mapping

| Codex OTEL Event | State | Indicator |
|------------------|-------|-----------|
| `codex.conversation_starts` | running | Yellow ● |
| `codex.tool_decision` (pending) | attention | Red ! |
| `codex.tool_decision` (approved) | running | Yellow ● |
| `codex.tool_result` (success) | running | Yellow ● |
| `codex.tool_result` (failed) | attention | Red ! |
| `codex.conversation_ends` | done | Green ✓ |

## Uninstallation

Remove hooks:

```bash
# Remove all hooks
~/.tmux/plugins/tmux-agentline/scripts/install-hooks.sh uninstall

# Or remove individually:
~/.tmux/plugins/tmux-agentline/scripts/install-hooks.sh uninstall-claude
~/.tmux/plugins/tmux-agentline/scripts/install-hooks.sh uninstall-codex-otel
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

### Codex status not showing

1. Ensure you're using the wrapper alias, not `codex` directly
2. Check OTEL receiver is running: `curl http://localhost:4319/health`
3. Verify OTEL config in `~/.codex/config.toml`:
   ```toml
   [otel]
   environment = "dev"

   [otel.exporter.otlp-http]
   endpoint = "http://127.0.0.1:4319"
   protocol = "json"
   ```
4. Check state files: `ls ~/.claude/tmux-stat/*.state`

### Codex OTEL errors in terminal

If you see `BatchLogProcessor.ExportError` messages, the OTEL receiver isn't running. Either:
- Use the wrapper alias (auto-starts receiver)
- Reload tmux config to start receiver: `tmux source ~/.tmux.conf`
- Start manually: `~/.tmux/plugins/tmux-agentline/scripts/otel-receiver.py &`

## License

MIT
