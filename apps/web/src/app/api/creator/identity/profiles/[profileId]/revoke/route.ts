import { NextResponse } from 'next/server';
import { RevokeConsentProfileInputSchema } from '@creator/contracts';
import { CreatorHttpError, creatorErrorResponse, readJsonBody, requireCreatorAuthority, throwForRpcError } from '../../../../../../../lib/server/authority';

type RouteContext = Readonly<{ params: Promise<{ profileId: string }> }>;

export async function POST(request: Request, context: RouteContext) {
  try {
    const { profileId } = await context.params;
    const parsed = RevokeConsentProfileInputSchema.safeParse(await readJsonBody(request));
    if (!parsed.success) throw new CreatorHttpError(400, 'VALIDATION_FAILED', 'Revocation details are invalid.');
    const { client } = await requireCreatorAuthority();
    const { data, error } = await client.rpc('creator_revoke_consent_profile', { p_profile_id: profileId, p_reason: parsed.data.reason, p_idempotency_key: parsed.data.idempotencyKey });
    throwForRpcError(error);
    return NextResponse.json({ profile: data });
  } catch (error) { return creatorErrorResponse(error); }
}
