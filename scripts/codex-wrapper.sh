#!/usr/bin/env bash
# codex-wrapper.sh - Wrapper for Codex CLI that integrates with tmux-stat OTEL receiver
#
# This wrapper:
# 1. Starts the OTEL receiver if not running
# 2. Registers the current tmux pane
# 3. Runs the real codex command
# 4. Unregisters the pane on exit
#
# Usage:
#   ./codex-wrapper.sh [codex args...]
#   alias codex='/path/to/tmux-stat/scripts/codex-wrapper.sh'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIVER_SCRIPT="${SCRIPT_DIR}/otel-receiver.py"
RECEIVER_PORT="${OTEL_RECEIVER_PORT:-4319}"
RECEIVER_URL="http://127.0.0.1:${RECEIVER_PORT}"
PID_FILE="${HOME}/.claude/tmux-stat/otel-receiver.pid"

# Get pane ID from tmux
get_pane_id() {
    echo "${TMUX_PANE:-}"
}

# Check if receiver is running
receiver_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            # Also verify it's responding
            if curl -s --connect-timeout 1 "${RECEIVER_URL}/health" > /dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    # Quick check without PID file
    curl -s --connect-timeout 1 "${RECEIVER_URL}/health" > /dev/null 2>&1
}

# Start the receiver
start_receiver() {
    if receiver_running; then
        return 0
    fi

    # Ensure directory exists
    mkdir -p "$(dirname "$PID_FILE")"

    # Start receiver in background
    nohup "$RECEIVER_SCRIPT" --port "$RECEIVER_PORT" > /dev/null 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    # Wait for it to be ready
    local max_wait=10
    local waited=0
    while ! receiver_running && [[ $waited -lt $max_wait ]]; do
        sleep 0.2
        ((waited++)) || true
    done

    if receiver_running; then
        return 0
    else
        echo "Warning: Failed to start OTEL receiver" >&2
        return 1
    fi
}

# Register pane with receiver
register_pane() {
    local pane_id="$1"
    curl -s -X POST "${RECEIVER_URL}/register" \
        -H "Content-Type: application/json" \
        -d "{\"pane_id\": \"$pane_id\"}" > /dev/null 2>&1 || true
}

# Unregister pane from receiver
unregister_pane() {
    local pane_id="$1"
    curl -s -X POST "${RECEIVER_URL}/unregister" \
        -H "Content-Type: application/json" \
        -d "{\"pane_id\": \"$pane_id\"}" > /dev/null 2>&1 || true
}

# Find the real codex binary
find_codex() {
    # Skip our wrapper script
    local wrapper_path
    wrapper_path=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")

    # Search PATH for codex, skipping our wrapper
    local IFS=':'
    for dir in $PATH; do
        local candidate="${dir}/codex"
        if [[ -x "$candidate" ]]; then
            local real_path
            real_path=$(realpath "$candidate" 2>/dev/null || echo "$candidate")
            if [[ "$real_path" != "$wrapper_path" ]]; then
                echo "$candidate"
                return 0
            fi
        fi
    done

    # Try common locations
    for candidate in \
        /usr/local/bin/codex \
        /opt/homebrew/bin/codex \
        "${HOME}/.local/bin/codex" \
        "${HOME}/bin/codex"; do
        if [[ -x "$candidate" ]]; then
            local real_path
            real_path=$(realpath "$candidate" 2>/dev/null || echo "$candidate")
            if [[ "$real_path" != "$wrapper_path" ]]; then
                echo "$candidate"
                return 0
            fi
        fi
    done

    echo ""
}

main() {
    local pane_id
    pane_id=$(get_pane_id)

    # Find real codex binary
    local codex_bin
    codex_bin=$(find_codex)

    if [[ -z "$codex_bin" ]]; then
        echo "Error: Could not find codex binary in PATH" >&2
        echo "Make sure Codex CLI is installed: https://github.com/openai/codex" >&2
        exit 1
    fi

    # Only integrate with receiver if running in tmux
    if [[ -n "$pane_id" ]]; then
        # Start receiver if needed
        start_receiver || true

        # Register this pane
        register_pane "$pane_id"

        # Set up cleanup trap
        cleanup() {
            unregister_pane "$pane_id"
        }
        trap cleanup EXIT INT TERM
    fi

    # Execute the real codex command
    exec "$codex_bin" "$@"
}

main "$@"
