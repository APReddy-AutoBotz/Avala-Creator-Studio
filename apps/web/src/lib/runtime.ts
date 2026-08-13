export type RuntimeMode = 'demo' | 'test' | 'preview' | 'production';

type CreatorEnvironment = Readonly<Partial<Record<
  | 'CREATOR_RUNTIME_MODE'
  | 'NEXT_PUBLIC_SUPABASE_URL'
  | 'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY',
  string | undefined
>>>;

export function runtimeMode(environment: CreatorEnvironment = process.env): RuntimeMode {
  const mode = environment.CREATOR_RUNTIME_MODE ?? 'production';
  if (!['demo', 'test', 'preview', 'production'].includes(mode)) throw new Error('INVALID_RUNTIME_MODE');
  return mode as RuntimeMode;
}

export function requireSupabaseConfig(environment: CreatorEnvironment = process.env) {
  const mode = runtimeMode(environment);
  if (mode === 'demo' || mode === 'test') return null;
  const url = environment.NEXT_PUBLIC_SUPABASE_URL;
  const key = environment.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) throw new Error('SUPABASE_CONFIGURATION_REQUIRED');
  return { url, key };
}
