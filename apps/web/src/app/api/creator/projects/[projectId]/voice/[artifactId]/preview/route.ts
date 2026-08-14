import { NextResponse } from 'next/server';
import { VOICE_OUTPUT_BUCKET, VoicePreviewResponseSchema } from '@creator/contracts';
import {
  CreatorHttpError,
  creatorErrorResponse,
  projectIdFromContext,
  requireCreatorAuthority,
  throwForRpcError,
} from '../../../../../../../../lib/server/authority';

type RouteContext = Readonly<{ params: Promise<{ projectId: string; artifactId: string }> }>;

function validUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

export async function POST(_request: Request, context: RouteContext) {
  try {
    const projectId = await projectIdFromContext(context);
    const { artifactId } = await context.params;
    if (!validUuid(artifactId)) throw new CreatorHttpError(400, 'ARTIFACT_ID_INVALID', 'The artifact ID is invalid.');

    const { client } = await requireCreatorAuthority();
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

    const { data, error: signedError } = await client.storage
      .from(VOICE_OUTPUT_BUCKET)
      .createSignedUrl(artifact.private_storage_path, 60);
    if (signedError || !data?.signedUrl) {
      throw new CreatorHttpError(403, 'VOICE_PREVIEW_FORBIDDEN', 'Private voice preview is not available.');
    }

    return NextResponse.json(VoicePreviewResponseSchema.parse({
      artifactId,
      expiresInSeconds: 60,
      url: data.signedUrl,
    }));
  } catch (error) {
    return creatorErrorResponse(error);
  }
}
