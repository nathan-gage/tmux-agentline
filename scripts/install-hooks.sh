#!/usr/bin/env bash
# install-hooks.sh - Configure Claude Code and Codex CLI hooks for tmux-stat integration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
CLAUDE_SETTINGS="${HOME}/.claude/settings.json"
CODEX_CONFIG="${HOME}/.codex/config.toml"
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

# ============================================================================
# Codex CLI Installation Functions (notify-based)
# ============================================================================

# Generate Codex notify config line
generate_codex_notify_config() {
    local hook_command="${PLUGIN_DIR}/scripts/codex-hook.sh"
    echo "notify = [\"$hook_command\"]"
}

# ============================================================================
# Codex CLI OTEL Installation Functions
# ============================================================================

# Generate Codex OTEL config
generate_codex_otel_config() {
    local receiver_port="${OTEL_RECEIVER_PORT:-4319}"
    cat << EOF
[otel]
environment = "dev"

[otel.exporter.otlp-http]
endpoint = "http://127.0.0.1:${receiver_port}"
protocol = "json"
EOF
}

# Update Codex config.toml with OTEL settings
update_codex_otel_settings() {
    local otel_config
    otel_config=$(generate_codex_otel_config)

    # Create ~/.codex directory if needed
    mkdir -p "$(dirname "$CODEX_CONFIG")"

    if [[ -f "$CODEX_CONFIG" ]]; then
        info "Updating existing Codex config: ${CODEX_CONFIG}"

        # Backup existing config
        cp "$CODEX_CONFIG" "${CODEX_CONFIG}.backup"
        info "Backup created: ${CODEX_CONFIG}.backup"

        # Check if OTEL is already configured
        if grep -q '^\[otel\]' "$CODEX_CONFIG"; then
            warn "Existing [otel] config found in Codex config."
            warn "Please manually update your OTEL config or remove it first:"
            echo ""
            echo "Current [otel] section will be replaced with:"
            echo "$otel_config"
            echo ""
            warn "To proceed, remove the existing [otel] section from ${CODEX_CONFIG}"
            return 1
        else
            # Append OTEL config to the file
            echo "" >> "$CODEX_CONFIG"
            echo "# tmux-stat OTEL integration" >> "$CODEX_CONFIG"
            echo "$otel_config" >> "$CODEX_CONFIG"
        fi
    else
        info "Creating new Codex config: ${CODEX_CONFIG}"
        cat > "$CODEX_CONFIG" << EOF
# Codex CLI configuration
# See: https://developers.openai.com/codex/config-reference

# tmux-stat OTEL integration
$otel_config
EOF
    fi
}

# Verify Codex OTEL installation
verify_codex_otel_installation() {
    info "Verifying Codex OTEL installation..."

    # Check state directory
    if [[ -d "$STATE_DIR" ]]; then
        info "State directory exists: ${STATE_DIR}"
    else
        error "State directory not created"
    fi

    # Check Codex config
    if [[ -f "$CODEX_CONFIG" ]]; then
        if grep -q '\[otel\]' "$CODEX_CONFIG"; then
            info "Codex OTEL config found"
        else
            warn "Codex OTEL config may not be properly configured"
        fi
    else
        warn "Codex config file not found (will be created on first use)"
    fi

    # Check OTEL receiver script
    if [[ -x "${PLUGIN_DIR}/scripts/otel-receiver.py" ]]; then
        info "OTEL receiver script is executable"
    else
        warn "OTEL receiver script is not executable, fixing..."
        chmod +x "${PLUGIN_DIR}/scripts/otel-receiver.py"
    fi

    # Check wrapper script
    if [[ -x "${PLUGIN_DIR}/scripts/codex-wrapper.sh" ]]; then
        info "Codex wrapper script is executable"
    else
        warn "Codex wrapper script is not executable, fixing..."
        chmod +x "${PLUGIN_DIR}/scripts/codex-wrapper.sh"
    fi

    info "Codex OTEL installation verified!"
}

