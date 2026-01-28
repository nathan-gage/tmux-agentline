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
# Test: codex-hook.sh
# ============================================================

test_codex_hook_turn_complete_done() {
    echo -e "\n${YELLOW}Testing codex-hook.sh agent-turn-complete (done state)...${NC}"
    setup

    export TMUX_PANE="%200"
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/codex-hook.sh" '{"type": "agent-turn-complete", "thread-id": "thread1", "last-assistant-message": "I have completed the task."}'

    assert_file_exists "${TEST_STATE_DIR}/200.state" "agent-turn-complete creates state file"
    assert_json_field "${TEST_STATE_DIR}/200.state" ".status" "done" "agent-turn-complete sets status to done"
    assert_json_field "${TEST_STATE_DIR}/200.state" ".session_id" "thread1" "agent-turn-complete sets session_id from thread-id"

    teardown
}

test_codex_hook_turn_complete_attention() {
    echo -e "\n${YELLOW}Testing codex-hook.sh agent-turn-complete (attention state)...${NC}"
    setup

    export TMUX_PANE="%201"
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/codex-hook.sh" '{"type": "agent-turn-complete", "thread-id": "thread2", "last-assistant-message": "Do you want to approve this action?"}'

    assert_json_field "${TEST_STATE_DIR}/201.state" ".status" "attention" "agent-turn-complete with approval message sets attention"

    teardown
}

test_codex_hook_turn_complete_attention_confirm() {
    echo -e "\n${YELLOW}Testing codex-hook.sh agent-turn-complete (attention - confirm pattern)...${NC}"
    setup

    export TMUX_PANE="%202"
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/codex-hook.sh" '{"type": "agent-turn-complete", "thread-id": "thread3", "last-assistant-message": "Should I proceed with the changes?"}'

    assert_json_field "${TEST_STATE_DIR}/202.state" ".status" "attention" "agent-turn-complete with 'Should I' message sets attention"

    teardown
}

