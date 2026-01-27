#!/usr/bin/env bash
# install-hooks.sh - Configure Claude Code hooks for tmux-stat integration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
STATE_DIR="${HOME}/.claude/tmux-stat"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
    exit 1
}

# Check for required dependencies
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        error "jq is required but not installed. Install with: brew install jq (macOS) or apt install jq (Linux)"
    fi
}

# Create state directory
create_state_dir() {
    info "Creating state directory: ${STATE_DIR}"
    mkdir -p "$STATE_DIR"
}

# Generate hooks configuration
generate_hooks_config() {
    local hook_command="${PLUGIN_DIR}/scripts/claude-hook.sh"

    jq -n \
        --arg cmd "$hook_command" \
        '{
            "SessionStart": [{
                "hooks": [{
                    "type": "command",
                    "command": $cmd
                }]
            }],
            "PreToolUse": [{
                "matcher": "*",
                "hooks": [{
                    "type": "command",
                    "command": $cmd
                }]
            }],
            "PostToolUse": [{
                "matcher": "*",
                "hooks": [{
                    "type": "command",
                    "command": $cmd
                }]
            }],
            "PermissionRequest": [{
                "matcher": "*",
                "hooks": [{
                    "type": "command",
                    "command": $cmd
                }]
            }],
            "Notification": [{
                "matcher": "permission_prompt|idle_prompt|elicitation_dialog",
                "hooks": [{
                    "type": "command",
                    "command": $cmd
                }]
            }],
            "Stop": [{
                "hooks": [{
                    "type": "command",
                    "command": $cmd
                }]
            }],
            "SessionEnd": [{
                "hooks": [{
                    "type": "command",
                    "command": $cmd
                }]
            }]
        }'
}

# Update Claude settings with hooks
update_claude_settings() {
    local hooks_config
    hooks_config=$(generate_hooks_config)

    # Create ~/.claude directory if needed
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        info "Updating existing Claude settings: ${CLAUDE_SETTINGS}"

        # Backup existing settings
        cp "$CLAUDE_SETTINGS" "${CLAUDE_SETTINGS}.backup"
        info "Backup created: ${CLAUDE_SETTINGS}.backup"

        # Merge hooks into existing settings
        local existing
        existing=$(cat "$CLAUDE_SETTINGS")

        # Check if hooks already exist
        if echo "$existing" | jq -e '.hooks' > /dev/null 2>&1; then
            warn "Existing hooks found. Merging with tmux-stat hooks..."
            # Merge hooks - tmux-stat hooks will be added/updated
            echo "$existing" | jq --argjson new_hooks "$hooks_config" '
                .hooks = (.hooks // {}) * $new_hooks
            ' > "$CLAUDE_SETTINGS"
        else
            # Add hooks to settings
            echo "$existing" | jq --argjson hooks "$hooks_config" '.hooks = $hooks' > "$CLAUDE_SETTINGS"
        fi
    else
        info "Creating new Claude settings: ${CLAUDE_SETTINGS}"
        jq -n --argjson hooks "$hooks_config" '{hooks: $hooks}' > "$CLAUDE_SETTINGS"
    fi
}

# Verify installation
verify_installation() {
    info "Verifying installation..."

    # Check state directory
    if [[ -d "$STATE_DIR" ]]; then
        info "State directory exists: ${STATE_DIR}"
    else
        error "State directory not created"
    fi

    # Check Claude settings
    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        if jq -e '.hooks.SessionStart' "$CLAUDE_SETTINGS" > /dev/null 2>&1; then
            info "Claude hooks configured successfully"
        else
            error "Hooks not properly configured in settings"
        fi
    else
        error "Claude settings file not created"
    fi

    # Check hook script is executable
    if [[ -x "${PLUGIN_DIR}/scripts/claude-hook.sh" ]]; then
        info "Hook script is executable"
    else
        warn "Hook script is not executable, fixing..."
        chmod +x "${PLUGIN_DIR}/scripts/claude-hook.sh"
    fi

    info "Installation verified successfully!"
}

# Print usage instructions
print_usage() {
    cat << EOF

${GREEN}tmux-stat Installation Complete!${NC}

To use the plugin, add this to your tmux.conf:

    # If using TPM (recommended):
    set -g @plugin 'your-username/tmux-stat'

    # Add to status line:
    set -g status-right "#{claude_status} | %H:%M"

    # Optional: Customize icons/colors
    set -g @claude_status_running "#[fg=yellow]"
    set -g @claude_status_attention "#[fg=red,bold]"
    set -g @claude_status_done "#[fg=green]"
    set -g @claude_status_icon_running ""
    set -g @claude_status_icon_attention ""
    set -g @claude_status_icon_done ""

Then reload tmux: tmux source ~/.tmux.conf

EOF
}

# Uninstall hooks
uninstall() {
    info "Uninstalling tmux-stat hooks..."

    if [[ -f "$CLAUDE_SETTINGS" ]]; then
        # Remove tmux-stat hooks
        local hooks_to_remove='["SessionStart", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"]'

        # Create backup
        cp "$CLAUDE_SETTINGS" "${CLAUDE_SETTINGS}.backup"

        # Remove hooks that contain our script
        jq --arg script "${PLUGIN_DIR}/scripts/claude-hook.sh" '
            .hooks |= (if . then
                with_entries(
                    .value |= map(
                        select(.hooks | not or (.hooks | all(.command != $script)))
                    ) | select(length > 0)
                ) | if . == {} then empty else . end
            else . end)
        ' "$CLAUDE_SETTINGS" > "${CLAUDE_SETTINGS}.tmp"
        mv "${CLAUDE_SETTINGS}.tmp" "$CLAUDE_SETTINGS"

        info "Hooks removed from Claude settings"
    fi

    # Clean up state files
    if [[ -d "$STATE_DIR" ]]; then
        rm -rf "$STATE_DIR"
        info "State directory removed"
    fi

    info "Uninstallation complete"
}

main() {
    case "${1:-install}" in
        install)
            check_dependencies
            create_state_dir
            update_claude_settings
            verify_installation
            print_usage
            ;;
        uninstall)
            uninstall
            ;;
        verify)
            verify_installation
            ;;
        *)
            echo "Usage: $0 [install|uninstall|verify]"
            exit 1
            ;;
    esac
}

main "$@"
