import { z } from 'zod';

export const RealProviderAssetSchema = z.object({
  path: z.string().min(1).max(240),
  sha256: z.string().regex(/^[a-f0-9]{64}$/).nullable(),
  required: z.boolean(),
}).strict();

export const RealProviderManifestSchema = z.object({
  schemaVersion: z.literal(1),
  providerId: z.literal('chatterbox_multilingual_v3'),
  packageName: z.literal('chatterbox-tts'),
  packageVersion: z.string().min(1).max(40),
  modelId: z.literal('ResembleAI/chatterbox'),
  modelVariant: z.literal('t3_mtl23ls_v3.safetensors'),
  perthCommit: z.string().regex(/^[a-f0-9]{40}$/).nullable(),
  installAllowed: z.boolean(),
  inferenceAllowed: z.boolean(),
  runtimeModelDownloadAllowed: z.boolean(),
  assets: z.array(RealProviderAssetSchema).min(1),
}).strict();
export type RealProviderManifest = z.infer<typeof RealProviderManifestSchema>;

export const RealProviderDeviceSchema = z.object({
  kind: z.enum(['cuda', 'cpu', 'mps', 'unknown']),
  available: z.boolean(),
  name: z.string().min(1).max(160).nullable(),
  vramMb: z.number().int().nonnegative().nullable(),
}).strict();
export type RealProviderDevice = z.infer<typeof RealProviderDeviceSchema>;

export const RealProviderPreflightRequestSchema = z.object({
  providerId: z.literal('chatterbox_multilingual_v3'),
  language: z.string().trim().min(2).max(8),
  projectId: z.string().uuid(),
  scriptArtifactId: z.string().uuid(),
  scriptSha256: z.string().regex(/^[a-f0-9]{64}$/),
  profileId: z.string().uuid(),
  voiceSampleIds: z.array(z.string().uuid()).min(1),
  humanTriggered: z.literal(true),
  maxCostMicrounits: z.number().int().nonnegative(),
  estimatedCostMicrounits: z.number().int().nonnegative(),
  manifestSha256: z.string().regex(/^[a-f0-9]{64}$/),
}).strict().superRefine((value, context) => {
  if (value.estimatedCostMicrounits > value.maxCostMicrounits) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ['estimatedCostMicrounits'],
      message: 'estimated cost exceeds the approved budget',
    });
  }
});
export type RealProviderPreflightRequest = z.infer<typeof RealProviderPreflightRequestSchema>;

export const RealProviderPreflightResultSchema = z.object({
  providerId: z.literal('chatterbox_multilingual_v3'),
  packageVersion: z.string().min(1),
  modelId: z.literal('ResembleAI/chatterbox'),
  modelVariant: z.literal('t3_mtl23ls_v3.safetensors'),
  language: z.string().min(2),
  structurallyReady: z.boolean(),
  executionAllowed: z.literal(false),
  blockers: z.array(z.string().min(1)).min(1),
}).strict();
export type RealProviderPreflightResult = z.infer<typeof RealProviderPreflightResultSchema>;

export const RealProviderOutputEvidenceSchema = z.object({
  providerId: z.literal('chatterbox_multilingual_v3'),
  packageVersion: z.string().min(1),
  modelId: z.literal('ResembleAI/chatterbox'),
  modelVariant: z.literal('t3_mtl23ls_v3.safetensors'),
  modelManifestSha256: z.string().regex(/^[a-f0-9]{64}$/),
  runtimeImageDigest: z.string().regex(/^sha256:[a-f0-9]{64}$/),
  scriptArtifactId: z.string().uuid(),
  scriptSha256: z.string().regex(/^[a-f0-9]{64}$/),
  profileId: z.string().uuid(),
  sampleIds: z.array(z.string().uuid()).min(1),
  outputSha256: z.string().regex(/^[a-f0-9]{64}$/),
  runtimeMs: z.number().int().nonnegative(),
  actualCostMicrounits: z.number().int().nonnegative(),
}).strict();
export type RealProviderOutputEvidence = z.infer<typeof RealProviderOutputEvidenceSchema>;
