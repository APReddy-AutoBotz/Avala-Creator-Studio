import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';
import { requireSupabaseConfig } from '../runtime';

export async function createCreatorSupabaseServerClient() {
  const config = requireSupabaseConfig();
  if (!config) throw new Error('SUPABASE_CLIENT_UNAVAILABLE_IN_MOCK_MODE');
  const cookieStore = await cookies();

  return createServerClient(config.url, config.key, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
        } catch {
          // Server Components cannot always write cookies; proxy.ts owns refresh writes.
        }
      },
    },
  });
}
