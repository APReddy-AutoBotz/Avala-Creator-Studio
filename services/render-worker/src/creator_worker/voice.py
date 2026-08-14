from __future__ import annotations

from dataclasses import dataclass
import hashlib
import io
import json
import math
import struct
from typing import Literal, Protocol
import wave

ProviderApprovalState = Literal["research_only", "approved_for_test", "approved_for_runtime", "disabled"]
ProfileStatus = Literal["draft", "active", "revoked", "deleting", "deleted"]

SYNTHETIC_VOICE_LABEL = "[SYNTHETIC MOCK VOICE DRAFT]"


class VoiceExecutionBlocked(RuntimeError):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class VoiceExecutionContext:
    provider_id: str
    provider_approval_state: ProviderApprovalState
    execution_enabled: bool
    profile_status: ProfileStatus
    validated_sample_count: int
    human_triggered: bool
    max_cost_microunits: int
    estimated_cost_microunits: int
    generation_mode: Literal["synthetic_mock", "real_provider"]


@dataclass(frozen=True)
class MockVoiceRequest:
    job_id: str
    script_artifact_id: str
    script_sha256: str
    profile_id: str
    segment_ids: tuple[str, ...]


@dataclass(frozen=True)
class MockVoiceDraft:
    label: str
    provider_id: str
    generation_mode: str
    job_id: str
    descriptor_sha256: str
    media_created: bool


@dataclass(frozen=True)
class SyntheticWavFixture:
    label: str
    mime_type: str
    duration_ms: int
    byte_length: int
    sha256: str
    audio_bytes: bytes


class VoiceProviderAdapter(Protocol):
    provider_id: str

    def create_draft(self, *, request: MockVoiceRequest, context: VoiceExecutionContext) -> MockVoiceDraft: ...


def validate_voice_execution(context: VoiceExecutionContext) -> None:
    if not context.human_triggered:
        raise VoiceExecutionBlocked("HUMAN_TRIGGER_REQUIRED")
    if context.profile_status != "active":
        raise VoiceExecutionBlocked("ACTIVE_VOICE_PROFILE_REQUIRED")
    if context.validated_sample_count < 1:
        raise VoiceExecutionBlocked("VALIDATED_SAMPLE_REQUIRED")
    if context.max_cost_microunits < 0 or context.estimated_cost_microunits < 0:
        raise VoiceExecutionBlocked("VOICE_BUDGET_INVALID")
    if context.estimated_cost_microunits > context.max_cost_microunits:
        raise VoiceExecutionBlocked("VOICE_BUDGET_EXCEEDED")
    if not context.execution_enabled:
        raise VoiceExecutionBlocked("PROVIDER_EXECUTION_DISABLED")
    if context.provider_id != "mock" or context.generation_mode != "synthetic_mock":
        raise VoiceExecutionBlocked("REAL_PROVIDER_EXECUTION_BLOCKED_PHASE_A")
    if context.provider_approval_state != "approved_for_test":
        raise VoiceExecutionBlocked("MOCK_PROVIDER_NOT_APPROVED_FOR_TEST")
    if context.max_cost_microunits != 0 or context.estimated_cost_microunits != 0:
        raise VoiceExecutionBlocked("MOCK_PROVIDER_MUST_BE_ZERO_COST")


class DeterministicMockVoiceAdapter:
    provider_id = "mock"

    def create_draft(self, *, request: MockVoiceRequest, context: VoiceExecutionContext) -> MockVoiceDraft:
        validate_voice_execution(context)
        if len(request.script_sha256) != 64 or any(char not in "0123456789abcdef" for char in request.script_sha256):
            raise VoiceExecutionBlocked("SCRIPT_DIGEST_INVALID")
        if not request.segment_ids or len(set(request.segment_ids)) != len(request.segment_ids):
            raise VoiceExecutionBlocked("VOICE_SEGMENTS_INVALID")

        material = json.dumps(
            {
                "label": SYNTHETIC_VOICE_LABEL,
                "job_id": request.job_id,
                "script_artifact_id": request.script_artifact_id,
                "script_sha256": request.script_sha256,
                "profile_id": request.profile_id,
                "segment_ids": list(request.segment_ids),
                "provider_id": self.provider_id,
                "generation_mode": "synthetic_mock",
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        digest = hashlib.sha256(material.encode("utf-8")).hexdigest()
        return MockVoiceDraft(
            label=SYNTHETIC_VOICE_LABEL,
            provider_id=self.provider_id,
            generation_mode="synthetic_mock",
            job_id=request.job_id,
            descriptor_sha256=digest,
            media_created=False,
        )


def create_synthetic_wav_fixture(*, job_id: str, duration_ms: int = 800) -> SyntheticWavFixture:
    """Create deterministic non-speech WAV bytes for governed review-path testing."""
    if not job_id or len(job_id) > 128:
        raise VoiceExecutionBlocked("VOICE_JOB_ID_INVALID")
    if duration_ms < 100 or duration_ms > 5_000:
        raise VoiceExecutionBlocked("VOICE_FIXTURE_DURATION_INVALID")

    sample_rate = 16_000
    frame_count = sample_rate * duration_ms // 1_000
    seed = hashlib.sha256(job_id.encode("utf-8")).digest()
    frequency = 240 + int.from_bytes(seed[:2], "big") % 240
    amplitude = 3_200

    pcm = bytearray()
    for frame in range(frame_count):
        value = int(amplitude * math.sin(2 * math.pi * frequency * frame / sample_rate))
        pcm.extend(struct.pack("<h", value))

    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(bytes(pcm))

    audio = buffer.getvalue()
    return SyntheticWavFixture(
        label=SYNTHETIC_VOICE_LABEL,
        mime_type="audio/wav",
        duration_ms=duration_ms,
        byte_length=len(audio),
        sha256=hashlib.sha256(audio).hexdigest(),
        audio_bytes=audio,
    )
