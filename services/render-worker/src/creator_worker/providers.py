from dataclasses import dataclass
import hashlib
from typing import Literal, Protocol

ArtifactKind = Literal["script", "voice", "avatar", "edit", "final"]


@dataclass(frozen=True)
class GeneratedArtifact:
    kind: ArtifactKind
    storage_path: str
    sha256: str
    provider: str
    is_mock: bool


class GenerationProvider(Protocol):
    name: str

    def generate(
        self,
        *,
        job_id: str,
        input_artifact_id: str,
        input_path: str,
        artifact_kind: ArtifactKind,
    ) -> GeneratedArtifact: ...


class ProviderUnavailable(RuntimeError):
    code = "PROVIDER_UNAVAILABLE"


class MockGenerationProvider:
    name = "mock"

    def generate(
        self,
        *,
        job_id: str,
        input_artifact_id: str,
        input_path: str,
        artifact_kind: ArtifactKind,
    ) -> GeneratedArtifact:
        material = f"mock:{job_id}:{input_artifact_id}:{input_path}:{artifact_kind}"
        digest = hashlib.sha256(material.encode()).hexdigest()
        return GeneratedArtifact(
            kind=artifact_kind,
            storage_path=f"mock/{artifact_kind}/{job_id}.json",
            sha256=digest,
            provider=self.name,
            is_mock=True,
        )
