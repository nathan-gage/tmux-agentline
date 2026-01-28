# tmux-agentline

A tmux plugin that shows real-time Claude Code status in the tmux status bar and window list.

## Architecture

```
Claude Code Hooks → claude-hook.sh → State Files → status.sh/window-status.sh → tmux status line
```

**State files** are stored in `~/.claude/tmux-stat/<pane_id>.state` as JSON with status, timestamp, session_id, tmux_window, and message fields.

## Key Files

| File | Purpose |
|------|---------|
| `tmux-agentline.tmux` | Plugin entry point, sets up tmux interpolation for `#{claude_status}` |
| `scripts/claude-hook.sh` | Receives Claude Code hook events via stdin JSON, writes state files |
| `scripts/status.sh` | Outputs aggregated status for status bar (highest priority state across all panes) |
| `scripts/window-status.sh` | Outputs per-window status for window list (takes window_id as arg) |
| `scripts/helpers.sh` | Shared functions: state file I/O, tmux option retrieval, cleanup |
| `scripts/install-hooks.sh` | Installs/uninstalls hooks in `~/.claude/settings.json` |

## States

- **running** (yellow ●) - Claude is actively working (PreToolUse, PostToolUse, SessionStart)
- **attention** (red !) - Claude needs user input (PermissionRequest, permission_prompt, elicitation_dialog)
- **done** (green ✓) - Claude finished or idle (Stop, idle_prompt)

Priority: attention > running > done

## Claude Code Hook Events

The hook script reads `hook_event_name` from JSON input:
- `SessionStart` → running
- `PreToolUse` / `PostToolUse` → running
- `PermissionRequest` → attention
- `Notification` with `notification_type: permission_prompt` → attention
- `Notification` with `notification_type: idle_prompt` → done
- `Stop` → done
- `SessionEnd` → removes state file

## Testing

```bash
./tests/run_tests.sh
```

Tests use `STATE_DIR` and `TMUX_STAT_SKIP_PANE_CHECK` env vars to isolate from real state.
