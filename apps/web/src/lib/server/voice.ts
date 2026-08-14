import { createHash } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  ArtifactViewSchema,
  VoiceArtifactMetadataSchema,
  VoiceArtifactViewSchema,
  type ArtifactView,
  type ProjectView,
  type VoiceArtifactView,
} from '@creator/contracts';
import { CreatorHttpError, serializeProject, throwForRpcError } from './authority';

type DbRecord = Record<string, unknown>;

function asRecord(value: unknown): DbRecord {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new CreatorHttpError(502, 'AUTHORITY_RESPONSE_INVALID', 'Creator authority returned an invalid response.');
  }
  return value as DbRecord;
}

function requiredString(record: DbRecord, key: string): string {
  const value = record[key];
  if (typeof value !== 'string') {
    throw new CreatorHttpError(502, 'AUTHORITY_RESPONSE_INVALID', 'Creator authority returned an invalid response.');
  }
  return value;
}

function positiveInteger(record: DbRecord, key: string): number {
  const value = Number(record[key]);
  if (!Number.isInteger(value) || value <= 0) {
    throw new CreatorHttpError(502, 'AUTHORITY_RESPONSE_INVALID', 'Creator authority returned an invalid response.');
  }
  return value;
}

function nullableString(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

export function serializeVoiceArtifact(value: unknown): VoiceArtifactView {
  const record = asRecord(value);
  const metadata = VoiceArtifactMetadataSchema.parse(record.metadata);
  return VoiceArtifactViewSchema.parse({
    id: requiredString(record, 'id'),
    projectId: requiredString(record, 'project_id'),
    version: positiveInteger(record, 'version_number'),
    sha256: requiredString(record, 'sha256'),
    profileId: requiredString(record, 'identity_profile_id'),
    staleAt: nullableString(record.stale_at),
    metadata,
    createdAt: nullableString(record.created_at),
  });
}

export function serializeScriptArtifact(value: unknown): ArtifactView {
  const record = asRecord(value);
  return ArtifactViewSchema.parse({
    id: requiredString(record, 'id'),
    kind: 'script',
    version: positiveInteger(record, 'version_number'),
    sha256: requiredString(record, 'sha256'),
    inlineText: nullableString(record.inline_text),
    staleAt: nullableString(record.stale_at),
    createdAt: nullableString(record.created_at),
  });
}

export function voiceManifestSha256(input: Readonly<{
  projectId: string;
  scriptArtifactId: string;
  scriptVersion: number;
  scriptSha256: string;
  profileId: string;
}>): string {
  const material = JSON.stringify({
    version: 'm3b1-voice-manifest-v1',
    projectId: input.projectId,
    script: {
      artifactId: input.scriptArtifactId,
      version: input.scriptVersion,
      sha256: input.scriptSha256,
    },
    profileId: input.profileId,
    providerId: 'mock',
    generationMode: 'synthetic_mock',
  });
  return createHash('sha256').update(material, 'utf8').digest('hex');
}

export async function readOwnedProject(client: SupabaseClient, projectId: string): Promise<ProjectView> {
  const { data, error } = await client.from('creator_projects').select('*').eq('id', projectId).maybeSingle();
  throwForRpcError(error);
  if (!data) throw new CreatorHttpError(404, 'PROJECT_NOT_FOUND', 'Creator project was not found.');
  return serializeProject(data);
}

export async function readLatestScript(client: SupabaseClient, projectId: string): Promise<ArtifactView | null> {
  const { data, error } = await client
    .from('creator_artifacts')
    .select('*')
    .eq('project_id', projectId)
    .eq('kind', 'script')
    .is('stale_at', null)
    .order('version_number', { ascending: false })
    .limit(1)
    .maybeSingle();
  throwForRpcError(error);
  return data ? serializeScriptArtifact(data) : null;
}

export async function readLatestVoice(client: SupabaseClient, projectId: string): Promise<VoiceArtifactView | null> {
  const { data, error } = await client
    .from('creator_artifacts')
    .select('*')
    .eq('project_id', projectId)
    .eq('kind', 'voice')
    .is('stale_at', null)
    .order('version_number', { ascending: false })
    .limit(1)
    .maybeSingle();
  throwForRpcError(error);
  return data ? serializeVoiceArtifact(data) : null;
}

export async function readVoiceApproval(client: SupabaseClient, artifactId: string): Promise<boolean> {
  const { data, error } = await client
    .from('creator_reviews')
    .select('id')
    .eq('artifact_id', artifactId)
    .eq('decision', 'approved')
    .is('invalidated_at', null)
    .limit(1)
    .maybeSingle();
  throwForRpcError(error);
  return Boolean(data);
}

export async function readProfileStatus(client: SupabaseClient, profileId: string): Promise<string | null> {
  const { data, error } = await client
    .from('creator_consent_profiles')
    .select('status')
    .eq('id', profileId)
    .maybeSingle();
  throwForRpcError(error);
  return data && typeof data.status === 'string' ? data.status : null;
}
