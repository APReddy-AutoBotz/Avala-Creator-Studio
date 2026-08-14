import { describe, expect, it } from 'vitest';
import { voiceManifestSha256 } from './voice';

describe('B1 voice server bindings', () => {
  it('creates a stable manifest digest and changes when authority input changes', () => {
    const base = {
      projectId: '11111111-1111-4111-8111-111111111111',
      scriptArtifactId: '22222222-2222-4222-8222-222222222222',
      scriptVersion: 3,
      scriptSha256: 'a'.repeat(64),
      profileId: '33333333-3333-4333-8333-333333333333',
    };
    const first = voiceManifestSha256(base);
    expect(first).toMatch(/^[a-f0-9]{64}$/);
    expect(voiceManifestSha256(base)).toBe(first);
    expect(voiceManifestSha256({ ...base, scriptVersion: 4 })).not.toBe(first);
    expect(voiceManifestSha256({ ...base, profileId: '44444444-4444-4444-8444-444444444444' })).not.toBe(first);
  });
});
