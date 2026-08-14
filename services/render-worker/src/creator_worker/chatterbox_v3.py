from __future__ import annotations

from dataclasses import dataclass
import hashlib
import importlib
import os
from pathlib import Path
from typing import Mapping

CHATTERBOX_PACKAGE = "chatterbox-tts"
CHATTERBOX_PACKAGE_VERSION = "0.1.7"
CHATTERBOX_MODEL_ID = "ResembleAI/chatterbox"
CHATTERBOX_MODEL_VARIANT = "t3_mtl23ls_v3.safetensors"
CHATTERBOX_T3_SHA256 = "5abca8321ede76f8e61f1cc0d19aea6c946b28871017ce8726f8a69203f05953"
CHATTERBOX_VE_SHA256 = "4b16d836bc598509860f6fa068165a8bb5e9ac84f05582dfcf278a5a372879f1"
CHATTERBOX_S3GEN_SHA256 = "9b9ff07e60b20c136e2b1b3d7563a24604e8d2c4c267888d1ee929dd0151d2a3"
CHATTERBOX_CONDS_SHA256 = "6552d70568833628ba019c6b03459e77fe71ca197d5c560cef9411bee9d87f4e"
PERTH_PIN_CANDIDATE = "ce86c49d029f42272c1902eccb675556b9ed2330"
B2_EXECUTION_PERMANENTLY_DISABLED = True

SUPPORTED_LANGUAGES = frozenset({
    "ar", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi", "it", "ja",
    "ko", "ms", "nl", "no", "pl", "pt", "ru", "sv", "sw", "tr", "zh",
})


class ChatterboxReadinessError(RuntimeError):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class CacheAsset:
    name: str
    sha256: str | None
    required: bool = True


@dataclass(frozen=True)
class ModelManifest:
    package_name: str
    package_version: str
    model_id: str
    model_variant: str
    perth_commit: str | None
    assets: tuple[CacheAsset, ...]


@dataclass(frozen=True)
class DeviceCapability:
    kind: str
    available: bool
    name: str | None = None
    vram_mb: int | None = None


@dataclass(frozen=True)
class RuntimePolicy:
    adapter_enabled: bool
    inference_approved: bool
    supply_chain_approved: bool
    network_download_allowed: bool
    max_job_cost_microunits: int
    model_cache_dir: str | None


@dataclass(frozen=True)
class PreflightResult:
    structurally_ready: bool
    execution_allowed: bool
    blockers: tuple[str, ...]
    package_version: str
    model_id: str
    model_variant: str
    language: str


def default_manifest() -> ModelManifest:
    return ModelManifest(
        package_name=CHATTERBOX_PACKAGE,
        package_version=CHATTERBOX_PACKAGE_VERSION,
        model_id=CHATTERBOX_MODEL_ID,
        model_variant=CHATTERBOX_MODEL_VARIANT,
        perth_commit=PERTH_PIN_CANDIDATE,
        assets=(
            CacheAsset("ve.pt", CHATTERBOX_VE_SHA256),
            CacheAsset(CHATTERBOX_MODEL_VARIANT, CHATTERBOX_T3_SHA256),
            CacheAsset("s3gen.pt", CHATTERBOX_S3GEN_SHA256),
            CacheAsset("grapheme_mtl_merged_expanded_v1.json", None),
            CacheAsset("Cangjie5_TC.json", None),
            CacheAsset("conds.pt", CHATTERBOX_CONDS_SHA256, required=False),
        ),
    )


def _env_bool(env: Mapping[str, str], name: str) -> bool:
    return env.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def runtime_policy_from_environment(env: Mapping[str, str] | None = None) -> RuntimePolicy:
    values = os.environ if env is None else env
    raw_budget = values.get("CREATOR_REAL_VOICE_MAX_JOB_COST_MICROUNITS", "0")
    try:
        budget = int(raw_budget)
    except ValueError as error:
        raise ChatterboxReadinessError("REAL_VOICE_BUDGET_INVALID") from error
    if budget < 0:
        raise ChatterboxReadinessError("REAL_VOICE_BUDGET_INVALID")
    return RuntimePolicy(
        adapter_enabled=_env_bool(values, "CREATOR_CHATTERBOX_ADAPTER_ENABLED"),
        inference_approved=_env_bool(values, "CREATOR_REAL_INFERENCE_APPROVED"),
        supply_chain_approved=_env_bool(values, "CREATOR_CHATTERBOX_SUPPLY_CHAIN_APPROVED"),
        network_download_allowed=_env_bool(values, "CREATOR_MODEL_NETWORK_DOWNLOAD_ALLOWED"),
        max_job_cost_microunits=budget,
        model_cache_dir=values.get("CREATOR_CHATTERBOX_MODEL_CACHE") or None,
    )


