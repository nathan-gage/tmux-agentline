#!/usr/bin/env bash
# claude-hook.sh - Handle Claude Code hook events and update state files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# Read JSON input from stdin
read_input() {
    cat
}

# Extract field from JSON
# Args: $1 = json, $2 = field path
json_field() {
    echo "$1" | jq -r "$2 // empty"
}

# Determine state from hook event
# Args: $1 = hook_type, $2 = json_input
determine_state() {
    local hook_type="$1"
    local json_input="$2"

    case "$hook_type" in
        SessionStart)
            echo "running"
            ;;
        PreToolUse|PostToolUse|SubagentStart)
            echo "running"
            ;;
        PermissionRequest)
            echo "attention"
            ;;
        Notification)
            # Check the notification type
            local notification_type
            notification_type=$(json_field "$json_input" '.notification.type')
            case "$notification_type" in
                permission_prompt|idle_prompt|elicitation_dialog)
                    echo "attention"
                    ;;
                *)
                    # Other notifications don't change state
                    echo ""
                    ;;
            esac
            ;;
        Stop)
            echo "done"
            ;;
        SessionEnd)
            echo "remove"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Get a descriptive message for the state
# Args: $1 = hook_type, $2 = json_input
get_message() {
    local hook_type="$1"
    local json_input="$2"

    case "$hook_type" in
        PreToolUse)
            local tool_name
            tool_name=$(json_field "$json_input" '.tool_name')
            echo "Using tool: ${tool_name:-unknown}"
            ;;
        PermissionRequest)
            local tool_name
            tool_name=$(json_field "$json_input" '.tool_name')
            echo "Permission needed: ${tool_name:-unknown}"
            ;;
        Notification)
            local notification_type
            notification_type=$(json_field "$json_input" '.notification.type')
            case "$notification_type" in
                permission_prompt)
                    echo "Permission prompt"
                    ;;
                idle_prompt)
                    echo "Waiting for input"
                    ;;
                elicitation_dialog)
                    echo "MCP input needed"
                    ;;
                *)
                    echo ""
                    ;;
            esac
            ;;
        Stop)
            local reason
            reason=$(json_field "$json_input" '.reason')
            echo "Stopped: ${reason:-completed}"
            ;;
        *)
            echo ""
            ;;
    esac
}

main() {
    # Read input from stdin
    local json_input
    json_input=$(read_input)

    # Get pane ID from environment
    local pane_id
    pane_id=$(get_current_pane_id)

    if [[ -z "$pane_id" ]]; then
        # Not running in a tmux pane, nothing to do
        exit 0
    fi

    # Determine hook type from the input
    local hook_type
    hook_type=$(json_field "$json_input" '.hook')

    if [[ -z "$hook_type" ]]; then
        # Try alternate field names based on hook structure
        # SessionStart/SessionEnd have different structure
        if [[ $(json_field "$json_input" '.session_id') != "" ]]; then
            # Could be SessionStart or SessionEnd based on context
            # Check for session-specific fields
            if [[ $(json_field "$json_input" '.cwd') != "" ]]; then
                hook_type="SessionStart"
            fi
        fi
    fi

    # Get session ID if available
    local session_id
    session_id=$(json_field "$json_input" '.session_id')

    # Determine new state
    local new_state
    new_state=$(determine_state "$hook_type" "$json_input")

    if [[ -z "$new_state" ]]; then
        # No state change needed
        exit 0
    fi

    # Handle state update
    if [[ "$new_state" == "remove" ]]; then
        remove_state "$pane_id"
    else
        local message
        message=$(get_message "$hook_type" "$json_input")
        write_state "$pane_id" "$new_state" "$session_id" "$message"
    fi

    # Trigger tmux status refresh
    refresh_tmux_status
}

main "$@"
