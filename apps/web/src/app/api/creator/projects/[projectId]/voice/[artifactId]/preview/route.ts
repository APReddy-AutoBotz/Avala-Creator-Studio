import { NextResponse } from 'next/server';
import { VOICE_OUTPUT_BUCKET } from '@creator/contracts';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  CreatorHttpError,
  creatorErrorResponse,
  projectIdFromContext,
  requireCreatorAuthority,
  throwForRpcError,
} from '../../../../../../../../lib/server/authority';

export const dynamic = 'force-dynamic';

type RouteContext = Readonly<{ params: Promise<{ projectId: string; artifactId: string }> }>;

function validUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

async function currentPreviewPath(client: SupabaseClient, projectId: string, artifactId: string): Promise<string> {
  const { data: artifact, error } = await client
    .from('creator_artifacts')
    .select('id,project_id,kind,private_storage_path,identity_profile_id,stale_at')
    .eq('id', artifactId)
    .eq('project_id', projectId)
    .eq('kind', 'voice')
    .is('stale_at', null)
    .maybeSingle();
  throwForRpcError(error);
  if (!artifact || typeof artifact.private_storage_path !== 'string' || typeof artifact.identity_profile_id !== 'string') {
    throw new CreatorHttpError(404, 'ARTIFACT_BINDING_INVALID', 'Current voice artifact was not found.');
  }

  const { data: profile, error: profileError } = await client
    .from('creator_consent_profiles')
    .select('status,revoked_at,deleted_at')
    .eq('id', artifact.identity_profile_id)
    .maybeSingle();
  throwForRpcError(profileError);
  if (!profile || profile.status !== 'active' || profile.revoked_at || profile.deleted_at) {
    throw new CreatorHttpError(409, 'ACTIVE_VOICE_PROFILE_REQUIRED', 'The voice profile is no longer active.');
  }
  return artifact.private_storage_path;
}

export async function GET(_request: Request, context: RouteContext) {
  try {
    const projectId = await projectIdFromContext(context);
    const { artifactId } = await context.params;
    if (!validUuid(artifactId)) throw new CreatorHttpError(400, 'ARTIFACT_ID_INVALID', 'The artifact ID is invalid.');

    const { client } = await requireCreatorAuthority();
    const path = await currentPreviewPath(client, projectId, artifactId);

    // Download through the caller's authenticated Supabase client. Storage RLS therefore
    // evaluates the current artifact authority at byte-request time; no bearer signed URL
    // survives a later consent revocation.
    const { data: audio, error: downloadError } = await client.storage
      .from(VOICE_OUTPUT_BUCKET)
      .download(path);
    if (downloadError || !audio) {
      throw new CreatorHttpError(403, 'VOICE_PREVIEW_FORBIDDEN', 'Private voice preview is not available.');
    }

    // Close the profile-check/download race before returning bytes.
    const confirmedPath = await currentPreviewPath(client, projectId, artifactId);
    if (confirmedPath !== path) {
      throw new CreatorHttpError(409, 'ARTIFACT_BINDING_INVALID', 'Voice preview authority changed.');
    }

    return new Response(audio, {
      status: 200,
      headers: {
        'content-type': 'audio/wav',
        'cache-control': 'private, no-store, max-age=0, must-revalidate',
        'content-disposition': 'inline',
        'x-content-type-options': 'nosniff',
      },
    });
  } catch (error) {
    return creatorErrorResponse(error);
  }
}

// Preserve the human-click API shape while returning only a same-origin authenticated path,
// never a Storage bearer URL. The GET path revalidates authority when the audio bytes are read.
export async function POST(request: Request, context: RouteContext) {
  try {
    const projectId = await projectIdFromContext(context);
    const { artifactId } = await context.params;
    if (!validUuid(artifactId)) throw new CreatorHttpError(400, 'ARTIFACT_ID_INVALID', 'The artifact ID is invalid.');
    const { client } = await requireCreatorAuthority();
    await currentPreviewPath(client, projectId, artifactId);

    const url = new URL(request.url);
    url.search = '';
    url.searchParams.set('request', crypto.randomUUID());
    return NextResponse.json({
      artifactId,
      expiresInSeconds: 60,
      url: url.toString(),
      authority: 'authenticated_same_origin',
    });
  } catch (error) {
    return creatorErrorResponse(error);
  }
}
