import { z } from 'zod';

export const VoiceProviderIdSchema = z.enum([
  'mock',
  'chatterbox_multilingual_v3',
  'qwen3_tts_12hz_0_6b_base',
  'fun_cosyvoice3_0_5b_2512',
  'openvoice_v2',
]);
export type VoiceProviderId = z.infer<typeof VoiceProviderIdSchema>;

export const VoiceProviderApprovalStateSchema = z.enum([
  'research_only',
  'approved_for_test',
  'approved_for_runtime',
  'disabled',
]);
export type VoiceProviderApprovalState = z.infer<typeof VoiceProviderApprovalStateSchema>;

export const VoiceProviderInstallStateSchema = z.enum(['not_installed', 'built_in', 'installed']);
export type VoiceProviderInstallState = z.infer<typeof VoiceProviderInstallStateSchema>;

export const VoiceProviderCapabilitySchema = z.object({
  languages: z.array(z.string().trim().min(2).max(16)).min(1),
  selfVoiceCloning: z.boolean(),
  crossLanguageCloning: z.boolean(),
  streaming: z.boolean(),
  pronunciationControl: z.boolean(),
  styleControl: z.boolean(),
  watermarking: z.boolean(),
  referenceTextRequired: z.boolean(),
  selfHostable: z.boolean(),
}).strict();
export type VoiceProviderCapability = z.infer<typeof VoiceProviderCapabilitySchema>;

export const VoiceCostPolicySchema = z.object({
  currency: z.enum(['USD']),
  unit: z.enum(['job']),
  maxCostMicrounits: z.number().int().min(0).max(1_000_000_000),
  executionEnabled: z.boolean(),
}).strict();
export type VoiceCostPolicy = z.infer<typeof VoiceCostPolicySchema>;

export const VoiceProviderCatalogEntrySchema = z.object({
  id: VoiceProviderIdSchema,
  displayName: z.string().trim().min(1).max(120),
  role: z.enum(['mock', 'champion', 'fallback', 'specialist', 'reference']),
  upstreamCodeId: z.string().trim().min(1).max(200),
  upstreamModelId: z.string().trim().min(1).max(200),
  codeLicenseSpdx: z.string().trim().min(1).max(64),
  modelLicenseSpdx: z.string().trim().min(1).max(64),
  verifiedAt: z.string().date(),
  modelRevision: z.string().trim().min(1).max(120).nullable(),
  approximateArtifactBytes: z.number().int().nonnegative().nullable(),
  approvalState: VoiceProviderApprovalStateSchema,
  installState: VoiceProviderInstallStateSchema,
  capabilities: VoiceProviderCapabilitySchema,
  costPolicy: VoiceCostPolicySchema,
}).strict();
export type VoiceProviderCatalogEntry = z.infer<typeof VoiceProviderCatalogEntrySchema>;

const REAL_PROVIDER_COMMON = {
  approvalState: 'research_only' as const,
  installState: 'not_installed' as const,
  costPolicy: { currency: 'USD' as const, unit: 'job' as const, maxCostMicrounits: 0, executionEnabled: false },
  verifiedAt: '2026-08-13',
  modelRevision: null,
};

