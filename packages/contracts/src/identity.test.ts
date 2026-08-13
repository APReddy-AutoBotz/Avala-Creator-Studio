import { describe, expect, it } from 'vitest';
import { ConfirmIdentityUploadInputSchema, PrepareIdentityUploadInputSchema } from './identity';

describe('identity upload contracts', () => {
  it('rejects nested/path-traversal filenames', () => {
    const base = { mimeType: 'audio/wav', byteLength: 1000, sha256: 'a'.repeat(64), clientRequestId: '11111111-1111-4111-8111-111111111111' };
    expect(PrepareIdentityUploadInputSchema.safeParse({ ...base, fileName: '../sample.wav' }).success).toBe(false);
    expect(PrepareIdentityUploadInputSchema.safeParse({ ...base, fileName: 'folder/sample.wav' }).success).toBe(false);
    expect(PrepareIdentityUploadInputSchema.safeParse({ ...base, fileName: 'sample.wav' }).success).toBe(true);
  });

  it('rejects public URL registration', () => {
    expect(ConfirmIdentityUploadInputSchema.safeParse({
      objectPath: 'https://example.com/sample.wav', mimeType: 'audio/wav', byteLength: 1000,
      sha256: 'b'.repeat(64), clientRequestId: '22222222-2222-4222-8222-222222222222',
    }).success).toBe(false);
  });
});
