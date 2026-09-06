#!/usr/bin/env python3
"""Dependency-free MCP bridge for Codex-managed live harness sessions."""

from __future__ import annotations

import argparse
import json
import os
import pty
import re
import signal
import select
import codecs
import subprocess
import sys
import termios
import threading
import time
from pathlib import Path
from typing import Any


MAX_TRANSCRIPT_CHARS = 2 * 1024 * 1024
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}")
EXTENSION_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")
SUPPORTED_TOOLS = {
    "read",
    "rg",
    "write",
    "edit",
    "shell",
    "traces",
    "live_eval",
    "extension",
}
SUBAGENT_TOOLS = {"read", "rg", "traces", "live_eval"}


def builtin_enabled(name: str) -> bool:
    return name in {
        item.strip()
        for item in os.environ.get("SHIFT_BUILTINS", "ollama,openai,tracing,mcp").split(
            ","
        )
    }


def fresh_hex(byte_count: int) -> str:
    return os.urandom(byte_count).hex()


def append_trace_span(
    state_dir: Path,
    checkpoint: dict[str, Any],
    *,
    trace_id: str,
    span_id: str,
    parent_span_id: str | None,
    name: str,
    kind: str,
    start_ns: int,
    status: str,
    attributes: dict[str, Any],
    links: list[dict[str, Any]] | None = None,
) -> None:
    if not builtin_enabled("tracing"):
        return
    end_ns = time.time_ns()
    value: dict[str, Any] = {
        "trace_id": trace_id,
        "span_id": span_id,
        "parent_span_id": parent_span_id,
        "name": name,
        "kind": kind,
        "start_time_unix_nano": start_ns,
        "end_time_unix_nano": end_ns,
        "duration_ms": round((end_ns - start_ns) / 1_000_000, 3),
        "status": status,
        "attributes": {
            "openinference.span.kind": kind,
            "session.id": checkpoint["id"],
            "session.name": checkpoint["name"],
            **attributes,
        },
    }
    if links:
        value["links"] = links
    state_dir.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(value, separators=(",", ":")) + "\n").encode()
    descriptor = os.open(
        state_dir / "traces.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600
    )
    try:
        os.write(descriptor, encoded)
    finally:
        os.close(descriptor)


def object_schema(
    properties: dict[str, Any], required: list[str] | None = None
) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": properties,
        "required": required or [],
        "additionalProperties": False,
    }


SESSION_PROPERTY = {
    "type": "string",
    "description": "Durable session name. Defaults to 'default'.",
    "pattern": r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$",
}


def session_schema(
    properties: dict[str, Any], required: list[str] | None = None
) -> dict[str, Any]:
    return object_schema({"session": SESSION_PROPERTY, **properties}, required)


