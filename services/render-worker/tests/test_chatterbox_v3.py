from __future__ import annotations

import importlib

import pytest

from creator_worker.chatterbox_v3 import (
    B2_EXECUTION_PERMANENTLY_DISABLED,
    CHATTERBOX_PACKAGE_VERSION,
    CHATTERBOX_T3_SHA256,
    CHATTERBOX_VE_SHA256,
    CHATTERBOX_S3GEN_SHA256,
    CacheAsset,
    ChatterboxReadinessError,
    ChatterboxV3Provider,
    DeviceCapability,
    ModelManifest,
    RuntimePolicy,
    default_manifest,
    runtime_policy_from_environment,
)


def complete_manifest() -> ModelManifest:
    base = default_manifest()
    return ModelManifest(
        package_name=base.package_name,
        package_version=base.package_version,
        model_id=base.model_id,
        model_variant=base.model_variant,
        perth_commit=base.perth_commit,
        assets=(
            CacheAsset("ve.pt", CHATTERBOX_VE_SHA256),
            CacheAsset(base.model_variant, CHATTERBOX_T3_SHA256),
            CacheAsset("s3gen.pt", CHATTERBOX_S3GEN_SHA256),
            CacheAsset("grapheme_mtl_merged_expanded_v1.json", "1" * 64),
            CacheAsset("Cangjie5_TC.json", "2" * 64),
        ),
    )


def ready_policy(*, inference_approved: bool = False) -> RuntimePolicy:
    return RuntimePolicy(
        adapter_enabled=True,
        inference_approved=inference_approved,
        supply_chain_approved=True,
        network_download_allowed=False,
        max_job_cost_microunits=0,
        model_cache_dir="/models/chatterbox",
    )


def cuda_device() -> DeviceCapability:
    return DeviceCapability(kind="cuda", available=True, name="test-gpu", vram_mb=16_384)


def test_default_manifest_is_intentionally_incomplete_for_unhashed_assets() -> None:
    result = ChatterboxV3Provider().preflight(
        language="en",
        estimated_cost_microunits=0,
        device=cuda_device(),
        policy=ready_policy(),
    )
    assert result.execution_allowed is False
    assert result.structurally_ready is False
    assert "MODEL_ASSET_DIGEST_REQUIRED:grapheme_mtl_merged_expanded_v1.json" in result.blockers
    assert "MODEL_ASSET_DIGEST_REQUIRED:Cangjie5_TC.json" in result.blockers


def test_complete_manifest_can_be_structurally_ready_but_never_executable_in_b2() -> None:
    result = ChatterboxV3Provider().preflight(
        language="en",
        estimated_cost_microunits=0,
        device=cuda_device(),
        manifest=complete_manifest(),
        policy=ready_policy(inference_approved=True),
    )
    assert result.structurally_ready is True
    assert result.execution_allowed is False
    assert result.blockers == ("REAL_INFERENCE_NOT_APPROVED_B2",)
    assert result.package_version == CHATTERBOX_PACKAGE_VERSION


def test_preflight_rejects_language_device_budget_and_runtime_download() -> None:
    policy = RuntimePolicy(
        adapter_enabled=True,
        inference_approved=True,
        supply_chain_approved=True,
        network_download_allowed=True,
        max_job_cost_microunits=10,
        model_cache_dir="/models/chatterbox",
    )
    result = ChatterboxV3Provider().preflight(
        language="xx",
        estimated_cost_microunits=11,
        device=DeviceCapability(kind="cpu", available=True),
        manifest=complete_manifest(),
        policy=policy,
    )
    assert "CHATTERBOX_LANGUAGE_UNSUPPORTED" in result.blockers
    assert "REAL_VOICE_BUDGET_EXCEEDED" in result.blockers
    assert "CUDA_DEVICE_REQUIRED" in result.blockers
    assert "RUNTIME_MODEL_DOWNLOAD_FORBIDDEN" in result.blockers
    assert result.execution_allowed is False


def test_default_environment_is_fail_closed() -> None:
    policy = runtime_policy_from_environment({})
    assert policy.adapter_enabled is False
    assert policy.inference_approved is False
    assert policy.supply_chain_approved is False
    assert policy.network_download_allowed is False
    assert policy.max_job_cost_microunits == 0
    assert policy.model_cache_dir is None


def test_generate_stops_before_any_optional_runtime_import(monkeypatch: pytest.MonkeyPatch) -> None:
    called: list[str] = []

    def fail_import(name: str, *args, **kwargs):  # noqa: ANN002, ANN003
        called.append(name)
        raise AssertionError("optional runtime import must not happen in B2")

    monkeypatch.setattr(importlib, "import_module", fail_import)
    assert B2_EXECUTION_PERMANENTLY_DISABLED is True
    with pytest.raises(ChatterboxReadinessError) as caught:
        ChatterboxV3Provider().generate(text="never executed")
    assert caught.value.code == "REAL_INFERENCE_NOT_APPROVED_B2"
    assert called == []


def test_bad_manifest_provenance_fails_closed() -> None:
    manifest = complete_manifest()
    bad = ModelManifest(
        package_name=manifest.package_name,
        package_version="999.0.0",
        model_id=manifest.model_id,
        model_variant=manifest.model_variant,
        perth_commit=manifest.perth_commit,
        assets=manifest.assets,
    )
    result = ChatterboxV3Provider().preflight(
        language="en",
        estimated_cost_microunits=0,
        device=cuda_device(),
        manifest=bad,
        policy=ready_policy(),
    )
    assert "CHATTERBOX_PACKAGE_PROVENANCE_MISMATCH" in result.blockers
    assert result.execution_allowed is False
