#!/usr/bin/env bash
# run_tests.sh - Test suite for tmux-stat plugin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
TEST_STATE_DIR="${SCRIPT_DIR}/test_state"
PASSED=0
FAILED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Override STATE_DIR for tests
export STATE_DIR="$TEST_STATE_DIR"
# Skip pane existence check during tests
export TMUX_STAT_SKIP_PANE_CHECK=1

# Test utilities
setup() {
    rm -rf "$TEST_STATE_DIR"
    mkdir -p "$TEST_STATE_DIR"
}

teardown() {
    rm -rf "$TEST_STATE_DIR"
}

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    ((PASSED++)) || true
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    echo "       Expected: $2"
    echo "       Got: $3"
    ((FAILED++)) || true
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local test_name="$3"

    if [[ "$expected" == "$actual" ]]; then
        pass "$test_name"
    else
        fail "$test_name" "$expected" "$actual"
    fi
}

assert_file_exists() {
    local file="$1"
    local test_name="$2"

    if [[ -f "$file" ]]; then
        pass "$test_name"
    else
        fail "$test_name" "file exists" "file not found: $file"
    fi
}

assert_file_not_exists() {
    local file="$1"
    local test_name="$2"

    if [[ ! -f "$file" ]]; then
        pass "$test_name"
    else
        fail "$test_name" "file does not exist" "file exists: $file"
    fi
}

assert_json_field() {
    local file="$1"
    local field="$2"
    local expected="$3"
    local test_name="$4"

    local actual
    actual=$(jq -r "$field" "$file" 2>/dev/null || echo "")

    assert_eq "$expected" "$actual" "$test_name"
}

# Source helpers with overridden STATE_DIR
source_helpers() {
    # Temporarily override the STATE_DIR in helpers.sh
    (
        source "${PLUGIN_DIR}/scripts/helpers.sh"
        # Re-export STATE_DIR
        export STATE_DIR="$TEST_STATE_DIR"
    )
}

# ============================================================
# Test: helpers.sh
# ============================================================

test_ensure_state_dir() {
    echo -e "\n${YELLOW}Testing ensure_state_dir...${NC}"
    setup

    # Remove dir to test creation
    rmdir "$TEST_STATE_DIR" 2>/dev/null || true

    (
        export STATE_DIR="$TEST_STATE_DIR"
        source "${PLUGIN_DIR}/scripts/helpers.sh"
        ensure_state_dir
    )

    if [[ -d "$TEST_STATE_DIR" ]]; then
        pass "ensure_state_dir creates directory"
    else
        fail "ensure_state_dir creates directory" "directory created" "directory not created"
    fi

    teardown
}

test_get_state_file() {
    echo -e "\n${YELLOW}Testing get_state_file...${NC}"
    setup

    local result
    result=$(
        export STATE_DIR="$TEST_STATE_DIR"
        source "${PLUGIN_DIR}/scripts/helpers.sh"
        get_state_file "%123"
    )

    assert_eq "${TEST_STATE_DIR}/123.state" "$result" "get_state_file strips % prefix"

    teardown
}

test_write_state() {
    echo -e "\n${YELLOW}Testing write_state...${NC}"
    setup

    (
        export STATE_DIR="$TEST_STATE_DIR"
        source "${PLUGIN_DIR}/scripts/helpers.sh"
        write_state "%123" "running" "session1" "Test message"
    )

    assert_file_exists "${TEST_STATE_DIR}/123.state" "write_state creates state file"
    assert_json_field "${TEST_STATE_DIR}/123.state" ".status" "running" "write_state sets status"
    assert_json_field "${TEST_STATE_DIR}/123.state" ".session_id" "session1" "write_state sets session_id"
    assert_json_field "${TEST_STATE_DIR}/123.state" ".message" "Test message" "write_state sets message"

    teardown
}