def _valid_sha256(value: str | None) -> bool:
    return bool(value) and len(value) == 64 and all(char in "0123456789abcdef" for char in value)


def validate_manifest(
    manifest: ModelManifest,
    *,
    cache_dir: str | None = None,
    verify_local_files: bool = False,
) -> tuple[str, ...]:
    blockers: list[str] = []
    if manifest.package_name != CHATTERBOX_PACKAGE or manifest.package_version != CHATTERBOX_PACKAGE_VERSION:
        blockers.append("CHATTERBOX_PACKAGE_PROVENANCE_MISMATCH")
    if manifest.model_id != CHATTERBOX_MODEL_ID or manifest.model_variant != CHATTERBOX_MODEL_VARIANT:
        blockers.append("CHATTERBOX_MODEL_PROVENANCE_MISMATCH")
    if manifest.perth_commit != PERTH_PIN_CANDIDATE:
        blockers.append("PERTH_IMMUTABLE_PIN_REQUIRED")

    for asset in manifest.assets:
        if asset.required and not _valid_sha256(asset.sha256):
            blockers.append(f"MODEL_ASSET_DIGEST_REQUIRED:{asset.name}")
            continue
        if verify_local_files:
            if not cache_dir:
                blockers.append("MODEL_CACHE_DIRECTORY_REQUIRED")
                continue
            path = Path(cache_dir) / asset.name
            if asset.required and not path.is_file():
                blockers.append(f"MODEL_ASSET_MISSING:{asset.name}")
                continue
            if path.is_file() and asset.sha256:
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                if digest != asset.sha256:
                    blockers.append(f"MODEL_ASSET_DIGEST_MISMATCH:{asset.name}")
    return tuple(dict.fromkeys(blockers))


class ChatterboxV3Provider:
    """B2 integration boundary. Real inference is intentionally impossible in this milestone."""

    provider_id = "chatterbox_multilingual_v3"

    def preflight(
        self,
        *,
        language: str,
        estimated_cost_microunits: int,
        device: DeviceCapability,
        manifest: ModelManifest | None = None,
        policy: RuntimePolicy | None = None,
        verify_local_files: bool = False,
    ) -> PreflightResult:
        manifest = default_manifest() if manifest is None else manifest
        policy = runtime_policy_from_environment() if policy is None else policy
        blockers = list(validate_manifest(
            manifest,
            cache_dir=policy.model_cache_dir,
            verify_local_files=verify_local_files,
        ))

        normalized_language = language.strip().lower()
        if normalized_language not in SUPPORTED_LANGUAGES:
            blockers.append("CHATTERBOX_LANGUAGE_UNSUPPORTED")
        if estimated_cost_microunits < 0 or estimated_cost_microunits > policy.max_job_cost_microunits:
            blockers.append("REAL_VOICE_BUDGET_EXCEEDED")
        if device.kind != "cuda" or not device.available:
            blockers.append("CUDA_DEVICE_REQUIRED")
        if not policy.adapter_enabled:
            blockers.append("CHATTERBOX_ADAPTER_DISABLED")
        if not policy.supply_chain_approved:
            blockers.append("CHATTERBOX_SUPPLY_CHAIN_NOT_APPROVED")
        if policy.network_download_allowed:
            blockers.append("RUNTIME_MODEL_DOWNLOAD_FORBIDDEN")
        if not policy.model_cache_dir:
            blockers.append("MODEL_CACHE_DIRECTORY_REQUIRED")
        if not policy.inference_approved:
            blockers.append("REAL_INFERENCE_APPROVAL_REQUIRED")

        blockers.append("REAL_INFERENCE_NOT_APPROVED_B2")
        unique = tuple(dict.fromkeys(blockers))
        structural_blockers = tuple(
            code for code in unique
            if code not in {"REAL_INFERENCE_APPROVAL_REQUIRED", "REAL_INFERENCE_NOT_APPROVED_B2"}
        )
        return PreflightResult(
            structurally_ready=not structural_blockers,
            execution_allowed=False,
            blockers=unique,
            package_version=manifest.package_version,
            model_id=manifest.model_id,
            model_variant=manifest.model_variant,
            language=normalized_language,
        )

    def _load_runtime_class(self):
        module = importlib.import_module("chatterbox.mtl_tts")
        return module.ChatterboxMultilingualTTS

    def generate(self, **_: object) -> None:
        if B2_EXECUTION_PERMANENTLY_DISABLED:
            raise ChatterboxReadinessError("REAL_INFERENCE_NOT_APPROVED_B2")
        self._load_runtime_class()
        raise ChatterboxReadinessError("REAL_INFERENCE_RUNTIME_NOT_IMPLEMENTED")
