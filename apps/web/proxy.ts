import type { NextRequest } from 'next/server';
import { updateCreatorSession } from './src/lib/supabase/proxy';

export async function proxy(request: NextRequest) {
  return updateCreatorSession(request);
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)'],
};
