"""Tests for connector model-override handling.

Covers the allowlist parser, the legacy Gemini alias, and the API executor
payload (with and without an override) plus job routing for overrides.
"""

from __future__ import annotations

import asyncio

import pytest

from hermes_mobile_connector.client import HermesMobileConnector
from hermes_mobile_connector.hermes_api_executor import HermesAPIExecutor
from hermes_mobile_connector.model_overrides import (
    SUPPORTED_MODEL_OVERRIDES,
    parse_model_override,
)
from hermes_mobile_connector.runtime_adapter import (
    HermesAPIRuntimeAdapter,
    HermesRuntimeAdapter,
)
from hermes_mobile_connector.state import ConnectorStateStore
from test_streaming import FakeWebSocket, make_enrolled_state, make_executor


# --------------------------------------------------------------------------
# parse_model_override
# --------------------------------------------------------------------------


def test_parse_model_override_accepts_every_supported_value():
    for override in SUPPORTED_MODEL_OVERRIDES:
        provider, model = parse_model_override(override)
        assert provider
        assert model
        assert f"{provider}/{model}" == override


def test_parse_model_override_maps_legacy_gemini_value():
    assert parse_model_override("gemini-3.8-flash") == ("gemini", "gemini-3.8-flash")


def test_parse_model_override_returns_none_without_override():
    assert parse_model_override(None) is None
    assert parse_model_override("") is None


@pytest.mark.parametrize(
    "override",
    ["hermes-agent", "gemini-3.8", "openai-codex/gpt-4", "gpt-6-luna", "bogus/model"],
)
def test_parse_model_override_rejects_unsupported_values(override):
    with pytest.raises(ValueError):
        parse_model_override(override)


# --------------------------------------------------------------------------
# HermesAPIExecutor payload
# --------------------------------------------------------------------------


def test_api_executor_payload_without_override_uses_hermes_agent():
    executor = HermesAPIExecutor()

    payload = executor._build_payload(  # noqa: SLF001
        stream=True,
        latest_user_message="hello",
        history=[],
        attachments=None,
    )

    assert payload["model"] == "hermes-agent"
    assert "provider" not in payload
    assert payload["stream"] is True
    assert payload["messages"] == [{"role": "user", "content": "hello"}]


def test_api_executor_payload_with_override_uses_provider_and_model():
    executor = HermesAPIExecutor(provider="openai-codex", model="gpt-6-luna")

    payload = executor._build_payload(  # noqa: SLF001
        stream=False,
        latest_user_message="hello",
        history=[],
        attachments=None,
    )

    assert payload["provider"] == "openai-codex"
    assert payload["model"] == "gpt-6-luna"
    assert payload["model"] != "hermes-agent"
    assert payload["stream"] is False


# --------------------------------------------------------------------------
# _handle_job routing
# --------------------------------------------------------------------------


def test_handle_job_fails_on_unsupported_override(tmp_path):
    store = ConnectorStateStore(state_dir=tmp_path / "bad-override")
    store.save(make_enrolled_state())
    connector = HermesMobileConnector(state_store=store, executor=make_executor())

    ws = FakeWebSocket()
    job = {
        "id": "job-bad-override",
        "latestUserMessage": "hello",
        "history": [],
        "modelOverride": "bogus/model",
    }

    asyncio.run(connector._handle_job(ws, job))  # noqa: SLF001

    assert ws.sent[0]["type"] == "job.failed"
    assert ws.sent[0]["retryable"] is False
    assert ws.sent[0]["error"] == "Unsupported mobile model override."


def test_handle_job_routes_override_to_api_executor(tmp_path, monkeypatch):
    store = ConnectorStateStore(state_dir=tmp_path / "api-override")
    store.save(make_enrolled_state())
    connector = HermesMobileConnector(state_store=store, executor=make_executor())

    shared_executor = HermesAPIExecutor(api_server_url="http://localhost:8642")

    async def fake_runtime_adapter_async(state):  # noqa: ANN001
        return HermesAPIRuntimeAdapter(shared_executor)

    captured: dict = {}

    async def fake_handle_job_streaming(websocket, job, runtime, workdir=None):  # noqa: ANN001
        captured["executor"] = runtime.executor

    monkeypatch.setattr(connector, "runtime_adapter_for_state_async", fake_runtime_adapter_async)
    monkeypatch.setattr(connector, "_handle_job_streaming", fake_handle_job_streaming)

    job = {
        "id": "job-api-override",
        "latestUserMessage": "hello",
        "history": [],
        "modelOverride": "gemini/gemini-3.8-flash",
    }

    asyncio.run(connector._handle_job(FakeWebSocket(), job))  # noqa: SLF001

    assert captured["executor"].provider == "gemini"
    assert captured["executor"].model == "gemini-3.8-flash"
    # The cached/shared executor must not be mutated.
    assert shared_executor.provider is None
    assert shared_executor.model is None


def test_handle_job_routes_override_to_cli_settings(tmp_path, monkeypatch):
    store = ConnectorStateStore(state_dir=tmp_path / "cli-override")
    store.save(make_enrolled_state())
    connector = HermesMobileConnector(state_store=store, executor=make_executor())

    cli_adapter = HermesRuntimeAdapter(make_executor())

    async def fake_runtime_adapter_async(state):  # noqa: ANN001
        return cli_adapter

    captured: dict = {}

    async def fake_handle_job_cli(websocket, job, runtime):  # noqa: ANN001
        captured["settings"] = runtime.executor.settings

    monkeypatch.setattr(connector, "runtime_adapter_for_state_async", fake_runtime_adapter_async)
    monkeypatch.setattr(connector, "_handle_job_cli", fake_handle_job_cli)

    job = {
        "id": "job-cli-override",
        "latestUserMessage": "hello",
        "history": [],
        "modelOverride": "openai-codex/gpt-6-luna",
    }

    asyncio.run(connector._handle_job(FakeWebSocket(), job))  # noqa: SLF001

    assert captured["settings"].hermes_provider == "openai-codex"
    assert captured["settings"].hermes_model == "gpt-6-luna"
