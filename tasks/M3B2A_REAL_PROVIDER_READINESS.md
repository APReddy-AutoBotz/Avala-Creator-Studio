# M3 Phase B2A — Real Voice Provider Deployment Readiness

Issue: #8

## Outcome

Prepare Avala Creator Studio to deploy a real self-owned voice-cloning provider later, without downloading model weights, running inference, creating paid GPU resources, calling hosted TTS, or generating real voice media in this milestone.

The current champion is `chatterbox_multilingual_v3`; `qwen3_tts_12hz_0_6b_base` remains the fallback. B2A may verify manifests and readiness metadata only. It must not import, install, download, initialize, execute, benchmark, or warm either provider.

## Non-negotiable boundaries

1. Real-provider execution remains disabled in every runtime policy and database row.
2. No model weights, model cache, generated audio, voice samples, embeddings, tokens, API keys, signed URLs, or secrets enter Git.
3. Do not add executable imports for Chatterbox, PyTorch, Transformers, Hugging Face Hub, Qwen TTS, CosyVoice or OpenVoice.
4. Do not create a GPU instance, paid hosted endpoint, always-on worker, or provider account.
5. Do not enable `approved_for_runtime`, `execution_enabled=true`, `real_provider_execution_enabled=true`, or an equivalent bypass.
6. A real-provider job must remain fail-closed and auditable in B2A.
7. Only self-owned, active voice consent profiles with validated samples may ever be eligible for a later real-provider gate.
8. Every future real request remains explicitly human-triggered and bound to the exact latest approved script version/digest.
9. Keep PR Draft. Do not merge this stacked milestone.

## Current authority baseline that must not regress

- B1 exact base: `d7003e77b71c035c348dbd3d6c08a0915525877d`.
- Live runtime safe state: research mode; mock creation disabled; real execution disabled.
- Private voice output and deletion ledger are authoritative.
- Human request/revision public gateways use `SECURITY INVOKER` with exact private implementation privileges.
- Worker gateways are service-role-only.
- Exact replay/idempotency, consent/profile locks, current-script approval, lease capability, private Storage, human approval, and deletion reconciliation remain mandatory.
- No bearer signed URL may be introduced for voice review media.

## Required implementation

### 1. Shared provider execution contracts

Add strict TypeScript/Zod contracts for a future real provider adapter. At minimum define:

- `ProviderRuntimeManifest`
  - provider ID
  - provider role
  - upstream code repository ID
  - upstream model repository ID
  - code license SPDX
  - model license SPDX
  - immutable upstream revision/commit
  - model revision/commit
  - expected model files with SHA-256 values
  - runtime image reference plus immutable image digest
  - runtime package/version evidence
  - required accelerator class and minimum VRAM as declared deployment requirements, not detected hardware
  - supported languages/capabilities
  - verification timestamp
  - readiness state
- Readiness states that cannot jump directly from research metadata to executable runtime. Use an explicit progression such as `research_only -> manifest_verified -> deployment_ready_disabled`; B2A must never introduce an executable `ready_enabled` state.
- `RealVoiceGenerationRequest` bound to:
  - owner-authorized profile ID
  - validated sample IDs
  - exact approved script artifact ID/version/SHA-256
  - language
  - pronunciation overrides
  - provider/model manifest fingerprint
  - human trigger evidence
  - idempotency key
  - hard max-cost microunits
- `RealVoiceGenerationResult` contract for future use only: private object path, digest, byte length, duration, runtime, actual cost, provider/model provenance and disclosure metadata.
- Deterministic manifest/fingerprint helpers with tests.

No B2A code may create a real `RealVoiceGenerationResult`.

### 2. Python provider adapter boundary — disabled implementation only

Add a provider interface that a future worker can implement, plus a `ChatterboxV3Provider` readiness adapter that performs metadata/configuration validation only.

Allowed in B2A:

- parse/validate a checked-in provider manifest
- verify that immutable revision/checksum fields are structurally present
- validate required environment-variable names without reading or logging secret values
- return a readiness report such as `configured=false`, `weights_present=false`, `execution_enabled=false`
- fail closed if asked to generate

Forbidden in B2A:

- import or dynamically import provider/model libraries
- call package installers
- download weights
- probe CUDA/MPS/ROCm hardware
- make network requests to model hubs
- synthesize speech
- inspect/use identity sample bytes

Provide deterministic unit tests proving generation always fails with a stable code such as `REAL_PROVIDER_EXECUTION_DISABLED_B2A`.

### 3. Provider provenance and deployment manifests

Create reviewed, non-secret manifests/docs for the Chatterbox champion and Qwen fallback.

For the champion, record current verified upstream evidence in data fields, but leave weight checksum entries explicitly unresolved until B2B if the actual immutable files have not been downloaded and hashed by an approved process. An unresolved checksum must prevent `deployment_ready_disabled` from becoming executable.

Add a deployment specification for a future scale-to-zero GPU worker:

- no weights baked into source Git
- no secrets baked into images
- immutable container image digest required before use
- private model/cache volume or provider-managed cache described but not provisioned
- worker starts only for an approved job and may scale to zero
- hard job timeout and idle shutdown
- egress restricted to the minimum required endpoints in B2B
- private Supabase object exchange via short-lived server authority, never public buckets
- health endpoint distinguishes process health from model readiness
- readiness endpoint must remain `blocked` in B2A
- no always-on GPU

