import { describe, expect, it } from 'vitest';
import {
  RealProviderManifestSchema,
  RealProviderPreflightRequestSchema,
  RealProviderPreflightResultSchema,
} from './real-provider-readiness';

const UUID_A = '11111111-1111-4111-8111-111111111111';
const UUID_B = '22222222-2222-4222-8222-222222222222';
const UUID_C = '33333333-3333-4333-8333-333333333333';
const UUID_D = '44444444-4444-4444-8444-444444444444';

describe('real-provider readiness contracts', () => {
  it('requires an explicitly non-executable B2 manifest', () => {
    const parsed = RealProviderManifestSchema.parse({
      schemaVersion: 1,
      providerId: 'chatterbox_multilingual_v3',
      packageName: 'chatterbox-tts',
      packageVersion: '0.1.7',
      modelId: 'ResembleAI/chatterbox',
      modelVariant: 't3_mtl23ls_v3.safetensors',
      perthCommit: 'c'.repeat(40),
      installAllowed: false,
      inferenceAllowed: false,
      runtimeModelDownloadAllowed: false,
      assets: [{ path: 've.pt', sha256: 'a'.repeat(64), required: true }],
    });
    expect(parsed.installAllowed).toBe(false);
    expect(parsed.inferenceAllowed).toBe(false);
    expect(parsed.runtimeModelDownloadAllowed).toBe(false);
  });

  it('rejects a request whose estimate exceeds the human-approved budget', () => {
    const result = RealProviderPreflightRequestSchema.safeParse({
      providerId: 'chatterbox_multilingual_v3',
      language: 'en',
      projectId: UUID_A,
      scriptArtifactId: UUID_B,
      scriptSha256: 'a'.repeat(64),
      profileId: UUID_C,
      voiceSampleIds: [UUID_D],
      humanTriggered: true,
      maxCostMicrounits: 10,
      estimatedCostMicrounits: 11,
      manifestSha256: 'b'.repeat(64),
    });
    expect(result.success).toBe(false);
  });

  it('cannot represent an executable B2 preflight result', () => {
    const base = {
      providerId: 'chatterbox_multilingual_v3',
      packageVersion: '0.1.7',
      modelId: 'ResembleAI/chatterbox',
      modelVariant: 't3_mtl23ls_v3.safetensors',
      language: 'en',
      structurallyReady: true,
      blockers: ['REAL_INFERENCE_NOT_APPROVED_B2'],
    } as const;
    expect(RealProviderPreflightResultSchema.safeParse({ ...base, executionAllowed: false }).success).toBe(true);
    expect(RealProviderPreflightResultSchema.safeParse({ ...base, executionAllowed: true }).success).toBe(false);
  });
});
