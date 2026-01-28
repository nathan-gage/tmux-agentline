#!/usr/bin/env bash
# window-status.sh - Generate status indicator for a specific tmux window

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# Get the window ID from argument
WINDOW_ID="${1:-}"

if [[ -z "$WINDOW_ID" ]]; then
    exit 0
fi

# Default icons (can be overridden via tmux options)
get_icon_running() {
    get_tmux_option "@claude_status_icon_running" "●"
}

get_icon_attention() {
    get_tmux_option "@claude_status_icon_attention" "!"
}

get_icon_done() {
    get_tmux_option "@claude_status_icon_done" "✓"
}

# Styles
get_style_running() {
    get_tmux_option "@claude_status_running" "#[fg=yellow]"
}

get_style_attention() {
    get_tmux_option "@claude_status_attention" "#[fg=red,bold]"
}

get_style_done() {
    get_tmux_option "@claude_status_done" "#[fg=green]"
}

# Count panes in each state for this window
count_window_states() {
    local window_id="$1"
    local attention_count=0
    local running_count=0
    local done_count=0

    ensure_state_dir

    # Use nullglob to handle case when no files match
    local old_nullglob
    old_nullglob=$(shopt -p nullglob 2>/dev/null || echo "shopt -u nullglob")
    shopt -s nullglob

    for state_file in "$STATE_DIR"/*.state; do
        [[ -f "$state_file" ]] || continue

        # Check if this state file belongs to the target window
        local file_window
        file_window=$(jq -r '.tmux_window // empty' "$state_file" 2>/dev/null || echo "")

        [[ "$file_window" == "$window_id" ]] || continue

        # Check timestamp - skip stale entries (>5 min old)
        local timestamp now
        timestamp=$(jq -r '.timestamp // 0' "$state_file" 2>/dev/null || echo "0")
        now=$(date +%s)
        (( now - timestamp > 300 )) && continue

        local status
        status=$(jq -r '.status // empty' "$state_file" 2>/dev/null || echo "")

        case "$status" in
            attention)
                ((attention_count++)) || true
                ;;
            running)
                ((running_count++)) || true
                ;;
            done)
                ((done_count++)) || true
                ;;
        esac
    done

    # Restore previous nullglob setting
    eval "$old_nullglob"

    echo "$attention_count $running_count $done_count"
}

# Format output - show icon with count, priority: attention > running > done
format_output() {
    local style="$1"
    local icon="$2"
    local count="$3"

    if (( count > 1 )); then
        echo " ${style}${icon}${count}#[default]"
    else
        echo " ${style}${icon}#[default]"
    fi
}

main() {
    local counts
    counts=$(count_window_states "$WINDOW_ID")

    local attention_count running_count done_count
    read -r attention_count running_count done_count <<< "$counts"

    # Priority: attention > running > done
    if (( attention_count > 0 )); then
        format_output "$(get_style_attention)" "$(get_icon_attention)" "$attention_count"
    elif (( running_count > 0 )); then
        format_output "$(get_style_running)" "$(get_icon_running)" "$running_count"
    elif (( done_count > 0 )); then
        format_output "$(get_style_done)" "$(get_icon_done)" "$done_count"
    fi
    # If no Claude sessions in this window, output nothing
}

main "$@"
