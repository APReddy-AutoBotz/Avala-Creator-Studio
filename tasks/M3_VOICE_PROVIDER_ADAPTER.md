# M3 — Voice provider evaluation + governed adapter design

## Parent gate

This is a stacked Phase-A implementation on top of M2 closure head `79e44287023e1255f4d610c803f3d99a667e04ed`.

M2 infrastructure/review authority is closed. PR #1 remains Draft for human product/UI review and is not merged. This M3 branch must target `agent/standalone-bootstrap`, not `main`.

## Provider decision for Phase A

Evaluation champion: **Chatterbox Multilingual V3** (`ResembleAI/chatterbox`).
Fallback: **Qwen3-TTS 12Hz 0.6B Base** (`Qwen/Qwen3-TTS-12Hz-0.6B-Base`).
Specialist benchmark candidate: **Fun-CosyVoice3 0.5B** (`FunAudioLLM/Fun-CosyVoice3-0.5B-2512`).
Lightweight reference: **OpenVoice V2** (`myshell-ai/OpenVoiceV2`).

This is a catalog/architecture decision only. All real providers remain `research_only`.

## Mandatory non-goals

Do **not**:

- add/import/install Chatterbox, Qwen3-TTS, CosyVoice, OpenVoice, MeloTTS or any model runtime package;
- download or cache any model/checkpoint/tokenizer/model weight;
- invoke CUDA/GPU/MPS/CPU TTS inference;
- call a hosted/paid TTS endpoint;
- add provider API keys/secrets;
- read or generate real voice media;
- enable `START_VOICE`, `VOICE_READY`, avatar/edit/final generation, or M4 work;
- add social publishing/OAuth;
- weaken M2 RLS, consent, deletion, idempotency, human-approval, synthetic-labelling or repository-boundary rules.

No runtime provider spend is authorized in M3 Phase A.

## Product authority invariants

1. Human owner explicitly triggers generation; no unattended voice generation.
2. Worker/provider can create immutable draft audio versions only; never approve them.
3. Voice job creation **and** worker execution must require the same owner-scoped active voice profile, current consent and at least one validated sample.
4. Revocation/deletion cancels/invalidate all profile-dependent voice/downstream work before it can become authoritative.
5. Provider/model availability, license approval and cost approval fail closed.
6. Mock/test output must remain visibly and structurally synthetic.
7. Private media paths/tokens/embeddings must never enter Git or logs.

## Required implementation

### 1. Provider-neutral contracts

Add strict typed contracts for:

- `VoiceProviderId`
- provider capability metadata: languages, zero-shot/self-voice cloning, streaming, pronunciation control, voice-style control, watermark capability, reference-text requirement, self-hostable flag
- provider legal/runtime state: `research_only | approved_for_test | approved_for_runtime | disabled`
- source/model metadata: code license SPDX, model-weight license SPDX, upstream code/model identifiers, verified-at date, model version/revision placeholder, artifact-size metadata, current install state (`not_installed` by default)
- runtime/cost policy: execution disabled by default, hard per-job budget ceiling, currency/unit metadata, no-unbounded-spend invariant
- provider provenance/evidence attached to future voice artifacts: provider/model revision/checksum, input script artifact id/version/SHA, profile id, sample ids, output SHA, generation mode, timestamps, duration/cost fields

Every real provider catalog entry must default to `research_only` + `not_installed` + execution disabled.

### 2. Provider catalog

Encode the Phase-A catalog above without importing provider libraries. Include only metadata verified in issue #3 / current primary-source research. Do not assert a hard VRAM requirement where the upstream project does not publish one.

The catalog must make Chatterbox V3 the evaluation champion and Qwen 0.6B Base the fallback, but must not make either executable.

### 3. Deterministic mock adapter

Create a provider interface and a deterministic mock/test adapter that:

- requires no network/GPU/model dependency;
- never accepts real identity media;
- returns structurally synthetic metadata and a deterministic fake output descriptor/checksum, not an audio file;
- cannot masquerade as a real provider result;
- supports unit/integration tests for orchestration and authority gates.

### 4. Voice request/segment/pronunciation contracts

Add immutable strict schemas for:

- exact approved script artifact binding;
- segmentation of narration into stable segment IDs/order;
- language code per segment;
- pronunciation overrides / lexicon entries (term, normalized pronunciation/phoneme representation, language, notes/source), provider-neutral rather than Chatterbox-specific;
- optional pace/style intent as bounded metadata;
- client/idempotency request identity.

Do not store sample bytes, signed URLs or embeddings in these contracts.

### 5. M3 authority/job design

Implement the database/service boundary needed to represent a future voice-generation job without running a provider:

- create a voice job only from `SCRIPT_APPROVED` and exact latest approved script binding;
- require an active self-owned voice profile with validated sample(s);
- require provider state to be explicitly `approved_for_test` or `approved_for_runtime`; because every real provider is `research_only`, real-provider job creation must fail closed in this PR;
- permit deterministic mock job creation only in explicit test/demo mode and label it synthetic;
- revalidate consent/profile/provider state at trusted worker claim/execution boundary;
- use exact idempotency and lock ordering consistent with M2;
- revocation/deletion remains authoritative over queued/leased/running voice jobs;
- do not transition the product workflow into `VOICE_GENERATING` for a real provider in Phase A.

Prefer schema/RPC design that can be extended in Phase B without changing browser trust boundaries.

### 6. Provenance and audit

Add audit/evidence fields/events for Phase-A mock orchestration and denied real-provider attempts. Never log confidential script text, sample paths, media URLs, provider credentials or biometric material.

### 7. Tests and guardrails

Add tests proving at minimum:

- all real providers are non-executable by default;
- no provider runtime package/model reference is installed or imported;
- no network/provider call is needed for tests;
- mock output is visibly + structurally synthetic;
- browser/user authority cannot choose another owner/profile or bypass consent;
- draft/revoked/deleting/deleted profiles are ineligible;
- unvalidated sample is ineligible;
- stale/unapproved/non-latest script cannot create a voice job;
- provider `research_only` blocks real job creation;
- budget missing/exceeded blocks execution;
- exact replay is idempotent and conflicting key reuse fails;
- worker execution revalidation catches consent/provider changes after queueing;
- no `START_VOICE` / `VOICE_READY` real workflow transition becomes available in Phase A;
- CI repository boundary still rejects model weights, private media and secrets.

## Evidence and documentation

Update the relevant security/threat/cost/provider documentation with:

- current provider decision and source/license identifiers;
- clear statement that no model was downloaded/run and no runtime cost was incurred;
- Phase-B approval checklist for license, model-weight license, compute/provider cost, privacy/data flow, deletion/retention, self-owned sample test and explicit human-triggered execution.

## Required checks

Run every existing repository check plus all new focused tests. Keep the PR Draft. Report exact head SHA, changed files, migrations, test counts, security impact, cost impact and known limitations.

## Stop gate

If any implementation step would require downloading a model, adding a real TTS dependency, invoking GPU/inference, creating a paid provider resource, or enabling real voice generation, **stop that part and report it as Phase-B blocked rather than proceeding**.
