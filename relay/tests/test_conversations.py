from __future__ import annotations

from test_api import build_client, register_device


def _create_message(client, access_token, text):
    response = client.post(
        "/v1/messages",
        headers={"Authorization": f"Bearer {access_token}"},
        json={"text": text},
    )
    assert response.status_code == 200, response.text
    return response.json()["data"]


def _list_conversations(client, access_token, limit=None):
    url = "/v1/conversations"
    if limit is not None:
        url = f"{url}?limit={limit}"
    response = client.get(url, headers={"Authorization": f"Bearer {access_token}"})
    assert response.status_code == 200, response.text
    return response.json()["data"]["conversations"]


def test_list_conversations_requires_auth(tmp_path):
    with build_client(tmp_path) as client:
        response = client.get("/v1/conversations")
        assert response.status_code == 401


def test_list_conversations_caps_limit(tmp_path):
    with build_client(tmp_path, hermes_adapter="mock") as client:
        access_token = register_device(client)["auth"]["accessToken"]
        for _ in range(3):
            client.post(
                "/v1/conversations",
                headers={"Authorization": f"Bearer {access_token}"},
            )

        conversations = _list_conversations(client, access_token)
        assert len(conversations) == 3
        assert len(_list_conversations(client, access_token, limit=2)) == 2
        assert len(_list_conversations(client, access_token, limit=500)) == 3


def test_create_conversation_starts_empty_and_becomes_current(tmp_path):
    with build_client(tmp_path, hermes_adapter="mock") as client:
        access_token = register_device(client)["auth"]["accessToken"]
        _create_message(client, access_token, "Hello Hermes")

        created = client.post(
            "/v1/conversations",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        assert created.status_code == 200, created.text
        new_conversation = created.json()["data"]["conversation"]
        assert new_conversation["messages"] == []
        assert new_conversation["title"] == "Nova conversa"

        current = client.get(
            "/v1/conversations/current",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        assert current.json()["data"]["conversation"]["id"] == new_conversation["id"]


def test_create_conversation_starts_new_hermes_session(tmp_path):
    with build_client(tmp_path, hermes_adapter="mock") as client:
        access_token = register_device(client)["auth"]["accessToken"]
        _create_message(client, access_token, "First session message")

        client.post(
            "/v1/conversations",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        response = _create_message(client, access_token, "Second session message")
        # Session id snapshots are stored per job; a fresh conversation must not
        # reuse the previous conversation's session.
        current = client.get(
            "/v1/conversations/current",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        messages = current.json()["data"]["conversation"]["messages"]
        assert [message["text"] for message in messages if message["role"] == "user"] == [
            "Second session message"
        ]
        assert response["conversation"]["id"] == current.json()["data"]["conversation"]["id"]


def test_conversation_title_derived_from_first_user_message(tmp_path):
    with build_client(tmp_path, hermes_adapter="mock") as client:
        access_token = register_device(client)["auth"]["accessToken"]
        _create_message(client, access_token, "  Summarize   my notes about databases  ")

        conversations = _list_conversations(client, access_token)
        assert conversations[0]["title"] == "Summarize my notes about databases"


def test_conversation_title_is_truncated(tmp_path):
    with build_client(tmp_path, hermes_adapter="mock") as client:
        access_token = register_device(client)["auth"]["accessToken"]
        long_text = "x" * 120
        _create_message(client, access_token, long_text)

        conversations = _list_conversations(client, access_token)
        assert len(conversations[0]["title"]) == 60


def test_list_conversations_reports_message_count(tmp_path):
    with build_client(tmp_path, hermes_adapter="mock") as client:
        access_token = register_device(client)["auth"]["accessToken"]
        _create_message(client, access_token, "Hello Hermes")

        conversations = _list_conversations(client, access_token)
        assert len(conversations) == 1
        assert conversations[0]["messageCount"] == 2
        assert conversations[0]["isCurrent"] is True


def test_select_conversation_switches_current_and_reloads_history(tmp_path):
    with build_client(tmp_path, hermes_adapter="mock") as client:
        access_token = register_device(client)["auth"]["accessToken"]
        first = _create_message(client, access_token, "First conversation message")["conversation"]["id"]

        client.post(
            "/v1/conversations",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        _create_message(client, access_token, "Second conversation message")

        selected = client.post(
            f"/v1/conversations/{first}/select",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        assert selected.status_code == 200, selected.text
        conversation = selected.json()["data"]["conversation"]
        assert conversation["id"] == first
        assert any(message["text"] == "First conversation message" for message in conversation["messages"])

        current = client.get(
            "/v1/conversations/current",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        assert current.json()["data"]["conversation"]["id"] == first


def test_select_conversation_is_user_scoped(tmp_path):
    # A second relay (own DB/user) must not see conversations from the first.
    owner_dir = tmp_path / "owner"
    other_dir = tmp_path / "other"
    owner_dir.mkdir()
    other_dir.mkdir()

    with build_client(owner_dir, hermes_adapter="mock") as owner_client:
        owner_token = register_device(owner_client)["auth"]["accessToken"]
        created = owner_client.post(
            "/v1/conversations",
            headers={"Authorization": f"Bearer {owner_token}"},
        )
        conversation_id = created.json()["data"]["conversation"]["id"]

        with build_client(other_dir, hermes_adapter="mock") as other_client:
            other_token = register_device(other_client)["auth"]["accessToken"]
            response = other_client.post(
                f"/v1/conversations/{conversation_id}/select",
                headers={"Authorization": f"Bearer {other_token}"},
            )
            assert response.status_code == 404


def test_select_unknown_conversation_returns_404(tmp_path):
    with build_client(tmp_path, hermes_adapter="mock") as client:
        access_token = register_device(client)["auth"]["accessToken"]
        response = client.post(
            "/v1/conversations/does-not-exist/select",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        assert response.status_code == 404


def test_clear_still_archives_current_conversation(tmp_path):
    with build_client(tmp_path, hermes_adapter="mock") as client:
        access_token = register_device(client)["auth"]["accessToken"]
        _create_message(client, access_token, "Hello Hermes")

        cleared = client.post(
            "/v1/conversations/current/clear",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        assert cleared.status_code == 200
        assert cleared.json()["data"]["conversation"]["messages"] == []

        conversations = _list_conversations(client, access_token)
        # The archived conversation and the freshly created one are both listed.
        assert len(conversations) == 2
        assert [c["isCurrent"] for c in conversations].count(True) == 1
