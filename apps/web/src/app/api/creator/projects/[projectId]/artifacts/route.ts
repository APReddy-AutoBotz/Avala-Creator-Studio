import { NextResponse } from 'next/server';
import { CreateArtifactVersionInputSchema } from '@creator/contracts';
import { CreatorHttpError, creatorErrorResponse, projectIdFromContext, readJsonBody, readRpcEnvelope, requireCreatorAuthority, throwForRpcError } from '../../../../../../lib/server/authority';

type RouteContext = Readonly<{ params: Promise<{ projectId: string }> }>;

export async function POST(request: Request, context: RouteContext) {
  try {
    const projectId = await projectIdFromContext(context);
    const parsed = CreateArtifactVersionInputSchema.safeParse(await readJsonBody(request));
    if (!parsed.success) throw new CreatorHttpError(400, 'VALIDATION_FAILED', 'Artifact version details are invalid.');
    const { client } = await requireCreatorAuthority();
    const { data, error } = await client.rpc('creator_create_artifact_version', {
      p_project_id: projectId, p_kind: parsed.data.kind, p_inline_text: parsed.data.inlineText,
      p_sha256: parsed.data.sha256, p_client_request_id: parsed.data.clientRequestId,
    });
    throwForRpcError(error);
    return NextResponse.json(readRpcEnvelope(data), { status: 201 });
  } catch (error) {
    return creatorErrorResponse(error);
  }
}
