import { describe, expect, it } from 'vitest';
import { ConfirmIdentityUploadInputSchema, ConsentProfileStatusSchema, PrepareIdentityUploadInputSchema, SELF_OWNED_CONSENT } from './identity';

describe('identity upload contracts', () => {
  it('rejects nested/path-traversal filenames', () => {
    const base={mimeType:'audio/wav',byteLength:1000,sha256:'a'.repeat(64),clientRequestId:'11111111-1111-4111-8111-111111111111'};
    expect(PrepareIdentityUploadInputSchema.safeParse({...base,fileName:'../sample.wav'}).success).toBe(false);
    expect(PrepareIdentityUploadInputSchema.safeParse({...base,fileName:'folder/sample.wav'}).success).toBe(false);
    expect(PrepareIdentityUploadInputSchema.safeParse({...base,fileName:'sample.wav'}).success).toBe(true);
  });
  it('confirms uploads by prepared request identity only', () => {
    expect(ConfirmIdentityUploadInputSchema.safeParse({clientRequestId:'22222222-2222-4222-8222-222222222222'}).success).toBe(true);
    expect(ConfirmIdentityUploadInputSchema.safeParse({clientRequestId:'22222222-2222-4222-8222-222222222222',objectPath:'https://example.com/bypass.wav'}).success).toBe(false);
  });
  it('pins governed consent statement versions and digests',()=>{
    expect(SELF_OWNED_CONSENT.voice.version).toBe('self-owned-v1');
    expect(SELF_OWNED_CONSENT.voice.sha256).toMatch(/^[a-f0-9]{64}$/);
    expect(SELF_OWNED_CONSENT.avatar.sha256).toMatch(/^[a-f0-9]{64}$/);
  });
  it('represents the two-phase deletion tombstone state',()=>{
    expect(ConsentProfileStatusSchema.parse('deleting')).toBe('deleting');
  });
});
