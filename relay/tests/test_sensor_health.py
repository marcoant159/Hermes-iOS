"""Regression tests for `POST /v1/device/sensor/health` (the 422 bug).

The iOS app (`SensorUploadService.swift`) sends a batch of HealthKit samples:

    {"samples": [{"metric": ..., "value": ..., "unit": ...,
                  "startAt": "<ISO8601 with fractional seconds>",
                  "endAt": "<ISO8601 or null>"}, ...]}

Historically the relay used `list[SensorHealthSample] = Field(max_length=100)`,
which Pydantic 2.13 interprets as "exactly 100 items after validation" for
nested models, so every realistic batch (e.g. 12 metrics) was rejected with 422.

These tests pin down:
  - the app-shaped payload (12 metrics) is accepted;
  - any batch size in 1..100 is accepted;
  - empty list is rejected (nothing to deliver);
  - >100 items is rejected at the HTTP boundary;
  - a full round-trip forwards `sensor.health` to the connector and stores it.
"""

from __future__ import annotations

from threading import Thread

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.schemas import SensorHealthRequest


CONNECTOR_SETUP = {
    "ownerDisplayName": "Taylor",
    "hostDisplayName": "Home Mac mini",
    "connector": {
        "platform": "macos",
        "hostname": "test-host",
        "connectorVersion": "0.1.0",
        "hermesCommand": "/usr/local/bin/hermes",
        "hermesVersion": "hermes 1.2.3",
    },
}

HELLO_PAYLOAD = {
    "type": "hello",
    "connector": {
        "platform": "macos",
        "hostname": "test-host",
        "connectorVersion": "0.1.0",
        "hermesCommand": "/usr/local/bin/hermes",
        "hermesVersion": "hermes 1.2.3",
    },
}


def build_client(tmp_path, **overrides):
    base = dict(
        environment="test",
        public_base_url="https://relay.example.test/v1",
        database_url=f"sqlite:///{tmp_path / 'relay-health.db'}",
        internal_api_key="test-internal-key",
        pairing_code_ttl_seconds=900,
        phone_pairing_code_ttl_seconds=900,
        phone_pairing_max_attempts_per_code=3,
        phone_pairing_max_attempts_per_ip=3,
        phone_pairing_rate_limit_window_seconds=300,
        host_enrollment_code_ttl_seconds=900,
        hermes_adapter="connector",
        connector_sync_wait_seconds=2,
        connector_job_lease_seconds=30,
        connector_heartbeat_timeout_seconds=5,
        connector_idle_poll_interval_seconds=0.1,
        connector_sensor_ack_timeout_seconds=2,
    )
    base.update(overrides)
    app = create_app(Settings(**base))
    return TestClient(app)


def phone_pairing_payload(code, installation_id):
    return {
        "code": code,
        "device": {
            "platform": "ios",
            "deviceName": "Taylor's iPhone",
            "appVersion": "1.0.0",
            "buildNumber": "1",
            "bundleId": "io.hermesmobile.HermesMobile",
            "installationId": installation_id,
            "deviceModel": "iPhone17,2",
            "systemVersion": "26.2",
        },
        "client": {"environment": "production"},
    }


def setup_environment(client, installation_id="aaaa1111-bbbb-cccc-dddd-eeeeeeee0a01"):
    """Set up connector + phone pairing, return (connector_credential, access_token)."""
    connector_data = client.post("/v1/connector/setup", json=CONNECTOR_SETUP).json()["data"]
    pairing = client.post(
        "/v1/connector/phone-pairing-codes",
        headers={"Authorization": f"Bearer {connector_data['connectorCredential']}"},
    ).json()["data"]
    phone = client.post(
        "/v1/phone-pairing/redeem",
        json=phone_pairing_payload(pairing["displayCode"], installation_id),
    ).json()["data"]
    return connector_data["connectorCredential"], phone["auth"]["accessToken"]