export const VOICE_PROVIDER_CATALOG = VoiceProviderCatalogEntrySchema.array().parse([
  {
    id: 'mock', displayName: 'Deterministic synthetic mock', role: 'mock',
    upstreamCodeId: 'internal/deterministic-mock', upstreamModelId: 'none',
    codeLicenseSpdx: 'NOASSERTION', modelLicenseSpdx: 'NOASSERTION', verifiedAt: '2026-08-13',
    modelRevision: 'm3-phase-a-v1', approximateArtifactBytes: 0,
    approvalState: 'approved_for_test', installState: 'built_in',
    capabilities: {
      languages: ['und'], selfVoiceCloning: false, crossLanguageCloning: false, streaming: false,
      pronunciationControl: true, styleControl: true, watermarking: false, referenceTextRequired: false, selfHostable: true,
    },
    costPolicy: { currency: 'USD', unit: 'job', maxCostMicrounits: 0, executionEnabled: true },
  },
  {
    ...REAL_PROVIDER_COMMON,
    id: 'chatterbox_multilingual_v3', displayName: 'Chatterbox Multilingual V3', role: 'champion',
    upstreamCodeId: 'resemble-ai/chatterbox', upstreamModelId: 'ResembleAI/chatterbox',
    codeLicenseSpdx: 'MIT', modelLicenseSpdx: 'MIT', approximateArtifactBytes: 3_200_000_000,
    capabilities: {
      languages: ['ar','da','de','el','en','es','fi','fr','he','hi','it','ja','ko','ms','nl','no','pl','pt','ru','sv','sw','tr','zh'],
      selfVoiceCloning: true, crossLanguageCloning: true, streaming: false, pronunciationControl: false,
      styleControl: true, watermarking: true, referenceTextRequired: false, selfHostable: true,
    },
  },
  {
    ...REAL_PROVIDER_COMMON,
    id: 'qwen3_tts_12hz_0_6b_base', displayName: 'Qwen3-TTS 12Hz 0.6B Base', role: 'fallback',
    upstreamCodeId: 'QwenLM/Qwen3-TTS', upstreamModelId: 'Qwen/Qwen3-TTS-12Hz-0.6B-Base',
    codeLicenseSpdx: 'Apache-2.0', modelLicenseSpdx: 'Apache-2.0', approximateArtifactBytes: 2_520_000_000,
    capabilities: {
      languages: ['zh','en','ja','ko','de','fr','ru','pt','es','it'], selfVoiceCloning: true,
      crossLanguageCloning: true, streaming: true, pronunciationControl: false, styleControl: true,
      watermarking: false, referenceTextRequired: false, selfHostable: true,
    },
  },
  {
    ...REAL_PROVIDER_COMMON,
    id: 'fun_cosyvoice3_0_5b_2512', displayName: 'Fun-CosyVoice3 0.5B', role: 'specialist',
    upstreamCodeId: 'FunAudioLLM/CosyVoice', upstreamModelId: 'FunAudioLLM/Fun-CosyVoice3-0.5B-2512',
    codeLicenseSpdx: 'Apache-2.0', modelLicenseSpdx: 'Apache-2.0', approximateArtifactBytes: 9_750_000_000,
    capabilities: {
      languages: ['zh','en','ja','ko','de','es','fr','it','ru'], selfVoiceCloning: true,
      crossLanguageCloning: true, streaming: true, pronunciationControl: true, styleControl: true,
      watermarking: false, referenceTextRequired: false, selfHostable: true,
    },
  },
  {
    ...REAL_PROVIDER_COMMON,
    id: 'openvoice_v2', displayName: 'OpenVoice V2', role: 'reference',
    upstreamCodeId: 'myshell-ai/OpenVoice', upstreamModelId: 'myshell-ai/OpenVoiceV2',
    codeLicenseSpdx: 'MIT', modelLicenseSpdx: 'MIT', approximateArtifactBytes: null,
    capabilities: {
      languages: ['en','es','fr','zh','ja','ko'], selfVoiceCloning: true, crossLanguageCloning: true,
      streaming: false, pronunciationControl: false, styleControl: true, watermarking: false,
      referenceTextRequired: false, selfHostable: true,
    },
  },
]);

export const VoiceScriptBindingSchema = z.object({
  projectId: z.string().uuid(),
  artifactId: z.string().uuid(),
  artifactVersion: z.number().int().positive(),
  artifactSha256: z.string().regex(/^[a-f0-9]{64}$/),
}).strict();
export type VoiceScriptBinding = z.infer<typeof VoiceScriptBindingSchema>;

export const VoicePronunciationEntrySchema = z.object({
  term: z.string().trim().min(1).max(160),
  pronunciation: z.string().trim().min(1).max(320),
  language: z.string().trim().min(2).max(16),
  notation: z.enum(['plain', 'phoneme', 'ipa', 'cmu', 'pinyin']),
  notes: z.string().trim().max(500).optional(),
  source: z.string().trim().max(200).optional(),
}).strict();
export type VoicePronunciationEntry = z.infer<typeof VoicePronunciationEntrySchema>;

export const VoiceSegmentSchema = z.object({
  id: z.string().trim().min(1).max(80).regex(/^[A-Za-z0-9._-]+$/),
  order: z.number().int().min(0).max(10_000),
  text: z.string().trim().min(1).max(12_000),
  language: z.string().trim().min(2).max(16),
  pace: z.number().min(0.5).max(2).optional(),
  styleIntent: z.string().trim().max(240).optional(),
  pronunciations: z.array(VoicePronunciationEntrySchema).max(100).default([]),
}).strict();
export type VoiceSegment = z.infer<typeof VoiceSegmentSchema>;

