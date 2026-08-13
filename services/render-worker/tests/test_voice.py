import hashlib
import io
import wave

import pytest

from creator_worker.voice import (
    DeterministicMockVoiceAdapter,
    MockVoiceRequest,
    VoiceExecutionBlocked,
    VoiceExecutionContext,
    create_synthetic_wav_fixture,
)


def context(**overrides: object) -> VoiceExecutionContext:
    values: dict[str, object] = {
        "provider_id": "mock",
        "provider_approval_state": "approved_for_test",
        "execution_enabled": True,
        "profile_status": "active",
        "validated_sample_count": 1,
        "human_triggered": True,
        "max_cost_microunits": 0,
        "estimated_cost_microunits": 0,
        "generation_mode": "synthetic_mock",
    }
    values.update(overrides)
    return VoiceExecutionContext(**values)  # type: ignore[arg-type]


def request() -> MockVoiceRequest:
    return MockVoiceRequest(
        job_id="job-1",
        script_artifact_id="script-1",
        script_sha256="a" * 64,
        profile_id="profile-1",
        segment_ids=("segment-1", "segment-2"),
    )


def test_mock_voice_descriptor_is_deterministic_and_has_no_media() -> None:
    adapter = DeterministicMockVoiceAdapter()
    first = adapter.create_draft(request=request(), context=context())
    second = adapter.create_draft(request=request(), context=context())
    assert first == second
    assert first.label == "[SYNTHETIC MOCK VOICE DRAFT]"
    assert first.generation_mode == "synthetic_mock"
    assert first.media_created is False


@pytest.mark.parametrize("status", ["draft", "revoked", "deleting", "deleted"])
def test_non_active_profiles_fail_closed(status: str) -> None:
    with pytest.raises(VoiceExecutionBlocked, match="ACTIVE_VOICE_PROFILE_REQUIRED"):
        DeterministicMockVoiceAdapter().create_draft(request=request(), context=context(profile_status=status))


def test_unvalidated_sample_and_missing_human_trigger_fail_closed() -> None:
    with pytest.raises(VoiceExecutionBlocked, match="VALIDATED_SAMPLE_REQUIRED"):
        DeterministicMockVoiceAdapter().create_draft(request=request(), context=context(validated_sample_count=0))
    with pytest.raises(VoiceExecutionBlocked, match="HUMAN_TRIGGER_REQUIRED"):
        DeterministicMockVoiceAdapter().create_draft(request=request(), context=context(human_triggered=False))


def test_real_provider_is_never_executable_in_phase_a() -> None:
    with pytest.raises(VoiceExecutionBlocked, match="REAL_PROVIDER_EXECUTION_BLOCKED_PHASE_A"):
        DeterministicMockVoiceAdapter().create_draft(
            request=request(),
            context=context(
                provider_id="chatterbox_multilingual_v3",
                provider_approval_state="approved_for_runtime",
                generation_mode="real_provider",
            ),
        )


def test_budget_missing_or_exceeded_blocks_execution() -> None:
    with pytest.raises(VoiceExecutionBlocked, match="VOICE_BUDGET_EXCEEDED"):
        DeterministicMockVoiceAdapter().create_draft(
            request=request(), context=context(max_cost_microunits=0, estimated_cost_microunits=1)
        )
    with pytest.raises(VoiceExecutionBlocked, match="PROVIDER_EXECUTION_DISABLED"):
        DeterministicMockVoiceAdapter().create_draft(request=request(), context=context(execution_enabled=False))


def test_synthetic_wav_fixture_is_deterministic_valid_and_non_speech() -> None:
    first = create_synthetic_wav_fixture(job_id="11111111-1111-4111-8111-111111111111")
    second = create_synthetic_wav_fixture(job_id="11111111-1111-4111-8111-111111111111")
    other = create_synthetic_wav_fixture(job_id="22222222-2222-4222-8222-222222222222")
    assert first == second
    assert first.sha256 != other.sha256
    assert first.label == "[SYNTHETIC MOCK VOICE DRAFT]"
    assert first.mime_type == "audio/wav"
    assert first.sha256 == hashlib.sha256(first.audio_bytes).hexdigest()
    assert first.byte_length == len(first.audio_bytes)
    assert first.byte_length < 25_000_000

    with wave.open(io.BytesIO(first.audio_bytes), "rb") as wav:
        assert wav.getnchannels() == 1
        assert wav.getsampwidth() == 2
        assert wav.getframerate() == 16_000
        assert wav.getnframes() > 0


def test_synthetic_wav_fixture_rejects_unbounded_duration() -> None:
    with pytest.raises(VoiceExecutionBlocked, match="VOICE_FIXTURE_DURATION_INVALID"):
        create_synthetic_wav_fixture(job_id="job", duration_ms=10)
