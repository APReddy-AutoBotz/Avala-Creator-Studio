import { describe, expect, it } from 'vitest';
import { requireSupabaseConfig, runtimeMode } from './runtime';

describe('runtime configuration', () => {
  it('permits deterministic demo and test modes without cloud credentials', () => {
    expect(requireSupabaseConfig({ CREATOR_RUNTIME_MODE: 'demo' })).toBeNull();
    expect(requireSupabaseConfig({ CREATOR_RUNTIME_MODE: 'test' })).toBeNull();
  });

  it('fails closed outside authorized mock modes', () => {
    expect(() => requireSupabaseConfig({ CREATOR_RUNTIME_MODE: 'preview' })).toThrow('SUPABASE_CONFIGURATION_REQUIRED');
    expect(() => requireSupabaseConfig({ CREATOR_RUNTIME_MODE: 'production' })).toThrow('SUPABASE_CONFIGURATION_REQUIRED');
    expect(() => runtimeMode({ CREATOR_RUNTIME_MODE: 'development' })).toThrow('INVALID_RUNTIME_MODE');
  });

  it('accepts the current publishable-key configuration in preview', () => {
    expect(requireSupabaseConfig({
      CREATOR_RUNTIME_MODE: 'preview',
      NEXT_PUBLIC_SUPABASE_URL: 'https://project.supabase.co',
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_example',
    })).toEqual({ url: 'https://project.supabase.co', key: 'sb_publishable_example' });
  });
});
