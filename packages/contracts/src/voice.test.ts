import { describe, expect, it } from 'vitest';
import {
  VOICE_PROVIDER_CATALOG,
  VoiceGenerationRequestSchema,
  VoiceProviderCatalogEntrySchema,
  createDeterministicMockVoiceDraft,
  getVoiceProvider,
  isRealVoiceProviderExecutable,
} from './voice';

const request = VoiceGenerationRequestSchema.parse({
  script: {
    projectId: '11111111-1111-4111-8111-111111111111',
    artifactId: '22222222-2222-4222-8222-222222222222',
    artifactVersion: 2,
    artifactSha256: 'a'.repeat(64),
  },
  profileId: '33333333-3333-4333-8333-333333333333',
  providerId: 'mock',
  segments: [{
    id: 'segment-001', order: 0, text: 'Synthetic test narration.', language: 'en',
    pronunciations: [{ term: 'Avala', pronunciation: 'uh-VAH-luh', language: 'en', notation: 'plain' }],
  }],
  budget: { currency: 'USD', unit: 'job', maxCostMicrounits: 0, executionEnabled: true },
  humanTriggered: true,
  idempotencyKey: '44444444-4444-4444-8444-444444444444',
});

describe('M3 provider catalog', () => {
  it('keeps every real provider research-only, not installed, and execution-disabled', () => {
    const real = VOICE_PROVIDER_CATALOG.filter(provider => provider.id !== 'mock');
    expect(real).toHaveLength(4);
    for (const provider of real) {
      expect(provider.approvalState).toBe('research_only');
      expect(provider.installState).toBe('not_installed');
      expect(provider.costPolicy.executionEnabled).toBe(false);
      expect(provider.costPolicy.maxCostMicrounits).toBe(0);
      expect(isRealVoiceProviderExecutable(provider)).toBe(false);
    }
  });

  it('records the Phase-A champion and fallback without making them executable', () => {
    expect(getVoiceProvider('chatterbox_multilingual_v3').role).toBe('champion');
    expect(getVoiceProvider('chatterbox_multilingual_v3').capabilities.languages).toContain('hi');
    expect(getVoiceProvider('qwen3_tts_12hz_0_6b_base').role).toBe('fallback');
    expect(getVoiceProvider('qwen3_tts_12hz_0_6b_base').capabilities.languages).not.toContain('hi');
  });

  it('rejects a real provider catalog record that is malformed', () => {
    expect(VoiceProviderCatalogEntrySchema.safeParse({ ...getVoiceProvider('openvoice_v2'), capabilities: { languages: [] } }).success).toBe(false);
  });
});

describe('M3 voice request and mock adapter', () => {
  it('requires an explicit human trigger and immutable approved-script binding shape', () => {
    expect(VoiceGenerationRequestSchema.safeParse({ ...request, humanTriggered: false }).success).toBe(false);
    expect(VoiceGenerationRequestSchema.safeParse({ ...request, script: { ...request.script, artifactSha256: 'not-a-digest' } }).success).toBe(false);
  });

  it('rejects duplicate segment ids and orders', () => {
    const duplicate = { ...request, segments: [request.segments[0], { ...request.segments[0]!, text: 'Other' }] };
    expect(VoiceGenerationRequestSchema.safeParse(duplicate).success).toBe(false);
  });

  it('returns the same synthetic descriptor for exact replay and never creates media', async () => {
    const first = await createDeterministicMockVoiceDraft(request);
    const second = await createDeterministicMockVoiceDraft(request);
    expect(first).toEqual(second);
    expect(first.label).toBe('[SYNTHETIC MOCK VOICE DRAFT]');
    expect(first.generationMode).toBe('synthetic_mock');
    expect(first.mediaCreated).toBe(false);
  });

  it('refuses to run a real provider through the deterministic mock adapter', async () => {
    await expect(createDeterministicMockVoiceDraft({ ...request, providerId: 'chatterbox_multilingual_v3' })).rejects.toThrow('REAL_PROVIDER_EXECUTION_BLOCKED');
  });
});
