from __future__ import annotations

import asyncio
import base64
import json
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
    CODEX_REALTIME_CALLS_URL,
    CODEX_REALTIME_MODEL,
    CODEX_REALTIME_VOICE,
    load_codex_credentials,
)


def make_jwt(payload: dict) -> str:
    def segment(value: dict) -> str:
        raw = json.dumps(value, separators=(",", ":")).encode("utf-8")
        return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

    return f"{segment({'alg': 'none', 'typ': 'JWT'})}.{segment(payload)}.fixture-signature"


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


def test_load_codex_credentials_reads_hermes_auth_jwt(tmp_path):
    hermes_home = tmp_path / ".hermes"
    hermes_home.mkdir()
    token = make_jwt(
        {
            "exp": 4_102_444_800,
            "https://api.openai.com/auth": {"chatgpt_account_id": "acct-from-jwt"},
        }
    )
    (hermes_home / "auth.json").write_text(
        json.dumps({"credential_pool": {"openai-codex": [{"access_token": token}]}}),
        encoding="utf-8",
    )

    credentials = load_codex_credentials(hermes_home=hermes_home, codex_home=tmp_path / "codex")

    assert credentials.access_token == token
    assert credentials.account_id == "acct-from-jwt"


def test_load_codex_credentials_falls_back_to_codex_auth_when_expired(tmp_path):
    hermes_home = tmp_path / ".hermes"
    hermes_home.mkdir()
    expired = make_jwt(
        {
            "exp": 1,
            "https://api.openai.com/auth": {"chatgpt_account_id": "acct-old"},
        }
    )
    (hermes_home / "auth.json").write_text(
        json.dumps({"credential_pool": {"openai-codex": [{"access_token": expired}]}}),
        encoding="utf-8",
    )
    codex_home = tmp_path / ".codex"
    codex_home.mkdir()
    fresh = make_jwt({"exp": 4_102_444_800})
    (codex_home / "auth.json").write_text(
        json.dumps({"tokens": {"access_token": fresh, "account_id": "acct-codex"}}),
        encoding="utf-8",
    )

    credentials = load_codex_credentials(hermes_home=hermes_home, codex_home=codex_home)

    assert credentials.access_token == fresh
    assert credentials.account_id == "acct-codex"


def test_load_codex_credentials_raises_when_nothing_is_valid(tmp_path):
    hermes_home = tmp_path / ".hermes"
    hermes_home.mkdir()

    with pytest.raises(RuntimeError, match="Codex OAuth credentials"):
        load_codex_credentials(hermes_home=hermes_home, codex_home=tmp_path / "codex")


def test_talk_readiness_prefers_codex_live_over_gemini(monkeypatch, tmp_path, codex_credentials):
    connector, _ = make_connector(tmp_path, "connector-readiness")
    monkeypatch.setenv("GOOGLE_API_KEY", "google-key-fixture")
    monkeypatch.setattr(
        "hermes_mobile_connector.client.load_codex_credentials",
        lambda **kwargs: codex_credentials,
    )

    payload = connector.talk_readiness_payload()

    assert payload["provider"] == "codex_live"
    assert payload["configured"] is True
    assert payload["selectedModel"] == "gpt-live-1-codex"
    assert payload["voice"] == "cove"
    assert payload["blockedReason"] is None


def test_talk_session_create_codex_realtime_stores_definition(
    monkeypatch, tmp_path, codex_credentials
):
    connector, store = make_connector(tmp_path, "connector-codex-session")
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
            "voiceSessionId": "voice-1",
            "relayMcpURL": "https://relay.example.com/v1/talk/mcp?token=test",
            "provider": "codex_realtime",
        }
    )

    assert payload["provider"] == "codex_realtime"
    assert payload["model"] == CODEX_REALTIME_MODEL
    assert payload["voice"] == CODEX_REALTIME_VOICE
    assert payload["clientSecret"] is None
    assert payload["session"] == {}

    definition = connector._codex_realtime_sessions["voice-1"]["session"]  # noqa: SLF001
    assert definition["type"] == "realtime"
    assert definition["model"] == CODEX_REALTIME_MODEL
    assert definition["audio"]["output"]["voice"] == CODEX_REALTIME_VOICE
    assert definition["audio"]["input"]["transcription"]["language"] == "pt"
    assert definition["tools"][0]["server_url"] == (
        "https://relay.example.com/v1/talk/mcp?token=test"
    )


