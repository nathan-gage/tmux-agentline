#!/usr/bin/env bash
# status.sh - Generate tmux status line output for Claude sessions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# Default styling options
DEFAULT_STYLE_RUNNING="#[fg=yellow]"
DEFAULT_STYLE_ATTENTION="#[fg=red,bold]"
DEFAULT_STYLE_DONE="#[fg=green]"
DEFAULT_STYLE_RESET="#[default]"

# Default icons (Nerd Font icons)
DEFAULT_ICON_RUNNING=""
DEFAULT_ICON_ATTENTION=""
DEFAULT_ICON_DONE=""

# Get styling options from tmux
get_style_running() {
    get_tmux_option "@claude_status_running" "$DEFAULT_STYLE_RUNNING"
}

get_style_attention() {
    get_tmux_option "@claude_status_attention" "$DEFAULT_STYLE_ATTENTION"
}

get_style_done() {
    get_tmux_option "@claude_status_done" "$DEFAULT_STYLE_DONE"
}

get_icon_running() {
    get_tmux_option "@claude_status_icon_running" "$DEFAULT_ICON_RUNNING"
}

get_icon_attention() {
    get_tmux_option "@claude_status_icon_attention" "$DEFAULT_ICON_ATTENTION"
}

get_icon_done() {
    get_tmux_option "@claude_status_icon_done" "$DEFAULT_ICON_DONE"
}

# Count panes in each state
count_states() {
    local attention_count=0
    local running_count=0
    local done_count=0

    ensure_state_dir

    # Clean up stale states first
    cleanup_stale_states

    # Use nullglob to handle case when no files match
    local old_nullglob
    old_nullglob=$(shopt -p nullglob 2>/dev/null || echo "shopt -u nullglob")
    shopt -s nullglob

    for state_file in "$STATE_DIR"/*.state; do
        [[ -f "$state_file" ]] || continue

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

# Format output with count if > 1
format_output() {
    local style="$1"
    local icon="$2"
    local count="$3"

    if (( count > 1 )); then
        echo "${style}${icon} ${count}${DEFAULT_STYLE_RESET}"
    else
        echo "${style}${icon}${DEFAULT_STYLE_RESET}"
    fi
}

main() {
    # Get counts for each state
    local counts
    counts=$(count_states)

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
    # If no active sessions, output nothing
}

main "$@"
