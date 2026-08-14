import os
import secrets
from typing import Literal
from uuid import UUID

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, ConfigDict, field_validator

from .b1_runtime import (
    B1WorkerError,
    SupabaseB1Client,
    reconcile_held_voice_output,
    run_media_deletion,
    run_mock_voice_job,
)
from .providers import ArtifactKind, MockGenerationProvider

RuntimeMode = Literal["demo", "test", "preview", "production"]
ProviderMode = Literal["mock", "real"]

app = FastAPI(title="Avala Creator Render Worker", version="0.2.1")


class ExecuteJobRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    job_id: UUID
    input_artifact_id: UUID
    input_path: str
    artifact_kind: ArtifactKind

    @field_validator("input_path")
    @classmethod
    def validate_private_object_path(cls, value: str) -> str:
        if not value or value.startswith("/") or ".." in value.split("/"):
            raise ValueError("input_path must be a relative private object path")
        if value.lower().startswith(("http://", "https://")):
            raise ValueError("public URL input is forbidden")
        allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/")
        if any(character not in allowed for character in value):
            raise ValueError("input_path contains unsupported characters")
        return value


def runtime_mode() -> RuntimeMode:
    value = os.getenv("CREATOR_RUNTIME_MODE", "demo")
    if value not in {"demo", "test", "preview", "production"}:
        raise RuntimeError("invalid runtime mode")
    return value  # type: ignore[return-value]


def provider_mode() -> ProviderMode:
    value = os.getenv("CREATOR_PROVIDER_MODE", "mock")
    if value not in {"mock", "real"}:
        raise RuntimeError("invalid provider mode")
    return value  # type: ignore[return-value]


def authorize_worker(supplied_token: str | None) -> None:
    expected = os.getenv("CREATOR_WORKER_TOKEN")
    if not expected or not supplied_token or not secrets.compare_digest(supplied_token, expected):
        raise HTTPException(status_code=401, detail="worker authorization failed")


def require_b1_mock_runtime() -> None:
    if runtime_mode() not in {"demo", "test"} or provider_mode() != "mock":
        raise HTTPException(status_code=503, detail="B1 synthetic worker runtime is disabled")


def b1_worker_error(error: B1WorkerError) -> HTTPException:
    status = 503 if error.code.endswith("CONFIGURATION_REQUIRED") else 409
    return HTTPException(status_code=status, detail=error.code)


@app.get("/health")
def health() -> dict[str, str | bool]:
    runtime = runtime_mode()
    provider = provider_mode()
    ready = not (runtime in {"preview", "production"} and provider == "mock")
    return {
        "status": "ok" if ready else "blocked",
        "runtime_mode": runtime,
        "provider_mode": provider,
        "ready": ready,
    }


@app.post("/v1/jobs/execute")
def execute_job(
    payload: ExecuteJobRequest,
    x_worker_token: str | None = Header(default=None),
) -> dict[str, object]:
    authorize_worker(x_worker_token)
    runtime = runtime_mode()
    provider = provider_mode()

    if runtime in {"preview", "production"} and provider == "mock":
        raise HTTPException(status_code=503, detail="mock provider is forbidden in production-like modes")
    if provider != "mock":
        raise HTTPException(status_code=503, detail="real provider is not configured")

    artifact = MockGenerationProvider().generate(
        job_id=str(payload.job_id),
        input_artifact_id=str(payload.input_artifact_id),
        input_path=payload.input_path,
        artifact_kind=payload.artifact_kind,
    )
    return {
        "artifact": artifact.__dict__,
        "warning": "synthetic_mock: no voice, avatar, or video inference was performed",
    }


@app.post("/v1/voice/jobs/{job_id}/run")
def run_b1_voice_job(
    job_id: UUID,
    x_worker_token: str | None = Header(default=None),
) -> dict[str, object]:
    authorize_worker(x_worker_token)
    require_b1_mock_runtime()
    try:
        result = run_mock_voice_job(SupabaseB1Client.from_environment(), str(job_id))
    except B1WorkerError as error:
        raise b1_worker_error(error) from None
    return {**result, "warning": "synthetic_mock: deterministic non-speech WAV only"}


@app.post("/v1/voice/jobs/{job_id}/reconcile-output")
def reconcile_b1_voice_output(
    job_id: UUID,
    x_worker_token: str | None = Header(default=None),
) -> dict[str, object]:
    authorize_worker(x_worker_token)
    require_b1_mock_runtime()
    try:
        result = reconcile_held_voice_output(SupabaseB1Client.from_environment(), str(job_id))
    except B1WorkerError as error:
        raise b1_worker_error(error) from None
    return {**result, "warning": "synthetic_mock: output-ledger reconciliation only"}


@app.post("/v1/media-deletions/{deletion_id}/run")
def run_b1_media_deletion(
    deletion_id: UUID,
    x_worker_token: str | None = Header(default=None),
) -> dict[str, object]:
    authorize_worker(x_worker_token)
    require_b1_mock_runtime()
    try:
        return run_media_deletion(SupabaseB1Client.from_environment(), str(deletion_id))
    except B1WorkerError as error:
        raise b1_worker_error(error) from None
