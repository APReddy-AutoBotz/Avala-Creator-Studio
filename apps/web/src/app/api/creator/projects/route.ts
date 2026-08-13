import { NextResponse } from 'next/server';
import { CreateProjectInputSchema } from '@creator/contracts';
import { CreatorHttpError, creatorErrorResponse, readJsonBody, requireCreatorAuthority, serializeProject, throwForRpcError } from '../../../../lib/server/authority';

export async function POST(request: Request) {
  try {
    const parsed = CreateProjectInputSchema.safeParse(await readJsonBody(request));
    if (!parsed.success) throw new CreatorHttpError(400, 'VALIDATION_FAILED', 'Project details are invalid.');
    const { client } = await requireCreatorAuthority();
    const { data, error } = await client.rpc('creator_create_project', {
      p_title: parsed.data.title,
      p_client_request_id: parsed.data.clientRequestId,
    });
    throwForRpcError(error);
    return NextResponse.json({ project: serializeProject(data) }, { status: 201 });
  } catch (error) {
    return creatorErrorResponse(error);
  }
}