TOOLS = [
    {
        "name": "live_sessions_list",
        "description": "List durable and currently running shift sessions.",
        "inputSchema": object_schema({}),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "live_session_start",
        "description": "Start or resume one named MCP-owned shift session.",
        "inputSchema": session_schema(
            {
                "agent": {
                    "type": "string",
                    "description": "Optional project-relative agent image path.",
                },
                "prompt": {
                    "type": "string",
                    "description": "Optional first user turn to run immediately after startup.",
                },
                "mode": {
                    "type": "string",
                    "enum": ["auto", "new", "resume"],
                    "description": "Auto resumes or creates; new and resume are strict.",
                },
            }
        ),
    },
    {
        "name": "live_session_fork",
        "description": (
            "Fork one durable checkpoint into an isolated child with the same "
            "generation fingerprint and a distinct session identity."
        ),
        "inputSchema": object_schema(
            {
                "parent_session": SESSION_PROPERTY,
                "child_session": SESSION_PROPERTY,
            },
            ["parent_session", "child_session"],
        ),
    },
    {
        "name": "live_subagent_run",
        "description": (
            "Fork a parent checkpoint, run one isolated child under a narrower "
            "process-level tool ceiling, wait or cancel it, and return a structured "
            "result with trajectory, trace, generation, proposal, and assertion refs."
        ),
        "inputSchema": object_schema(
            {
                "parent_session": SESSION_PROPERTY,
                "child_session": SESSION_PROPERTY,
                "task": {"type": "string"},
                "tools": {
                    "type": "array",
                    "items": {"type": "string", "enum": sorted(SUBAGENT_TOOLS)},
                    "minItems": 1,
                    "uniqueItems": True,
                    "description": "Stable child authority ceiling; it cannot widen this live.",
                },
                "agent": {
                    "type": "string",
                    "description": "Optional project-relative agent image path.",
                },
                "extension": {
                    "type": "string",
                    "description": "Optional disabled extension to evaluate only in the child.",
                },
                "timeout_seconds": {"type": "number", "minimum": 1, "maximum": 600},
                "proposal_name": {
                    "type": "string",
                    "description": "Export child-only live patches as a disabled extension.",
                },
                "assert_tool": {
                    "type": "string",
                    "enum": sorted(SUPPORTED_TOOLS),
                },
                "assert_output_contains": {"type": "string"},
            },
            ["parent_session", "child_session", "task", "tools"],
        ),
    },
    {
        "name": "live_session_status",
        "description": "Read whether the live session is running and its transcript cursor.",
        "inputSchema": session_schema({}),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "live_session_send",
        "description": (
            "Send a user prompt to the live session and return streamed output through the next "
            "agent prompt or shell-approval boundary."
        ),
        "inputSchema": session_schema(
            {
                "text": {"type": "string"},
                "timeout_seconds": {"type": "number", "minimum": 1, "maximum": 600},
            },
            ["text"],
        ),
    },
    {
        "name": "live_session_read",
        "description": "Read transcript output at or after an optional absolute cursor.",
        "inputSchema": session_schema({"cursor": {"type": "integer", "minimum": 0}}),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "live_session_approve",
        "description": "Answer the current shell request with one y or N keystroke.",
        "inputSchema": session_schema(
            {
                "approved": {"type": "boolean"},
                "timeout_seconds": {"type": "number", "minimum": 1, "maximum": 600},
            },
            ["approved"],
        ),
    },
    {
        "name": "live_session_cancel",
        "description": "Cancel the in-flight turn or compaction and keep prior conversation state.",
        "inputSchema": session_schema(
            {"timeout_seconds": {"type": "number", "minimum": 1, "maximum": 60}}
        ),
    },
    {
        "name": "live_session_traces",
        "description": (
            "List recent spans, search the complete durable session trace, or fetch one "
            "full span by its stable ID."
        ),
        "inputSchema": session_schema(
            {
                "query": {
                    "type": "string",
                    "maxLength": 256,
                    "description": "Case-insensitive literal search across all session spans.",
                },
                "span_id": {
                    "type": "string",
                    "maxLength": 256,
                    "description": "Exact span ID to retrieve with its stored attributes.",
                },
            }
        ),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "live_session_compact",
        "description": "Compact older session history into a traced summary now.",
        "inputSchema": session_schema(
            {"timeout_seconds": {"type": "number", "minimum": 1, "maximum": 600}}
        ),
    },
    {
        "name": "live_session_recovery",
        "description": "Inspect, explicitly retry, or discard an interrupted tool record.",
        "inputSchema": session_schema(
            {
                "action": {"type": "string", "enum": ["status", "retry", "discard"]},
                "timeout_seconds": {"type": "number", "minimum": 1, "maximum": 600},
            },
            ["action"],
        ),
    },
    {
        "name": "live_session_set",
        "description": "Change a live session setting by creating a transactional generation.",
        "inputSchema": session_schema(
            {
                "name": {"type": "string", "enum": ["thinking", "stream"]},
                "value": {"type": "string"},
            },
            ["name", "value"],
        ),
    },
    {
        "name": "live_session_add_prompt",
        "description": "Append text to the live system prompt transactionally for later turns.",
        "inputSchema": session_schema({"text": {"type": "string"}}, ["text"]),
    },
    {
        "name": "live_session_eval",
        "description": "Apply a restricted Scheme live expression to the managed session.",
        "inputSchema": session_schema(
            {"expression": {"type": "string"}}, ["expression"]
        ),
    },
    {
        "name": "live_extension",
        "description": "List, create, load, disable, or export persistent live extension artifacts.",
        "inputSchema": session_schema(
            {
                "action": {
                    "type": "string",
                    "enum": ["list", "create", "load", "disable", "export"],
                },
                "name": {"type": "string"},
                "expression": {"type": "string"},
            },
            ["action"],
        ),
    },
    {
        "name": "live_session_stop",
        "description": "Stop the MCP-owned live session.",
        "inputSchema": session_schema({}),
    },
]


