#!/usr/bin/env python3
"""
otel-receiver.py - Lightweight OTLP HTTP receiver for Codex CLI telemetry.

This server captures OpenTelemetry events from Codex CLI and maps them to
tmux-stat state files for status display.

Endpoints:
  POST /v1/logs      - OTLP logs receiver (Codex telemetry)
  POST /register     - Register pane ID with conversation ID
  POST /unregister   - Unregister pane ID
  GET  /health       - Health check

Usage:
  ./otel-receiver.py [--port PORT] [--state-dir DIR]
"""

import argparse
import base64
import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from pathlib import Path


# Configuration
DEFAULT_PORT = 4319
DEFAULT_STATE_DIR = os.path.expanduser("~/.claude/tmux-stat")
IDLE_TIMEOUT = 300  # 5 minutes
STALE_MAPPING_TIMEOUT = 600  # 10 minutes


class OTELReceiver:
    """Manages OTEL event processing and pane mappings."""

    def __init__(self, state_dir: str):
        self.state_dir = Path(state_dir)
        self.state_dir.mkdir(parents=True, exist_ok=True)

        # conversation_id -> pane_id mapping
        self.mappings: dict[str, dict] = {}
        self.mappings_lock = threading.Lock()

        # Track last activity for idle shutdown
        self.last_activity = time.time()

    def touch_activity(self):
        """Update last activity timestamp."""
        self.last_activity = time.time()

    def is_idle(self) -> bool:
        """Check if server has been idle beyond timeout."""
        return time.time() - self.last_activity > IDLE_TIMEOUT

    def register_pane(self, pane_id: str, conversation_id: str = None) -> str:
        """Register a pane, optionally with a conversation ID."""
        self.touch_activity()
        with self.mappings_lock:
            # Generate a temporary ID if no conversation ID yet
            mapping_key = conversation_id or f"pending_{pane_id}"
            self.mappings[mapping_key] = {
                "pane_id": pane_id,
                "registered_at": time.time(),
                "conversation_id": conversation_id,
            }
            return mapping_key

    def unregister_pane(self, pane_id: str):
        """Unregister a pane and remove its state file."""
        self.touch_activity()
        with self.mappings_lock:
            # Find and remove all mappings for this pane
            to_remove = [
                k for k, v in self.mappings.items()
                if v.get("pane_id") == pane_id
            ]
            for key in to_remove:
                del self.mappings[key]

        # Remove state file
        self._remove_state(pane_id)
        self._refresh_tmux()

    def get_pane_for_conversation(self, conversation_id: str) -> str | None:
        """Look up pane ID for a conversation ID."""
        with self.mappings_lock:
            mapping = self.mappings.get(conversation_id)
            if mapping:
                return mapping.get("pane_id")

            # Also check pending mappings and update them
            for key, value in list(self.mappings.items()):
                if key.startswith("pending_") and not value.get("conversation_id"):
                    # Update pending mapping with real conversation ID
                    pane_id = value["pane_id"]
                    self.mappings[conversation_id] = {
                        "pane_id": pane_id,
                        "registered_at": value["registered_at"],
                        "conversation_id": conversation_id,
                    }
                    del self.mappings[key]
                    return pane_id
        return None

    def cleanup_stale_mappings(self):
        """Remove mappings older than the stale timeout."""
        now = time.time()
        with self.mappings_lock:
            to_remove = [
                k for k, v in self.mappings.items()
                if now - v.get("registered_at", 0) > STALE_MAPPING_TIMEOUT
            ]
            for key in to_remove:
                del self.mappings[key]

    def process_otel_data(self, data: dict):
        """Process OTLP log/trace data and update state files."""
        self.touch_activity()

        try:
            # Handle logs format
            resource_logs = data.get("resourceLogs", [])
            for resource_log in resource_logs:
                scope_logs = resource_log.get("scopeLogs", [])
                for scope_log in scope_logs:
                    log_records = scope_log.get("logRecords", [])
                    for log_record in log_records:
                        self._process_record(log_record)

            # Handle traces format
            resource_spans = data.get("resourceSpans", [])
            for resource_span in resource_spans:
                scope_spans = resource_span.get("scopeSpans", [])
                for scope_span in scope_spans:
                    spans = scope_span.get("spans", [])
                    for span in spans:
                        self._process_record(span)
        except Exception as e:
            print(f"Error processing OTEL data: {e}", file=sys.stderr)

    def _process_record(self, record: dict):
        """Process a single OTLP log/span record."""
        # Extract attributes
        attributes = {}
        for attr in record.get("attributes", []):
            key = attr.get("key", "")
            value = attr.get("value", {})
            # OTLP values have type wrappers
            if "stringValue" in value:
                attributes[key] = value["stringValue"]
            elif "intValue" in value:
                attributes[key] = int(value["intValue"])
            elif "boolValue" in value:
                attributes[key] = value["boolValue"]

        # Get event name - check both attribute and span name field
        event_name = attributes.get("event.name", "") or record.get("name", "")
        conversation_id = attributes.get("conversation_id", "") or attributes.get("session_id", "")

        if not event_name:
            return

        # Get pane ID for this conversation
        pane_id = self.get_pane_for_conversation(conversation_id)
        if not pane_id:
            # Try to find any pending mapping
            with self.mappings_lock:
                for key, value in self.mappings.items():
                    if key.startswith("pending_"):
                        pane_id = value["pane_id"]
                        # Update with real conversation ID
                        if conversation_id:
                            self.mappings[conversation_id] = {
                                "pane_id": pane_id,
                                "registered_at": value["registered_at"],
                                "conversation_id": conversation_id,
                            }
                            del self.mappings[key]
                        break

        if not pane_id:
            return

        # Map event to state
        state, message = self._map_event_to_state(event_name, attributes)
        if state:
            self._write_state(pane_id, state, conversation_id, message)
            self._refresh_tmux()

    def _map_event_to_state(self, event_name: str, attributes: dict) -> tuple[str | None, str]:
        """Map Codex OTEL event to tmux-stat state."""
        model = attributes.get("model", "")
        tool = attributes.get("tool_name", attributes.get("tool", ""))
        status = attributes.get("status", "")

        if event_name == "codex.conversation_starts":
            msg = f"Codex: {model}" if model else "Codex started"
            return "running", msg

        elif event_name == "codex.tool_decision":
            if status == "pending" or attributes.get("needs_approval"):
                return "attention", f"Approve? {tool}" if tool else "Approval needed"
            elif status == "approved":
                return "running", f"Approved: {tool}" if tool else "Tool approved"
            elif status == "denied":
                return "done", f"Denied: {tool}" if tool else "Tool denied"

        elif event_name == "codex.tool_result":
            success = attributes.get("success", True)
            if not success or status == "failed" or attributes.get("error"):
                return "attention", f"Failed: {tool}" if tool else "Tool failed"
            return "running", f"Ran: {tool}" if tool else "Tool completed"

        elif event_name == "codex.conversation_ends":
            return "done", "Codex finished"

        elif event_name == "codex.response":
            # Response generation - still running
            return "running", "Generating..."

        elif event_name == "codex.user_input_required":
            return "attention", "Input needed"

        return None, ""

    def _write_state(self, pane_id: str, status: str, session_id: str, message: str):
        """Write state to a pane's state file."""
        safe_id = pane_id.lstrip("%")
        state_file = self.state_dir / f"{safe_id}.state"

        # Get tmux window for this pane (always try, don't require $TMUX)
        tmux_window = ""
        try:
            result = subprocess.run(
                ["tmux", "display-message", "-t", pane_id, "-p", "#{window_id}"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            if result.returncode == 0:
                tmux_window = result.stdout.strip()
        except Exception:
            pass

        state = {
            "status": status,
            "timestamp": int(time.time()),
            "session_id": session_id,
            "tmux_window": tmux_window,
            "message": message,
        }

        with open(state_file, "w") as f:
            json.dump(state, f)

    def _remove_state(self, pane_id: str):
        """Remove a pane's state file."""
        safe_id = pane_id.lstrip("%")
        state_file = self.state_dir / f"{safe_id}.state"
        try:
            state_file.unlink(missing_ok=True)
        except Exception:
            pass

    def _refresh_tmux(self):
        """Trigger tmux status line refresh."""
        if os.environ.get("TMUX"):
            try:
                subprocess.run(
                    ["tmux", "refresh-client", "-S"],
                    capture_output=True,
                    timeout=2,
                )
            except Exception:
                pass


class OTELRequestHandler(BaseHTTPRequestHandler):
    """HTTP request handler for OTEL receiver."""

    # Suppress default logging
    def log_message(self, format, *args):
        pass

    def _send_response(self, status: int, body: dict = None):
        """Send a JSON response."""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if body:
            self.wfile.write(json.dumps(body).encode())

    def _read_body(self) -> bytes:
        """Read request body."""
        content_length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(content_length)

    def do_GET(self):
        """Handle GET requests."""
        if self.path == "/health":
            self._send_response(200, {
                "status": "ok",
                "mappings": len(self.server.receiver.mappings),
                "idle_seconds": int(time.time() - self.server.receiver.last_activity),
            })
        else:
            self._send_response(404, {"error": "not found"})

    def do_POST(self):
        """Handle POST requests."""
        try:
            body = self._read_body()

            if self.path in ("/v1/logs", "/v1/traces", "/"):
                # OTLP logs/traces endpoint - accept all and process
                data = json.loads(body) if body else {}
                self.server.receiver.process_otel_data(data)
                self._send_response(200, {"status": "ok"})

            elif self.path == "/register":
                # Pane registration
                data = json.loads(body) if body else {}
                pane_id = data.get("pane_id")
                conversation_id = data.get("conversation_id")

                if not pane_id:
                    self._send_response(400, {"error": "pane_id required"})
                    return

                mapping_key = self.server.receiver.register_pane(pane_id, conversation_id)
                self._send_response(200, {"status": "registered", "mapping_key": mapping_key})

            elif self.path == "/unregister":
                # Pane unregistration
                data = json.loads(body) if body else {}
                pane_id = data.get("pane_id")

                if not pane_id:
                    self._send_response(400, {"error": "pane_id required"})
                    return

                self.server.receiver.unregister_pane(pane_id)
                self._send_response(200, {"status": "unregistered"})

            else:
                self._send_response(200, {"status": "ok"})  # Accept unknown paths silently

        except json.JSONDecodeError:
            self._send_response(400, {"error": "invalid JSON"})
        except Exception as e:
            self._send_response(500, {"error": str(e)})


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """Threaded HTTP server."""
    daemon_threads = True


class OTELHTTPServer(ThreadedHTTPServer):
    """HTTP server with OTEL receiver."""

    def __init__(self, address, handler, receiver: OTELReceiver):
        super().__init__(address, handler)
        self.receiver = receiver


def run_server(port: int, state_dir: str):
    """Run the OTEL receiver server."""
    receiver = OTELReceiver(state_dir)
    server = OTELHTTPServer(("127.0.0.1", port), OTELRequestHandler, receiver)

    print(f"OTEL receiver listening on http://127.0.0.1:{port}", file=sys.stderr)
    print(f"State directory: {state_dir}", file=sys.stderr)

    # Set up signal handlers for graceful shutdown
    def shutdown(signum, frame):
        print("\nShutting down...", file=sys.stderr)
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    # Start idle checker thread
    def idle_checker():
        while True:
            time.sleep(60)  # Check every minute
            receiver.cleanup_stale_mappings()
            if receiver.is_idle():
                print("Idle timeout reached, shutting down...", file=sys.stderr)
                server.shutdown()
                break

    checker_thread = threading.Thread(target=idle_checker, daemon=True)
    checker_thread.start()

    # Run server
    server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description="OTEL receiver for Codex CLI")
    parser.add_argument(
        "--port", "-p",
        type=int,
        default=int(os.environ.get("OTEL_RECEIVER_PORT", DEFAULT_PORT)),
        help=f"Port to listen on (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--state-dir", "-d",
        default=os.environ.get("STATE_DIR", DEFAULT_STATE_DIR),
        help=f"State directory (default: {DEFAULT_STATE_DIR})",
    )

    args = parser.parse_args()
    run_server(args.port, args.state_dir)


if __name__ == "__main__":
    main()