def test_talk_session_create_respects_forced_openai_provider(monkeypatch, tmp_path, codex_credentials):
    connector, store = make_connector(tmp_path, "connector-force-openai")
    store.save_secrets(ConnectorSecrets(openai_api_key="sk-test-realtime"))
    monkeypatch.setattr(
        "hermes_mobile_connector.client.load_codex_credentials",
        lambda **kwargs: codex_credentials,
    )
    monkeypatch.setattr(
        connector, "refresh_voice_context_if_stale", lambda *, state=None: state or store.load()
    )
    monkeypatch.setattr(
        connector,
        "_create_openai_realtime_session",
        lambda **kwargs: (
            {"value": "ephemeral-secret", "expires_at": 1_775_001_600, "session": {"id": "sess_1"}},
            "gpt-realtime-1.5",
        ),
    )

    payload = connector._rpc_talk_session_create(  # noqa: SLF001
        {
            "voiceSessionId": "voice-2",
            "relayMcpURL": "https://relay.example.com/v1/talk/mcp?token=test",
            "provider": "openai_realtime",
        }
    )

    assert payload["provider"] == "openai_realtime"
    assert payload["clientSecret"] == "ephemeral-secret"


def test_talk_session_create_rejects_unavailable_requested_provider(monkeypatch, tmp_path):
    connector, store = make_connector(tmp_path, "connector-force-gemini")
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "empty-hermes"))
    monkeypatch.setattr(
        connector, "refresh_voice_context_if_stale", lambda *, state=None: state or store.load()
    )

    with pytest.raises(RuntimeError, match="Gemini Live is not configured"):
        connector._rpc_talk_session_create(  # noqa: SLF001
            {
                "voiceSessionId": "voice-3",
                "relayMcpURL": "https://relay.example.com/v1/talk/mcp?token=test",
                "provider": "gemini_live",
            }
        )


def test_talk_sdp_exchange_posts_codex_call_and_returns_answer(
    monkeypatch, tmp_path, codex_credentials
):
    connector, _ = make_connector(tmp_path, "connector-codex-exchange")
    definition = {"type": "realtime", "model": CODEX_REALTIME_MODEL, "instructions": "hi"}
    connector._codex_realtime_sessions["voice-1"] = {  # noqa: SLF001
        "session": definition,
        "created_at": time.monotonic(),
    }
    captured: dict = {}

    def fake_post(url, headers=None, json=None, timeout=None):  # noqa: ANN001
        captured["url"] = url
        captured["headers"] = headers
        captured["json"] = json
        captured["timeout"] = timeout
        return FakeResponse(201, "v=0\r\nsdp-answer", {"Location": "/v1/realtime/calls/call_abc"})

    monkeypatch.setattr("hermes_mobile_connector.client.httpx.post", fake_post)
    monkeypatch.setattr(
        "hermes_mobile_connector.client.load_codex_credentials",
        lambda **kwargs: codex_credentials,
    )

    result = connector._rpc_talk_sdp_exchange(  # noqa: SLF001
        {"voiceSessionId": "voice-1", "sdp": "v=0\r\nsdp-offer"}
    )

    assert captured["url"] == CODEX_REALTIME_CALLS_URL
    assert captured["headers"]["Authorization"] == "Bearer codex-access-token-fixture"
    assert captured["headers"]["ChatGPT-Account-Id"] == "acct-fixture"
    assert captured["headers"]["originator"] == "codex_cli_rs"
    assert captured["headers"]["User-Agent"] == "codex_cli_rs/0.156.1"
    assert captured["headers"]["Content-Type"] == "application/json"
    assert captured["json"] == {"sdp": "v=0\r\nsdp-offer", "session": definition}
    assert captured["timeout"] == 20.0
    assert result == {"sdp": "v=0\r\nsdp-answer", "callId": "call_abc"}


