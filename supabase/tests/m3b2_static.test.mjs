import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const adapter = readFileSync(new URL('../../services/render-worker/src/creator_worker/chatterbox_v3.py', import.meta.url), 'utf8');
const workerPyproject = readFileSync(new URL('../../services/render-worker/pyproject.toml', import.meta.url), 'utf8');
const manifest = JSON.parse(readFileSync(new URL('../../services/render-worker/real-provider/chatterbox-runtime.lock.json', import.meta.url), 'utf8'));
const dockerfile = readFileSync(new URL('../../services/render-worker/real-provider/Dockerfile.b2', import.meta.url), 'utf8');
const phaseA = readFileSync(new URL('../migrations/20260813124538_m3_voice_phase_a_authority.sql', import.meta.url), 'utf8');
const phaseAConstraints = readFileSync(new URL('../migrations/20260813124552_m3_voice_phase_a_constraints.sql', import.meta.url), 'utf8');

assert.match(adapter, /B2_EXECUTION_PERMANENTLY_DISABLED\s*=\s*True/);
assert.match(adapter, /REAL_INFERENCE_NOT_APPROVED_B2/);
assert.match(adapter, /def _load_runtime_class[\s\S]*import_module\(["']chatterbox\.mtl_tts["']\)/);
assert.match(adapter, /def generate[\s\S]*B2_EXECUTION_PERMANENTLY_DISABLED[\s\S]*_load_runtime_class/);
assert.doesNotMatch(adapter, /^\s*(?:from|import)\s+(?:chatterbox|torch|torchaudio|transformers|huggingface_hub)\b/m,
  'default module import must not load optional provider/runtime packages');
assert.doesNotMatch(adapter, /snapshot_download|from_pretrained\s*\(/,
  'B2 adapter must not expose runtime model download');

assert.equal(manifest.install_allowed, false);
assert.equal(manifest.inference_allowed, false);
assert.equal(manifest.supply_chain.runtime_model_download_allowed, false);
assert.equal(manifest.supply_chain.required_loader, 'ChatterboxMultilingualTTS.from_local');
assert.match(manifest.supply_chain.perth_candidate_pin, /^[a-f0-9]{40}$/);
assert.ok(manifest.model.assets.some(asset => asset.required && asset.sha256 === null),
  'B2 must stay blocked while required model-cache digests are incomplete');

assert.doesNotMatch(workerPyproject, /chatterbox|torch|torchaudio|transformers|huggingface_hub/i,
  'default/dev worker dependencies must remain lightweight in B2');
assert.match(dockerfile, /CREATOR_REAL_INFERENCE_APPROVED=false/);
assert.match(dockerfile, /CREATOR_MODEL_NETWORK_DOWNLOAD_ALLOWED=false/);
assert.doesNotMatch(dockerfile, /pip install[^\n]*(?:chatterbox|torch)|snapshot_download|huggingface\.co|wget|curl/i,
  'B2 readiness image must not install or download real provider/model artifacts');

assert.match(phaseA, /real_provider_execution_enabled boolean[\s\S]*check \(real_provider_execution_enabled = false\)/i,
  'database policy must structurally forbid real-provider execution');
assert.match(phaseA, /provider_id = 'mock'[\s\S]*approval_state = 'research_only'[\s\S]*install_state = 'not_installed'[\s\S]*execution_enabled = false/is,
  'non-mock providers must remain research-only/not-installed/disabled');
assert.doesNotMatch(phaseA + phaseAConstraints, /real_provider_execution_enabled\s*=\s*true/i);

console.log('M3 B2 real-provider readiness guardrails: PASS');