test_codex_hook_message_truncation() {
    echo -e "\n${YELLOW}Testing codex-hook.sh message truncation...${NC}"
    setup

    export TMUX_PANE="%203"
    export STATE_DIR="$TEST_STATE_DIR"
    local long_message="This is a very long message that should be truncated to fit in the status display properly without taking too much space"
    "${PLUGIN_DIR}/scripts/codex-hook.sh" "{\"type\": \"agent-turn-complete\", \"thread-id\": \"thread4\", \"last-assistant-message\": \"$long_message\"}"

    local message
    message=$(jq -r '.message' "${TEST_STATE_DIR}/203.state")

    # Message should be truncated and have "..." at the end
    if [[ "$message" == *"..."* ]] && [[ ${#message} -lt 70 ]]; then
        pass "codex-hook.sh truncates long messages"
    else
        fail "codex-hook.sh truncates long messages" "truncated with ..." "$message"
    fi

    teardown
}

test_codex_hook_no_tmux_pane() {
    echo -e "\n${YELLOW}Testing codex-hook.sh without TMUX_PANE...${NC}"
    setup

    unset TMUX_PANE
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/codex-hook.sh" '{"type": "agent-turn-complete", "thread-id": "thread5", "last-assistant-message": "Done"}'

    # Should not create any files
    local count
    count=$(find "$TEST_STATE_DIR" -name "*.state" -type f 2>/dev/null | wc -l | tr -d ' ')

    assert_eq "0" "$count" "No state file created without TMUX_PANE (codex)"

    teardown
}

test_codex_hook_no_input() {
    echo -e "\n${YELLOW}Testing codex-hook.sh with no input...${NC}"
    setup

    export TMUX_PANE="%204"
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/codex-hook.sh" ""

    # Should not create any files
    local count
    count=$(find "$TEST_STATE_DIR" -name "*.state" -type f 2>/dev/null | wc -l | tr -d ' ')

    assert_eq "0" "$count" "No state file created with empty input (codex)"

    teardown
}

test_codex_hook_unknown_event() {
    echo -e "\n${YELLOW}Testing codex-hook.sh with unknown event type...${NC}"
    setup

    export TMUX_PANE="%205"
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/codex-hook.sh" '{"type": "unknown-event", "thread-id": "thread6"}'

    # Should not create any files for unknown events
    local count
    count=$(find "$TEST_STATE_DIR" -name "*.state" -type f 2>/dev/null | wc -l | tr -d ' ')

    assert_eq "0" "$count" "No state file created for unknown event type (codex)"

    teardown
}

# ============================================================
# Test: otel-receiver.py
# ============================================================

test_otel_receiver_health() {
    echo -e "\n${YELLOW}Testing otel-receiver.py health endpoint...${NC}"
    setup

    # Start receiver on a test port
    local test_port=14319
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/otel-receiver.py" --port "$test_port" --state-dir "$TEST_STATE_DIR" > /dev/null 2>&1 &
    local receiver_pid=$!

    # Give it time to start
    local waited=0
    while ! curl -s --connect-timeout 1 "http://127.0.0.1:${test_port}/health" > /dev/null 2>&1 && [[ $waited -lt 20 ]]; do
        sleep 0.1
        ((waited++)) || true
    done

    # Check health endpoint
    local health_response
    health_response=$(curl -s --max-time 2 "http://127.0.0.1:${test_port}/health" 2>/dev/null || echo "")

    # Stop receiver with SIGTERM then SIGKILL if needed
    kill -TERM "$receiver_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true

    if [[ "$health_response" == *'"status": "ok"'* ]] || [[ "$health_response" == *'"status":"ok"'* ]]; then
        pass "otel-receiver health endpoint responds"
    else
        fail "otel-receiver health endpoint responds" "status: ok" "$health_response"
    fi

    teardown
}

test_otel_receiver_register_unregister() {
    echo -e "\n${YELLOW}Testing otel-receiver.py register/unregister...${NC}"
    setup

    # Start receiver on a test port
    local test_port=14320
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/otel-receiver.py" --port "$test_port" --state-dir "$TEST_STATE_DIR" > /dev/null 2>&1 &
    local receiver_pid=$!

    # Wait for startup
    local waited=0
    while ! curl -s --connect-timeout 1 "http://127.0.0.1:${test_port}/health" > /dev/null 2>&1 && [[ $waited -lt 20 ]]; do
        sleep 0.1
        ((waited++)) || true
    done

    # Register a pane
    local register_response
    register_response=$(curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/register" \
        -H "Content-Type: application/json" \
        -d '{"pane_id": "%999"}' 2>/dev/null || echo "")

    local register_ok=0
    if [[ "$register_response" == *'"status": "registered"'* ]] || [[ "$register_response" == *'"status":"registered"'* ]]; then
        register_ok=1
    fi

    # Unregister
    local unregister_response
    unregister_response=$(curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/unregister" \
        -H "Content-Type: application/json" \
        -d '{"pane_id": "%999"}' 2>/dev/null || echo "")

    # Stop receiver
    kill -TERM "$receiver_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true

    if [[ $register_ok -eq 1 ]]; then
        pass "otel-receiver register endpoint works"
    else
        fail "otel-receiver register endpoint works" "status: registered" "$register_response"
    fi

    if [[ "$unregister_response" == *'"status": "unregistered"'* ]] || [[ "$unregister_response" == *'"status":"unregistered"'* ]]; then
        pass "otel-receiver unregister endpoint works"
    else
        fail "otel-receiver unregister endpoint works" "status: unregistered" "$unregister_response"
    fi

    teardown
}

test_otel_receiver_logs_processing() {
    echo -e "\n${YELLOW}Testing otel-receiver.py OTLP logs processing...${NC}"
    setup

    # Start receiver on a test port
    local test_port=14321
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/otel-receiver.py" --port "$test_port" --state-dir "$TEST_STATE_DIR" > /dev/null 2>&1 &
    local receiver_pid=$!

    # Wait for startup
    local waited=0
    while ! curl -s --connect-timeout 1 "http://127.0.0.1:${test_port}/health" > /dev/null 2>&1 && [[ $waited -lt 20 ]]; do
        sleep 0.1
        ((waited++)) || true
    done

    # Register a pane first
    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/register" \
        -H "Content-Type: application/json" \
        -d '{"pane_id": "%888"}' > /dev/null 2>&1

    # Send OTLP log with conversation_starts event
    local otlp_payload='{
        "resourceLogs": [{
            "scopeLogs": [{
                "logRecords": [{
                    "attributes": [
                        {"key": "event.name", "value": {"stringValue": "codex.conversation_starts"}},
                        {"key": "conversation_id", "value": {"stringValue": "conv123"}},
                        {"key": "model", "value": {"stringValue": "gpt-4"}}
                    ]
                }]
            }]
        }]
    }'

    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/v1/logs" \
        -H "Content-Type: application/json" \
        -d "$otlp_payload" > /dev/null 2>&1

    # Give it time to process
    sleep 0.3

    # Stop receiver
    kill -TERM "$receiver_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true

    # Check if state file was created
    if [[ -f "${TEST_STATE_DIR}/888.state" ]]; then
        local status
        status=$(jq -r '.status' "${TEST_STATE_DIR}/888.state" 2>/dev/null || echo "")
        if [[ "$status" == "running" ]]; then
            pass "otel-receiver processes OTLP logs and creates state"
        else
            fail "otel-receiver processes OTLP logs" "status: running" "status: $status"
        fi
    else
        fail "otel-receiver creates state file" "file exists" "file not found"
    fi

    teardown
}

test_otel_receiver_attention_state() {
    echo -e "\n${YELLOW}Testing otel-receiver.py attention state on tool_decision...${NC}"
    setup

    # Start receiver on a test port
    local test_port=14322
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/otel-receiver.py" --port "$test_port" --state-dir "$TEST_STATE_DIR" > /dev/null 2>&1 &
    local receiver_pid=$!

    # Wait for startup
    local waited=0
    while ! curl -s --connect-timeout 1 "http://127.0.0.1:${test_port}/health" > /dev/null 2>&1 && [[ $waited -lt 20 ]]; do
        sleep 0.1
        ((waited++)) || true
    done

    # Register a pane first
    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/register" \
        -H "Content-Type: application/json" \
        -d '{"pane_id": "%777"}' > /dev/null 2>&1

    # Send OTLP log with tool_decision pending event
    local otlp_payload='{
        "resourceLogs": [{
            "scopeLogs": [{
                "logRecords": [{
                    "attributes": [
                        {"key": "event.name", "value": {"stringValue": "codex.tool_decision"}},
                        {"key": "conversation_id", "value": {"stringValue": "conv456"}},
                        {"key": "status", "value": {"stringValue": "pending"}},
                        {"key": "tool_name", "value": {"stringValue": "write_file"}}
                    ]
                }]
            }]
        }]
    }'

    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/v1/logs" \
        -H "Content-Type: application/json" \
        -d "$otlp_payload" > /dev/null 2>&1

    # Give it time to process
    sleep 0.3

    # Stop receiver
    kill -TERM "$receiver_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true

    # Check state
    if [[ -f "${TEST_STATE_DIR}/777.state" ]]; then
        local status
        status=$(jq -r '.status' "${TEST_STATE_DIR}/777.state" 2>/dev/null || echo "")
        assert_eq "attention" "$status" "otel-receiver sets attention on pending tool_decision"
    else
        fail "otel-receiver sets attention state" "file exists" "file not found"
    fi

    teardown
}

test_otel_receiver_traces_processing() {
    echo -e "\n${YELLOW}Testing otel-receiver.py OTLP traces processing...${NC}"
    setup

    # Start receiver on a test port
    local test_port=14323
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/otel-receiver.py" --port "$test_port" --state-dir "$TEST_STATE_DIR" > /dev/null 2>&1 &
    local receiver_pid=$!

    # Wait for startup
    local waited=0
    while ! curl -s --connect-timeout 1 "http://127.0.0.1:${test_port}/health" > /dev/null 2>&1 && [[ $waited -lt 20 ]]; do
        sleep 0.1
        ((waited++)) || true
    done

    # Register a pane first
    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/register" \
        -H "Content-Type: application/json" \
        -d '{"pane_id": "%666"}' > /dev/null 2>&1

    # Send OTLP trace (spans format) with conversation_starts event
    local otlp_payload='{
        "resourceSpans": [{
            "scopeSpans": [{
                "spans": [{
                    "name": "codex.conversation_starts",
                    "attributes": [
                        {"key": "conversation_id", "value": {"stringValue": "conv-trace-1"}},
                        {"key": "model", "value": {"stringValue": "gpt-4"}}
                    ]
                }]
            }]
        }]
    }'

    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/v1/traces" \
        -H "Content-Type: application/json" \
        -d "$otlp_payload" > /dev/null 2>&1

    sleep 0.3

    # Stop receiver
    kill -TERM "$receiver_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true

    # Check if state file was created
    if [[ -f "${TEST_STATE_DIR}/666.state" ]]; then
        local status
        status=$(jq -r '.status' "${TEST_STATE_DIR}/666.state" 2>/dev/null || echo "")
        if [[ "$status" == "running" ]]; then
            pass "otel-receiver processes OTLP traces and creates state"
        else
            fail "otel-receiver processes OTLP traces" "status: running" "status: $status"
        fi
    else
        fail "otel-receiver creates state file from traces" "file exists" "file not found"
    fi

    teardown
}

test_otel_receiver_root_path() {
    echo -e "\n${YELLOW}Testing otel-receiver.py root path handling...${NC}"
    setup

    # Start receiver on a test port
    local test_port=14324
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/otel-receiver.py" --port "$test_port" --state-dir "$TEST_STATE_DIR" > /dev/null 2>&1 &
    local receiver_pid=$!

    # Wait for startup
    local waited=0
    while ! curl -s --connect-timeout 1 "http://127.0.0.1:${test_port}/health" > /dev/null 2>&1 && [[ $waited -lt 20 ]]; do
        sleep 0.1
        ((waited++)) || true
    done

    # Register a pane first
    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/register" \
        -H "Content-Type: application/json" \
        -d '{"pane_id": "%555"}' > /dev/null 2>&1

    # Send OTLP data to root path (Codex sends here)
    local otlp_payload='{
        "resourceLogs": [{
            "scopeLogs": [{
                "logRecords": [{
                    "attributes": [
                        {"key": "event.name", "value": {"stringValue": "codex.conversation_starts"}},
                        {"key": "conversation_id", "value": {"stringValue": "conv-root-1"}}
                    ]
                }]
            }]
        }]
    }'

    local response
    response=$(curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/" \
        -H "Content-Type: application/json" \
        -d "$otlp_payload" 2>/dev/null || echo "")

    sleep 0.3

    # Stop receiver
    kill -TERM "$receiver_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true

    # Check response was OK
    if [[ "$response" == *'"status"'*'"ok"'* ]]; then
        pass "otel-receiver accepts POST to root path"
    else
        fail "otel-receiver accepts POST to root path" "status: ok" "$response"
    fi

    teardown
}

test_otel_receiver_tool_result_failed() {
    echo -e "\n${YELLOW}Testing otel-receiver.py attention state on tool_result failure...${NC}"
    setup

    # Start receiver on a test port
    local test_port=14325
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/otel-receiver.py" --port "$test_port" --state-dir "$TEST_STATE_DIR" > /dev/null 2>&1 &
    local receiver_pid=$!

    # Wait for startup
    local waited=0
    while ! curl -s --connect-timeout 1 "http://127.0.0.1:${test_port}/health" > /dev/null 2>&1 && [[ $waited -lt 20 ]]; do
        sleep 0.1
        ((waited++)) || true
    done

    # Register a pane first
    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/register" \
        -H "Content-Type: application/json" \
        -d '{"pane_id": "%444"}' > /dev/null 2>&1

    # Send OTLP log with tool_result failed event
    local otlp_payload='{
        "resourceLogs": [{
            "scopeLogs": [{
                "logRecords": [{
                    "attributes": [
                        {"key": "event.name", "value": {"stringValue": "codex.tool_result"}},
                        {"key": "conversation_id", "value": {"stringValue": "conv-fail-1"}},
                        {"key": "status", "value": {"stringValue": "failed"}},
                        {"key": "tool_name", "value": {"stringValue": "shell_command"}}
                    ]
                }]
            }]
        }]
    }'

    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/v1/logs" \
        -H "Content-Type: application/json" \
        -d "$otlp_payload" > /dev/null 2>&1

    sleep 0.3

    # Stop receiver
    kill -TERM "$receiver_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true

    # Check state
    if [[ -f "${TEST_STATE_DIR}/444.state" ]]; then
        local status
        status=$(jq -r '.status' "${TEST_STATE_DIR}/444.state" 2>/dev/null || echo "")
        assert_eq "attention" "$status" "otel-receiver sets attention on failed tool_result"
    else
        fail "otel-receiver sets attention on failed tool" "file exists" "file not found"
    fi

    teardown
}

test_otel_receiver_conversation_ends() {
    echo -e "\n${YELLOW}Testing otel-receiver.py done state on conversation_ends...${NC}"
    setup

    # Start receiver on a test port
    local test_port=14326
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/otel-receiver.py" --port "$test_port" --state-dir "$TEST_STATE_DIR" > /dev/null 2>&1 &
    local receiver_pid=$!

    # Wait for startup
    local waited=0
    while ! curl -s --connect-timeout 1 "http://127.0.0.1:${test_port}/health" > /dev/null 2>&1 && [[ $waited -lt 20 ]]; do
        sleep 0.1
        ((waited++)) || true
    done

    # Register a pane first
    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/register" \
        -H "Content-Type: application/json" \
        -d '{"pane_id": "%333"}' > /dev/null 2>&1

    # Send OTLP log with conversation_ends event
    local otlp_payload='{
        "resourceLogs": [{
            "scopeLogs": [{
                "logRecords": [{
                    "attributes": [
                        {"key": "event.name", "value": {"stringValue": "codex.conversation_ends"}},
                        {"key": "conversation_id", "value": {"stringValue": "conv-end-1"}}
                    ]
                }]
            }]
        }]
    }'

    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/v1/logs" \
        -H "Content-Type: application/json" \
        -d "$otlp_payload" > /dev/null 2>&1

    sleep 0.3

    # Stop receiver
    kill -TERM "$receiver_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true

    # Check state
    if [[ -f "${TEST_STATE_DIR}/333.state" ]]; then
        local status
        status=$(jq -r '.status' "${TEST_STATE_DIR}/333.state" 2>/dev/null || echo "")
        assert_eq "done" "$status" "otel-receiver sets done on conversation_ends"
    else
        fail "otel-receiver sets done state" "file exists" "file not found"
    fi

    teardown
}

