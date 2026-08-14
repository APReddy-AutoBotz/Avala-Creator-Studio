import { NextResponse } from 'next/server';
import { VoiceReviewInputSchema } from '@creator/contracts';
import {
  CreatorHttpError,
  creatorErrorResponse,
  projectIdFromContext,
  readJsonBody,
  requireCreatorAuthority,
  serializeProject,
  throwForRpcError,
} from '../../../../../../../../lib/server/authority';

type RouteContext = Readonly<{ params: Promise<{ projectId: string; artifactId: string }> }>;

function validUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

export async function POST(request: Request, context: RouteContext) {
  try {
    const projectId = await projectIdFromContext(context);
    const { artifactId } = await context.params;
    if (!validUuid(artifactId)) throw new CreatorHttpError(400, 'ARTIFACT_ID_INVALID', 'The artifact ID is invalid.');
    const parsed = VoiceReviewInputSchema.safeParse(await readJsonBody(request));
    if (!parsed.success) throw new CreatorHttpError(400, 'VALIDATION_FAILED', 'Voice approval details are invalid.');

    const { client } = await requireCreatorAuthority();
    const { data: artifact, error: artifactError } = await client
      .from('creator_artifacts')
      .select('id,sha256')
      .eq('id', artifactId)
      .eq('project_id', projectId)
      .eq('kind', 'voice')
      .eq('sha256', parsed.data.artifactSha256)
      .is('stale_at', null)
      .maybeSingle();
    throwForRpcError(artifactError);
    if (!artifact) throw new CreatorHttpError(409, 'ARTIFACT_BINDING_INVALID', 'Voice artifact binding is no longer current.');

    const { data, error } = await client.rpc('creator_transition_project', {
      p_project_id: projectId,
      p_expected_stage: 'VOICE_REVIEW',
      p_event: 'APPROVE_VOICE',
      p_artifact_id: artifactId,
      p_artifact_sha256: parsed.data.artifactSha256,
      p_idempotency_key: parsed.data.idempotencyKey,
      p_notes: parsed.data.notes,
    });
    throwForRpcError(error);
    return NextResponse.json({ project: serializeProject(data) });
  } catch (error) {
    return creatorErrorResponse(error);
  }
}