test_read_state() {
    echo -e "\n${YELLOW}Testing read_state...${NC}"
    setup

    # Create a state file manually
    echo '{"status": "done", "timestamp": 12345}' > "${TEST_STATE_DIR}/456.state"

    local result
    result=$(
        export STATE_DIR="$TEST_STATE_DIR"
        source "${PLUGIN_DIR}/scripts/helpers.sh"
        read_state "%456"
    )

    local status
    status=$(echo "$result" | jq -r '.status')

    assert_eq "done" "$status" "read_state reads status correctly"

    # Test non-existent file
    result=$(
        export STATE_DIR="$TEST_STATE_DIR"
        source "${PLUGIN_DIR}/scripts/helpers.sh"
        read_state "%nonexistent"
    )

    assert_eq "" "$result" "read_state returns empty for non-existent file"

    teardown
}

test_remove_state() {
    echo -e "\n${YELLOW}Testing remove_state...${NC}"
    setup

    # Create a state file
    echo '{"status": "done"}' > "${TEST_STATE_DIR}/789.state"

    (
        export STATE_DIR="$TEST_STATE_DIR"
        source "${PLUGIN_DIR}/scripts/helpers.sh"
        remove_state "%789"
    )

    assert_file_not_exists "${TEST_STATE_DIR}/789.state" "remove_state deletes state file"

    teardown
}

test_cleanup_stale_states() {
    echo -e "\n${YELLOW}Testing cleanup_stale_states...${NC}"
    setup

    # Create a stale state file (timestamp from 10 minutes ago)
    local old_timestamp=$(($(date +%s) - 600))
    echo "{\"status\": \"running\", \"timestamp\": $old_timestamp}" > "${TEST_STATE_DIR}/old.state"

    # Create a fresh state file
    local new_timestamp=$(date +%s)
    echo "{\"status\": \"running\", \"timestamp\": $new_timestamp}" > "${TEST_STATE_DIR}/new.state"

    (
        export STATE_DIR="$TEST_STATE_DIR"
        source "${PLUGIN_DIR}/scripts/helpers.sh"
        cleanup_stale_states
    )

    assert_file_not_exists "${TEST_STATE_DIR}/old.state" "cleanup_stale_states removes old files"
    assert_file_exists "${TEST_STATE_DIR}/new.state" "cleanup_stale_states keeps fresh files"

    teardown
}

# ============================================================
# Test: claude-hook.sh
# ============================================================

test_hook_session_start() {
    echo -e "\n${YELLOW}Testing claude-hook.sh SessionStart...${NC}"
    setup

    export TMUX_PANE="%100"
    export STATE_DIR="$TEST_STATE_DIR"
    echo '{"hook_event_name": "SessionStart", "session_id": "sess1", "cwd": "/tmp"}' | "${PLUGIN_DIR}/scripts/claude-hook.sh"

    assert_file_exists "${TEST_STATE_DIR}/100.state" "SessionStart creates state file"
    assert_json_field "${TEST_STATE_DIR}/100.state" ".status" "running" "SessionStart sets status to running"

    teardown
}

test_hook_pre_tool_use() {
    echo -e "\n${YELLOW}Testing claude-hook.sh PreToolUse...${NC}"
    setup

    export TMUX_PANE="%101"
    export STATE_DIR="$TEST_STATE_DIR"
    echo '{"hook_event_name": "PreToolUse", "tool_name": "Read", "session_id": "sess2"}' | "${PLUGIN_DIR}/scripts/claude-hook.sh"

    assert_file_exists "${TEST_STATE_DIR}/101.state" "PreToolUse creates state file"
    assert_json_field "${TEST_STATE_DIR}/101.state" ".status" "running" "PreToolUse sets status to running"
    assert_json_field "${TEST_STATE_DIR}/101.state" ".message" "Using tool: Read" "PreToolUse sets message"

    teardown
}

test_hook_permission_request() {
    echo -e "\n${YELLOW}Testing claude-hook.sh PermissionRequest...${NC}"
    setup

    export TMUX_PANE="%102"
    export STATE_DIR="$TEST_STATE_DIR"
    echo '{"hook_event_name": "PermissionRequest", "tool_name": "Bash", "session_id": "sess3"}' | "${PLUGIN_DIR}/scripts/claude-hook.sh"

    assert_json_field "${TEST_STATE_DIR}/102.state" ".status" "attention" "PermissionRequest sets status to attention"

    teardown
}