test_otel_receiver_tool_decision_approved() {
    echo -e "\n${YELLOW}Testing otel-receiver.py running state on tool_decision approved...${NC}"
    setup

    # Start receiver on a test port
    local test_port=14327
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/otel-receiver.py" --port "$test_port" --state-dir "$TEST_STATE_DIR" > /dev/null 2>&1 &
    local receiver_pid=$!

    # Wait for startup
    local waited=0
    while ! curl -s --connect-timeout 1 "http://127.0.0.1:${test_port}/health" > /dev/null 2>&1 && [[ $waited -lt 20 ]]; do
        sleep 0.1
        ((waited++)) || true
    done

    # Register a pane first
    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/register" \
        -H "Content-Type: application/json" \
        -d '{"pane_id": "%222"}' > /dev/null 2>&1

    # Send OTLP log with tool_decision approved event
    local otlp_payload='{
        "resourceLogs": [{
            "scopeLogs": [{
                "logRecords": [{
                    "attributes": [
                        {"key": "event.name", "value": {"stringValue": "codex.tool_decision"}},
                        {"key": "conversation_id", "value": {"stringValue": "conv-approved-1"}},
                        {"key": "status", "value": {"stringValue": "approved"}},
                        {"key": "tool_name", "value": {"stringValue": "write_file"}}
                    ]
                }]
            }]
        }]
    }'

    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/v1/logs" \
        -H "Content-Type: application/json" \
        -d "$otlp_payload" > /dev/null 2>&1

    sleep 0.3

    # Stop receiver
    kill -TERM "$receiver_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true

    # Check state
    if [[ -f "${TEST_STATE_DIR}/222.state" ]]; then
        local status message
        status=$(jq -r '.status' "${TEST_STATE_DIR}/222.state" 2>/dev/null || echo "")
        message=$(jq -r '.message' "${TEST_STATE_DIR}/222.state" 2>/dev/null || echo "")
        assert_eq "running" "$status" "otel-receiver sets running on approved tool_decision"
        if [[ "$message" == *"Approved"* ]]; then
            pass "otel-receiver message contains 'Approved'"
        else
            fail "otel-receiver message contains 'Approved'" "contains Approved" "$message"
        fi
    else
        fail "otel-receiver sets running state" "file exists" "file not found"
    fi

    teardown
}

