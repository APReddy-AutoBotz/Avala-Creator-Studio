import { NextResponse } from 'next/server';
import { ConsentProfileViewSchema, CreateConsentProfileInputSchema } from '@creator/contracts';
import { CreatorHttpError, creatorErrorResponse, readJsonBody, requireCreatorAuthority, throwForRpcError } from '../../../../../lib/server/authority';

function serializeProfile(record: Record<string, unknown>) {
  return ConsentProfileViewSchema.parse({
    id: record.id, kind: record.profile_kind, displayName: record.display_name,
    consentStatementVersion: record.consent_statement_version, consentSha256: record.consent_sha256,
    status: record.status, createdAt: record.created_at, activatedAt: record.activated_at ?? null,
    revokedAt: record.revoked_at ?? null, deletedAt: record.deleted_at ?? null,
  });
}

export async function GET() {
  try {
    const { client } = await requireCreatorAuthority();
    const { data, error } = await client.from('creator_consent_profiles').select('*').order('created_at', { ascending: false });
    if (error) throwForRpcError(error);
    const profiles = (data ?? []).filter(record => record.status !== 'deleted').map(record => serializeProfile(record));
    const withSamples = await Promise.all(profiles.map(async profile => {
      const { data: samples, error: sampleError } = await client.from('creator_identity_samples').select('*').eq('profile_id', profile.id).order('created_at', { ascending: false });
      if (sampleError) throwForRpcError(sampleError);
      return { ...profile, samples: (samples ?? []).map(sample => ({
        id: sample.id, profileId: sample.profile_id, mimeType: sample.mime_type ?? null,
        byteLength: sample.byte_length === null ? null : Number(sample.byte_length), sha256: sample.sha256 ?? null,
        status: sample.status, createdAt: sample.created_at, validatedAt: sample.validated_at ?? null,
        rejectionCode: sample.rejection_code ?? null, deletedAt: sample.deleted_at ?? null,
      })) };
    }));
    return NextResponse.json({ profiles: withSamples });
  } catch (error) { return creatorErrorResponse(error); }
}

export async function POST(request: Request) {
  try {
    const parsed = CreateConsentProfileInputSchema.safeParse(await readJsonBody(request));
    if (!parsed.success) throw new CreatorHttpError(400, 'VALIDATION_FAILED', 'Consent profile details are invalid.');
    const { client } = await requireCreatorAuthority();
    const { data, error } = await client.rpc('creator_create_consent_profile', {
      p_kind: parsed.data.kind, p_display_name: parsed.data.displayName,
      p_consent_statement_version: parsed.data.consentStatementVersion,
      p_consent_sha256: parsed.data.consentSha256, p_client_request_id: parsed.data.clientRequestId,
    });
    throwForRpcError(error);
    return NextResponse.json({ profile: serializeProfile(data as Record<string, unknown>) }, { status: 201 });
  } catch (error) { return creatorErrorResponse(error); }
}
