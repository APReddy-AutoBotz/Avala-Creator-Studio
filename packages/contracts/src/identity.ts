import { z } from 'zod';
import { IdentityProfileKindSchema, SampleStatusSchema } from './workflow';

export const ConsentProfileStatusSchema = z.enum(['draft', 'active', 'revoked', 'deleting', 'deleted']);
export type ConsentProfileStatus = z.infer<typeof ConsentProfileStatusSchema>;

export const SELF_OWNED_CONSENT = {
  voice: {
    version: 'self-owned-v1',
    text: 'I confirm that this is my own voice and authorize Avala Creator Studio to use the submitted sample only for my requested synthetic narration workflow.',
    sha256: '0b8f3516bacfbd4275c6f950e5ce9625f914db9916b77f08cf2264f28329d19b',
  },
  avatar: {
    version: 'self-owned-v1',
    text: 'I confirm that this is my own likeness and authorize Avala Creator Studio to use the submitted sample only for my requested synthetic avatar workflow.',
    sha256: '312d2299b85694391156bdc63daf9a21ea699b8ea4942d9be708185b22a194fa',
  },
} as const satisfies Record<z.infer<typeof IdentityProfileKindSchema>, Readonly<{ version: string; text: string; sha256: string }>>;

export const ConsentProfileViewSchema = z.object({
  id: z.string().uuid(),
  kind: IdentityProfileKindSchema,
  displayName: z.string().min(1).max(120),
  consentStatementVersion: z.string().min(1).max(64),
  consentSha256: z.string().regex(/^[a-f0-9]{64}$/),
  status: ConsentProfileStatusSchema,
  createdAt: z.string().datetime(),
  activatedAt: z.string().datetime().nullable(),
  revokedAt: z.string().datetime().nullable(),
  deletedAt: z.string().datetime().nullable(),
}).strict();
export type ConsentProfileView = z.infer<typeof ConsentProfileViewSchema>;

export const IdentitySampleViewSchema = z.object({
  id: z.string().uuid(), profileId: z.string().uuid(), mimeType: z.string().nullable(),
  byteLength: z.number().int().positive().nullable(), sha256: z.string().regex(/^[a-f0-9]{64}$/).nullable(),
  status: SampleStatusSchema, createdAt: z.string().datetime(), validatedAt: z.string().datetime().nullable(),
  rejectionCode: z.string().nullable(), deletedAt: z.string().datetime().nullable(),
}).strict();
export type IdentitySampleView = z.infer<typeof IdentitySampleViewSchema>;

export const PrepareIdentityUploadInputSchema = z.object({
  fileName: z.string().trim().min(1).max(120).regex(/^[A-Za-z0-9][A-Za-z0-9._-]*$/),
  mimeType: z.string().trim().min(1).max(120), byteLength: z.number().int().positive().max(250_000_000),
  sha256: z.string().regex(/^[a-f0-9]{64}$/), clientRequestId: z.string().uuid(),
}).strict();

export const ConfirmIdentityUploadInputSchema = z.object({ clientRequestId: z.string().uuid() }).strict();
export const ActivateConsentProfileInputSchema = z.object({ idempotencyKey: z.string().uuid() }).strict();
