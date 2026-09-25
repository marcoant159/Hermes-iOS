from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _isolate_talk_credentials(monkeypatch, tmp_path):
    """Keep tests hermetic and away from real credentials.

    * Codex OAuth credentials are never loaded from the developer's machine.
      Tests that need them patch ``client.load_codex_credentials`` explicitly
      or call ``talk_support.load_codex_credentials`` with fixture paths.
    * Google API keys are cleared and ``HERMES_HOME`` points at an empty
      fixture directory, so a real ``~/.hermes/.env`` is never read. Tests may
      override ``HERMES_HOME`` (and re-add keys) from the test body.
    """

    def _raise(**kwargs):  # noqa: ANN003, ANN202
        raise RuntimeError("No Codex OAuth credentials in tests (fixture).")

    monkeypatch.setattr("hermes_mobile_connector.client.load_codex_credentials", _raise)
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes-home-fixture"))


@pytest.fixture
def codex_credentials():
    from hermes_mobile_connector.talk_support import CodexCredentials

    return CodexCredentials(access_token="codex-access-token-fixture", account_id="acct-fixture")