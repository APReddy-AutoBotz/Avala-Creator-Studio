import type { SupabaseClient } from '@supabase/supabase-js';
import { NextResponse } from 'next/server';
import {
  ArtifactViewSchema,
  ProjectViewSchema,
  type ArtifactView,
  type ProjectView,
} from '@creator/contracts';
import { createCreatorSupabaseServerClient } from '../supabase/server';

export class CreatorHttpError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
    this.name = 'CreatorHttpError';
  }
}

export type CreatorAuthority = Readonly<{ client: SupabaseClient; userId: string }>;

export async function requireCreatorAuthority(): Promise<CreatorAuthority> {
  let client: SupabaseClient;
  try {
    client = await createCreatorSupabaseServerClient();
  } catch {
    throw new CreatorHttpError(503, 'AUTHORITY_UNAVAILABLE', 'Creator Studio authority is not configured.');
  }

  const { data, error } = await client.auth.getClaims();
  const subject = data?.claims?.sub;
  if (error || typeof subject !== 'string' || subject.length === 0) {
    throw new CreatorHttpError(401, 'AUTHENTICATION_REQUIRED', 'Sign in is required.');
  }
  return { client, userId: subject };
}

export async function readJsonBody(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    throw new CreatorHttpError(400, 'INVALID_JSON', 'The request body is not valid JSON.');
  }
}

export async function projectIdFromContext(context: Readonly<{ params: Promise<{ projectId: string }> }>): Promise<string> {
  const { projectId } = await context.params;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(projectId)) {
    throw new CreatorHttpError(400, 'PROJECT_ID_INVALID', 'The project ID is invalid.');
  }
  return projectId;
}

function asRecord(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new CreatorHttpError(502, 'AUTHORITY_RESPONSE_INVALID', 'Authority returned an invalid response.');
  }
  return value as Record<string, unknown>;
}

function nullableString(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

function requiredString(record: Record<string, unknown>, key: string): string {
  const value = record[key];
  if (typeof value !== 'string') throw new CreatorHttpError(502, 'AUTHORITY_RESPONSE_INVALID', 'Authority returned an invalid response.');
  return value;
}

function requiredPositiveInteger(record: Record<string, unknown>, key: string): number {
  const value = record[key];
  if (!Number.isInteger(value) || Number(value) <= 0) throw new CreatorHttpError(502, 'AUTHORITY_RESPONSE_INVALID', 'Authority returned an invalid response.');
  return Number(value);
}

export function serializeProject(value: unknown): ProjectView {
  const record = asRecord(value);
  return ProjectViewSchema.parse({
    id: requiredString(record, 'id'),
    title: requiredString(record, 'title'),
    currentStage: requiredString(record, 'current_stage'),
    createdAt: nullableString(record.created_at),
    updatedAt: nullableString(record.updated_at),
  });
}

export function serializeArtifact(value: unknown): ArtifactView {
  const record = asRecord(value);
  return ArtifactViewSchema.parse({
    id: requiredString(record, 'id'),
    kind: requiredString(record, 'kind'),
    version: requiredPositiveInteger(record, 'version_number'),
    sha256: requiredString(record, 'sha256'),
    inlineText: nullableString(record.inline_text),
    staleAt: nullableString(record.stale_at),
    createdAt: nullableString(record.created_at),
  });
}

export function readRpcEnvelope(value: unknown): Readonly<{ project: ProjectView; artifact: ArtifactView; replayed: boolean }> {
  const record = asRecord(value);
  return {
    project: serializeProject(record.project),
    artifact: serializeArtifact(record.artifact),
    replayed: record.replayed === true,
  };
}

const CLIENT_ERROR_CODES = new Set([
  'APPROVAL_BINDING_REQUIRED', 'ARTIFACT_BINDING_INVALID', 'ARTIFACT_KIND_NOT_ENABLED',
  'ARTIFACT_TEXT_INVALID', 'CLIENT_REQUEST_ID_REQUIRED', 'IDEMPOTENCY_KEY_REQUIRED',
  'IDEMPOTENCY_KEY_REUSED', 'INVALID_WORKFLOW_TRANSITION', 'LATEST_ARTIFACT_REQUIRED',
  'PROJECT_TITLE_INVALID', 'REVISION_REASON_INVALID', 'REVISION_TARGET_INVALID',
  'REVISION_TARGET_NOT_REACHED', 'RIGHTS_ATTESTATION_REQUIRED', 'RIGHTS_STATEMENT_INVALID',
  'SHA256_INVALID', 'STAGE_CONFLICT', 'TEXT_ARTIFACT_PATH_FORBIDDEN',
]);

function authorityErrorCode(message: string): string | null {
  for (const code of CLIENT_ERROR_CODES) if (message.includes(code)) return code;
  if (message.includes('PROJECT_NOT_FOUND')) return 'PROJECT_NOT_FOUND';
  if (message.includes('BIOMETRIC_UPLOADS_NOT_ENABLED')) return 'BIOMETRIC_UPLOADS_NOT_ENABLED';
  return null;
}

export function throwForRpcError(error: Readonly<{ message: string }> | null): void {
  if (!error) return;
  const code = authorityErrorCode(error.message);
  if (code === 'PROJECT_NOT_FOUND') throw new CreatorHttpError(404, code, 'Project not found.');
  if (code === 'BIOMETRIC_UPLOADS_NOT_ENABLED') throw new CreatorHttpError(409, code, 'Voice and avatar uploads are not enabled yet.');
  if (code) throw new CreatorHttpError(409, code, 'The requested creator action is not allowed.');
  throw new CreatorHttpError(502, 'AUTHORITY_REQUEST_FAILED', 'Creator authority rejected the request.');
}

export function creatorErrorResponse(error: unknown): NextResponse {
  if (error instanceof CreatorHttpError) {
    return NextResponse.json({ error: error.message, code: error.code }, { status: error.status });
  }
  return NextResponse.json({ error: 'Creator Studio request failed.', code: 'INTERNAL_ERROR' }, { status: 500 });
}
