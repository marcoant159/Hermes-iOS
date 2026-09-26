from __future__ import annotations

import json
import os
import stat
import threading
import time

from hermes_mobile_connector.client import HermesMobileConnector
from hermes_mobile_connector.hermes_runner import ConnectorHermesSettings, HermesCLIExecutor
from hermes_mobile_connector.state import (
    ConnectorState,
    ConnectorStateStore,
    VoiceContextSnapshot,
)


def make_executor() -> HermesCLIExecutor:
    return HermesCLIExecutor(
        ConnectorHermesSettings(
            hermes_command="hermes",
            hermes_workdir=None,
            hermes_provider=None,
            hermes_model=None,
            hermes_toolsets=None,
            hermes_source="tool",
            hermes_history_limit=20,
        )
    )


def make_state(**overrides) -> ConnectorState:
    base = {
        "relay_url": "https://relay.example.com/v1",
        "web_socket_url": "wss://relay.example.com/v1/hosts/ws",
        "user_id": "user-123",
        "host_id": "host-123",
        "connector_credential": "secret-token",
    }
    base.update(overrides)
    return ConnectorState(**base)


def make_snapshot(updated_at: str) -> VoiceContextSnapshot:
    return VoiceContextSnapshot(
        system_prompt="prompt",
        memory_summary="mem",
        user_summary="user",
        sensor_summary="sensors",
        readiness_summary="ready",
        updated_at=updated_at,
    )


def test_slow_refresh_does_not_clobber_connected_at(monkeypatch, tmp_path):
    store = ConnectorStateStore(state_dir=tmp_path / "slow-refresh")
    store.save(make_state(last_connected_at="2020-01-01T00:00:00+00:00"))
    connector = HermesMobileConnector(state_store=store, executor=make_executor())

    started = threading.Event()
    release = threading.Event()

    def blocking_build(**kwargs):  # noqa: ANN003, ANN202
        started.set()
        assert release.wait(timeout=5)
        return make_snapshot("2026-09-26T12:00:00+00:00")

    monkeypatch.setattr(
        "hermes_mobile_connector.client.build_voice_context_snapshot", blocking_build
    )
    monkeypatch.setattr(
        "hermes_mobile_connector.client.native_mcp_readiness_message",
        lambda **kwargs: "ready",
    )

    result: dict = {}

    def run_refresh() -> None:
        result["state"] = connector.refresh_voice_context()

    worker = threading.Thread(target=run_refresh)
    worker.start()
    assert started.wait(timeout=5)

    # Another path (e.g. the relay connect loop) persists while the rebuild runs.
    new_connected = "2026-09-26T12:00:01+00:00"
    store.update(lambda state: setattr(state, "last_connected_at", new_connected))

    release.set()
    worker.join(timeout=5)
    assert not worker.is_alive()

    persisted = store.load()
    assert persisted.last_connected_at == new_connected
    assert persisted.voice_context_snapshot.updated_at == "2026-09-26T12:00:00+00:00"
    assert result["state"].voice_context_snapshot.updated_at == "2026-09-26T12:00:00+00:00"


def test_concurrent_updates_do_not_lose_writes(tmp_path):
    store = ConnectorStateStore(state_dir=tmp_path / "concurrent")
    store.save(make_state(mcp_last_test_error="0"))

    threads_count = 8
    iterations = 50
    barrier = threading.Barrier(threads_count)

    def mutate(state: ConnectorState) -> None:
        state.mcp_last_test_error = str(int(state.mcp_last_test_error or "0") + 1)

    def bump() -> None:
        barrier.wait(timeout=5)
        for _ in range(iterations):
            store.update(mutate)

    threads = [threading.Thread(target=bump) for _ in range(threads_count)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)
        assert not thread.is_alive()

    # Every increment is serialized, so none is lost to a stale load+save.
    assert store.load().mcp_last_test_error == str(threads_count * iterations)


def test_atomic_save_keeps_file_valid_and_preserves_mode(tmp_path):
    store = ConnectorStateStore(state_dir=tmp_path / "atomic")
    store.save(make_state(host_id="host-initial"))
    os.chmod(store.state_path, 0o600)

    stop = threading.Event()
    errors: list[BaseException] = []

    def writer() -> None:
        index = 0
        while not stop.is_set():
            index += 1
            store.save(make_state(host_id=f"host-{index}"))

    def reader() -> None:
        try:
            while not stop.is_set():
                state = store.load()
                assert state.connector_credential == "secret-token"
                assert state.host_id.startswith("host-")
        except BaseException as error:  # noqa: BLE001
            errors.append(error)

    writer_thread = threading.Thread(target=writer)
    reader_thread = threading.Thread(target=reader)
    writer_thread.start()
    reader_thread.start()
    time.sleep(0.5)
    stop.set()
    writer_thread.join(timeout=5)
    reader_thread.join(timeout=5)

    assert not errors
    # No half-written temp files are left behind.
    assert not [path for path in store.state_dir.iterdir() if path.suffix == ".tmp"]
    assert stat.S_IMODE(store.state_path.stat().st_mode) == 0o600
    # The file on disk is always complete JSON.
    json.loads(store.state_path.read_text(encoding="utf-8"))
