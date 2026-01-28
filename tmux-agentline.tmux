#!/usr/bin/env bash
# tmux-stat.tmux - Main plugin entry point for TPM

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default option values
declare -A DEFAULTS=(
    ["@claude_status_running"]="#[fg=yellow]"
    ["@claude_status_attention"]="#[fg=red,bold]"
    ["@claude_status_done"]="#[fg=green]"
    ["@claude_status_icon_running"]=""
    ["@claude_status_icon_attention"]=""
    ["@claude_status_icon_done"]=""
)

# Set default options if not already set
set_defaults() {
    for option in "${!DEFAULTS[@]}"; do
        local current
        current=$(tmux show-option -gqv "$option" 2>/dev/null)
        if [[ -z "$current" ]]; then
            tmux set-option -gq "$option" "${DEFAULTS[$option]}"
        fi
    done
}

# Set up the #{claude_status} interpolation
setup_interpolation() {
    local status_script="${CURRENT_DIR}/scripts/status.sh"

    # Make scripts executable
    chmod +x "${CURRENT_DIR}/scripts/"*.sh

    # Get current status-right and status-left
    local status_right status_left
    status_right=$(tmux show-option -gqv "status-right")
    status_left=$(tmux show-option -gqv "status-left")

    # Replace #{claude_status} with script call
    # Using #() for shell command interpolation in tmux
    local replacement="#(${status_script})"

    if [[ "$status_right" == *'#{claude_status}'* ]]; then
        status_right="${status_right//\#\{claude_status\}/$replacement}"
        tmux set-option -gq "status-right" "$status_right"
    fi

    if [[ "$status_left" == *'#{claude_status}'* ]]; then
        status_left="${status_left//\#\{claude_status\}/$replacement}"
        tmux set-option -gq "status-left" "$status_left"
    fi
}

# Register cleanup hooks for when tmux panes are destroyed
setup_cleanup_hooks() {
    local cleanup_script="${CURRENT_DIR}/scripts/cleanup-pane.sh"

    # Create cleanup script if it doesn't exist
    if [[ ! -f "$cleanup_script" ]]; then
        cat > "$cleanup_script" << 'EOF'
#!/usr/bin/env bash
# Clean up state file when a pane is destroyed
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

pane_id="$1"
if [[ -n "$pane_id" ]]; then
    remove_state "$pane_id"
fi
EOF
        chmod +x "$cleanup_script"
    fi

    # Note: tmux hooks for pane-died would be ideal but have limitations
    # State cleanup happens via timeout in status.sh instead
}

# Ensure state directory exists
ensure_state_directory() {
    mkdir -p "${HOME}/.claude/tmux-stat"
}

# Start OTEL receiver if not running
start_otel_receiver() {
    local receiver_script="${CURRENT_DIR}/scripts/otel-receiver.py"
    local pid_file="${HOME}/.claude/tmux-stat/otel-receiver.pid"

    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi

    # Start receiver in background
    if [[ -x "$receiver_script" ]]; then
        nohup "$receiver_script" > /dev/null 2>&1 &
        echo $! > "$pid_file"
    fi
}

main() {
    set_defaults
    ensure_state_directory
    setup_interpolation
    setup_cleanup_hooks
    start_otel_receiver
}

main