Do not create vendor-specific paid infrastructure in B2A.

### 4. Live authority schema — readiness metadata only

Add an additive Supabase migration that extends the private provider authority without allowing real execution.

The schema should support:

- immutable provider runtime manifest records/fingerprints
- manifest verification status and reason
- deployment artifact/image digest evidence
- per-provider B2A readiness state
- per-job hard budget evidence for future real jobs
- a monthly real-provider budget policy/ledger capable of failing closed before execution
- human-trigger evidence and provider-manifest binding for future requests
- service-role-only readiness/preflight RPC if useful
- auditable denial codes for real-provider requests while B2A is active

Critical requirements:

- Chatterbox remains `research_only` or equivalent non-executable state.
- Qwen remains non-executable.
- Existing Phase A/B1 real-provider denial behavior must continue.
- No authenticated caller can mutate provider readiness or budgets directly.
- No service-role path can flip execution on without a future B2B migration.
- Database constraints must make `real_provider_execution_enabled=true` impossible in B2A.
- Preserve owner/profile/project/job lock order and idempotency conventions.
- Any new private functions require explicit role-scoped privileges; avoid public authenticated `SECURITY DEFINER` advisor warnings.

### 5. Cost governance

Add B2A cost controls without spending money:

- hard per-job maximum expressed in integer microunits
- monthly budget cap and monthly consumed/reserved ledger semantics
- reservation/release/finalization contract for a future real job
- exact idempotency/replay rules
- no negative or over-cap states
- no accepted real job unless a future executable provider gate exists

Tests must prove budget authority cannot itself make a provider executable.

Create `docs/M3B2A_COST_GATE.md` that defines the future B2B cost decision. B2B must obtain current GPU/provider pricing and explicit cost approval before any billable resource is created or inference is run.

### 6. Privacy and deletion boundary

Document and enforce the future data path:

`private validated self-owned sample -> approved script -> ephemeral worker authority -> provider runtime -> private output -> B1 review/deletion lifecycle`

B2A must specify:

- whether reference samples ever leave Supabase Storage
- max signed/server-authority lifetime
- no logs containing sample paths/URLs/tokens/text marked confidential
- no persistent voice embedding unless separately approved
- temporary worker files must have bounded retention and deletion evidence
- provider/model caches must contain models only, never user identity media
- revocation/deletion before a future job starts must fail closed
- in-flight cancellation/revocation semantics must be defined for B2B

Create/update a focused threat model for sample exfiltration, stale consent, replay, provider compromise, output orphaning, model/cache contamination and cost abuse.

### 7. Readiness APIs/UI — evidence only

If a UI/API surface is added, it may show only provider readiness evidence and why execution is blocked. It must not contain a `Generate real voice` control in B2A.

Recommended status display:

- Provider: Chatterbox Multilingual V3
- License evidence: verified/current date
- Manifest: complete/incomplete
- Model files/checksums: unresolved until B2B
- Runtime image: not built/not verified
- GPU: not provisioned
- Real execution: disabled
- Estimated/actual spend: $0

### 8. Static and runtime regression coverage

Add permanent CI guards proving:

- no executable imports of real TTS/model/GPU libraries
- no model/media extensions or weight files are committed
- no runtime/provider execution flag is true
- no `approved_for_runtime` state is introduced
- no provider API key/secrets are required for B2A tests
- no external provider URL is invoked by tests
- manifest readiness cannot pass without immutable revision/checksum/image evidence
- real requests remain denied and audited
- monthly/per-job budget authority fails closed and is idempotent
- human approval/review authority from B1 remains unchanged
- private Storage/deletion lifecycle remains unchanged

Run all existing JS/TS/Python/static/build checks plus new B2A tests.

## Live Supabase acceptance tests expected from controller after Codex implementation

Do not claim these unless actually executed on the dedicated `Avala Creator Studio` preview:

1. apply migration and reconcile assigned version to GitHub
2. security advisor = 0 findings
3. no structural performance warnings other than acceptable unused-index INFO
4. generated DB types include new readiness/budget RPCs/tables
5. authenticated user cannot mutate provider readiness/budget policy directly
6. cross-user access is denied
7. service-role readiness preflight remains non-executable for real provider
8. real-provider request produces stable denial/audit and zero job/output side effects
9. budget reservation cannot make execution possible
10. runtime policy ends in research mode with both execution switches false
11. real-provider voice jobs remain zero

## B2B gate document

Create `docs/M3B2B_FIRST_REAL_INFERENCE_GATE.md` defining the explicit future go/no-go requirements before the first real voice inference. It must require, at minimum:

- re-verify code/model license and immutable revisions immediately before use
- verify actual model files and SHA-256 values
- verify container image digest and SBOM/dependency scan
- choose GPU provider/region only after current price lookup
- state exact hourly/per-job/monthly maximum cost
- explicit cost approval before any billable resource
- confirm self-owned voice consent and approved sample
- confirm data-flow/retention/deletion behavior
- one bounded test sentence only for first inference
- human review before any additional run
- rollback/kill-switch procedure

## Acceptance evidence required in the Codex result

- exact head SHA
- changed-file list
- all test/build commands and exact results
- migration list and SQL authority summary
- dependency/license impact
- cost impact = zero for B2A
- proof no model/provider package or weights were installed/downloaded
- proof no real inference was attempted
- known limitations and B2B blockers

Keep the PR Draft and do not merge.