# The exact set of metrics the app's LiveHealthService collects for a full
# refresh, with their real units and ISO8601-with-fraction timestamps.
APP_HEALTH_SAMPLES = [
    {"metric": "steps", "value": 4231.0, "unit": "count",
     "startAt": "2026-04-01T00:00:00.000Z", "endAt": "2026-04-01T12:34:56.789Z"},
    {"metric": "active_calories", "value": 312.5, "unit": "kcal",
     "startAt": "2026-04-01T00:00:00.000Z", "endAt": "2026-04-01T12:34:56.789Z"},
    {"metric": "distance_walking", "value": 3210.4, "unit": "meters",
     "startAt": "2026-04-01T00:00:00.000Z", "endAt": "2026-04-01T12:34:56.789Z"},
    {"metric": "heart_rate", "value": 72.0, "unit": "bpm",
     "startAt": "2026-04-01T12:30:00.000Z", "endAt": None},
    {"metric": "resting_heart_rate", "value": 58.0, "unit": "bpm",
     "startAt": "2026-04-01T06:00:00.000Z", "endAt": None},
    {"metric": "blood_oxygen", "value": 98.2, "unit": "%",
     "startAt": "2026-04-01T06:00:00.000Z", "endAt": None},
    {"metric": "respiratory_rate", "value": 15.0, "unit": "breaths/min",
     "startAt": "2026-04-01T06:00:00.000Z", "endAt": None},
    {"metric": "body_mass", "value": 74.3, "unit": "kg",
     "startAt": "2026-03-30T07:00:00.000Z", "endAt": None},
    {"metric": "workout_minutes", "value": 42.0, "unit": "minutes",
     "startAt": "2026-04-01T00:00:00.000Z", "endAt": "2026-04-01T12:34:56.789Z"},
    {"metric": "stand_hours", "value": 6.5, "unit": "hours",
     "startAt": "2026-04-01T00:00:00.000Z", "endAt": "2026-04-01T12:34:56.789Z"},
    {"metric": "sleep_duration", "value": 7.25, "unit": "hours",
     "startAt": "2026-04-01T00:00:00.000Z", "endAt": "2026-04-01T12:34:56.789Z"},
    {"metric": "user_activity", "value": 1.0, "unit": "activity_code",
     "startAt": "2026-04-01T12:34:56.789Z", "endAt": None},
]


# --------------------------------------------------------------------------
# Schema-level regression (no HTTP): the nested `max_length` trap.
# --------------------------------------------------------------------------

def test_schema_accepts_app_shaped_payload():
    parsed = SensorHealthRequest.model_validate({"samples": APP_HEALTH_SAMPLES})
    assert len(parsed.samples) == 12
    assert parsed.samples[0].metric == "steps"
    assert parsed.samples[3].endAt is None


def test_schema_accepts_any_batch_size_up_to_100():
    sample = {"metric": "steps", "value": 1.0, "unit": "count",
              "startAt": "2026-04-01T00:00:00.000Z"}
    for count in (1, 2, 12, 57, 99, 100):
        parsed = SensorHealthRequest.model_validate({"samples": [sample] * count})
        assert len(parsed.samples) == count


def test_schema_rejects_empty_and_oversized_batches():
    sample = {"metric": "steps", "value": 1.0, "unit": "count",
              "startAt": "2026-04-01T00:00:00.000Z"}
    for count in (0, 101):
        try:
            SensorHealthRequest.model_validate({"samples": [sample] * count})
        except Exception:
            continue
        raise AssertionError(f"batch of {count} samples should be rejected")


# --------------------------------------------------------------------------
# HTTP boundary
# --------------------------------------------------------------------------

def test_health_endpoint_accepts_app_payload_without_connector(tmp_path):
    """No connector online → 202 retry, but never 422 for a valid app payload."""
    with build_client(tmp_path) as client:
        _, access_token = setup_environment(client)
        response = client.post(
            "/v1/device/sensor/health",
            headers={"Authorization": f"Bearer {access_token}"},
            json={"samples": APP_HEALTH_SAMPLES},
        )
        assert response.status_code == 202
        assert response.json()["data"]["deliveryState"] == "retry"


def test_health_endpoint_rejects_oversized_batch(tmp_path):
    with build_client(tmp_path) as client:
        _, access_token = setup_environment(client)
        sample = {"metric": "steps", "value": 1.0, "unit": "count",
                  "startAt": "2026-04-01T00:00:00.000Z"}
        response = client.post(
            "/v1/device/sensor/health",
            headers={"Authorization": f"Bearer {access_token}"},
            json={"samples": [sample] * 101},
        )
        assert response.status_code == 422


# --------------------------------------------------------------------------
# Full round-trip through the connector websocket
# --------------------------------------------------------------------------

def test_health_endpoint_forwards_to_connector_and_acks(tmp_path):
    with build_client(tmp_path) as client:
        credential, access_token = setup_environment(client)

        with client.websocket_connect(
            "/v1/hosts/ws",
            headers={"Authorization": f"Bearer {credential}"},
        ) as websocket:
            websocket.send_json(HELLO_PAYLOAD)
            assert websocket.receive_json()["type"] == "ready"

            holder: dict = {}

            def send_health():
                holder["r"] = client.post(
                    "/v1/device/sensor/health",
                    headers={"Authorization": f"Bearer {access_token}"},
                    json={"samples": APP_HEALTH_SAMPLES},
                )

            thread = Thread(target=send_health)
            thread.start()

            forwarded = websocket.receive_json()
            assert forwarded["type"] == "sensor.health"
            assert len(forwarded["samples"]) == 12
            assert forwarded["samples"][0]["metric"] == "steps"
            assert forwarded["samples"][3]["endAt"] is None

            websocket.send_json(
                {
                    "type": "sensor.ack",
                    "deliveryId": forwarded["deliveryId"],
                    "deliveryState": "delivered",
                }
            )
            thread.join(timeout=5)

        assert holder["r"].status_code == 200
        assert holder["r"].json()["data"]["deliveryState"] == "delivered"
