#!/usr/bin/env bash
# codex-hook.sh - Handle OpenAI Codex CLI notify events and update state files
#
# Codex CLI uses a `notify` config that triggers on events like `agent-turn-complete`.
# The JSON payload includes: type, thread-id, turn-id, cwd, input-messages, last-assistant-message
#
# Limitations vs Claude Code hooks:
# - Only `agent-turn-complete` event is currently exposed
# - No direct "running" state detection (no session start/tool use events)
# - No direct "approval needed" event (must infer from message content)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# Extract field from JSON
# Args: $1 = json, $2 = field path
json_field() {
    echo "$1" | jq -r "$2 // empty"
}

# Determine state from Codex notification
# Args: $1 = json_input
determine_state() {
    local json_input="$1"
    local event_type
    local last_message

    event_type=$(json_field "$json_input" '.type')
    last_message=$(json_field "$json_input" '."last-assistant-message"')

    case "$event_type" in
        agent-turn-complete)
            # Try to detect if approval/input is needed from message content
            # Common patterns that indicate waiting for user decision
            if [[ "$last_message" =~ (approve|permission|allow|deny|confirm|proceed\?) ]] ||
               [[ "$last_message" =~ (Do you want|Would you like|Should I) ]]; then
                echo "attention"
            else
                # Turn complete - waiting for user input
                echo "done"
            fi
            ;;
        *)
            # Unknown event type
            echo ""
            ;;
    esac
}

# Get a descriptive message for the state
# Args: $1 = json_input
get_message() {
    local json_input="$1"
    local event_type
    local last_message

    event_type=$(json_field "$json_input" '.type')
    last_message=$(json_field "$json_input" '."last-assistant-message"')

    case "$event_type" in
        agent-turn-complete)
            # Truncate message for display
            if [[ -n "$last_message" ]]; then
                # Take first 50 chars
                local truncated="${last_message:0:50}"
                if [[ ${#last_message} -gt 50 ]]; then
                    truncated="${truncated}..."
                fi
                echo "Codex: $truncated"
            else
                echo "Codex turn complete"
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

main() {
    # Read JSON from first argument (Codex passes JSON as $1)
    local json_input="${1:-}"

    if [[ -z "$json_input" ]]; then
        # No input provided
        exit 0
    fi

    # Get pane ID from environment
    local pane_id
    pane_id=$(get_current_pane_id)

    if [[ -z "$pane_id" ]]; then
        # Not running in a tmux pane, nothing to do
        exit 0
    fi

    # Get thread ID as session identifier
    local session_id
    session_id=$(json_field "$json_input" '."thread-id"')

    # Determine new state
    local new_state
    new_state=$(determine_state "$json_input")

    if [[ -z "$new_state" ]]; then
        # No state change needed
        exit 0
    fi

    # Get message
    local message
    message=$(get_message "$json_input")

    # Write state (Codex sessions use thread-id as session identifier)
    write_state "$pane_id" "$new_state" "$session_id" "$message"

    # Trigger tmux status refresh
    refresh_tmux_status
}

main "$@"
