from __future__ import annotations

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
from hermes_mobile_connector.talk_support import (
    CODEX_LIVE_ALPHA_HEADER,
    CODEX_LIVE_CALLS_URL,
    CODEX_LIVE_MODEL,
    CODEX_LIVE_VOICE,
    CODEX_REALTIME_CALLS_URL,
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


def make_connector(tmp_path, name: str) -> tuple[HermesMobileConnector, ConnectorStateStore]:
    store = ConnectorStateStore(state_dir=tmp_path / name)
    store.save(
        ConnectorState(
            relay_url="https://relay.example.com/v1",
            web_socket_url="wss://relay.example.com/v1/hosts/ws",
            user_id="user-123",
            host_id="host-123",
            connector_credential="secret-token",
            realtime_talk=RealtimeTalkConfig(enabled=True, last_validation_error=None),
            voice_context_snapshot=VoiceContextSnapshot(
                system_prompt="System prompt",
                memory_summary="Memory",
                user_summary="User",
                sensor_summary="Sensors",
                readiness_summary="Ready",
                updated_at="2026-04-01T12:00:00+00:00",
            ),
        )
    )
    return HermesMobileConnector(state_store=store, executor=make_executor()), store


class FakeResponse:
    def __init__(self, status_code: int, text: str = "", headers: dict | None = None) -> None:
        self.status_code = status_code
        self.text = text
        self.headers = headers or {}


def test_auto_provider_prefers_codex_live_over_realtime_and_gemini(
    monkeypatch, tmp_path, codex_credentials
):
    connector, _ = make_connector(tmp_path, "connector-live-priority")
    monkeypatch.setenv("GOOGLE_API_KEY", "google-key-fixture")
    monkeypatch.setattr(
        "hermes_mobile_connector.client.load_codex_credentials",
        lambda **kwargs: codex_credentials,
    )

    assert (
        connector._resolve_talk_provider(  # noqa: SLF001
            requested="auto",
            codex_ready=True,
            gemini_ready=True,
            openai_ready=True,
            config=RealtimeTalkConfig(enabled=True),
        )
        == "codex_live"
    )
    assert (
        connector._resolve_talk_provider(  # noqa: SLF001
            requested="codex_realtime",
            codex_ready=True,
            gemini_ready=True,
            openai_ready=True,
            config=RealtimeTalkConfig(enabled=True),
        )
        == "codex_realtime"
    )


def test_forced_codex_live_requires_credentials(monkeypatch, tmp_path):
    connector, _ = make_connector(tmp_path, "connector-live-no-creds")

    with pytest.raises(RuntimeError, match="Codex Live is not available"):
        connector._resolve_talk_provider(  # noqa: SLF001
            requested="codex_live",
            codex_ready=False,
            gemini_ready=True,
            openai_ready=True,
            config=RealtimeTalkConfig(enabled=True),
        )


def test_talk_session_create_builds_exact_live_definition(
    monkeypatch, tmp_path, codex_credentials
):
    connector, store = make_connector(tmp_path, "connector-live-session")
    monkeypatch.setenv("GOOGLE_API_KEY", "google-key-fixture")
    monkeypatch.setattr(
        "hermes_mobile_connector.client.load_codex_credentials",
        lambda **kwargs: codex_credentials,
    )
    monkeypatch.setattr(
        connector, "refresh_voice_context_if_stale", lambda *, state=None: state or store.load()
    )

    payload = connector._rpc_talk_session_create(  # noqa: SLF001
        {
            "voiceSessionId": "voice-live-1",
            "relayMcpURL": "https://relay.example.com/v1/talk/mcp?token=test",
            "provider": "codex_live",
        }
    )

    assert payload["provider"] == "codex_live"
    assert payload["model"] == CODEX_LIVE_MODEL
    assert payload["voice"] == CODEX_LIVE_VOICE
    assert payload["clientSecret"] is None
    assert payload["expiresAt"] is None
    assert payload["session"] == {}
    assert payload["relayMcpURL"] == "https://relay.example.com/v1/talk/mcp?token=test"

    entry = connector._codex_realtime_sessions["voice-live-1"]  # noqa: SLF001
    assert entry["kind"] == "live"
    definition = entry["session"]
    assert definition == {
        "instructions": (
            "System prompt\n\n"
            "Quando o usuário pedir algo que exija dados, ações ou ferramentas "
            "(fazenda, reservatórios, sensores, Inttegra, agenda, e-mail, arquivos etc.), "
            "delegue. Fale sempre em português do Brasil, de forma breve."
        ),
        "model": CODEX_LIVE_MODEL,
        "audio": {"output": {"voice": CODEX_LIVE_VOICE}},
        "delegation": {"type": "client", "ack_filler": True},
    }
    assert "type" not in definition
    assert "tools" not in definition
    assert "output_modalities" not in definition
    assert "input" not in definition["audio"]


def test_live_sdp_exchange_uses_live_url_and_alpha_header(
    monkeypatch, tmp_path, codex_credentials
):
    connector, _ = make_connector(tmp_path, "connector-live-exchange")
    definition = {"model": CODEX_LIVE_MODEL, "instructions": "hi"}
    connector._codex_realtime_sessions["voice-live-1"] = {  # noqa: SLF001
        "session": definition,
        "kind": "live",
        "created_at": time.monotonic(),
    }
    captured: dict = {}

    def fake_post(url, headers=None, json=None, timeout=None):  # noqa: ANN001
        captured["url"] = url
        captured["headers"] = headers
        captured["json"] = json
        return FakeResponse(201, "v=0\r\nlive-answer", {"Location": "/v1/live/rtc_live123"})

    monkeypatch.setattr("hermes_mobile_connector.client.httpx.post", fake_post)
    monkeypatch.setattr(
        "hermes_mobile_connector.client.load_codex_credentials",
        lambda **kwargs: codex_credentials,
    )

    result = connector._rpc_talk_sdp_exchange(  # noqa: SLF001
        {"voiceSessionId": "voice-live-1", "sdp": "v=0\r\nsdp-offer"}
    )

    assert captured["url"] == CODEX_LIVE_CALLS_URL
    assert "intent=quicksilver" in CODEX_LIVE_CALLS_URL
    assert "architecture=avas" in CODEX_LIVE_CALLS_URL
    assert captured["headers"]["OpenAI-Alpha"] == CODEX_LIVE_ALPHA_HEADER
    assert captured["headers"]["Authorization"] == "Bearer codex-access-token-fixture"
    assert captured["headers"]["ChatGPT-Account-Id"] == "acct-fixture"
    assert captured["headers"]["originator"] == "codex_cli_rs"
    assert captured["json"] == {"sdp": "v=0\r\nsdp-offer", "session": definition}
    assert result == {"sdp": "v=0\r\nlive-answer", "callId": "rtc_live123"}


def test_realtime_sdp_exchange_does_not_send_alpha_header(
    monkeypatch, tmp_path, codex_credentials
):
    connector, _ = make_connector(tmp_path, "connector-realtime-no-alpha")
    connector._codex_realtime_sessions["voice-rt-1"] = {  # noqa: SLF001
        "session": {"type": "realtime", "model": "gpt-realtime-1.5"},
        "kind": "realtime",
        "created_at": time.monotonic(),
    }
    captured: dict = {}

    def fake_post(url, headers=None, json=None, timeout=None):  # noqa: ANN001
        captured["url"] = url
        captured["headers"] = headers
        return FakeResponse(201, "v=0\r\nanswer", {"Location": "/v1/realtime/calls/call_rt"})

    monkeypatch.setattr("hermes_mobile_connector.client.httpx.post", fake_post)
    monkeypatch.setattr(
        "hermes_mobile_connector.client.load_codex_credentials",
        lambda **kwargs: codex_credentials,
    )

    connector._rpc_talk_sdp_exchange(  # noqa: SLF001
        {"voiceSessionId": "voice-rt-1", "sdp": "v=0\r\noffer"}
    )

    assert captured["url"] == CODEX_REALTIME_CALLS_URL
    assert "OpenAI-Alpha" not in captured["headers"]


def test_live_session_create_requires_codex_credentials(monkeypatch, tmp_path):
    connector, store = make_connector(tmp_path, "connector-live-create-no-creds")
    store.save_secrets(ConnectorSecrets(openai_api_key="sk-test"))
    monkeypatch.setattr(
        connector, "refresh_voice_context_if_stale", lambda *, state=None: state or store.load()
    )

    with pytest.raises(RuntimeError, match="Codex Live is not available"):
        connector._rpc_talk_session_create(  # noqa: SLF001
            {
                "voiceSessionId": "voice-live-2",
                "relayMcpURL": "https://relay.example.com/v1/talk/mcp?token=test",
                "provider": "codex_live",
            }
        )