def test_talk_sdp_exchange_reports_status_and_body_without_token(
    monkeypatch, tmp_path, codex_credentials
):
    connector, _ = make_connector(tmp_path, "connector-codex-exchange-error")
    connector._codex_realtime_sessions["voice-1"] = {  # noqa: SLF001
        "session": {"type": "realtime", "model": CODEX_REALTIME_MODEL},
        "created_at": time.monotonic(),
    }
    monkeypatch.setattr(
        "hermes_mobile_connector.client.httpx.post",
        lambda *args, **kwargs: FakeResponse(400, '{"error":"invalid_model"}'),
    )
    monkeypatch.setattr(
        "hermes_mobile_connector.client.load_codex_credentials",
        lambda **kwargs: codex_credentials,
    )

    with pytest.raises(RuntimeError) as info:
        connector._rpc_talk_sdp_exchange(  # noqa: SLF001
            {"voiceSessionId": "voice-1", "sdp": "v=0\r\nsdp-offer"}
        )

    message = str(info.value)
    assert "400" in message
    assert "invalid_model" in message
    assert codex_credentials.access_token not in message


def test_talk_sdp_exchange_rejects_missing_or_expired_session(monkeypatch, tmp_path, codex_credentials):
    connector, _ = make_connector(tmp_path, "connector-codex-exchange-missing")
    monkeypatch.setattr(
        "hermes_mobile_connector.client.load_codex_credentials",
        lambda **kwargs: codex_credentials,
    )

    with pytest.raises(RuntimeError, match="not found or expired"):
        connector._rpc_talk_sdp_exchange(  # noqa: SLF001
            {"voiceSessionId": "voice-missing", "sdp": "v=0"}
        )

    connector._codex_realtime_sessions["voice-old"] = {  # noqa: SLF001
        "session": {"type": "realtime"},
        "created_at": time.monotonic() - 601.0,
    }
    with pytest.raises(RuntimeError, match="not found or expired"):
        connector._rpc_talk_sdp_exchange(  # noqa: SLF001
            {"voiceSessionId": "voice-old", "sdp": "v=0"}
        )


def test_handle_rpc_request_dispatches_talk_sdp_exchange(monkeypatch, tmp_path, codex_credentials):
    connector, _ = make_connector(tmp_path, "connector-codex-dispatch")
    connector._codex_realtime_sessions["voice-1"] = {  # noqa: SLF001
        "session": {"type": "realtime", "model": CODEX_REALTIME_MODEL},
        "created_at": time.monotonic(),
    }
    monkeypatch.setattr(
        "hermes_mobile_connector.client.httpx.post",
        lambda *args, **kwargs: FakeResponse(201, "v=0\r\nanswer", {"Location": "/v1/realtime/calls/c1"}),
    )
    monkeypatch.setattr(
        "hermes_mobile_connector.client.load_codex_credentials",
        lambda **kwargs: codex_credentials,
    )

    response = asyncio.run(
        connector._handle_rpc_request(  # noqa: SLF001
            {
                "requestId": "req-1",
                "method": "talk.sdp.exchange",
                "params": {"voiceSessionId": "voice-1", "sdp": "v=0\r\noffer"},
            }
        )
    )

    assert response["success"] is True
    assert response["result"] == {"sdp": "v=0\r\nanswer", "callId": "c1"}


def test_talk_session_end_clears_stored_codex_definition(monkeypatch, tmp_path, codex_credentials):
    connector, store = make_connector(tmp_path, "connector-codex-end")
    monkeypatch.setattr(
        "hermes_mobile_connector.client.load_codex_credentials",
        lambda **kwargs: codex_credentials,
    )
    monkeypatch.setattr(
        connector, "refresh_voice_context_if_stale", lambda *, state=None: state or store.load()
    )
    connector._rpc_talk_session_create(  # noqa: SLF001
        {
            "voiceSessionId": "voice-1",
            "relayMcpURL": "https://relay.example.com/v1/talk/mcp?token=test",
        }
    )
    assert "voice-1" in connector._codex_realtime_sessions  # noqa: SLF001

    connector._rpc_talk_session_end({"voiceSessionId": "voice-1"})  # noqa: SLF001

    assert "voice-1" not in connector._codex_realtime_sessions  # noqa: SLF001