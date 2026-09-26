from __future__ import annotations

import asyncio
import subprocess
import threading
import time

import pytest

from hermes_mobile_connector.client import HermesMobileConnector
from hermes_mobile_connector.hermes_runner import ConnectorHermesSettings, HermesCLIExecutor
from hermes_mobile_connector.state import (
    ConnectorSecrets,
    ConnectorState,
    ConnectorStateStore,
    RealtimeTalkConfig,
    VoiceContextSnapshot,
)
import hermes_mobile_connector.talk_support as talk_support

STALE_UPDATED_AT = "2020-01-01T00:00:00+00:00"


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


def make_snapshot(updated_at: str) -> VoiceContextSnapshot:
    return VoiceContextSnapshot(
        system_prompt=f"System prompt {updated_at}",
        memory_summary="Memory",
        user_summary="User",
        sensor_summary="Sensors",
        readiness_summary="Ready",
        updated_at=updated_at,
    )


def make_connector(
    tmp_path,
    *,
    name: str,
    snapshot: VoiceContextSnapshot | None,
    openai_api_key: str | None = None,
) -> tuple[HermesMobileConnector, ConnectorStateStore]:
    store = ConnectorStateStore(state_dir=tmp_path / name)
    store.save(
        ConnectorState(
            relay_url="https://relay.example.com/v1",
            web_socket_url="wss://relay.example.com/v1/hosts/ws",
            user_id="user-123",
            host_id="host-123",
            connector_credential="secret-token",
            realtime_talk=RealtimeTalkConfig(enabled=True, last_validation_error=None),
            voice_context_snapshot=snapshot,
        )
    )
    if openai_api_key:
        store.save_secrets(ConnectorSecrets(openai_api_key=openai_api_key))
    return HermesMobileConnector(state_store=store, executor=make_executor()), store


def _patch_readiness(monkeypatch) -> None:
    monkeypatch.setattr(
        "hermes_mobile_connector.client.native_mcp_readiness_message",
        lambda **kwargs: "Ready now (test).",
    )


def test_prewarm_returns_stale_snapshot_fast_and_schedules_refresh(monkeypatch, tmp_path):
    connector, store = make_connector(
        tmp_path, name="prewarm-stale", snapshot=make_snapshot(STALE_UPDATED_AT)
    )
    _patch_readiness(monkeypatch)

    calls: list[float] = []

    def slow_refresh(self, *, state=None):
        calls.append(time.monotonic())
        time.sleep(0.5)
        state = state or self.state_store.load()
        state.voice_context_snapshot = make_snapshot("2026-09-26T12:00:00+00:00")
        return self.state_store.save(state)

    monkeypatch.setattr(HermesMobileConnector, "refresh_voice_context", slow_refresh)

    async def scenario():
        start = time.monotonic()
        payload = await connector._handle_talk_prewarm()  # noqa: SLF001
        elapsed = time.monotonic() - start

        assert elapsed < 0.25
        assert payload["voiceContextUpdatedAt"] == STALE_UPDATED_AT
        assert connector._voice_refresh_task is not None  # noqa: SLF001

        await asyncio.wait_for(connector._voice_refresh_task, timeout=3.0)  # noqa: SLF001
        assert len(calls) == 1
        assert store.load().voice_context_snapshot.updated_at != STALE_UPDATED_AT

    asyncio.run(scenario())


def test_prewarm_does_not_stack_background_refreshes(monkeypatch, tmp_path):
    connector, _ = make_connector(
        tmp_path, name="prewarm-single", snapshot=make_snapshot(STALE_UPDATED_AT)
    )
    _patch_readiness(monkeypatch)

    started = threading.Event()
    release = threading.Event()
    calls: list[int] = []

    def blocking_refresh(self, *, state=None):
        calls.append(1)
        started.set()
        release.wait(timeout=5)
        state = state or self.state_store.load()
        state.voice_context_snapshot = make_snapshot("2026-09-26T12:00:00+00:00")
        return self.state_store.save(state)

    monkeypatch.setattr(HermesMobileConnector, "refresh_voice_context", blocking_refresh)

    async def scenario():
        await connector._handle_talk_prewarm()  # noqa: SLF001
        assert await asyncio.to_thread(started.wait, 1.0)
        first_task = connector._voice_refresh_task  # noqa: SLF001

        await connector._handle_talk_prewarm()  # noqa: SLF001
        await connector._handle_talk_prewarm()  # noqa: SLF001

        assert connector._voice_refresh_task is first_task  # noqa: SLF001
        assert len(calls) == 1

        release.set()
        await asyncio.wait_for(first_task, timeout=3.0)
        assert len(calls) == 1

    asyncio.run(scenario())


def test_session_create_without_snapshot_does_not_block(monkeypatch, tmp_path):
    connector, _ = make_connector(
        tmp_path,
        name="session-no-snapshot",
        snapshot=None,
        openai_api_key="sk-test-realtime",
    )
    _patch_readiness(monkeypatch)

    captured: dict = {}

    def slow_refresh(self, *, state=None):
        time.sleep(0.5)
        state = state or self.state_store.load()
        state.voice_context_snapshot = make_snapshot("2026-09-26T12:00:00+00:00")
        return self.state_store.save(state)

    monkeypatch.setattr(HermesMobileConnector, "refresh_voice_context", slow_refresh)
    monkeypatch.setattr(
        connector,
        "_create_openai_realtime_session",
        lambda **kwargs: (
            captured.update(kwargs)
            or (
                {"value": "ek", "expires_at": 1_775_001_600, "session": {"id": "sess"}},
                "gpt-realtime-1.5",
            )
        ),
    )

    async def scenario():
        start = time.monotonic()
        payload = await connector._handle_talk_session_create(  # noqa: SLF001
            {
                "relayMcpURL": "https://relay.example.com/v1/talk/mcp?token=test",
                "provider": "openai_realtime",
            }
        )
        elapsed = time.monotonic() - start

        assert elapsed < 0.25
        assert payload["clientSecret"] == "ek"
        assert "being checked in the background" in captured["instructions"]
        assert connector._voice_refresh_task is not None  # noqa: SLF001

        await asyncio.wait_for(connector._voice_refresh_task, timeout=3.0)  # noqa: SLF001

    asyncio.run(scenario())


def test_memory_provider_timeout_preserves_previous_cache(monkeypatch):
    now = time.monotonic()
    monkeypatch.setattr(
        talk_support,
        "_memory_provider_cache",
        (now - talk_support._MEMORY_PROVIDER_CACHE_TTL - 1.0, "cached-status"),
    )

    def boom(*args, **kwargs):
        raise subprocess.TimeoutExpired(cmd=["hermes"], timeout=30)

    monkeypatch.setattr(talk_support.subprocess, "run", boom)

    result = talk_support.summarize_memory_provider(hermes_command="hermes", hermes_home=None)
    assert result == "cached-status"


def test_memory_provider_timeout_without_cache_reports_unavailable(monkeypatch):
    monkeypatch.setattr(talk_support, "_memory_provider_cache", (0.0, ""))

    def boom(*args, **kwargs):
        raise subprocess.TimeoutExpired(cmd=["hermes"], timeout=30)

    monkeypatch.setattr(talk_support.subprocess, "run", boom)

    result = talk_support.summarize_memory_provider(hermes_command="hermes", hermes_home=None)
    assert "timed out" in result
