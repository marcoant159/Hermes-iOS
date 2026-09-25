from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.schemas import (
    LEGACY_MODEL_OVERRIDES,
    SUPPORTED_MODEL_OVERRIDES,
    MessageCreateRequest,
)
from test_api import build_client, register_device


ALL_ACCEPTED_OVERRIDES = sorted(SUPPORTED_MODEL_OVERRIDES | set(LEGACY_MODEL_OVERRIDES))


def test_schema_accepts_supported_overrides():
    for override in SUPPORTED_MODEL_OVERRIDES:
        request = MessageCreateRequest(text="hello", modelOverride=override)
        assert request.modelOverride == override


def test_schema_normalizes_legacy_gemini_override():
    request = MessageCreateRequest(text="hello", modelOverride="gemini-3.8-flash")
    assert request.modelOverride == "gemini/gemini-3.8-flash"


def test_schema_defaults_to_no_override():
    request = MessageCreateRequest(text="hello")
    assert request.modelOverride is None


@pytest.mark.parametrize(
    "override",
    ["hermes-agent", "gemini-3.8", "openai-codex/gpt-4", "gpt-6-luna", ""],
)
def test_schema_rejects_unsupported_overrides(override):
    with pytest.raises(ValidationError):
        MessageCreateRequest(text="hello", modelOverride=override)


def test_message_endpoint_accepts_supported_overrides_and_legacy(tmp_path):
    with build_client(tmp_path, hermes_adapter="mock") as client:
        access_token = register_device(client)["auth"]["accessToken"]
        headers = {"Authorization": f"Bearer {access_token}"}

        for override in ALL_ACCEPTED_OVERRIDES:
            response = client.post(
                "/v1/messages",
                headers=headers,
                json={"text": "hello", "modelOverride": override},
            )
            assert response.status_code == 200, (override, response.text)


def test_message_endpoint_rejects_unsupported_override(tmp_path):
    with build_client(tmp_path, hermes_adapter="mock") as client:
        access_token = register_device(client)["auth"]["accessToken"]

        response = client.post(
            "/v1/messages",
            headers={"Authorization": f"Bearer {access_token}"},
            json={"text": "hello", "modelOverride": "bogus/model"},
        )

        assert response.status_code == 422