test_hook_notification_permission() {
    echo -e "\n${YELLOW}Testing claude-hook.sh Notification (permission_prompt)...${NC}"
    setup

    export TMUX_PANE="%103"
    export STATE_DIR="$TEST_STATE_DIR"
    echo '{"hook_event_name": "Notification", "notification_type": "permission_prompt", "session_id": "sess4"}' | "${PLUGIN_DIR}/scripts/claude-hook.sh"

    assert_json_field "${TEST_STATE_DIR}/103.state" ".status" "attention" "Notification permission_prompt sets attention"

    teardown
}

test_hook_notification_idle() {
    echo -e "\n${YELLOW}Testing claude-hook.sh Notification (idle_prompt)...${NC}"
    setup

    export TMUX_PANE="%104"
    export STATE_DIR="$TEST_STATE_DIR"
    echo '{"hook_event_name": "Notification", "notification_type": "idle_prompt", "session_id": "sess5"}' | "${PLUGIN_DIR}/scripts/claude-hook.sh"

    assert_json_field "${TEST_STATE_DIR}/104.state" ".status" "done" "Notification idle_prompt sets done (not attention)"

    teardown
}

test_hook_stop() {
    echo -e "\n${YELLOW}Testing claude-hook.sh Stop...${NC}"
    setup

    export TMUX_PANE="%105"
    export STATE_DIR="$TEST_STATE_DIR"
    echo '{"hook_event_name": "Stop", "reason": "completed", "session_id": "sess6"}' | "${PLUGIN_DIR}/scripts/claude-hook.sh"

    assert_json_field "${TEST_STATE_DIR}/105.state" ".status" "done" "Stop sets status to done"

    teardown
}

test_hook_session_end() {
    echo -e "\n${YELLOW}Testing claude-hook.sh SessionEnd...${NC}"
    setup

    # First create a state file
    export TMUX_PANE="%106"
    export STATE_DIR="$TEST_STATE_DIR"
    echo '{"status": "done"}' > "${TEST_STATE_DIR}/106.state"

    # Then send SessionEnd
    echo '{"hook_event_name": "SessionEnd", "session_id": "sess7"}' | "${PLUGIN_DIR}/scripts/claude-hook.sh"

    assert_file_not_exists "${TEST_STATE_DIR}/106.state" "SessionEnd removes state file"

    teardown
}

test_hook_no_tmux_pane() {
    echo -e "\n${YELLOW}Testing claude-hook.sh without TMUX_PANE...${NC}"
    setup

    unset TMUX_PANE
    export STATE_DIR="$TEST_STATE_DIR"
    echo '{"hook_event_name": "SessionStart", "session_id": "sess8"}' | "${PLUGIN_DIR}/scripts/claude-hook.sh"

    # Should not create any files
    local count
    count=$(find "$TEST_STATE_DIR" -name "*.state" -type f 2>/dev/null | wc -l | tr -d ' ')

    assert_eq "0" "$count" "No state file created without TMUX_PANE"

    teardown
}

# ============================================================
# Test: status.sh
# ============================================================

test_status_empty() {
    echo -e "\n${YELLOW}Testing status.sh with no state files...${NC}"
    setup

    export STATE_DIR="$TEST_STATE_DIR"
    local result
    result=$("${PLUGIN_DIR}/scripts/status.sh")

    assert_eq "" "$result" "status.sh returns empty when no sessions"

    teardown
}

test_status_running() {
    echo -e "\n${YELLOW}Testing status.sh with running state...${NC}"
    setup

    export STATE_DIR="$TEST_STATE_DIR"
    local now=$(date +%s)
    echo "{\"status\": \"running\", \"timestamp\": $now}" > "${TEST_STATE_DIR}/1.state"

    local result
    result=$("${PLUGIN_DIR}/scripts/status.sh")

    # Should contain yellow style and running icon
    if [[ "$result" == *"fg=yellow"* ]]; then
        pass "status.sh shows running indicator"
    else
        fail "status.sh shows running indicator" "contains fg=yellow" "$result"
    fi

    teardown
}