class LiveSession:
    def __init__(
        self, project_root: Path, state_root: Path, name: str = "default"
    ) -> None:
        if not isinstance(name, str) or not SAFE_NAME.fullmatch(name):
            raise ValueError("session names must match [A-Za-z0-9][A-Za-z0-9._-]*")
        self.project_root = project_root.resolve()
        self.state_root = state_root.resolve()
        self.name = name
        self.state_dir = self.state_root / "sessions" / name
        self.process: subprocess.Popen[bytes] | None = None
        self.master_fd: int | None = None
        self._base_cursor = 0
        self._transcript = ""
        self._condition = threading.Condition()
        self._command_lock = threading.Lock()
        self._boundary = {"state": "stopped", "status": "ok"}
        self.tool_ceiling: tuple[str, ...] | None = None

    def _authority_ceiling(self) -> tuple[str, ...] | None:
        path = self.state_dir / "authority.json"
        try:
            value = json.loads(path.read_text())
        except FileNotFoundError:
            return None
        except (OSError, ValueError) as error:
            raise RuntimeError(f"invalid session authority record: {path}") from error
        if not isinstance(value, dict):
            raise RuntimeError(f"invalid session authority record: {path}")
        tools = value.get("tool_ceiling")
        if (
            value.get("version") != 1
            or not isinstance(tools, list)
            or not tools
            or any(
                not isinstance(tool, str) or tool not in SUPPORTED_TOOLS
                for tool in tools
            )
        ):
            raise RuntimeError(f"invalid session authority record: {path}")
        return tuple(dict.fromkeys(tools))

    def _save_authority_ceiling(self, ceiling: tuple[str, ...]) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        path = self.state_dir / "authority.json"
        temporary = self.state_dir / f".authority-{os.getpid()}-{fresh_hex(4)}.tmp"
        temporary.write_text(
            json.dumps({"version": 1, "tool_ceiling": list(ceiling)}, indent=2) + "\n"
        )
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)

    @property
    def busy(self) -> bool:
        return self._running() and self._boundary["state"] in {
            "running",
            "needs_approval",
        }

    def _running(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def _cursor(self) -> int:
        return self._base_cursor + len(self._transcript)

    def _append(self, value: str) -> None:
        with self._condition:
            self._transcript += value
            if len(self._transcript) > MAX_TRANSCRIPT_CHARS:
                removed = len(self._transcript) - MAX_TRANSCRIPT_CHARS
                self._transcript = self._transcript[removed:]
                self._base_cursor += removed
            self._condition.notify_all()

    def _reader(self, fd: int, control_fd: int) -> None:
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        control = b""
        try:
            while True:
                readable, _, _ = select.select([fd, control_fd], [], [])
                # The child flushes terminal output before its control frame.
                if fd in readable or control_fd in readable:
                    while select.select([fd], [], [], 0)[0]:
                        chunk = os.read(fd, 65536)
                        if not chunk:
                            return
                        self._append(decoder.decode(chunk))
                if control_fd in readable:
                    chunk = os.read(control_fd, 65536)
                    if not chunk:
                        return
                    control += chunk
                    while b"\n" in control:
                        line, control = control.split(b"\n", 1)
                        event = json.loads(line)
                        with self._condition:
                            self._boundary = event
                            self._condition.notify_all()
        except (OSError, ValueError):
            pass
        finally:
            os.close(control_fd)
            with self._condition:
                self._condition.notify_all()

    def _resolve_agent(self, requested: str | None) -> Path:
        candidate = (self.project_root / (requested or "agent/default.scm")).resolve()
        try:
            candidate.relative_to(self.project_root)
        except ValueError as error:
            raise ValueError("agent path escapes the project root") from error
        if not candidate.is_file():
            raise ValueError(
                f"agent image does not exist: {requested or 'agent/default.scm'}"
            )
        return candidate

    def _segment(self, cursor: int) -> str:
        start = max(cursor, self._base_cursor) - self._base_cursor
        return self._transcript[start:]

    @staticmethod
    def _clean(value: str) -> str:
        value = value.replace("\r\n", "\n").replace("\r", "")
        return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", value)

    def _wait_for_boundary(self, cursor: int, timeout_seconds: float) -> dict[str, Any]:
        deadline = time.monotonic() + timeout_seconds
        with self._condition:
            while True:
                state = self._boundary["state"]
                if state in {"ready", "needs_approval"}:
                    break
                if not self._running():
                    state = "stopped"
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    state = "timeout"
                    break
                self._condition.wait(min(remaining, 0.25))
            return {
                "state": state,
                "status": self._boundary.get("status"),
                "error": self._boundary.get("error"),
                "span_id": self._boundary.get("span_id"),
                "output": self._clean(self._segment(cursor)),
                "cursor": self._cursor(),
            }

    def _write(self, value: bytes) -> None:
        if not self._running() or self.master_fd is None:
            raise RuntimeError(
                "live session is not running; call live_session_start first"
            )
        os.write(self.master_fd, value)

    def _awaiting_approval(self) -> bool:
        with self._condition:
            return self._boundary["state"] == "needs_approval"

    def start(
        self,
        agent: str | None = None,
        mode: str = "auto",
        initial_prompt: str | None = None,
        tool_ceiling: list[str] | None = None,
    ) -> dict[str, Any]:
        if initial_prompt is not None and (
            not isinstance(initial_prompt, str) or not initial_prompt.strip()
        ):
            raise ValueError("prompt must be a non-empty string")
        stored_ceiling = self._authority_ceiling()
        if tool_ceiling is not None:
            if (
                not isinstance(tool_ceiling, list)
                or not tool_ceiling
                or any(tool not in SUPPORTED_TOOLS for tool in tool_ceiling)
            ):
                raise ValueError(
                    "tools must be a non-empty list of supported tool names"
                )
            normalized_ceiling = tuple(dict.fromkeys(tool_ceiling))
            if stored_ceiling is not None and not set(normalized_ceiling).issubset(
                stored_ceiling
            ):
                raise ValueError(
                    "requested tools exceed the durable session authority ceiling"
                )
        else:
            normalized_ceiling = stored_ceiling
        if self._running():
            if (
                normalized_ceiling is not None
                and normalized_ceiling != self.tool_ceiling
            ):
                raise RuntimeError(
                    "running session has a different process tool ceiling"
                )
            if initial_prompt is not None:
                return self.send(initial_prompt)
            return {
                **self.status(),
                **self._boundary,
                "output": "Session already running.",
            }
        if mode not in {"auto", "new", "resume"}:
            raise ValueError("mode must be auto, new, or resume")
        image = self._resolve_agent(agent)
        checkpoint_exists = (self.state_dir / "session.json").is_file()
        if mode == "new" and checkpoint_exists:
            raise ValueError(f"session already exists: {self.name}")
        if mode == "resume" and not checkpoint_exists:
            raise ValueError(f"session does not exist: {self.name}")
        self.state_root.mkdir(parents=True, exist_ok=True)
        marker = self._cursor()
        master_fd, slave_fd = pty.openpty()
        control_read, control_write = os.pipe()
        self._boundary = {"state": "running", "status": None}
        terminal_attributes = termios.tcgetattr(slave_fd)
        terminal_attributes[3] &= ~(termios.ECHO | termios.ECHONL)
        termios.tcsetattr(slave_fd, termios.TCSANOW, terminal_attributes)
        environment = os.environ.copy()
        environment.setdefault("TERM", "dumb")
        environment["SHIFT_CONTROL_FD"] = str(control_write)
        if normalized_ceiling is not None:
            environment["SHIFT_TOOL_CEILING"] = ",".join(normalized_ceiling)
        else:
            environment.pop("SHIFT_TOOL_CEILING", None)
        command = [
            str(self.project_root / "bin/shift"),
            "--agent",
            str(image),
            "--state-dir",
            str(self.state_root),
            {"auto": "--session", "new": "--new-session", "resume": "--resume"}[mode],
            self.name,
        ]
        if initial_prompt is not None:
            command.append(initial_prompt)
        try:
            process = subprocess.Popen(
                command,
                cwd=self.project_root,
                env=environment,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                close_fds=True,
                pass_fds=(control_write,),
                start_new_session=True,
            )
        except Exception:
            os.close(master_fd)
            os.close(control_read)
            raise
        finally:
            os.close(slave_fd)
            os.close(control_write)
        self.process = process
        self.master_fd = master_fd
        self.tool_ceiling = normalized_ceiling
        if normalized_ceiling is not None and normalized_ceiling != stored_ceiling:
            self._save_authority_ceiling(normalized_ceiling)
        threading.Thread(
            target=self._reader, args=(master_fd, control_read), daemon=True
        ).start()
        result = self._wait_for_boundary(marker, 15)
        result.update(self.status())
        return result

    def status(self) -> dict[str, Any]:
        effective_ceiling = self.tool_ceiling or self._authority_ceiling()
        result = {
            "session": self.name,
            "busy": self.busy,
            "operation_status": self._boundary.get("status"),
            "running": self._running(),
            "pid": self.process.pid if self._running() and self.process else None,
            "cursor": self._cursor(),
            "state_dir": str(self.state_dir),
            "resumable": (self.state_dir / "session.json").is_file(),
            "recovery_pending": (self.state_dir / "interrupted-tool.json").is_file(),
            "tool_ceiling": list(effective_ceiling) if effective_ceiling else None,
        }
        try:
            checkpoint = json.loads((self.state_dir / "session.json").read_text())
            result.update(
                {
                    "session_id": checkpoint.get("id"),
                    "generation": checkpoint.get("generation_id"),
                    "fingerprint": checkpoint.get("fingerprint"),
                    "next_turn": checkpoint.get("next_turn"),
                }
            )
        except (OSError, ValueError):
            pass
        return result

    def send(self, text: str, timeout_seconds: float = 180) -> dict[str, Any]:
        if not isinstance(text, str) or not text.strip():
            raise ValueError("text must be a non-empty string")
        with self._command_lock:
            if self._awaiting_approval():
                raise RuntimeError(
                    "a shell request is waiting; approve or deny it before sending input"
                )
            if self.busy:
                raise RuntimeError(
                    "the live session is busy; wait or cancel before sending input"
                )
            marker = self._cursor()
            with self._condition:
                self._boundary = {"state": "running", "status": None}
            self._write(text.encode("utf-8") + b"\n")
            return self._wait_for_boundary(marker, timeout_seconds)

    def approve(self, approved: bool, timeout_seconds: float = 180) -> dict[str, Any]:
        if not isinstance(approved, bool):
            raise ValueError("approved must be a boolean")
        with self._command_lock:
            if not self._awaiting_approval():
                raise RuntimeError("the live session is not waiting for shell approval")
            marker = self._cursor()
            with self._condition:
                self._boundary = {"state": "running", "status": None}
            self._write(b"y" if approved else b"n")
            return self._wait_for_boundary(marker, timeout_seconds)

    def cancel(self, timeout_seconds: float = 15) -> dict[str, Any]:
        if not self._running() or self.process is None:
            raise RuntimeError("the live session has no running turn to cancel")
        with self._condition:
            busy = self.busy
        if not (busy or self._awaiting_approval()):
            raise RuntimeError("the live session is idle; there is no turn to cancel")
        marker = self._cursor()
        with self._condition:
            self._boundary = {"state": "running", "status": None}
        os.killpg(self.process.pid, signal.SIGINT)
        result = self._wait_for_boundary(marker, timeout_seconds)
        result.update(self.status())
        return result

    def read(self, cursor: int | None = None) -> dict[str, Any]:
        with self._condition:
            requested = self._base_cursor if cursor is None else int(cursor)
            return {
                **self.status(),
                "from_cursor": max(requested, self._base_cursor),
                "output": self._clean(self._segment(requested)),
            }

    def stop(self) -> dict[str, Any]:
        if not self._running():
            if self.master_fd is not None:
                try:
                    os.close(self.master_fd)
                except OSError:
                    pass
                self.master_fd = None
            return {
                **self.status(),
                "state": "stopped",
                "output": "Session is not running.",
            }
        assert self.process is not None
        try:
            self._write(b"/quit\n")
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=2)
        if self.master_fd is not None:
            try:
                os.close(self.master_fd)
            except OSError:
                pass
            self.master_fd = None
        return {**self.status(), "state": "stopped", "output": "Session stopped."}


