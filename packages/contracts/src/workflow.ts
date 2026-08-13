import { z } from 'zod';

export const WorkflowStageSchema = z.enum([
  'CONTENT_REVIEW', 'CONTENT_APPROVED', 'SCRIPT_GENERATING', 'SCRIPT_REVIEW', 'SCRIPT_APPROVED',
  'VOICE_GENERATING', 'VOICE_REVIEW', 'VOICE_APPROVED', 'AVATAR_GENERATING', 'AVATAR_REVIEW',
  'AVATAR_APPROVED', 'EDIT_GENERATING', 'EDIT_REVIEW', 'EDIT_APPROVED', 'FINAL_RENDERING', 'FINAL_REVIEW', 'FINAL_APPROVED'
]);
export type WorkflowStage = z.infer<typeof WorkflowStageSchema>;
export const WORKFLOW_STAGES = WorkflowStageSchema.options;
export const ActorKindSchema = z.enum(['human', 'worker']);
export type ActorKind = z.infer<typeof ActorKindSchema>;
export const WorkflowEventSchema = z.enum([
  'APPROVE_CONTENT','START_SCRIPT','SCRIPT_READY','APPROVE_SCRIPT','START_VOICE','VOICE_READY','APPROVE_VOICE',
  'START_AVATAR','AVATAR_READY','APPROVE_AVATAR','START_EDIT','EDIT_READY','APPROVE_EDIT','START_FINAL','FINAL_READY','APPROVE_FINAL'
]);
export type WorkflowEvent = z.infer<typeof WorkflowEventSchema>;
export const ArtifactKindSchema = z.enum(['content','script','voice','avatar','edit','final']);
export type ArtifactKind = z.infer<typeof ArtifactKindSchema>;
export const IdentityProfileKindSchema = z.enum(['voice','avatar']);
export type IdentityProfileKind = z.infer<typeof IdentityProfileKindSchema>;
export const SampleStatusSchema = z.enum(['pending_validation','validated','rejected','deleted']);
export type SampleStatus = z.infer<typeof SampleStatusSchema>;
export const CONTENT_RIGHTS_STATEMENT = {
  version: 'content-rights-v1',
  text: 'I own this content or have permission to adapt it into a video.',
  sha256: '42250e837adc94788c9a403c5e49362eac5c6914279ba74bfdc83c588bc2cb80',
} as const;
type Rule = Readonly<{ from: WorkflowStage; event: WorkflowEvent; to: WorkflowStage; actor: ActorKind }>;
export const TRANSITION_RULES: readonly Rule[] = [
  { from:'CONTENT_REVIEW',event:'APPROVE_CONTENT',to:'CONTENT_APPROVED',actor:'human' },
  { from:'CONTENT_APPROVED',event:'START_SCRIPT',to:'SCRIPT_GENERATING',actor:'human' },
  { from:'SCRIPT_GENERATING',event:'SCRIPT_READY',to:'SCRIPT_REVIEW',actor:'worker' },
  { from:'SCRIPT_REVIEW',event:'APPROVE_SCRIPT',to:'SCRIPT_APPROVED',actor:'human' },
  { from:'VOICE_REVIEW',event:'APPROVE_VOICE',to:'VOICE_APPROVED',actor:'human' },
  { from:'AVATAR_REVIEW',event:'APPROVE_AVATAR',to:'AVATAR_APPROVED',actor:'human' },
  { from:'EDIT_REVIEW',event:'APPROVE_EDIT',to:'EDIT_APPROVED',actor:'human' },
  { from:'FINAL_REVIEW',event:'APPROVE_FINAL',to:'FINAL_APPROVED',actor:'human' }
] as const;
export class InvalidWorkflowTransition extends Error { readonly code='INVALID_WORKFLOW_TRANSITION'; constructor(){ super('The requested workflow transition is not allowed.'); } }
export function transitionStage(current:WorkflowStage,event:WorkflowEvent,actor:ActorKind):WorkflowStage {
  const rule=TRANSITION_RULES.find(item=>item.from===current&&item.event===event&&item.actor===actor); if(!rule) throw new InvalidWorkflowTransition(); return rule.to;
}
export const ApprovalBindingSchema=z.object({ artifactId:z.string().uuid(),artifactVersion:z.number().int().positive(),sha256:z.string().regex(/^[a-f0-9]{64}$/),reviewerId:z.string().uuid(),reviewedAt:z.string().datetime(),decision:z.literal('approved') }).strict();
export type ApprovalBinding=z.infer<typeof ApprovalBindingSchema>;
export type ArtifactSnapshot=Readonly<{id:string;kind:ArtifactKind;version:number;sha256:string;stale:boolean}>;
export function approvalMatchesArtifact(approval:ApprovalBinding,artifact:ArtifactSnapshot):boolean { return !artifact.stale&&approval.artifactId===artifact.id&&approval.artifactVersion===artifact.version&&approval.sha256===artifact.sha256; }
const downstreamKinds:ArtifactKind[]=['content','script','voice','avatar','edit','final'];
export function invalidateDownstream(artifacts:readonly ArtifactSnapshot[],revisedKind:ArtifactKind):ArtifactSnapshot[]{ const boundary=downstreamKinds.indexOf(revisedKind); return artifacts.map(a=>downstreamKinds.indexOf(a.kind)>boundary?{...a,stale:true}:a); }
export const CreateProjectInputSchema=z.object({title:z.string().trim().min(1).max(160),clientRequestId:z.string().uuid()}).strict();
export const ProjectViewSchema=z.object({id:z.string().uuid(),title:z.string(),currentStage:WorkflowStageSchema,createdAt:z.string().datetime().nullable(),updatedAt:z.string().datetime().nullable()}).strict();
export type ProjectView=z.infer<typeof ProjectViewSchema>;
export const ArtifactViewSchema=z.object({id:z.string().uuid(),kind:ArtifactKindSchema,version:z.number().int().positive(),sha256:z.string().regex(/^[a-f0-9]{64}$/),inlineText:z.string().nullable(),staleAt:z.string().datetime().nullable(),createdAt:z.string().datetime().nullable()}).strict();
export type ArtifactView=z.infer<typeof ArtifactViewSchema>;
export const CreateArtifactVersionInputSchema=z.object({kind:z.enum(['content','script']),inlineText:z.string().trim().min(1).max(100_000),sha256:z.string().regex(/^[a-f0-9]{64}$/),clientRequestId:z.string().uuid()}).strict();
export const RightsAttestationInputSchema=z.object({artifactId:z.string().uuid(),statementVersion:z.string().trim().min(1).max(64),clientRequestId:z.string().uuid()}).strict();
export const TransitionInputSchema=z.object({expectedStage:WorkflowStageSchema,event:WorkflowEventSchema,artifactId:z.string().uuid().nullable().optional(),artifactSha256:z.string().regex(/^[a-f0-9]{64}$/).nullable().optional(),idempotencyKey:z.string().uuid(),notes:z.string().trim().max(4000).optional()}).strict();
export const RequestRevisionInputSchema=z.object({targetKind:ArtifactKindSchema,reason:z.string().trim().min(1).max(4000),idempotencyKey:z.string().uuid()}).strict();
export const CreateConsentProfileInputSchema=z.object({kind:IdentityProfileKindSchema,displayName:z.string().trim().min(1).max(120),consentStatementVersion:z.string().trim().min(1).max(64),consentSha256:z.string().regex(/^[a-f0-9]{64}$/),clientRequestId:z.string().uuid()}).strict();
export const RegisterIdentitySampleInputSchema=z.object({profileId:z.string().uuid(),clientRequestId:z.string().uuid()}).strict();
export const RevokeConsentProfileInputSchema=z.object({reason:z.string().trim().min(1).max(1000),idempotencyKey:z.string().uuid()}).strict();
export const DeleteConsentProfileInputSchema=z.object({idempotencyKey:z.string().uuid()}).strict();
export type ConsentEligibility=Readonly<{status:'draft'|'active'|'revoked'|'deleting'|'deleted';revoked:boolean;samples:readonly Readonly<{status:SampleStatus}>[]}>;
export function isIdentityProfileGenerationEligible(input:ConsentEligibility):boolean { return input.status==='active'&&!input.revoked&&input.samples.some(s=>s.status==='validated'); }
