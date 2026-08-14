import { NextResponse } from 'next/server';
import { creatorErrorResponse, projectIdFromContext, requireCreatorAuthority } from '../../../../../../lib/server/authority';
import {
  readLatestScript,
  readLatestVoice,
  readOwnedProject,
  readProfileStatus,
  readVoiceApproval,
} from '../../../../../../lib/server/voice';

type RouteContext = Readonly<{ params: Promise<{ projectId: string }> }>;

export async function GET(_request: Request, context: RouteContext) {
  try {
    const projectId = await projectIdFromContext(context);
    const { client } = await requireCreatorAuthority();
    const project = await readOwnedProject(client, projectId);
    const script = await readLatestScript(client, projectId);
    const voiceArtifact = await readLatestVoice(client, projectId);
    const voiceApproved = voiceArtifact ? await readVoiceApproval(client, voiceArtifact.id) : false;
    const profileStatus = voiceArtifact ? await readProfileStatus(client, voiceArtifact.profileId) : null;

    return NextResponse.json({ project, script, voiceArtifact, voiceApproved, profileStatus });
  } catch (error) {
    return creatorErrorResponse(error);
  }
}