test_otel_receiver_tool_result_success() {
    echo -e "\n${YELLOW}Testing otel-receiver.py running state on successful tool_result...${NC}"
    setup

    # Start receiver on a test port
    local test_port=14328
    export STATE_DIR="$TEST_STATE_DIR"
    "${PLUGIN_DIR}/scripts/otel-receiver.py" --port "$test_port" --state-dir "$TEST_STATE_DIR" > /dev/null 2>&1 &
    local receiver_pid=$!

    # Wait for startup
    local waited=0
    while ! curl -s --connect-timeout 1 "http://127.0.0.1:${test_port}/health" > /dev/null 2>&1 && [[ $waited -lt 20 ]]; do
        sleep 0.1
        ((waited++)) || true
    done

    # Register a pane first
    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/register" \
        -H "Content-Type: application/json" \
        -d '{"pane_id": "%111"}' > /dev/null 2>&1

    # Send OTLP log with successful tool_result event
    local otlp_payload='{
        "resourceLogs": [{
            "scopeLogs": [{
                "logRecords": [{
                    "attributes": [
                        {"key": "event.name", "value": {"stringValue": "codex.tool_result"}},
                        {"key": "conversation_id", "value": {"stringValue": "conv-success-1"}},
                        {"key": "tool_name", "value": {"stringValue": "read_file"}},
                        {"key": "success", "value": {"boolValue": true}}
                    ]
                }]
            }]
        }]
    }'

    curl -s --max-time 2 -X POST "http://127.0.0.1:${test_port}/v1/logs" \
        -H "Content-Type: application/json" \
        -d "$otlp_payload" > /dev/null 2>&1

    sleep 0.3

    # Stop receiver
    kill -TERM "$receiver_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$receiver_pid" 2>/dev/null || true
    wait "$receiver_pid" 2>/dev/null || true

    # Check state
    if [[ -f "${TEST_STATE_DIR}/111.state" ]]; then
        local status message
        status=$(jq -r '.status' "${TEST_STATE_DIR}/111.state" 2>/dev/null || echo "")
        message=$(jq -r '.message' "${TEST_STATE_DIR}/111.state" 2>/dev/null || echo "")
        assert_eq "running" "$status" "otel-receiver sets running on successful tool_result"
        if [[ "$message" == *"Ran:"* ]]; then
            pass "otel-receiver message contains 'Ran:'"
        else
            fail "otel-receiver message contains 'Ran:'" "contains Ran:" "$message"
        fi
    else
        fail "otel-receiver sets running state on success" "file exists" "file not found"
    fi

    teardown
}

