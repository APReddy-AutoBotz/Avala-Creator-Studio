import { NextResponse } from 'next/server';
import { TransitionInputSchema } from '@creator/contracts';
import { CreatorHttpError, creatorErrorResponse, projectIdFromContext, readJsonBody, requireCreatorAuthority, serializeProject, throwForRpcError } from '../../../../../../lib/server/authority';

type RouteContext = Readonly<{ params: Promise<{ projectId: string }> }>;

export async function POST(request: Request, context: RouteContext) {
  try {
    const projectId = await projectIdFromContext(context);
    const parsed = TransitionInputSchema.safeParse(await readJsonBody(request));
    if (!parsed.success) throw new CreatorHttpError(400, 'VALIDATION_FAILED', 'Workflow transition details are invalid.');
    const { client } = await requireCreatorAuthority();
    const { data, error } = await client.rpc('creator_transition_project', {
      p_project_id: projectId, p_expected_stage: parsed.data.expectedStage, p_event: parsed.data.event,
      p_artifact_id: parsed.data.artifactId ?? null, p_artifact_sha256: parsed.data.artifactSha256 ?? null,
      p_idempotency_key: parsed.data.idempotencyKey, p_notes: parsed.data.notes ?? null,
    });
    throwForRpcError(error);
    return NextResponse.json({ project: serializeProject(data) });
  } catch (error) {
    return creatorErrorResponse(error);
  }
}
