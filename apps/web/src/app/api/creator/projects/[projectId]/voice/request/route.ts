import { NextResponse } from 'next/server';
import { RequestVoiceJobInputSchema } from '@creator/contracts';
import {
  CreatorHttpError,
  creatorErrorResponse,
  projectIdFromContext,
  readJsonBody,
  requireCreatorAuthority,
  serializeProject,
  throwForRpcError,
} from '../../../../../../../lib/server/authority';
import { readLatestScript, readOwnedProject, voiceManifestSha256 } from '../../../../../../../lib/server/voice';

type RouteContext = Readonly<{ params: Promise<{ projectId: string }> }>;

function sanitizeResult(value: unknown) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new CreatorHttpError(502, 'AUTHORITY_RESPONSE_INVALID', 'Voice authority returned an invalid response.');
  }
  const record = value as Record<string, unknown>;
  const job = record.job && typeof record.job === 'object' && !Array.isArray(record.job)
    ? record.job as Record<string, unknown>
    : null;
  return {
    accepted: record.accepted === true,
    replayed: record.replayed === true,
    code: typeof record.code === 'string' ? record.code : null,
    jobId: job && typeof job.id === 'string' ? job.id : null,
    jobStatus: job && typeof job.status === 'string' ? job.status : null,
    project: record.project ? serializeProject(record.project) : null,
  };
}

export async function POST(request: Request, context: RouteContext) {
  try {
    const projectId = await projectIdFromContext(context);
    const parsed = RequestVoiceJobInputSchema.safeParse(await readJsonBody(request));
    if (!parsed.success) throw new CreatorHttpError(400, 'VALIDATION_FAILED', 'Voice request details are invalid.');

    const { client } = await requireCreatorAuthority();
    // Project existence is checked here for a clear 404, but stage/idempotency authority
    // belongs to the RPC. This lets an exact response-loss retry reach the recorded
    // idempotent result even after the first request moved the project forward.
    await readOwnedProject(client, projectId);

    const script = await readLatestScript(client, projectId);
    if (!script) throw new CreatorHttpError(409, 'SCRIPT_APPROVAL_REQUIRED', 'An approved script is required.');

    const manifestSha256 = voiceManifestSha256({
      projectId,
      scriptArtifactId: script.id,
      scriptVersion: script.version,
      scriptSha256: script.sha256,
      profileId: parsed.data.profileId,
    });

    const { data, error } = await client.rpc('creator_request_voice_job', {
      p_project_id: projectId,
      p_script_artifact_id: script.id,
      p_script_sha256: script.sha256,
      p_profile_id: parsed.data.profileId,
      p_provider_id: 'mock',
      p_voice_manifest_sha256: manifestSha256,
      p_generation_mode: 'synthetic_mock',
      p_max_cost_microunits: 0,
      p_human_triggered: true,
      p_idempotency_key: parsed.data.idempotencyKey,
    });
    throwForRpcError(error);
    const result = sanitizeResult(data);
    return NextResponse.json(result, { status: result.accepted ? 202 : 409 });
  } catch (error) {
    return creatorErrorResponse(error);
  }
}
