import { describe, expect, it } from 'vitest';
import {
  RequestVoiceJobInputSchema,
  SYNTHETIC_MOCK_VOICE_LABEL,
  VoiceArtifactMetadataSchema,
  VoiceCompletionInputSchema,
  VoiceRevisionInputSchema,
  expectedSyntheticVoiceObjectPath,
} from './voice-runtime';

describe('M3 B1 voice runtime contracts', () => {
  it('keeps the browser request caller-scoped and minimal', () => {
    expect(RequestVoiceJobInputSchema.safeParse({
      profileId: '11111111-1111-4111-8111-111111111111',
      idempotencyKey: '22222222-2222-4222-8222-222222222222',
    }).success).toBe(true);
    expect(RequestVoiceJobInputSchema.safeParse({
      profileId: '11111111-1111-4111-8111-111111111111',
      idempotencyKey: '22222222-2222-4222-8222-222222222222',
      ownerId: '33333333-3333-4333-8333-333333333333',
    }).success).toBe(false);
  });

  it('requires zero-cost labelled WAV completion evidence', () => {
    const result = VoiceCompletionInputSchema.safeParse({
      jobId: '11111111-1111-4111-8111-111111111111',
      leaseCapability: 'a'.repeat(64),
      completionIdempotencyKey: '22222222-2222-4222-8222-222222222222',
      objectPath: 'owner/project/job/output.wav',
      outputSha256: 'b'.repeat(64),
      byteLength: 32044,
      mimeType: 'audio/wav',
      durationMs: 1000,
      runtimeMs: 7,
      actualCostMicrounits: 0,
      syntheticLabel: SYNTHETIC_MOCK_VOICE_LABEL,
    });
    expect(result.success).toBe(true);
    expect(VoiceCompletionInputSchema.safeParse({
      ...result.success ? result.data : {},
      actualCostMicrounits: 1,
    }).success).toBe(false);
  });

  it('binds review metadata to the approved script and voice profile', () => {
    expect(VoiceArtifactMetadataSchema.safeParse({
      label: SYNTHETIC_MOCK_VOICE_LABEL,
      jobId: '11111111-1111-4111-8111-111111111111',
      generationMode: 'synthetic_mock',
      providerId: 'mock',
      providerModelId: 'none',
      providerModelRevision: 'm3-phase-a-v1',
      providerVerifiedAt: '2026-08-13',
      script: {
        projectId: '22222222-2222-4222-8222-222222222222',
        artifactId: '33333333-3333-4333-8333-333333333333',
        artifactVersion: 2,
        artifactSha256: 'c'.repeat(64),
      },
      profileId: '44444444-4444-4444-8444-444444444444',
      sampleIds: ['55555555-5555-4555-8555-555555555555'],
      voiceManifestSha256: 'd'.repeat(64),
      outputSha256: 'e'.repeat(64),
      byteLength: 32044,
      mimeType: 'audio/wav',
      durationMs: 1000,
      runtimeMs: 7,
      costMicrounits: 0,
      currency: 'USD',
    }).success).toBe(true);
  });

  it('requires a reason for voice revision', () => {
    expect(VoiceRevisionInputSchema.safeParse({
      artifactSha256: 'a'.repeat(64),
      reason: '',
      idempotencyKey: '11111111-1111-4111-8111-111111111111',
    }).success).toBe(false);
  });

  it('derives a private object path from immutable authority bindings', () => {
    expect(expectedSyntheticVoiceObjectPath({
      ownerId: '11111111-1111-4111-8111-111111111111',
      projectId: '22222222-2222-4222-8222-222222222222',
      jobId: '33333333-3333-4333-8333-333333333333',
      outputSha256: 'a'.repeat(64),
    })).toBe('11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333/' + 'a'.repeat(64) + '.wav');
  });
});
