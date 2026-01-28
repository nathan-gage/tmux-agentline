# tmux-agentline

A tmux plugin that shows real-time AI agent status in the tmux status bar and window list. Supports Claude Code and OpenAI Codex CLI.

## Architecture

### Claude Code
```
Claude Code Hooks → claude-hook.sh → State Files → status.sh/window-status.sh → tmux status line
```

### Codex CLI (OTEL)
```
codex-wrapper.sh → registers pane → otel-receiver.py ← OTEL events ← Codex CLI
                                           ↓
                                    State Files → status.sh → tmux status line
```

**State files** are stored in `~/.claude/tmux-stat/<pane_id>.state` as JSON with status, timestamp, session_id, tmux_window, and message fields.

## Key Files

| File | Purpose |
|------|---------|
| `tmux-agentline.tmux` | Plugin entry point, sets up tmux interpolation for `#{claude_status}`, starts OTEL receiver |
| `scripts/claude-hook.sh` | Receives Claude Code hook events via stdin JSON, writes state files |
| `scripts/codex-hook.sh` | Receives Codex notify events (limited, legacy) |
| `scripts/otel-receiver.py` | HTTP server receiving OTEL telemetry from Codex, writes state files |
| `scripts/codex-wrapper.sh` | Wrapper for codex that registers pane and starts receiver |
| `scripts/status.sh` | Outputs aggregated status for status bar (highest priority state across all panes) |
| `scripts/window-status.sh` | Outputs per-window status for window list (takes window_id as arg) |
| `scripts/helpers.sh` | Shared functions: state file I/O, tmux option retrieval, cleanup |
| `scripts/install-hooks.sh` | Installs/uninstalls hooks in `~/.claude/settings.json` and `~/.codex/config.toml` |

## States

- **running** (yellow) - Agent is actively working
- **attention** (red) - Agent needs user input
- **done** (green) - Agent finished or idle

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

## Codex OTEL Events

The OTEL receiver maps these events:
- `codex.conversation_starts` → running
- `codex.tool_decision` (pending) → attention
- `codex.tool_decision` (approved) → running
- `codex.tool_result` (success) → running
- `codex.tool_result` (failed) → attention
- `codex.conversation_ends` → done

## OTEL Receiver

- Listens on `localhost:4319`
- Endpoints: `POST /v1/logs`, `POST /v1/traces`, `POST /`, `POST /register`, `POST /unregister`, `GET /health`
- Threaded HTTP server (handles concurrent requests)
- Auto-shutdown after 5 minutes idle
- Started automatically by tmux plugin or codex-wrapper.sh

## Testing

```bash
./tests/run_tests.sh
```

Tests use `STATE_DIR` and `TMUX_STAT_SKIP_PANE_CHECK` env vars to isolate from real state.

51 tests covering:
- helpers.sh functions
- claude-hook.sh events
- codex-hook.sh notify events
- otel-receiver.py endpoints and event mapping
- codex-wrapper.sh
- status.sh output and priority
