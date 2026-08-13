import { NextResponse } from 'next/server';
import { RequestRevisionInputSchema } from '@creator/contracts';
import { CreatorHttpError, creatorErrorResponse, projectIdFromContext, readJsonBody, requireCreatorAuthority, serializeProject, throwForRpcError } from '../../../../../../lib/server/authority';

type RouteContext = Readonly<{ params: Promise<{ projectId: string }> }>;

export async function POST(request: Request, context: RouteContext) {
  try {
    const projectId = await projectIdFromContext(context);
    const parsed = RequestRevisionInputSchema.safeParse(await readJsonBody(request));
    if (!parsed.success) throw new CreatorHttpError(400, 'VALIDATION_FAILED', 'Revision request details are invalid.');
    const { client } = await requireCreatorAuthority();
    const { data, error } = await client.rpc('creator_request_revision', {
      p_project_id: projectId, p_target_kind: parsed.data.targetKind,
      p_reason: parsed.data.reason, p_idempotency_key: parsed.data.idempotencyKey,
    });
    throwForRpcError(error);
    return NextResponse.json({ project: serializeProject(data) });
  } catch (error) {
    return creatorErrorResponse(error);
  }
}
