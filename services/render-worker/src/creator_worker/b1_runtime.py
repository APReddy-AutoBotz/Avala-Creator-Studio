from __future__ import annotations

import base64
from dataclasses import dataclass
import hashlib
import io
import json
import math
import os
from pathlib import PurePosixPath
import struct
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen
from uuid import UUID, NAMESPACE_URL, uuid5
import wave

VOICE_OUTPUT_BUCKET = "creator-voice-output"
SYNTHETIC_LABEL = "[SYNTHETIC MOCK VOICE DRAFT]"


class B1WorkerError(RuntimeError):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class B1AuthorityClient(Protocol):
    def get_voice_job(self, job_id: str) -> dict[str, Any] | None: ...
    def rpc(self, name: str, payload: dict[str, Any]) -> Any: ...
    def upload_voice_object(self, path: str, content: bytes, metadata: dict[str, str]) -> None: ...
    def remove_object(self, bucket: str, path: str) -> None: ...


def create_synthetic_b1_wav(job_id: str, *, duration_ms: int = 1000, sample_rate: int = 16000) -> bytes:
    """Create deterministic non-speech test audio. No voice sample or model is read."""
    if duration_ms < 100 or duration_ms > 5000:
        raise B1WorkerError("SYNTHETIC_DURATION_INVALID")
    UUID(job_id)
    digest = hashlib.sha256(job_id.encode("ascii")).digest()
    frequency = 220 + digest[0]
    amplitude = 2200
    frame_count = sample_rate * duration_ms // 1000
    stream = io.BytesIO()
    with wave.open(stream, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        frames = bytearray()
        for frame in range(frame_count):
            value = int(amplitude * math.sin(2 * math.pi * frequency * frame / sample_rate))
            frames.extend(struct.pack("<h", value))
        wav.writeframes(bytes(frames))
    return stream.getvalue()


def _voice_object_path(job: dict[str, Any], output_sha256: str) -> str:
    owner_id = str(job.get("requested_by") or "")
    project_id = str(job.get("project_id") or "")
    job_id = str(job.get("id") or "")
    for value in (owner_id, project_id, job_id):
        UUID(value)
    if len(output_sha256) != 64:
        raise B1WorkerError("VOICE_OUTPUT_DIGEST_INVALID")
    return f"{owner_id}/{project_id}/{job_id}/{output_sha256}.wav"


def run_mock_voice_job(client: B1AuthorityClient, job_id: str) -> dict[str, Any]:
    UUID(job_id)
    current = client.get_voice_job(job_id)
    if current is None:
        raise B1WorkerError("VOICE_JOB_NOT_FOUND")
    if current.get("status") == "succeeded" and current.get("output_artifact_id"):
        return {
            "status": "succeeded",
            "job_id": job_id,
            "artifact_id": current["output_artifact_id"],
            "replayed": True,
            "media_kind": "synthetic_mock",
        }

    claim = client.rpc("creator_claim_mock_voice_job_b1", {"p_job_id": job_id, "p_lease_seconds": 60})
    if not isinstance(claim, dict) or not isinstance(claim.get("job"), dict):
        raise B1WorkerError("VOICE_CLAIM_RESPONSE_INVALID")
    capability = claim.get("capability")
    if not isinstance(capability, str) or len(capability) != 64:
        raise B1WorkerError("VOICE_CLAIM_RESPONSE_INVALID")
    job = claim["job"]
    wav_bytes = create_synthetic_b1_wav(job_id)
    output_sha256 = hashlib.sha256(wav_bytes).hexdigest()
    object_path = _voice_object_path(job, output_sha256)
    client.upload_voice_object(
        object_path,
        wav_bytes,
        {"sha256": output_sha256, "job_id": job_id},
    )
    completion_key = str(uuid5(NAMESPACE_URL, f"avala-creator-b1-completion:{job_id}"))
    completion = client.rpc(
        "creator_complete_mock_voice_job",
        {
            "p_job_id": job_id,
            "p_capability": capability,
            "p_idempotency_key": completion_key,
            "p_object_path": object_path,
            "p_output_sha256": output_sha256,
            "p_byte_length": len(wav_bytes),
            "p_mime_type": "audio/wav",
            "p_duration_ms": 1000,
            "p_runtime_ms": 0,
            "p_actual_cost_microunits": 0,
            "p_synthetic_label": SYNTHETIC_LABEL,
        },
    )
    if not isinstance(completion, dict) or not isinstance(completion.get("artifact"), dict):
        raise B1WorkerError("VOICE_COMPLETION_RESPONSE_INVALID")
    return {
        "status": "succeeded",
        "job_id": job_id,
        "artifact_id": completion["artifact"].get("id"),
        "replayed": bool(completion.get("replayed")),
        "output_sha256": output_sha256,
        "object_path": object_path,
        "media_kind": "synthetic_mock",
    }


def run_media_deletion(client: B1AuthorityClient, deletion_id: str) -> dict[str, Any]:
    UUID(deletion_id)
    claim = client.rpc("creator_claim_media_deletion", {"p_deletion_id": deletion_id, "p_lease_seconds": 60})
    if not isinstance(claim, dict) or not isinstance(claim.get("deletion"), dict):
        raise B1WorkerError("MEDIA_DELETE_CLAIM_RESPONSE_INVALID")
    deletion = claim["deletion"]
    if deletion.get("status") == "deleted":
        return {"status": "deleted", "deletion_id": deletion_id, "replayed": True}
    capability = claim.get("capability")
    if not isinstance(capability, str) or len(capability) != 64:
        raise B1WorkerError("MEDIA_DELETE_CLAIM_RESPONSE_INVALID")
    bucket = deletion.get("bucket_id")
    path = deletion.get("object_path")
    if bucket != VOICE_OUTPUT_BUCKET or not isinstance(path, str):
        raise B1WorkerError("MEDIA_DELETE_OBJECT_BINDING_INVALID")
    client.remove_object(bucket, path)
    finished = client.rpc(
        "creator_finish_media_deletion",
        {
            "p_deletion_id": deletion_id,
            "p_capability": capability,
            "p_success": True,
            "p_error_code": None,
        },
    )
    return {"status": "deleted", "deletion_id": deletion_id, "result": finished, "replayed": False}


@dataclass
class SupabaseB1Client:
    url: str
    service_role_key: str
    timeout_seconds: float = 20.0

    @classmethod
    def from_environment(cls) -> "SupabaseB1Client":
        url = os.getenv("CREATOR_SUPABASE_URL") or os.getenv("NEXT_PUBLIC_SUPABASE_URL")
        key = os.getenv("SUPABASE_SERVICE_ROLE_KEY")
        if not url or not key:
            raise B1WorkerError("SUPABASE_WORKER_CONFIGURATION_REQUIRED")
        return cls(url=url.rstrip("/"), service_role_key=key)

    def _headers(self, *, content_type: str = "application/json") -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.service_role_key}",
            "apikey": self.service_role_key,
            "Content-Type": content_type,
        }

    def _json_request(self, method: str, path: str, payload: Any | None = None) -> Any:
        data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
        request = Request(self.url + path, data=data, headers=self._headers(), method=method)
        try:
            with urlopen(request, timeout=self.timeout_seconds) as response:  # noqa: S310 - fixed trusted Supabase origin
                raw = response.read()
        except (HTTPError, URLError) as error:
            status = getattr(error, "code", 0)
            raise B1WorkerError(f"SUPABASE_WORKER_REQUEST_FAILED_{status}") from None
        if not raw:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            raise B1WorkerError("SUPABASE_WORKER_RESPONSE_INVALID") from None

    def get_voice_job(self, job_id: str) -> dict[str, Any] | None:
        query = urlencode({"id": f"eq.{job_id}", "select": "id,project_id,status,requested_by,output_artifact_id"})
        result = self._json_request("GET", f"/rest/v1/creator_jobs?{query}")
        if not isinstance(result, list):
            raise B1WorkerError("VOICE_JOB_LOOKUP_RESPONSE_INVALID")
        if not result:
            return None
        if not isinstance(result[0], dict):
            raise B1WorkerError("VOICE_JOB_LOOKUP_RESPONSE_INVALID")
        return result[0]

    def rpc(self, name: str, payload: dict[str, Any]) -> Any:
        if not name.startswith("creator_"):
            raise B1WorkerError("RPC_NAME_INVALID")
        return self._json_request("POST", f"/rest/v1/rpc/{name}", payload)

    def upload_voice_object(self, path: str, content: bytes, metadata: dict[str, str]) -> None:
        pure = PurePosixPath(path)
        if path.startswith("/") or ".." in pure.parts or pure.suffix != ".wav":
            raise B1WorkerError("VOICE_OBJECT_PATH_INVALID")
        encoded_path = quote(path, safe="/")
        encoded_metadata = base64.b64encode(json.dumps(metadata, separators=(",", ":")).encode("utf-8")).decode("ascii")
        headers = self._headers(content_type="audio/wav")
        headers["x-upsert"] = "false"
        headers["x-metadata"] = encoded_metadata
        request = Request(
            f"{self.url}/storage/v1/object/{VOICE_OUTPUT_BUCKET}/{encoded_path}",
            data=content,
            headers=headers,
            method="POST",
        )
        try:
            with urlopen(request, timeout=self.timeout_seconds):  # noqa: S310 - fixed trusted Supabase origin
                return
        except HTTPError as error:
            if error.code == 409:  # exact retry after a successful upload may see the existing immutable path
                return
            raise B1WorkerError(f"VOICE_STORAGE_UPLOAD_FAILED_{error.code}") from None
        except URLError:
            raise B1WorkerError("VOICE_STORAGE_UPLOAD_FAILED_0") from None

    def remove_object(self, bucket: str, path: str) -> None:
        if bucket != VOICE_OUTPUT_BUCKET:
            raise B1WorkerError("MEDIA_DELETE_OBJECT_BINDING_INVALID")
        payload = {"prefixes": [path]}
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        request = Request(
            f"{self.url}/storage/v1/object/{bucket}",
            data=data,
            headers=self._headers(),
            method="DELETE",
        )
        try:
            with urlopen(request, timeout=self.timeout_seconds):  # noqa: S310 - fixed trusted Supabase origin
                return
        except HTTPError as error:
            if error.code == 404:
                return
            raise B1WorkerError(f"MEDIA_DELETE_STORAGE_FAILED_{error.code}") from None
        except URLError:
            raise B1WorkerError("MEDIA_DELETE_STORAGE_FAILED_0") from None
