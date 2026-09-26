from __future__ import annotations

from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from datetime import datetime
import json
import os
from pathlib import Path
import stat
import tempfile
import threading


def _default_state_dir() -> Path:
    configured = os.getenv("HERMES_MOBILE_CONNECTOR_HOME")
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".hermes-mobile"


@dataclass
class ConnectorRuntimeConfig:
    python_executable: str
    state_dir: str
    relay_url: str
    hermes_command: str
    hermes_workdir: str | None
    hermes_provider: str | None
    hermes_model: str | None
    hermes_toolsets: str | None
    hermes_source: str
    hermes_history_limit: int
    hermes_home: str | None = None
    api_server_url: str | None = None
    api_server_key: str | None = None


@dataclass
class RealtimeTalkConfig:
    enabled: bool = False
    preferred_models: list[str] = field(default_factory=lambda: ["gpt-realtime-1.5", "gpt-realtime"])
    voice: str = "ballad"
    turn_detection_type: str = "semantic_vad"
    create_response: bool = True
    interrupt_response: bool = True
    last_validated_at: str | None = None
    last_validation_error: str | None = None
    last_selected_model: str | None = None


@dataclass
class VoiceContextSnapshot:
    system_prompt: str
    memory_summary: str
    user_summary: str
    sensor_summary: str
    readiness_summary: str
    updated_at: str
    memory_provider_summary: str = "Memory provider status unavailable."


@dataclass
class ConnectorState:
    relay_url: str
    web_socket_url: str
    host_id: str
    connector_credential: str
    user_id: str | None = None
    connector_display_name: str | None = None
    enrolled_at: str | None = None
    last_connected_at: str | None = None
    last_error: str | None = None
    mcp_server_name: str = "hermes_mobile"
    mcp_configured: bool = False
    mcp_command_path: str | None = None
    mcp_registered_at: str | None = None
    mcp_last_test_at: str | None = None
    mcp_last_test_error: str | None = None
    runtime_config: ConnectorRuntimeConfig | None = None
    realtime_talk: RealtimeTalkConfig | None = None
    voice_context_snapshot: VoiceContextSnapshot | None = None

    @property
    def enrolled_datetime(self) -> datetime | None:
        return datetime.fromisoformat(self.enrolled_at) if self.enrolled_at else None


@dataclass
class ConnectorSecrets:
    openai_api_key: str | None = None


class ConnectorStateStore:
    def __init__(self, state_dir: Path | None = None) -> None:
        self.state_dir = (state_dir or _default_state_dir()).expanduser()
        self.state_path = self.state_dir / "state.json"
        self.secrets_path = self.state_dir / "secrets.json"
        # The store is read and written from worker threads (`asyncio.to_thread`)
        # as well as the event loop, so every load/save/update is serialized.
        self._lock = threading.RLock()

    def load(self) -> ConnectorState:
        with self._lock:
            if not self.state_path.exists():
                raise RuntimeError(
                    "Connector is not set up yet. Run `hermes-mobile setup` first "
                    "or use the legacy `hermes-mobile enroll --code ...` flow."
                )
            data = json.loads(self.state_path.read_text(encoding="utf-8"))
            runtime_config = data.get("runtime_config")
            if isinstance(runtime_config, dict):
                data["runtime_config"] = ConnectorRuntimeConfig(**runtime_config)
            realtime_talk = data.get("realtime_talk")
            if isinstance(realtime_talk, dict):
                data["realtime_talk"] = RealtimeTalkConfig(**realtime_talk)
            voice_context_snapshot = data.get("voice_context_snapshot")
            if isinstance(voice_context_snapshot, dict):
                data["voice_context_snapshot"] = VoiceContextSnapshot(**voice_context_snapshot)
            data.setdefault(
                "mcp_configured",
                bool(data.get("mcp_registered_at") or data.get("mcp_command_path")),
            )
            return ConnectorState(**data)

    def save(self, state: ConnectorState) -> ConnectorState:
        with self._lock:
            self._write_state(state)
            return state

    def update(self, mutator: Callable[[ConnectorState], None]) -> ConnectorState:
        """Atomically load, mutate, and persist the latest state.

        Use this instead of ``load`` + ``save`` whenever the mutation happens
        after slow work (subprocesses, network calls) or from a background
        thread: it serializes against other writers and only the mutated fields
        are derived from the newest state, so concurrent writes are not lost.
        """
        with self._lock:
            state = self.load()
            mutator(state)
            self._write_state(state)
            return state

    def _write_state(self, state: ConnectorState) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(self.state_dir, 0o700)
        except PermissionError:
            pass

        payload = json.dumps(asdict(state), indent=2, sort_keys=True)
        self._atomic_write(self.state_path, payload, default_mode=0o600)

    @staticmethod
    def _atomic_write(path: Path, payload: str, *, default_mode: int) -> None:
        """Write ``payload`` to ``path`` atomically, keeping its current mode.

        The temp file lives in the same directory so ``os.replace`` is a
        same-filesystem rename: readers never observe a half-written state.json.
        """
        try:
            mode = stat.S_IMODE(os.stat(path).st_mode)
        except FileNotFoundError:
            mode = default_mode

        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as tmp_file:
                tmp_file.write(payload)
            try:
                os.chmod(tmp_name, mode)
            except PermissionError:
                pass
            os.replace(tmp_name, path)
        except BaseException:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            raise

    def load_secrets(self) -> ConnectorSecrets:
        with self._lock:
            if not self.secrets_path.exists():
                return ConnectorSecrets()
            data = json.loads(self.secrets_path.read_text(encoding="utf-8"))
            return ConnectorSecrets(**data)

    def save_secrets(self, secrets: ConnectorSecrets) -> ConnectorSecrets:
        with self._lock:
            self.state_dir.mkdir(parents=True, exist_ok=True)
            try:
                os.chmod(self.state_dir, 0o700)
            except PermissionError:
                pass

            payload = json.dumps(asdict(secrets), indent=2, sort_keys=True)
            self._atomic_write(self.secrets_path, payload, default_mode=0o600)
            return secrets

    def clear(self) -> None:
        with self._lock:
            if self.state_path.exists():
                self.state_path.unlink()
            if self.secrets_path.exists():
                self.secrets_path.unlink()
            if self.state_dir.exists() and not any(self.state_dir.iterdir()):
                self.state_dir.rmdir()