test_status_attention() {
    echo -e "\n${YELLOW}Testing status.sh with attention state...${NC}"
    setup

    export STATE_DIR="$TEST_STATE_DIR"
    local now=$(date +%s)
    echo "{\"status\": \"attention\", \"timestamp\": $now}" > "${TEST_STATE_DIR}/1.state"

    local result
    result=$("${PLUGIN_DIR}/scripts/status.sh")

    # Should contain red style
    if [[ "$result" == *"fg=red"* ]]; then
        pass "status.sh shows attention indicator"
    else
        fail "status.sh shows attention indicator" "contains fg=red" "$result"
    fi

    teardown
}

test_status_done() {
    echo -e "\n${YELLOW}Testing status.sh with done state...${NC}"
    setup

    export STATE_DIR="$TEST_STATE_DIR"
    local now=$(date +%s)
    echo "{\"status\": \"done\", \"timestamp\": $now}" > "${TEST_STATE_DIR}/1.state"

    local result
    result=$("${PLUGIN_DIR}/scripts/status.sh")

    # Should contain green style
    if [[ "$result" == *"fg=green"* ]]; then
        pass "status.sh shows done indicator"
    else
        fail "status.sh shows done indicator" "contains fg=green" "$result"
    fi

    teardown
}

test_status_priority() {
    echo -e "\n${YELLOW}Testing status.sh priority (attention > running > done)...${NC}"
    setup

    export STATE_DIR="$TEST_STATE_DIR"
    local now=$(date +%s)

    # Create all three states
    echo "{\"status\": \"running\", \"timestamp\": $now}" > "${TEST_STATE_DIR}/1.state"
    echo "{\"status\": \"done\", \"timestamp\": $now}" > "${TEST_STATE_DIR}/2.state"
    echo "{\"status\": \"attention\", \"timestamp\": $now}" > "${TEST_STATE_DIR}/3.state"

    local result
    result=$("${PLUGIN_DIR}/scripts/status.sh")

    # Should show attention (highest priority) with red
    if [[ "$result" == *"fg=red"* ]]; then
        pass "status.sh shows attention (highest priority)"
    else
        fail "status.sh shows attention (highest priority)" "contains fg=red" "$result"
    fi

    teardown
}

test_status_count() {
    echo -e "\n${YELLOW}Testing status.sh count display...${NC}"
    setup

    export STATE_DIR="$TEST_STATE_DIR"
    local now=$(date +%s)

    # Create multiple attention states
    echo "{\"status\": \"attention\", \"timestamp\": $now}" > "${TEST_STATE_DIR}/1.state"
    echo "{\"status\": \"attention\", \"timestamp\": $now}" > "${TEST_STATE_DIR}/2.state"
    echo "{\"status\": \"attention\", \"timestamp\": $now}" > "${TEST_STATE_DIR}/3.state"

    local result
    result=$("${PLUGIN_DIR}/scripts/status.sh")

    # Should show count of 3
    if [[ "$result" == *" 3"* ]]; then
        pass "status.sh shows count when multiple sessions"
    else
        fail "status.sh shows count when multiple sessions" "contains 3" "$result"
    fi

    teardown
}

# ============================================================
# Run all tests
# ============================================================

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}tmux-stat Test Suite${NC}"
echo -e "${YELLOW}========================================${NC}"

# Check for required dependencies
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is required for tests${NC}"
    exit 1
fi

# helpers.sh tests
test_ensure_state_dir
test_get_state_file
test_write_state
test_read_state
test_remove_state
test_cleanup_stale_states

# claude-hook.sh tests
test_hook_session_start
test_hook_pre_tool_use
test_hook_permission_request
test_hook_notification_permission
test_hook_notification_idle
test_hook_stop
test_hook_session_end
test_hook_no_tmux_pane

# status.sh tests
test_status_empty
test_status_running
test_status_attention
test_status_done
test_status_priority
test_status_count

# Summary
echo -e "\n${YELLOW}========================================${NC}"
echo -e "${YELLOW}Test Summary${NC}"
echo -e "${YELLOW}========================================${NC}"
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
