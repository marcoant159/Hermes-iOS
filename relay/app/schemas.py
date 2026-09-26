from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from pydantic import BaseModel, Field, conlist, field_validator, model_validator


# Model overrides the mobile app may request (format "provider/model").
# Single source of truth for relay-side validation.
SUPPORTED_MODEL_OVERRIDES = frozenset({
    "openai-codex/gpt-6-luna",
    "openai-codex/gpt-6-astra",
    "gemini/gemini-3.8-flash",
    "opencode-go/deepseek-v4.1-flash",
})

# Older app builds sent the bare Gemini model name; map it to the canonical
# provider/model form so existing installs keep working.
LEGACY_MODEL_OVERRIDES = {
    "gemini-3.8-flash": "gemini/gemini-3.8-flash",
}


class Meta(BaseModel):
    requestId: str
    timestamp: datetime


class ErrorPayload(BaseModel):
    code: str
    message: str
    retryable: bool = False


class ErrorEnvelope(BaseModel):
    error: ErrorPayload


class SuccessEnvelope(BaseModel):
    data: dict[str, Any]
    meta: Meta


class DeviceInfo(BaseModel):
    platform: str
    deviceName: str
    appVersion: str
    buildNumber: str
    bundleId: str
    installationId: UUID
    deviceModel: str
    systemVersion: str


class ClientInfo(BaseModel):
    environment: str


class DeviceRegisterRequest(BaseModel):
    device: DeviceInfo
    client: ClientInfo


class PairingRedeemRequest(BaseModel):
    inviteToken: str = Field(min_length=1)
    displayName: str = Field(min_length=1, max_length=120)
    device: DeviceInfo
    client: ClientInfo


class HostEnrollmentCodeCreateRequest(BaseModel):
    displayName: str | None = Field(default=None, max_length=120)


class HostConnectorInfo(BaseModel):
    platform: str
    hostname: str
    connectorVersion: str
    hermesCommand: str
    hermesVersion: str | None = None


class ConnectorSetupRequest(BaseModel):
    connector: HostConnectorInfo
    installationSecret: str | None = None


class HostRedeemRequest(BaseModel):
    enrollmentToken: str = Field(min_length=1)
    displayName: str | None = Field(default=None, max_length=120)
    connector: HostConnectorInfo


class PhonePairingRedeemRequest(BaseModel):
    code: str = Field(min_length=1, max_length=32)
    device: DeviceInfo
    client: ClientInfo


class RefreshRequest(BaseModel):
    refreshToken: str


class PushRegisterRequest(BaseModel):
    deviceId: UUID
    apnsToken: str
    pushEnvironment: str
    bundleId: str


class DeviceAppStateRequest(BaseModel):
    state: str = Field(pattern="^(foreground|background)$")


class AttachmentPayload(BaseModel):
    type: str = Field(min_length=1, max_length=16)    # "image" or "file"
    filename: str = Field(min_length=1, max_length=256)
    mimeType: str = Field(min_length=1, max_length=128)
    data: str = Field(min_length=1, max_length=7_000_000)  # base64-encoded
    thumbnailData: str | None = Field(default=None, max_length=250_000)


class MessageCreateRequest(BaseModel):
    conversationId: UUID | None = None
    text: str = Field(default="")
    clientMessageId: UUID | None = None
    attachments: list[AttachmentPayload] | None = Field(default=None, max_length=4)
    modelOverride: str | None = None

    @field_validator("modelOverride")
    @classmethod
    def _normalize_model_override(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = LEGACY_MODEL_OVERRIDES.get(value, value)
        if normalized not in SUPPORTED_MODEL_OVERRIDES:
            raise ValueError("Unsupported modelOverride.")
        return normalized

    @model_validator(mode="after")
    def _require_text_or_attachments(self) -> "MessageCreateRequest":
        has_text = bool(self.text and self.text.strip())
        has_attachments = bool(self.attachments)
        if not has_text and not has_attachments:
            raise ValueError("Either text or attachments must be provided.")
        return self


class InboxActionRequest(BaseModel):
    actionId: str


class SensorLocationRequest(BaseModel):
    latitude: float
    longitude: float
    altitude: float | None = None
    accuracy: float | None = None
    address: str | None = None
    recordedAt: str  # ISO8601


class SensorHealthSample(BaseModel):
    metric: str = Field(min_length=1, max_length=64)
    value: float
    unit: str = Field(min_length=1, max_length=32)
    startAt: str  # ISO8601
    endAt: str | None = None


class SensorHealthRequest(BaseModel):
    # `conlist` bounds the *input* item count. Using `list[...] = Field(max_length=100)`
    # with a nested model makes Pydantic 2.13 require exactly 100 items after
    # validation, which rejected every realistic app payload (e.g. 12 metrics).
    samples: conlist(SensorHealthSample, min_length=1, max_length=100)


class VoiceTurnCreateRequest(BaseModel):
    clientTurnId: UUID | None = None
    role: str = Field(min_length=1, max_length=32)
    source: str = Field(default="realtime", min_length=1, max_length=32)
    text: str = Field(min_length=1)


class TalkSessionCreateRequest(BaseModel):
    provider: str | None = Field(
        default=None,
        pattern="^(auto|codex_realtime|gemini_live|openai_realtime)$",
    )


class TalkSDPExchangeRequest(BaseModel):
    sdp: str = Field(min_length=1)


class TalkDelegationCreateRequest(BaseModel):
    prompt: str = Field(min_length=1)


class InternalInboxCreateRequest(BaseModel):
    userId: UUID | None = None
    deviceId: UUID | None = None
    kind: str
    title: str
    body: str
    priority: str = "normal"
    payload: dict[str, str] | None = None
    expiresAt: datetime | None = None
