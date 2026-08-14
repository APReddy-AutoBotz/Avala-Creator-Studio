from __future__ import annotations

from typing import Any
from uuid import UUID

import pytest

from creator_worker.b1_runtime import (
    B1WorkerError,
    SYNTHETIC_LABEL,
    create_synthetic_b1_wav,
    reconcile_held_voice_output,
    run_media_deletion,
    run_mock_voice_job,
)

JOB_ID = "11111111-1111-4111-8111-111111111111"
PROJECT_ID = "22222222-2222-4222-8222-222222222222"
OWNER_ID = "33333333-3333-4333-8333-333333333333"
ARTIFACT_ID = "44444444-4444-4444-8444-444444444444"
DELETION_ID = "55555555-5555-4555-8555-555555555555"
CAPABILITY = "a" * 64


class FakeClient:
    def __init__(self) -> None:
        self.job = {
            "id": JOB_ID,
            "project_id": PROJECT_ID,
            "requested_by": OWNER_ID,
            "status": "queued",
            "output_artifact_id": None,
        }
        self.calls: list[tuple[str, Any]] = []
        self.events: list[str] = []
        self.upload: tuple[str, bytes, dict[str, str]] | None = None
        self.removed: tuple[str, str] | None = None
        self.completion_mode = "success"

    def get_voice_job(self, job_id: str) -> dict[str, Any] | None:
        assert job_id == JOB_ID
        return dict(self.job)

    def rpc(self, name: str, payload: dict[str, Any]) -> Any:
        self.calls.append((name, payload))
        self.events.append(name)
        if name == "creator_claim_mock_voice_job_b1":
            return {"job": dict(self.job), "capability": CAPABILITY, "replayed": False}
        if name == "creator_hold_mock_voice_output":
            assert payload["p_capability"] == CAPABILITY
            return {
                "id": DELETION_ID,
                "status": "held",
                "job_id": JOB_ID,
                "object_path": payload["p_object_path"],
            }
        if name == "creator_complete_mock_voice_job":
            assert payload["p_synthetic_label"] == SYNTHETIC_LABEL
            assert payload["p_actual_cost_microunits"] == 0
            if self.completion_mode == "fail_after_commit":
                self.job["status"] = "succeeded"
                self.job["output_artifact_id"] = ARTIFACT_ID
                raise B1WorkerError("SUPABASE_WORKER_REQUEST_FAILED_0")
            if self.completion_mode == "fail_before_commit":
                raise B1WorkerError("VOICE_JOB_NOT_COMPLETABLE")
            self.job["status"] = "succeeded"
            self.job["output_artifact_id"] = ARTIFACT_ID
            return {"artifact": {"id": ARTIFACT_ID}, "replayed": False}
        if name == "creator_reconcile_held_voice_output":
            return {"tracked": True, "status": "held", "queued_for_deletion": False, "deferred": True}
        if name == "creator_claim_media_deletion":
            return {
                "deletion": {
                    "id": DELETION_ID,
                    "status": "queued",
                    "bucket_id": "creator-voice-output",
                    "object_path": f"{OWNER_ID}/stale.wav",
                },
                "capability": CAPABILITY,
                "replayed": False,
            }
        if name == "creator_finish_media_deletion":
            assert payload["p_capability"] == CAPABILITY
            return {"id": DELETION_ID, "status": "deleted"}
        raise AssertionError(name)

    def upload_voice_object(self, path: str, content: bytes, metadata: dict[str, str]) -> None:
        self.events.append("upload_voice_object")
        self.upload = (path, content, metadata)

    def remove_object(self, bucket: str, path: str) -> None:
        self.removed = (bucket, path)


def test_synthetic_wav_is_deterministic_non_empty_and_valid_riff() -> None:
    first = create_synthetic_b1_wav(JOB_ID)
    second = create_synthetic_b1_wav(JOB_ID)
    assert first == second
    assert first[:4] == b"RIFF"
    assert first[8:12] == b"WAVE"
    assert len(first) > 1000


def test_mock_voice_run_holds_before_upload_then_completes_zero_cost() -> None:
    client = FakeClient()
    result = run_mock_voice_job(client, JOB_ID)
    assert result["status"] == "succeeded"
    assert result["artifact_id"] == ARTIFACT_ID
    assert result["media_kind"] == "synthetic_mock"
    assert client.upload is not None
    path, content, metadata = client.upload
    assert path.startswith(f"{OWNER_ID}/{PROJECT_ID}/{JOB_ID}/")
    assert path.endswith(".wav")
    assert metadata["job_id"] == JOB_ID
    assert len(metadata["sha256"]) == 64
    assert len(content) > 1000
    assert client.events == [
        "creator_claim_mock_voice_job_b1",
        "creator_hold_mock_voice_output",
        "upload_voice_object",
        "creator_complete_mock_voice_job",
    ]


def test_succeeded_job_replay_does_not_reupload_or_reclaim() -> None:
    client = FakeClient()
    client.job["status"] = "succeeded"
    client.job["output_artifact_id"] = ARTIFACT_ID
    result = run_mock_voice_job(client, JOB_ID)
    assert result["replayed"] is True
    assert result["artifact_id"] == ARTIFACT_ID
    assert client.calls == []
    assert client.upload is None


def test_completion_response_loss_after_commit_recovers_without_deleting_output() -> None:
    client = FakeClient()
    client.completion_mode = "fail_after_commit"
    result = run_mock_voice_job(client, JOB_ID)
    assert result["status"] == "succeeded"
    assert result["replayed"] is True
    assert result["artifact_id"] == ARTIFACT_ID
    names = [name for name, _ in client.calls]
    assert "creator_reconcile_held_voice_output" not in names


def test_failed_completion_invokes_conservative_reconciler() -> None:
    client = FakeClient()
    client.completion_mode = "fail_before_commit"
    with pytest.raises(B1WorkerError, match="VOICE_JOB_NOT_COMPLETABLE"):
        run_mock_voice_job(client, JOB_ID)
    names = [name for name, _ in client.calls]
    assert names[-1] == "creator_reconcile_held_voice_output"
    assert client.upload is not None


def test_explicit_output_reconcile_uses_authoritative_rpc() -> None:
    client = FakeClient()
    result = reconcile_held_voice_output(client, JOB_ID, abandon_after_seconds=1200)
    assert result["deferred"] is True
    assert client.calls == [
        (
            "creator_reconcile_held_voice_output",
            {"p_job_id": JOB_ID, "p_abandon_after_seconds": 1200},
        )
    ]


def test_media_deletion_uses_claim_storage_remove_and_capability_finish() -> None:
    client = FakeClient()
    result = run_media_deletion(client, DELETION_ID)
    assert result["status"] == "deleted"
    assert client.removed == ("creator-voice-output", f"{OWNER_ID}/stale.wav")
    names = [name for name, _ in client.calls]
    assert names == ["creator_claim_media_deletion", "creator_finish_media_deletion"]
    finish = client.calls[-1][1]
    assert finish["p_capability"] == CAPABILITY
    UUID(finish["p_deletion_id"])
