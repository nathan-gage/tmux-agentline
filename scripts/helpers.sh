#!/usr/bin/env bash
# helpers.sh - Shared utility functions for tmux-stat plugin

# State directory for tracking Claude sessions
# Allow override via environment variable for testing
STATE_DIR="${STATE_DIR:-${HOME}/.claude/tmux-stat}"

# Ensure state directory exists
ensure_state_dir() {
    mkdir -p "$STATE_DIR"
}

# Get the state file path for a given pane ID
# Args: $1 = pane_id (e.g., %123)
get_state_file() {
    local pane_id="$1"
    # Replace % with empty to avoid filesystem issues
    local safe_id="${pane_id#%}"
    echo "${STATE_DIR}/${safe_id}.state"
}

# Read a state file and output its contents
# Args: $1 = pane_id
# Returns: JSON content or empty if file doesn't exist
read_state() {
    local pane_id="$1"
    local state_file
    state_file=$(get_state_file "$pane_id")

    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    fi
}

# Write state to a pane's state file
# Args: $1 = pane_id, $2 = status, $3 = session_id (optional), $4 = message (optional)
write_state() {
    local pane_id="$1"
    local state_status="$2"
    local state_session_id="${3:-}"
    local state_message="${4:-}"
    local state_file

    ensure_state_dir
    state_file=$(get_state_file "$pane_id")

    # Get tmux window if available
    local tmux_window=""
    if [[ -n "${TMUX:-}" ]]; then
        tmux_window=$(tmux display-message -p '#{window_id}' 2>/dev/null || echo "")
    fi

    # Create JSON state file
    jq -n \
        --arg state_status "$state_status" \
        --arg timestamp "$(date +%s)" \
        --arg session_id "$state_session_id" \
        --arg tmux_window "$tmux_window" \
        --arg message "$state_message" \
        '{
            status: $state_status,
            timestamp: ($timestamp | tonumber),
            session_id: $session_id,
            tmux_window: $tmux_window,
            message: $message
        }' > "$state_file"
}

# Remove state file for a pane
# Args: $1 = pane_id
remove_state() {
    local pane_id="$1"
    local state_file
    state_file=$(get_state_file "$pane_id")

    rm -f "$state_file"
}

# Get a tmux option with a default value
# Args: $1 = option name, $2 = default value
get_tmux_option() {
    local option="$1"
    local default="$2"
    local value

    value=$(tmux show-option -gqv "$option" 2>/dev/null)

    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Clean up stale state files (older than 5 minutes)
cleanup_stale_states() {
    local max_age=300  # 5 minutes in seconds
    local now
    now=$(date +%s)

    ensure_state_dir

    # Use nullglob to handle case when no files match
    local old_nullglob
    old_nullglob=$(shopt -p nullglob 2>/dev/null || echo "shopt -u nullglob")
    shopt -s nullglob

    for state_file in "$STATE_DIR"/*.state; do
        [[ -f "$state_file" ]] || continue

        local timestamp
        timestamp=$(jq -r '.timestamp // 0' "$state_file" 2>/dev/null || echo "0")

        if (( now - timestamp > max_age )); then
            rm -f "$state_file"
        fi
    done

    # Restore previous nullglob setting
    eval "$old_nullglob"
}

# Trigger tmux status line refresh
refresh_tmux_status() {
    if [[ -n "${TMUX:-}" ]]; then
        tmux refresh-client -S 2>/dev/null || true
    fi
}

# Get current pane ID from environment
get_current_pane_id() {
    echo "${TMUX_PANE:-}"
}