def scheme_string(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


class McpServer:
    def __init__(
        self, project_root: Path, state_root: Path, session_factory=LiveSession
    ) -> None:
        self.project_root = project_root.resolve()
        self.state_root = state_root.resolve()
        self.session_factory = session_factory
        self.sessions: dict[str, LiveSession] = {}
        self._sessions_lock = threading.Lock()

    @staticmethod
    def _session_name(arguments: dict[str, Any]) -> str:
        name = arguments.get("session", "default")
        if not isinstance(name, str) or not SAFE_NAME.fullmatch(name):
            raise ValueError("session names must match [A-Za-z0-9][A-Za-z0-9._-]*")
        return name

    def _session(self, arguments: dict[str, Any]) -> LiveSession:
        name = self._session_name(arguments)
        with self._sessions_lock:
            if name not in self.sessions:
                self.sessions[name] = self.session_factory(
                    self.project_root, self.state_root, name
                )
            return self.sessions[name]

    def _list_sessions(self) -> dict[str, Any]:
        names = set(self.sessions)
        root = self.state_root / "sessions"
        if root.is_dir():
            names.update(
                path.parent.name
                for path in root.glob("*/session.json")
                if SAFE_NAME.fullmatch(path.parent.name)
            )
        return {
            "sessions": [
                self._session({"session": name}).status() for name in sorted(names)
            ]
        }

    def _checkpoint(self, name: str) -> dict[str, Any]:
        if not isinstance(name, str) or not SAFE_NAME.fullmatch(name):
            raise ValueError("session names must match [A-Za-z0-9][A-Za-z0-9._-]*")
        path = self.state_root / "sessions" / name / "session.json"
        try:
            checkpoint = json.loads(path.read_text())
        except FileNotFoundError as error:
            raise ValueError(f"session does not exist: {name}") from error
        if checkpoint.get("name") != name or not checkpoint.get("fingerprint"):
            raise ValueError(f"invalid session checkpoint: {name}")
        return checkpoint

    def _fork_session(self, parent_name: str, child_name: str) -> dict[str, Any]:
        if not isinstance(parent_name, str) or not SAFE_NAME.fullmatch(parent_name):
            raise ValueError("invalid parent session name")
        if not isinstance(child_name, str) or not SAFE_NAME.fullmatch(child_name):
            raise ValueError("invalid child session name")
        command = [
            str(self.project_root / "bin/shift"),
            "session-fork",
            parent_name,
            child_name,
            "--state-dir",
            str(self.state_root),
        ]
        completed = subprocess.run(
            command,
            cwd=self.project_root,
            env=os.environ.copy(),
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout).strip()
            raise RuntimeError(detail or "session fork failed")
        return self._checkpoint(child_name)

    def _checkpoint_agent(self, checkpoint: dict[str, Any]) -> str | None:
        source = checkpoint.get("source")
        if not isinstance(source, str) or not source:
            return None
        source_path = Path(source).resolve()
        try:
            return str(source_path.relative_to(self.project_root))
        except ValueError:
            return None

    @staticmethod
    def _tool_assertion(
        checkpoint: dict[str, Any],
        tool_name: str | None,
        output_fragment: str | None,
        history_start: int,
    ) -> dict[str, Any] | None:
        if tool_name is None and output_fragment is None:
            return None
        history = checkpoint.get("history") or []
        for index in range(history_start, len(history)):
            message = history[index]
            if message.get("role") != "tool":
                continue
            actual_name = message.get("tool_name")
            call_id = message.get("tool_call_id")
            if actual_name is None and call_id:
                for earlier in reversed(history[:index]):
                    for call in earlier.get("tool_calls") or []:
                        if call.get("id") == call_id:
                            actual_name = (call.get("function") or {}).get("name")
                            break
                    if actual_name is not None:
                        break
            content = message.get("content")
            name_matches = tool_name is None or actual_name == tool_name
            output_matches = output_fragment is None or (
                isinstance(content, str) and output_fragment in content
            )
            if name_matches and output_matches:
                return {
                    "passed": True,
                    "tool": actual_name,
                    "history_index": index,
                    "tool_call_id": call_id,
                    "output_contains": output_fragment,
                }
        return {
            "passed": False,
            "tool": tool_name,
            "output_contains": output_fragment,
        }

    def _export_proposal(
        self,
        name: str | None,
        parent_checkpoint: dict[str, Any],
        child_checkpoint: dict[str, Any],
    ) -> dict[str, Any] | None:
        if name is None:
            return None
        if not isinstance(name, str) or not EXTENSION_NAME.fullmatch(name):
            raise ValueError(
                "proposal name must be 1-64 letters, numbers, hyphens, or underscores"
            )
        parent_patches = parent_checkpoint.get("patches") or []
        child_patches = child_checkpoint.get("patches") or []
        if child_patches[: len(parent_patches)] != parent_patches:
            raise RuntimeError("child patch lineage diverged from its fork checkpoint")
        child_only = child_patches[len(parent_patches) :]
        if not child_only:
            return {"name": name, "status": "empty", "loaded": False}
        proposal_directory = (
            self.state_root / "sessions" / child_checkpoint["name"] / "proposals"
        )
        proposal_directory.mkdir(parents=True, exist_ok=True)
        extension_path = proposal_directory / f"{name}.scm"
        content = (
            f";; Live Agent extension: {name}\n"
            ";; Disabled proposal exported from an isolated subagent.\n\n"
            + "\n\n".join(child_only)
            + "\n"
        )
        try:
            with extension_path.open("x") as port:
                port.write(content)
        except FileExistsError as error:
            raise ValueError(f"extension already exists: {name}") from error
        return {
            "name": name,
            "status": "exported",
            "path": str(extension_path),
            "patch_count": len(child_only),
            "loaded": False,
        }

    def _run_subagent(self, arguments: dict[str, Any]) -> dict[str, Any]:
        parent_name = arguments.get("parent_session")
        child_name = arguments.get("child_session")
        task = arguments.get("task")
        tools = arguments.get("tools")
        if not isinstance(task, str) or not task.strip():
            raise ValueError("task must be a non-empty string")
        if (
            not isinstance(tools, list)
            or not tools
            or any(
                not isinstance(tool, str) or tool not in SUBAGENT_TOOLS
                for tool in tools
            )
        ):
            raise ValueError(
                "subagent tools must be a non-empty list of read, rg, traces, or live_eval"
            )
        tools = list(dict.fromkeys(tools))
        timeout = float(arguments.get("timeout_seconds", 180))
        if not 1 <= timeout <= 600:
            raise ValueError("timeout_seconds must be from 1 through 600")
        parent_checkpoint = self._checkpoint(parent_name)
        parent_tools = parent_checkpoint.get("tools")
        if not isinstance(parent_tools, list) or any(
            not isinstance(tool, str) for tool in parent_tools
        ):
            raise RuntimeError(
                "parent checkpoint predates tool ceilings; resume it once before forking"
            )
        if not set(tools).issubset(parent_tools):
            raise ValueError(
                "child tools must be a subset of the parent generation tools"
            )
        fanout_start = time.time_ns()
        parent_trace_id = fresh_hex(16)
        fanout_span_id = fresh_hex(8)
        run_trace_id = fresh_hex(16)
        run_span_id = fresh_hex(8)
        join_span_id = fresh_hex(8)
        child_checkpoint = self._fork_session(parent_name, child_name)
        child = self._session({"session": child_name})
        requested_agent = arguments.get("agent") or self._checkpoint_agent(
            parent_checkpoint
        )
        started = child.start(
            requested_agent,
            "resume",
            tool_ceiling=tools,
        )
        if started.get("state") != "ready":
            raise RuntimeError(f"child failed to start: {started.get('state')}")
        if started.get("fingerprint") != parent_checkpoint.get("fingerprint"):
            child.stop()
            raise RuntimeError(
                "parent generation changed before child start; fork again from a fresh checkpoint"
            )
        extension_name = arguments.get("extension")
        if extension_name is not None:
            if not isinstance(extension_name, str) or not EXTENSION_NAME.fullmatch(
                extension_name
            ):
                child.stop()
                raise ValueError("extension must be a safe extension artifact name")
            extension_result = child.send(f"/extension-load {extension_name}", 15)
            if (
                extension_result.get("state") != "ready"
                or extension_result.get("status") != "ok"
            ):
                child.stop()
                raise RuntimeError(f"child extension failed to load: {extension_name}")

        run_start = time.time_ns()
        outcome: dict[str, Any] = {}
        failure: list[Exception] = []

        def run_turn() -> None:
            try:
                outcome.update(child.send(task, timeout + 30))
            except Exception as error:  # Preserve a structured join on child failure.
                failure.append(error)

        worker = threading.Thread(target=run_turn, daemon=True)
        worker.start()
        worker.join(timeout)
        cancelled = False
        if worker.is_alive():
            cancellation = child.cancel(15)
            cancelled = True
            worker.join(15)
            outcome = {**outcome, **cancellation}
        if failure:
            child.stop()
            raise failure[0]

        child_checkpoint = self._checkpoint(child_name)
        assertion = self._tool_assertion(
            child_checkpoint,
            arguments.get("assert_tool"),
            arguments.get("assert_output_contains"),
            len(parent_checkpoint.get("history") or []),
        )
        proposal = self._export_proposal(
            arguments.get("proposal_name"), parent_checkpoint, child_checkpoint
        )
        assertion_failed = assertion is not None and not assertion.get("passed")
        status = (
            "CANCELLED"
            if cancelled
            else (
                "OK"
                if outcome.get("status") == "ok" and not assertion_failed
                else "ERROR"
            )
        )
        output = outcome.get("output") or ""
        result_text = output[-16_384:]

        append_trace_span(
            child.state_dir,
            child_checkpoint,
            trace_id=run_trace_id,
            span_id=run_span_id,
            parent_span_id=None,
            name="subagent.run",
            kind="AGENT",
            start_ns=run_start,
            status=status,
            attributes={
                "subagent.parent_session": parent_name,
                "subagent.child_session": child_name,
                "subagent.task": task,
                "subagent.tool_ceiling": tools,
                "subagent.extension": extension_name,
                "subagent.cancelled": cancelled,
                "generation.id": child_checkpoint["generation_id"],
                "generation.fingerprint": child_checkpoint["fingerprint"],
                "output.value": result_text,
            },
            links=[{"trace_id": parent_trace_id, "span_id": fanout_span_id}],
        )
        append_trace_span(
            self.state_root / "sessions" / parent_name,
            parent_checkpoint,
            trace_id=parent_trace_id,
            span_id=fanout_span_id,
            parent_span_id=None,
            name="subagent.fanout",
            kind="AGENT",
            start_ns=fanout_start,
            status=status,
            attributes={
                "subagent.child_session": child_name,
                "subagent.task": task,
                "subagent.tool_ceiling": tools,
                "subagent.extension": extension_name,
                "generation.id": parent_checkpoint["generation_id"],
                "generation.fingerprint": parent_checkpoint["fingerprint"],
            },
        )
        join_start = time.time_ns()
        append_trace_span(
            self.state_root / "sessions" / parent_name,
            parent_checkpoint,
            trace_id=parent_trace_id,
            span_id=join_span_id,
            parent_span_id=fanout_span_id,
            name="subagent.join",
            kind="AGENT",
            start_ns=join_start,
            status=status,
            attributes={
                "subagent.child_session": child_name,
                "subagent.assertion_passed": (
                    assertion.get("passed") if assertion is not None else None
                ),
                "subagent.cancelled": cancelled,
            },
            links=[{"trace_id": run_trace_id, "span_id": run_span_id}],
        )

        if outcome.get("state") == "ready":
            child.stop()
        return {
            "result": result_text,
            "state": outcome.get("state"),
            "status": status.lower(),
            "error": outcome.get("error"),
            "trajectory_ref": str(child.state_dir / "session.json"),
            "trace_ref": {
                "parent_trace_id": parent_trace_id,
                "fanout_span_id": fanout_span_id,
                "child_trace_id": run_trace_id,
                "run_span_id": run_span_id,
                "join_span_id": join_span_id,
            }
            if builtin_enabled("tracing")
            else None,
            "generation_ref": {
                "parent_generation": parent_checkpoint["generation_id"],
                "parent_fingerprint": parent_checkpoint["fingerprint"],
                "child_generation": child_checkpoint["generation_id"],
                "child_fingerprint": child_checkpoint["fingerprint"],
            },
            "extension_proposal": proposal,
            "assertion": assertion,
            "cancelled": cancelled,
        }

    def _run_command(
        self, session: LiveSession, command: str, arguments: dict[str, Any]
    ) -> dict[str, Any]:
        timeout = float(arguments.get("timeout_seconds", 180))
        return session.send(command, timeout)

    def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name == "live_sessions_list":
            result = self._list_sessions()
            return {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]}

        if name == "live_session_fork":
            checkpoint = self._fork_session(
                arguments.get("parent_session"), arguments.get("child_session")
            )
            result = {
                "session": checkpoint["name"],
                "session_id": checkpoint["id"],
                "next_turn": checkpoint["next_turn"],
                "generation": checkpoint["generation_id"],
                "fingerprint": checkpoint["fingerprint"],
                "fork": checkpoint.get("fork"),
                "trajectory_ref": str(
                    self.state_root / "sessions" / checkpoint["name"] / "session.json"
                ),
            }
            return {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]}

        if name == "live_subagent_run":
            result = self._run_subagent(arguments)
            return {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]}

        session = self._session(arguments)
        if name == "live_session_start":
            result = session.start(
                arguments.get("agent"),
                arguments.get("mode", "auto"),
                arguments.get("prompt"),
            )
        elif name == "live_session_status":
            result = session.status()
        elif name == "live_session_send":
            result = session.send(
                arguments.get("text"), float(arguments.get("timeout_seconds", 180))
            )
        elif name == "live_session_read":
            result = session.read(arguments.get("cursor"))
        elif name == "live_session_approve":
            if not isinstance(arguments.get("approved"), bool):
                raise ValueError("approved must be a boolean")
            result = session.approve(
                arguments["approved"],
                float(arguments.get("timeout_seconds", 180)),
            )
        elif name == "live_session_cancel":
            result = session.cancel(float(arguments.get("timeout_seconds", 15)))
        elif name == "live_session_traces":
            query = arguments.get("query")
            span_id = arguments.get("span_id")
            if query and span_id:
                raise ValueError("use either query or span_id, not both")
            if span_id:
                command = f"/trace {span_id}"
            elif query:
                command = f"/traces {query}"
            else:
                command = "/traces"
            result = self._run_command(session, command, arguments)
        elif name == "live_session_compact":
            result = self._run_command(session, "/compact", arguments)
        elif name == "live_session_recovery":
            action = arguments.get("action")
            if action == "status":
                command = "/recover"
            elif action in {"retry", "discard"}:
                command = f"/recover {action}"
            else:
                raise ValueError("recovery action must be status, retry, or discard")
            result = self._run_command(session, command, arguments)
        elif name == "live_session_set":
            setting = arguments.get("name")
            value = arguments.get("value")
            if setting == "thinking" and value in {
                "off",
                "on",
                "low",
                "medium",
                "high",
            }:
                result = self._run_command(session, f"/thinking {value}", arguments)
            elif setting == "stream" and value in {"off", "on"}:
                result = self._run_command(session, f"/stream {value}", arguments)
            else:
                raise ValueError("unsupported setting value")
        elif name == "live_session_add_prompt":
            text = arguments.get("text")
            if not isinstance(text, str) or not text:
                raise ValueError("text must be a non-empty string")
            expression = (
                "(set! agent-system-prompt (string-append agent-system-prompt "
                + scheme_string("\n\n" + text)
                + "))"
            )
            result = self._run_command(session, f"/eval {expression}", arguments)
        elif name == "live_session_eval":
            expression = arguments.get("expression")
            if not isinstance(expression, str) or not expression.strip():
                raise ValueError("expression must be a non-empty string")
            result = self._run_command(session, f"/eval {expression}", arguments)
        elif name == "live_extension":
            action = arguments.get("action")
            extension_name = arguments.get("name")
            if action == "list":
                command = "/extensions"
            else:
                if not isinstance(extension_name, str) or not re.fullmatch(
                    r"[A-Za-z0-9][A-Za-z0-9._-]*", extension_name
                ):
                    raise ValueError("a safe extension name is required")
                if action == "create":
                    expression = arguments.get("expression")
                    if not isinstance(expression, str) or not expression.strip():
                        raise ValueError("create requires a non-empty expression")
                    command = f"/extension-create {extension_name} {expression}"
                elif action in {"load", "disable", "export"}:
                    command = f"/extension-{action} {extension_name}"
                else:
                    raise ValueError("unsupported extension action")
            result = self._run_command(session, command, arguments)
        elif name == "live_session_stop":
            result = session.stop()
        else:
            raise ValueError(f"unknown tool: {name}")
        return {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]}

    def close(self) -> None:
        for session in self.sessions.values():
            session.stop()

    def handle(self, request: dict[str, Any]) -> dict[str, Any] | None:
        method = request.get("method")
        request_id = request.get("id")
        if method == "initialize":
            version = request.get("params", {}).get("protocolVersion", "2025-06-18")
            result = {
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "shift", "version": "0.2.0"},
            }
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            params = request.get("params", {})
            try:
                result = self.call_tool(
                    params.get("name", ""), params.get("arguments") or {}
                )
            except Exception as error:  # MCP tools report operational failures in-band.
                result = {
                    "content": [{"type": "text", "text": str(error)}],
                    "isError": True,
                }
        elif method == "ping":
            result = {}
        elif request_id is None:
            return None
        else:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": f"Method not found: {method}"},
            }
        if request_id is None:
            return None
        return {"jsonrpc": "2.0", "id": request_id, "result": result}


def main() -> int:
    if not builtin_enabled("mcp"):
        raise SystemExit("mcp built-in is disabled; enable it in SHIFT_BUILTINS")
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir")
    options = parser.parse_args()
    project_root = Path(__file__).resolve().parents[2]
    state_dir = (
        Path(options.state_dir) if options.state_dir else project_root / ".shift"
    )
    server = McpServer(project_root, state_dir)
    output_lock = threading.Lock()
    workers: list[threading.Thread] = []

    def dispatch(line: str) -> None:
        request: dict[str, Any] = {}
        try:
            request = json.loads(line)
            response = server.handle(request)
        except Exception as error:
            request_id = request.get("id") if isinstance(request, dict) else None
            response = {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32603, "message": str(error)},
            }
        if response is not None:
            with output_lock:
                print(json.dumps(response, separators=(",", ":")), flush=True)

    try:
        for line in sys.stdin:
            if not line.strip():
                continue
            worker = threading.Thread(target=dispatch, args=(line,), daemon=True)
            workers.append(worker)
            worker.start()
    finally:
        for worker in workers:
            worker.join(timeout=1)
        server.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
