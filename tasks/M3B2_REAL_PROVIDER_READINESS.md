# M3 Phase B2 — Real-provider integration readiness

Issue: #10
Base: exact M3 B1 closure head `d7003e77b71c035c348dbd3d6c08a0915525877d`

## Goal
Prepare a production-grade Chatterbox Multilingual V3 adapter and cloud-worker deployment boundary without downloading model weights or executing real voice inference.

## Current verified upstream
- Package: `chatterbox-tts` 0.1.7.
- Code license: MIT.
- Champion model: Chatterbox Multilingual V3, 0.5B family.
- V3 T3 weight object: `t3_mtl23ls_v3.safetensors`, SHA-256 `5abca8321ede76f8e61f1cc0d19aea6c946b28871017ce8726f8a69203f05953`.
- Keep these values in a reviewable provenance manifest. They are evidence, not permission to download or run the model in B2.

## Non-negotiable gates
1. Real-provider execution stays disabled by default in DB, worker config, CI, preview and production.
2. No model weights, voice samples, generated real speech, Torch checkpoints, Hugging Face caches or GPU artifacts enter Git.
3. Default `dev`/`test` install must not install `chatterbox-tts`, Torch or model dependencies.
4. Real adapter imports must be lazy and unreachable unless a separately approved runtime flag is enabled.
5. A real job must require current human trigger, active self-owned voice consent, validated current sample(s), approved immutable script, exact model provenance, private input/output paths and a hard job budget.
6. The worker must revalidate all authority immediately before inference and again before completion.
7. Real provider code cannot create human approvals or advance beyond `VOICE_REVIEW`.
8. B2 must not create or invoke a paid API, GPU machine, model download, hosted inference, avatar generation or publishing integration.

## Required implementation
### Provider/runtime contracts
- Add strict contracts for real-provider preflight, model provenance, device capability, cost estimate, inference request, output evidence and failure codes.
- Model provenance must include provider/package version, model id/version, expected SHA-256, language, sample/script/profile bindings and runtime image digest placeholder.
- Add a provider readiness state distinct from execution approval.

### Python adapter boundary
- Add `ChatterboxV3Provider` behind a protocol/interface.
- The adapter module may describe how to import/run Chatterbox but may not import `chatterbox`, `torch`, `torchaudio`, `transformers`, `huggingface_hub` or similar at module import time.
- Runtime imports happen only inside an execution method after explicit preflight gates.
- In B2, the execution method must fail closed with `REAL_INFERENCE_NOT_APPROVED_B2` before any model loading/downloading call.
- Add deterministic dry-run/preflight mode that validates configuration/provenance without network or inference.

### Dependency isolation
- Put Chatterbox in a separately named optional dependency/install path; default worker `[dev]` install must remain lightweight and CI-safe.
- Pin reviewed versions. Do not execute the optional install in CI.
- Add lock/provenance documentation for any Git dependency inherited by upstream Chatterbox.

### Runtime image/deployment readiness
- Add a GPU-worker Dockerfile or equivalent deployment manifest separate from the normal mock worker image.
- It must support scale-to-zero/on-demand operation, read-only model cache where possible, private Supabase inputs/outputs, resource limits, and explicit environment kill-switches.
- Do not deploy it in B2.
- Document expected runtime requirements, model-cache size, cold-start risks and the future B3 cost-measurement procedure.

### Database/runtime authority
- Add additive schema only if needed for model/runtime evidence; preserve current B1 authority.
- Any real-provider request must remain denied/audited while `real_provider_execution_enabled=false`.
- Add an explicit future runtime-approval record/version or equivalent evidence so flipping a single environment variable cannot enable real inference.
- Require both DB approval and worker runtime approval for B3.

### Security/privacy
- Add threat-model notes for model supply chain, prompt/sample exfiltration, cache persistence, malicious model/artifact substitution, GPU host compromise and response-loss recovery.
- Keep private media out of logs and provider telemetry.
- Define deletion/retention behavior for temporary model inputs and generated outputs.

### Tests and static guards
Prove at minimum:
- importing the normal worker does not import optional real-provider packages;
- dry-run preflight performs no network/model access;
- execution fails before lazy import/model load when B2 execution is disabled;
- provenance/checksum mismatch fails closed;
- unsupported language/device/budget fails closed;
- DB real-provider execution remains false;
- no real provider can complete a job in B2;
- no media/model/checkpoint files are committed;
- current B1 mock lifecycle remains green.

## Required checks
- `pnpm check`
- `python -m pytest services/render-worker/tests -q`
- `python -m compileall -q services/render-worker/src services/render-worker/tests`
- repository boundary/secret/media guards
- exact-head GitHub Actions
- Supabase security/performance advisors if schema changes
- independent Codex review

## Exit criteria
B2 is complete only when code/CI/security review prove the real-provider integration is structurally ready but impossible to execute. B3 will be a separate explicit inference-pilot gate and may require cloud GPU cost confirmation before any real voice generation.
