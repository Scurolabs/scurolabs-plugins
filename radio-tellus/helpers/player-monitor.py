#!/usr/bin/python3
"""Maintain one bounded MPV JSON-IPC connection for Radio Tellus status."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import select
import socket
import stat
import sys
import time
from pathlib import Path
from typing import Any


GENERATION_RE = re.compile(r"^\d+-\d+$")
MAX_FILE_BYTES = 65536
MAX_SOCKET_LINE = 131072
MAX_OUTPUT_BYTES = 16384
PROPERTY_RESPONSE_TIMEOUT_SECONDS = 2.0
PROPERTIES = ("pause", "metadata", "volume", "mute", "audio-out-params", "core-idle")
MAX_PENDING_PROPERTY_REQUESTS = len(PROPERTIES)


def _error_detail(error: BaseException) -> str:
    detail = f"{type(error).__name__}: {error}".replace("\n", " ")
    return detail[:180]


def _safe_owner_mode(path: Path, directory: bool = False) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    if stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid():
        return False
    if directory:
        return not info.st_mode & 0o077 and stat.S_ISDIR(info.st_mode)
    if not stat.S_ISREG(info.st_mode):
        return False
    try:
        parent = path.parent.lstat()
    except OSError:
        return False
    return (
        not stat.S_ISLNK(parent.st_mode)
        and stat.S_ISDIR(parent.st_mode)
        and parent.st_uid == os.getuid()
        and not parent.st_mode & 0o077
    )


def _has_symlink_component(path: Path) -> bool:
    return any(component.is_symlink() for component in (path, *path.parents))


class PlayerMonitor:
    def __init__(self, data_dir: Path) -> None:
        self.data_dir = data_dir
        self.playback_path = data_dir / "playback.json"
        self.control_path = data_dir / "monitor-control.json"
        self.target_signature: tuple[int, int, int, int] | None = None
        self.target: dict[str, str] | None = None
        self.sock: socket.socket | None = None
        self.buffer = b""
        self.request_id = 1
        self.sequence = 0
        self.values: dict[str, Any] = {
            "title": "",
            "audio_ready": False,
            "audio_ready_known": False,
            "paused_known": False,
            "core_idle": False,
            "core_idle_known": False,
        }
        self.property_requests: dict[int, str] = {}
        self.property_errors: dict[str, str] = {}
        self.property_deadline = 0.0
        self.last_ipc_response = 0.0
        self.next_heartbeat = 0.0
        self.next_resync = 0.0
        self.backoff = 0.1
        self.last_connect_error = ""

    def emit(self, kind: str, **values: Any) -> None:
        payload = {"kind": kind, **values}
        payload.setdefault("generation", (self.target or {}).get("generation", ""))
        payload["sequence"] = self.sequence
        raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=True)
        if len(raw.encode("utf-8")) > MAX_OUTPUT_BYTES:
            raw = json.dumps({"kind": "status", "generation": payload["generation"],
                              "sequence": self.sequence, "ok": False, "error": "output_oversized"},
                             separators=(",", ":"))
        sys.stdout.write(raw + "\n")
        sys.stdout.flush()
        self.sequence += 1

    def close_socket(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None
        self.buffer = b""
        self.values = {
            "title": "",
            "audio_ready": False,
            "audio_ready_known": False,
            "paused_known": False,
            "core_idle": False,
            "core_idle_known": False,
        }
        self.property_requests = {}
        self.property_errors = {}
        self.property_deadline = 0.0
        self.last_ipc_response = 0.0

    def read_control_disabled(self) -> bool:
        try:
            if not _safe_owner_mode(self.control_path):
                return True
            info = self.control_path.lstat()
            if info.st_size > 1024:
                return True
            with self.control_path.open("rb") as stream:
                value = json.loads(stream.read(MAX_FILE_BYTES).decode("utf-8"))
            return isinstance(value, dict) and value.get("mode") == "disabled"
        except FileNotFoundError:
            return False
        except (OSError, UnicodeError, ValueError):
            return True

    def read_target(self) -> dict[str, str] | None:
        try:
            info = self.playback_path.lstat()
            signature = (info.st_ino, info.st_mtime_ns, info.st_ctime_ns, info.st_size)
        except FileNotFoundError:
            self.target_signature = None
            return None
        except OSError:
            return None
        if not _safe_owner_mode(self.playback_path) or info.st_size > MAX_FILE_BYTES:
            return None
        if signature == self.target_signature and self.target is not None:
            return self.target
        try:
            with self.playback_path.open("rb") as stream:
                value = json.loads(stream.read(MAX_FILE_BYTES).decode("utf-8"))
        except (OSError, UnicodeError, ValueError):
            return None
        if not isinstance(value, dict) or value.get("secure_session") is not True:
            return None
        generation = value.get("generation")
        socket_path = value.get("socket")
        if not isinstance(generation, str) or not GENERATION_RE.fullmatch(generation):
            return None
        expected = self.data_dir / f"run-{generation}" / "mpv.sock"
        try:
            if Path(socket_path).resolve(strict=False) != expected.resolve(strict=False):
                return None
        except (OSError, TypeError):
            return None
        parent = expected.parent
        if not _safe_owner_mode(parent, directory=True):
            return None
        self.target_signature = signature
        return {"generation": generation, "socket": str(expected)}

    def send(self, command: list[Any]) -> None:
        if self.sock is None:
            return
        request_id = self.request_id
        if command and command[0] == "get_property" and len(command) == 2:
            property_name = str(command[1])
            # A newer refresh supersedes an unanswered lookup for the same property.
            for pending_id, pending_name in list(self.property_requests.items()):
                if pending_name == property_name:
                    del self.property_requests[pending_id]
            while len(self.property_requests) >= MAX_PENDING_PROPERTY_REQUESTS:
                del self.property_requests[next(iter(self.property_requests))]
            self.property_requests[request_id] = property_name
            self.property_errors.pop(property_name, None)
            self.property_deadline = max(
                self.property_deadline,
                time.monotonic() + PROPERTY_RESPONSE_TIMEOUT_SECONDS,
            )
        raw = json.dumps({"command": command, "request_id": request_id}, separators=(",", ":"))
        self.request_id += 1
        try:
            self.sock.sendall((raw + "\n").encode("utf-8"))
        except (OSError, ConnectionError):
            self.close_socket()
            raise

    def connect(self) -> bool:
        if self.target is None:
            return False
        try:
            socket_path = Path(self.target["socket"])
            socket_info = socket_path.lstat()
            if (stat.S_ISLNK(socket_info.st_mode) or not stat.S_ISSOCK(socket_info.st_mode)
                    or socket_info.st_uid != os.getuid()):
                return False
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(1.0)
            connection.connect(str(socket_path))
            connection.setblocking(False)
            self.sock = connection
            self.backoff = 0.1
            for name in PROPERTIES:
                self.send(["observe_property", 0, name])
            for name in PROPERTIES:
                self.send(["get_property", name])
            self.next_resync = time.monotonic() + 2.0
            self.emit("status", ok=True, connected=True, audio_ready=False,
                      audio_ready_known=False, paused=False, paused_known=False,
                      core_idle=False, core_idle_known=False, title="", volume=None,
                      muted=False, complete=False, initial=True)
            return True
        except (OSError, ValueError) as error:
            self.last_connect_error = _error_detail(error)
            self.close_socket()
            return False

    @staticmethod
    def valid_audio(value: Any) -> bool:
        if not isinstance(value, dict) or not isinstance(value.get("format"), str):
            return False
        try:
            return float(value.get("samplerate", 0)) > 0 and float(value.get("channel-count", 0)) > 0
        except (TypeError, ValueError):
            return False

    def handle_line(self, line: bytes) -> bool:
        if len(line) > MAX_SOCKET_LINE:
            return False
        try:
            value = json.loads(line.decode("utf-8"))
        except (UnicodeError, ValueError):
            return False
        if not isinstance(value, dict):
            return False
        error = value.get("error")
        error_reply = error not in (None, "success")
        request_response = False
        if value.get("event") == "property-change":
            name, data = value.get("name"), value.get("data")
        else:
            name, data = None, value.get("data")
            request_id = value.get("request_id")
            if isinstance(request_id, int):
                request_response = True
                name = self.property_requests.pop(request_id, None)
        if request_response:
            self.last_ipc_response = time.monotonic()
            if error_reply and name is not None:
                self.property_errors[name] = str(error)[:256]
            if not self.property_requests:
                self.property_deadline = 0.0
        if error_reply:
            return request_response
        changed = False
        if name == "pause" and isinstance(data, bool):
            changed = self.values.get("paused") != data
            self.values["paused"] = data
            if not self.values.get("paused_known"):
                changed = True
            self.values["paused_known"] = True
        elif name == "metadata":
            title = data.get("icy-title", "") if isinstance(data, dict) else ""
            title = title[:1024] if isinstance(title, str) else ""
            changed = self.values.get("title") != title
            self.values["title"] = title
        elif name == "volume":
            try:
                number = float(data)
                if math.isfinite(number):
                    changed = self.values.get("volume") != number
                    self.values["volume"] = number
            except (TypeError, ValueError):
                pass
        elif name == "mute" and isinstance(data, bool):
            changed = self.values.get("muted") != data
            self.values["muted"] = data
        elif name == "audio-out-params":
            ready = self.valid_audio(data)
            changed = self.values.get("audio_ready") != ready
            self.values["audio_ready"] = ready
            if not self.values.get("audio_ready_known"):
                changed = True
            self.values["audio_ready_known"] = True
        elif name == "core-idle" and isinstance(data, bool):
            changed = self.values.get("core_idle") != data
            self.values["core_idle"] = data
            if not self.values.get("core_idle_known"):
                changed = True
            self.values["core_idle_known"] = True
        if ((changed or request_response and not self.property_requests)
                and self.values.get("paused_known")
                and self.values.get("audio_ready_known")
                and self.values.get("core_idle_known")):
            self.emit("status", ok=True, connected=True, complete=True, **self.values)
        return True

    def read_socket(self) -> None:
        if self.sock is None:
            return
        try:
            data = self.sock.recv(65536)
            if not data:
                raise ConnectionError
            self.buffer += data
        except BlockingIOError:
            return
        except (OSError, ConnectionError):
            raise
        if len(self.buffer) > MAX_SOCKET_LINE * 2:
            raise ValueError("socket buffer oversized")
        while b"\n" in self.buffer:
            line, self.buffer = self.buffer.split(b"\n", 1)
            if line.endswith(b"\r"):
                line = line[:-1]
            self.handle_line(line)

    def loop(self) -> None:
        if not _safe_owner_mode(self.data_dir, directory=True):
            return
        while True:
            disabled = self.read_control_disabled()
            target = None if disabled else self.read_target()
            if target is None:
                self.close_socket()
                self.target = None
            elif self.target is None or target["generation"] != self.target.get("generation"):
                self.close_socket()
                self.target = target
            if self.sock is None and target is not None and not disabled:
                if not self.connect():
                    self.emit("status", ok=False, connected=False, audio_ready=False,
                              error="socket_unavailable", detail=self.last_connect_error)
                    time.sleep(self.backoff)
                    self.backoff = min(1.0, self.backoff * 2)
                    continue
            now = time.monotonic()
            if now >= self.next_heartbeat:
                self.emit("heartbeat", connected=self.sock is not None,
                          audio_ready=self.values.get("audio_ready", False),
                          ipc_ready=self.sock is not None
                          and not self.property_requests
                          and self.last_ipc_response > 0
                          and now - self.last_ipc_response <= 2.5)
                self.next_heartbeat = now + 2.0
            if self.sock is not None:
                try:
                    if (
                        self.property_requests
                        and self.property_deadline > 0
                        and now >= self.property_deadline
                    ):
                        self.emit("status", ok=False, connected=False, audio_ready=False,
                                  error="ipc_unresponsive")
                        self.close_socket()
                        self.backoff = 0.1
                        continue
                    if now >= self.next_resync and not self.property_requests:
                        for name in PROPERTIES:
                            self.send(["get_property", name])
                        self.next_resync = now + 2.0
                    readable, _, _ = select.select([self.sock], [], [], 0.25)
                    if readable:
                        self.read_socket()
                except (OSError, ValueError, ConnectionError) as error:
                    self.emit("status", ok=False, connected=False, audio_ready=False,
                              error="socket_read_failed", detail=_error_detail(error))
                    self.close_socket()
                    self.backoff = 0.1
            else:
                time.sleep(0.25 if target is not None else 1.0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", required=True)
    args = parser.parse_args()
    try:
        data_dir = Path(args.data_dir).absolute()
        if _has_symlink_component(data_dir):
            raise ValueError("data directory contains a symlink")
        PlayerMonitor(data_dir).loop()
    except (OSError, ValueError, ConnectionError) as error:
        print(f"radio-tellus player monitor stopped: {_error_detail(error)}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
