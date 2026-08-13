import { z } from 'zod';
import { IdentityProfileKindSchema, SampleStatusSchema } from './workflow';

export const ConsentProfileStatusSchema = z.enum(['draft', 'active', 'revoked', 'deleted']);
export type ConsentProfileStatus = z.infer<typeof ConsentProfileStatusSchema>;

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
  id: z.string().uuid(),
  profileId: z.string().uuid(),
  mimeType: z.string().nullable(),
  byteLength: z.number().int().positive().nullable(),
  sha256: z.string().regex(/^[a-f0-9]{64}$/).nullable(),
  status: SampleStatusSchema,
  createdAt: z.string().datetime(),
  validatedAt: z.string().datetime().nullable(),
  rejectionCode: z.string().nullable(),
  deletedAt: z.string().datetime().nullable(),
}).strict();
export type IdentitySampleView = z.infer<typeof IdentitySampleViewSchema>;

export const PrepareIdentityUploadInputSchema = z.object({
  fileName: z.string().trim().min(1).max(120).regex(/^[A-Za-z0-9][A-Za-z0-9._-]*$/),
  mimeType: z.string().trim().min(1).max(120),
  byteLength: z.number().int().positive().max(250_000_000),
  sha256: z.string().regex(/^[a-f0-9]{64}$/),
  clientRequestId: z.string().uuid(),
}).strict();

export const ConfirmIdentityUploadInputSchema = z.object({
  objectPath: z.string().trim().min(1).max(512)
    .refine(value => !value.startsWith('/') && !value.includes('..') && !/^https?:\/\//i.test(value), 'Private relative object path required.'),
  mimeType: z.string().trim().min(1).max(120),
  byteLength: z.number().int().positive().max(250_000_000),
  sha256: z.string().regex(/^[a-f0-9]{64}$/),
  clientRequestId: z.string().uuid(),
}).strict();

export const ActivateConsentProfileInputSchema = z.object({ idempotencyKey: z.string().uuid() }).strict();
