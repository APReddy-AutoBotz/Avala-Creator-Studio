import { NextResponse } from 'next/server';
import { VoiceRevisionInputSchema } from '@creator/contracts';
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
    const parsed = VoiceRevisionInputSchema.safeParse(await readJsonBody(request));
    if (!parsed.success) throw new CreatorHttpError(400, 'VALIDATION_FAILED', 'Voice revision details are invalid.');

    const { client } = await requireCreatorAuthority();
    const { data, error } = await client.rpc('creator_request_voice_revision', {
      p_project_id: projectId,
      p_artifact_id: artifactId,
      p_artifact_sha256: parsed.data.artifactSha256,
      p_reason: parsed.data.reason,
      p_idempotency_key: parsed.data.idempotencyKey,
    });
    throwForRpcError(error);
    return NextResponse.json({ project: serializeProject(data) });
  } catch (error) {
    return creatorErrorResponse(error);
  }
}
