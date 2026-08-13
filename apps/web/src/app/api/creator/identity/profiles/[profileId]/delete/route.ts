import { NextResponse } from 'next/server';
import { DeleteConsentProfileInputSchema } from '@creator/contracts';
import { CreatorHttpError, creatorErrorResponse, readJsonBody, requireCreatorAuthority, throwForRpcError } from '../../../../../../../lib/server/authority';

type RouteContext = Readonly<{ params: Promise<{ profileId: string }> }>;

export async function POST(request: Request, context: RouteContext) {
  try {
    const { profileId } = await context.params;
    const parsed = DeleteConsentProfileInputSchema.safeParse(await readJsonBody(request));
    if (!parsed.success) throw new CreatorHttpError(400, 'VALIDATION_FAILED', 'Deletion details are invalid.');
    const { client } = await requireCreatorAuthority();
    const { data: samples, error: sampleError } = await client.from('creator_identity_samples').select('object_path').eq('profile_id', profileId).neq('status', 'deleted');
    if (sampleError) throwForRpcError(sampleError);
    const paths = (samples ?? []).map(item => item.object_path).filter((path): path is string => typeof path === 'string' && path.length > 0);
    if (paths.length) {
      const { error: storageError } = await client.storage.from('creator-private').remove(paths);
      if (storageError) throw new CreatorHttpError(502, 'PRIVATE_MEDIA_DELETE_FAILED', 'Private identity media could not be deleted.');
    }
    const { data, error } = await client.rpc('creator_delete_consent_profile', { p_profile_id: profileId, p_idempotency_key: parsed.data.idempotencyKey });
    throwForRpcError(error);
    return NextResponse.json({ deleted: true, profile: data });
  } catch (error) { return creatorErrorResponse(error); }
}