# Uninstall Codex OTEL hooks
uninstall_codex_otel() {
    info "Uninstalling Codex OTEL hooks..."

    if [[ -f "$CODEX_CONFIG" ]]; then
        # Create backup
        cp "$CODEX_CONFIG" "${CODEX_CONFIG}.backup"

        # Remove OTEL section and tmux-stat comment
        # Use awk to remove the [otel] section, [otel.exporter] section, and related content
        awk '
            /^# tmux-stat OTEL integration/ { skip = 1; next }
            /^\[otel\]/ { skip = 1; next }
            /^\[otel\./ { skip = 1; next }
            /^\[/ && !/^\[otel/ { skip = 0 }
            !skip { print }
        ' "$CODEX_CONFIG" > "${CODEX_CONFIG}.tmp"
        mv "${CODEX_CONFIG}.tmp" "$CODEX_CONFIG"

        # Clean up empty lines at end of file (macOS compatible)
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$CODEX_CONFIG" 2>/dev/null || true
        else
            sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$CODEX_CONFIG" 2>/dev/null || true
        fi

        info "Codex OTEL config removed"
    fi

    # Stop receiver if running
    local pid_file="${STATE_DIR}/otel-receiver.pid"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            info "Stopped OTEL receiver (PID: $pid)"
        fi
        rm -f "$pid_file"
    fi

    info "Codex OTEL uninstallation complete"
}

# Update Codex config.toml with notify hook
update_codex_settings() {
    local notify_config
    notify_config=$(generate_codex_notify_config)

    # Create ~/.codex directory if needed
    mkdir -p "$(dirname "$CODEX_CONFIG")"

    if [[ -f "$CODEX_CONFIG" ]]; then
        info "Updating existing Codex config: ${CODEX_CONFIG}"

        # Backup existing config
        cp "$CODEX_CONFIG" "${CODEX_CONFIG}.backup"
        info "Backup created: ${CODEX_CONFIG}.backup"

        # Check if notify is already configured
        if grep -q '^notify\s*=' "$CODEX_CONFIG"; then
            warn "Existing notify config found in Codex config."
            warn "Please manually update your notify config to include the tmux-stat hook."
            warn "Add this to your existing notify array or replace it:"
            echo ""
            echo "    $notify_config"
            echo ""
            warn "If you have an existing notify script, you can chain them:"
            echo "    notify = [\"${PLUGIN_DIR}/scripts/codex-notify-wrapper.sh\"]"
            echo ""
            return 1
        else
            # Append notify config to the file
            echo "" >> "$CODEX_CONFIG"
            echo "# tmux-stat Codex integration" >> "$CODEX_CONFIG"
            echo "$notify_config" >> "$CODEX_CONFIG"
        fi
    else
        info "Creating new Codex config: ${CODEX_CONFIG}"
        cat > "$CODEX_CONFIG" << EOF
# Codex CLI configuration
# See: https://developers.openai.com/codex/config-reference

# tmux-stat Codex integration
$notify_config
EOF
    fi
}

# Verify Codex installation
verify_codex_installation() {
    info "Verifying Codex installation..."

    # Check state directory
    if [[ -d "$STATE_DIR" ]]; then
        info "State directory exists: ${STATE_DIR}"
    else
        error "State directory not created"
    fi

    # Check Codex config
    if [[ -f "$CODEX_CONFIG" ]]; then
        if grep -q "codex-hook.sh" "$CODEX_CONFIG"; then
            info "Codex notify hook configured successfully"
        else
            warn "Codex notify hook may not be properly configured"
        fi
    else
        warn "Codex config file not found (will be created on first use)"
    fi

    # Check hook script is executable
    if [[ -x "${PLUGIN_DIR}/scripts/codex-hook.sh" ]]; then
        info "Codex hook script is executable"
    else
        warn "Codex hook script is not executable, fixing..."
        chmod +x "${PLUGIN_DIR}/scripts/codex-hook.sh"
    fi

    info "Codex installation verified!"
}

# Uninstall Codex hooks
uninstall_codex() {
    info "Uninstalling Codex tmux-stat hooks..."

    if [[ -f "$CODEX_CONFIG" ]]; then
        # Create backup
        cp "$CODEX_CONFIG" "${CODEX_CONFIG}.backup"

        # Remove lines containing codex-hook.sh and the comment
        grep -v "codex-hook.sh" "$CODEX_CONFIG" | grep -v "# tmux-stat Codex integration" > "${CODEX_CONFIG}.tmp" || true
        mv "${CODEX_CONFIG}.tmp" "$CODEX_CONFIG"

        # Clean up empty lines at end of file
        sed -i.bak -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$CODEX_CONFIG" 2>/dev/null || true
        rm -f "${CODEX_CONFIG}.bak"

        info "Codex notify hook removed"
    fi

    info "Codex uninstallation complete"
}

# ============================================================================
# Print Usage Instructions
# ============================================================================

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

${YELLOW}Note on Codex CLI (notify method):${NC}
The basic Codex integration uses the 'notify' config which currently only
supports 'agent-turn-complete' events. This means:
- Status shows "done" when Codex is waiting for input
- Status shows "attention" if approval seems needed (heuristic)
- No "running" indicator (Codex doesn't expose session start events)

For richer Codex status tracking, use 'install-codex-otel' instead.

EOF
}

# Print OTEL usage instructions
print_otel_usage() {
    local wrapper_path="${PLUGIN_DIR}/scripts/codex-wrapper.sh"
    cat << EOF

${GREEN}Codex OTEL Integration Complete!${NC}

The OTEL receiver provides richer status tracking for Codex CLI:
- Running: When Codex starts working
- Attention: When tools need approval or fail
- Done: When Codex finishes

${YELLOW}Usage:${NC}

Use the wrapper script instead of codex directly:

    ${wrapper_path} "your prompt"

Or create an alias in your shell config (~/.bashrc or ~/.zshrc):

    alias codex='${wrapper_path}'

The wrapper automatically:
- Starts the OTEL receiver if not running
- Registers your tmux pane
- Cleans up on exit

${YELLOW}Manual Testing:${NC}

1. Start receiver manually:
   ${PLUGIN_DIR}/scripts/otel-receiver.py

2. In another terminal, check health:
   curl http://localhost:4319/health

3. Run the wrapper in a tmux pane and check state files:
   ls -la ~/.claude/tmux-stat/

${YELLOW}Receiver Auto-shutdown:${NC}
The receiver automatically shuts down after 5 minutes of inactivity.

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
            # Install both Claude Code and Codex hooks
            check_dependencies
            create_state_dir
            update_claude_settings
            verify_installation
            echo ""
            info "Installing Codex CLI hooks..."
            update_codex_settings && verify_codex_installation || true
            print_usage
            ;;
        install-claude)
            # Install only Claude Code hooks
            check_dependencies
            create_state_dir
            update_claude_settings
            verify_installation
            print_usage
            ;;
        install-codex)
            # Install only Codex CLI hooks (notify-based)
            check_dependencies
            create_state_dir
            update_codex_settings
            verify_codex_installation
            print_usage
            ;;
        install-codex-otel)
            # Install Codex CLI OTEL integration
            check_dependencies
            create_state_dir
            update_codex_otel_settings
            verify_codex_otel_installation
            print_otel_usage
            ;;
        uninstall)
            # Uninstall all
            uninstall
            uninstall_codex
            uninstall_codex_otel
            ;;
        uninstall-claude)
            uninstall
            ;;
        uninstall-codex)
            uninstall_codex
            ;;
        uninstall-codex-otel)
            uninstall_codex_otel
            ;;
        verify)
            verify_installation
            verify_codex_installation
            ;;
        *)
            echo "Usage: $0 [command]"
            echo ""
            echo "Commands:"
            echo "  install            Install hooks for both Claude Code and Codex CLI"
            echo "  install-claude     Install hooks for Claude Code only"
            echo "  install-codex      Install hooks for Codex CLI (notify-based, limited)"
            echo "  install-codex-otel Install Codex CLI OTEL integration (richer status)"
            echo "  uninstall          Uninstall all hooks"
            echo "  uninstall-claude   Uninstall Claude Code hooks only"
            echo "  uninstall-codex    Uninstall Codex CLI notify hooks only"
            echo "  uninstall-codex-otel Uninstall Codex OTEL integration"
            echo "  verify             Verify installation status"
            exit 1
            ;;
    esac
}

main "$@"
