import { NextResponse } from 'next/server';
import { PrepareIdentityUploadInputSchema } from '@creator/contracts';
import { CreatorHttpError, creatorErrorResponse, readJsonBody, requireCreatorAuthority } from '../../../../../../../lib/server/authority';

type RouteContext = Readonly<{ params: Promise<{ profileId: string }> }>;

const VOICE_MIME = new Set(['audio/wav','audio/mpeg','audio/mp4','audio/x-m4a']);
const AVATAR_MIME = new Set(['video/mp4','video/quicktime','image/jpeg','image/png','image/webp']);

export async function POST(request: Request, context: RouteContext) {
  try {
    const { profileId } = await context.params;
    const parsed = PrepareIdentityUploadInputSchema.safeParse(await readJsonBody(request));
    if (!parsed.success) throw new CreatorHttpError(400, 'VALIDATION_FAILED', 'Upload details are invalid.');
    const { client, userId } = await requireCreatorAuthority();
    const { data: profile, error: profileError } = await client.from('creator_consent_profiles')
      .select('id,profile_kind,status,revoked_at,deleted_at').eq('id', profileId).maybeSingle();
    if (profileError || !profile) throw new CreatorHttpError(404, 'PROFILE_NOT_FOUND', 'Profile not found.');
    if (profile.revoked_at || profile.deleted_at || !['draft','active'].includes(profile.status)) throw new CreatorHttpError(409, 'PROFILE_NOT_AVAILABLE', 'Profile is not available for new samples.');
    const allowed = profile.profile_kind === 'voice' ? VOICE_MIME : AVATAR_MIME;
    if (!allowed.has(parsed.data.mimeType)) throw new CreatorHttpError(400, 'MIME_TYPE_NOT_ALLOWED', 'This media type is not allowed for the profile.');

    const objectPath = `${userId}/${profileId}/${parsed.data.clientRequestId}/${parsed.data.fileName}`;
    const { data, error } = await client.storage.from('creator-private').createSignedUploadUrl(objectPath, { upsert: false });
    if (error || !data?.token) throw new CreatorHttpError(502, 'SIGNED_UPLOAD_PREPARATION_FAILED', 'Private upload could not be prepared.');
    return NextResponse.json({ objectPath, token: data.token, expiresInSeconds: 7200 });
  } catch (error) { return creatorErrorResponse(error); }
}