export const VoiceGenerationRequestSchema = z.object({
  script: VoiceScriptBindingSchema,
  profileId: z.string().uuid(),
  providerId: VoiceProviderIdSchema,
  segments: z.array(VoiceSegmentSchema).min(1).max(500).superRefine((segments, ctx) => {
    const ids = new Set<string>();
    const orders = new Set<number>();
    for (const segment of segments) {
      if (ids.has(segment.id)) ctx.addIssue({ code: 'custom', message: 'Duplicate segment id.' });
      if (orders.has(segment.order)) ctx.addIssue({ code: 'custom', message: 'Duplicate segment order.' });
      ids.add(segment.id); orders.add(segment.order);
    }
  }),
  budget: VoiceCostPolicySchema,
  humanTriggered: z.literal(true),
  idempotencyKey: z.string().uuid(),
}).strict();
export type VoiceGenerationRequest = z.infer<typeof VoiceGenerationRequestSchema>;

export const VoiceArtifactProvenanceSchema = z.object({
  providerId: VoiceProviderIdSchema,
  providerModelId: z.string().min(1).max(200),
  providerModelRevision: z.string().min(1).max(120).nullable(),
  providerModelChecksum: z.string().regex(/^[a-f0-9]{64}$/).nullable(),
  script: VoiceScriptBindingSchema,
  profileId: z.string().uuid(),
  sampleIds: z.array(z.string().uuid()).min(1),
  outputSha256: z.string().regex(/^[a-f0-9]{64}$/),
  generationMode: z.enum(['synthetic_mock', 'real_provider']),
  generatedAt: z.string().datetime(),
  durationMs: z.number().int().nonnegative().nullable(),
  costMicrounits: z.number().int().nonnegative(),
  currency: z.enum(['USD']),
}).strict();
export type VoiceArtifactProvenance = z.infer<typeof VoiceArtifactProvenanceSchema>;

export const MockVoiceDraftDescriptorSchema = z.object({
  label: z.literal('[SYNTHETIC MOCK VOICE DRAFT]'),
  providerId: z.literal('mock'),
  generationMode: z.literal('synthetic_mock'),
  requestId: z.string().uuid(),
  segmentCount: z.number().int().positive(),
  descriptorSha256: z.string().regex(/^[a-f0-9]{64}$/),
  mediaCreated: z.literal(false),
}).strict();
export type MockVoiceDraftDescriptor = z.infer<typeof MockVoiceDraftDescriptorSchema>;

function bytesToHex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), value => value.toString(16).padStart(2, '0')).join('');
}

export async function createDeterministicMockVoiceDraft(input: VoiceGenerationRequest): Promise<MockVoiceDraftDescriptor> {
  const request = VoiceGenerationRequestSchema.parse(input);
  if (request.providerId !== 'mock') throw new Error('REAL_PROVIDER_EXECUTION_BLOCKED');
  const material = JSON.stringify({
    label: '[SYNTHETIC MOCK VOICE DRAFT]',
    script: request.script,
    profileId: request.profileId,
    segments: [...request.segments].sort((a, b) => a.order - b.order),
    idempotencyKey: request.idempotencyKey,
  });
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(material));
  return MockVoiceDraftDescriptorSchema.parse({
    label: '[SYNTHETIC MOCK VOICE DRAFT]', providerId: 'mock', generationMode: 'synthetic_mock',
    requestId: request.idempotencyKey, segmentCount: request.segments.length,
    descriptorSha256: bytesToHex(digest), mediaCreated: false,
  });
}

export function getVoiceProvider(providerId: VoiceProviderId): VoiceProviderCatalogEntry {
  const provider = VOICE_PROVIDER_CATALOG.find(entry => entry.id === providerId);
  if (!provider) throw new Error('VOICE_PROVIDER_NOT_FOUND');
  return provider;
}

export function isRealVoiceProviderExecutable(provider: VoiceProviderCatalogEntry): boolean {
  return provider.id !== 'mock'
    && provider.approvalState === 'approved_for_runtime'
    && provider.installState === 'installed'
    && provider.costPolicy.executionEnabled
    && provider.costPolicy.maxCostMicrounits > 0;
}
