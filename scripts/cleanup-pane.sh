#!/usr/bin/env bash
# Clean up state file when a pane is destroyed
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

pane_id="$1"
if [[ -n "$pane_id" ]]; then
    remove_state "$pane_id"
fi
