import { z } from 'zod';
import { VoiceScriptBindingSchema } from './voice';

export const SYNTHETIC_MOCK_VOICE_LABEL = '[SYNTHETIC MOCK VOICE DRAFT]' as const;
export const VOICE_OUTPUT_BUCKET = 'creator-voice-output' as const;

export const RequestVoiceJobInputSchema = z.object({
  profileId: z.string().uuid(),
  idempotencyKey: z.string().uuid(),
}).strict();

export const VoiceCompletionInputSchema = z.object({
  jobId: z.string().uuid(),
  leaseCapability: z.string().regex(/^[a-f0-9]{64}$/),
  completionIdempotencyKey: z.string().uuid(),
  objectPath: z.string().min(1).max(500).regex(/^[A-Za-z0-9._/-]+$/),
  outputSha256: z.string().regex(/^[a-f0-9]{64}$/),
  byteLength: z.number().int().positive().max(25_000_000),
  mimeType: z.literal('audio/wav'),
  durationMs: z.number().int().min(100).max(600_000),
  runtimeMs: z.number().int().nonnegative().max(3_600_000),
  actualCostMicrounits: z.literal(0),
  syntheticLabel: z.literal(SYNTHETIC_MOCK_VOICE_LABEL),
}).strict();

export const VoiceReviewInputSchema = z.object({
  artifactSha256: z.string().regex(/^[a-f0-9]{64}$/),
  notes: z.string().trim().min(1).max(4000),
  idempotencyKey: z.string().uuid(),
}).strict();

export const VoiceRevisionInputSchema = z.object({
  artifactSha256: z.string().regex(/^[a-f0-9]{64}$/),
  reason: z.string().trim().min(1).max(4000),
  idempotencyKey: z.string().uuid(),
}).strict();

export const VoiceArtifactMetadataSchema = z.object({
  label: z.literal(SYNTHETIC_MOCK_VOICE_LABEL),
  jobId: z.string().uuid(),
  generationMode: z.literal('synthetic_mock'),
  providerId: z.literal('mock'),
  providerModelId: z.string().min(1).max(200),
  providerModelRevision: z.string().min(1).max(120).nullable(),
  providerVerifiedAt: z.string().date(),
  script: VoiceScriptBindingSchema,
  profileId: z.string().uuid(),
  sampleIds: z.array(z.string().uuid()).min(1),
  voiceManifestSha256: z.string().regex(/^[a-f0-9]{64}$/),
  outputSha256: z.string().regex(/^[a-f0-9]{64}$/),
  byteLength: z.number().int().positive(),
  mimeType: z.literal('audio/wav'),
  durationMs: z.number().int().positive(),
  runtimeMs: z.number().int().nonnegative(),
  costMicrounits: z.literal(0),
  currency: z.literal('USD'),
}).strict();

export const VoiceArtifactViewSchema = z.object({
  id: z.string().uuid(),
  projectId: z.string().uuid(),
  version: z.number().int().positive(),
  sha256: z.string().regex(/^[a-f0-9]{64}$/),
  profileId: z.string().uuid(),
  staleAt: z.string().datetime().nullable(),
  metadata: VoiceArtifactMetadataSchema,
  createdAt: z.string().datetime().nullable(),
}).strict();
export type VoiceArtifactView = z.infer<typeof VoiceArtifactViewSchema>;

export const VoicePreviewResponseSchema = z.object({
  artifactId: z.string().uuid(),
  expiresInSeconds: z.literal(60),
  url: z.string().url(),
}).strict();

export function expectedSyntheticVoiceObjectPath(input: Readonly<{
  ownerId: string;
  projectId: string;
  jobId: string;
  outputSha256: string;
}>): string {
  for (const value of [input.ownerId, input.projectId, input.jobId]) {
    if (!z.string().uuid().safeParse(value).success) throw new Error('VOICE_OBJECT_BINDING_INVALID');
  }
  if (!/^[a-f0-9]{64}$/.test(input.outputSha256)) throw new Error('VOICE_OUTPUT_DIGEST_INVALID');
  return `${input.ownerId}/${input.projectId}/${input.jobId}/${input.outputSha256}.wav`;
}