# ============================================================
# Test: codex-wrapper.sh
# ============================================================

test_codex_wrapper_finds_codex_error() {
    echo -e "\n${YELLOW}Testing codex-wrapper.sh error when codex not found...${NC}"
    setup

    # Run wrapper with a PATH that has only basic commands but no codex
    # We need /usr/bin for basic commands like cat, but exclude any codex installation
    local result
    result=$(PATH="/usr/bin:/bin" "${PLUGIN_DIR}/scripts/codex-wrapper.sh" 2>&1 || true)

    if [[ "$result" == *"Could not find codex binary"* ]]; then
        pass "codex-wrapper reports error when codex not found"
    else
        fail "codex-wrapper reports error when codex not found" "error message" "$result"
    fi

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

# codex-hook.sh tests
test_codex_hook_turn_complete_done
test_codex_hook_turn_complete_attention
test_codex_hook_turn_complete_attention_confirm
test_codex_hook_message_truncation
test_codex_hook_no_tmux_pane
test_codex_hook_no_input
test_codex_hook_unknown_event

# otel-receiver.py tests (only run if Python 3 and curl available)
if command -v python3 &> /dev/null && command -v curl &> /dev/null; then
    test_otel_receiver_health
    test_otel_receiver_register_unregister
    test_otel_receiver_logs_processing
    test_otel_receiver_attention_state
    test_otel_receiver_traces_processing
    test_otel_receiver_root_path
    test_otel_receiver_tool_result_failed
    test_otel_receiver_conversation_ends
    test_otel_receiver_tool_decision_approved
    test_otel_receiver_tool_result_success
else
    echo -e "${YELLOW}Skipping OTEL receiver tests (python3 or curl not available)${NC}"
fi

# codex-wrapper.sh tests
test_codex_wrapper_finds_codex_error

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
