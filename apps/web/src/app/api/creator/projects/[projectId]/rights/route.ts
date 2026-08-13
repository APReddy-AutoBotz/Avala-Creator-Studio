import { NextResponse } from 'next/server';
import { RightsAttestationInputSchema } from '@creator/contracts';
import { CreatorHttpError, creatorErrorResponse, projectIdFromContext, readJsonBody, requireCreatorAuthority, throwForRpcError } from '../../../../../../lib/server/authority';

type RouteContext = Readonly<{ params: Promise<{ projectId: string }> }>;

export async function POST(request: Request, context: RouteContext) {
  try {
    const projectId = await projectIdFromContext(context);
    const parsed = RightsAttestationInputSchema.safeParse(await readJsonBody(request));
    if (!parsed.success) throw new CreatorHttpError(400, 'VALIDATION_FAILED', 'Rights attestation details are invalid.');
    const { client } = await requireCreatorAuthority();
    const { error } = await client.rpc('creator_attest_rights', {
      p_project_id: projectId, p_artifact_id: parsed.data.artifactId,
      p_statement_version: parsed.data.statementVersion, p_client_request_id: parsed.data.clientRequestId,
    });
    throwForRpcError(error);
    return NextResponse.json({ attested: true }, { status: 201 });
  } catch (error) {
    return creatorErrorResponse(error);
  }
}
