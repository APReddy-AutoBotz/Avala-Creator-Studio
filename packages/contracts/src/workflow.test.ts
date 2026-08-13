import { describe, expect, it } from 'vitest';
import { approvalMatchesArtifact,CONTENT_RIGHTS_STATEMENT,CreateConsentProfileInputSchema,InvalidWorkflowTransition,invalidateDownstream,isIdentityProfileGenerationEligible,RegisterIdentitySampleInputSchema,transitionStage } from './workflow';

describe('human-gated workflow',()=>{
  it('allows human content approval but not worker approval',()=>{ expect(transitionStage('CONTENT_REVIEW','APPROVE_CONTENT','human')).toBe('CONTENT_APPROVED'); expect(()=>transitionStage('CONTENT_REVIEW','APPROVE_CONTENT','worker')).toThrow(InvalidWorkflowTransition); });
  it('prevents stage skipping',()=>{ expect(()=>transitionStage('CONTENT_REVIEW','START_VOICE','human')).toThrow(InvalidWorkflowTransition); });
  it('requires worker authority for generated draft readiness',()=>{ expect(()=>transitionStage('SCRIPT_GENERATING','SCRIPT_READY','human')).toThrow(InvalidWorkflowTransition); expect(transitionStage('SCRIPT_GENERATING','SCRIPT_READY','worker')).toBe('SCRIPT_REVIEW'); });
  it('pins governed content-rights evidence',()=>{expect(CONTENT_RIGHTS_STATEMENT.version).toBe('content-rights-v1');expect(CONTENT_RIGHTS_STATEMENT.sha256).toBe('42250e837adc94788c9a403c5e49362eac5c6914279ba74bfdc83c588bc2cb80');});
});
describe('immutable approval bindings',()=>{
 const approval={artifactId:'11111111-1111-1111-8111-111111111111',artifactVersion:1,sha256:'a'.repeat(64),reviewerId:'22222222-2222-4222-8222-222222222222',reviewedAt:'2026-08-13T00:00:00.000Z',decision:'approved' as const};
 it('binds approval to exact non-stale version and digest',()=>{expect(approvalMatchesArtifact(approval,{id:approval.artifactId,kind:'content',version:1,sha256:approval.sha256,stale:false})).toBe(true);expect(approvalMatchesArtifact(approval,{id:approval.artifactId,kind:'content',version:2,sha256:approval.sha256,stale:false})).toBe(false);});
 it('invalidates downstream kinds only',()=>{const artifacts=['content','script','voice','final'].map((kind,index)=>({id:String(index),kind:kind as 'content'|'script'|'voice'|'final',version:1,sha256:'a'.repeat(64),stale:false}));expect(invalidateDownstream(artifacts,'content').map(i=>i.stale)).toEqual([false,true,true,true]);});
});
describe('M2 identity contracts',()=>{
 it('does not accept browser supplied owner authority',()=>{expect(CreateConsentProfileInputSchema.safeParse({kind:'voice',displayName:'My voice',consentStatementVersion:'self-owned-v1',consentSha256:'b'.repeat(64),clientRequestId:'33333333-3333-4333-8333-333333333333',ownerId:'44444444-4444-4444-8444-444444444444'}).success).toBe(false);});
 it('registers samples by prepared intent identity only',()=>{expect(RegisterIdentitySampleInputSchema.safeParse({profileId:'55555555-5555-4555-8555-555555555555',clientRequestId:'66666666-6666-4666-8666-666666666666'}).success).toBe(true);expect(RegisterIdentitySampleInputSchema.safeParse({profileId:'55555555-5555-4555-8555-555555555555',clientRequestId:'66666666-6666-4666-8666-666666666666',objectPath:'https://example.com/bypass.wav'}).success).toBe(false);});
 it('requires active current consent plus a validated sample for generation eligibility',()=>{expect(isIdentityProfileGenerationEligible({status:'draft',revoked:false,samples:[{status:'validated'}]})).toBe(false);expect(isIdentityProfileGenerationEligible({status:'active',revoked:false,samples:[{status:'pending_validation'}]})).toBe(false);expect(isIdentityProfileGenerationEligible({status:'active',revoked:false,samples:[{status:'validated'}]})).toBe(true);expect(isIdentityProfileGenerationEligible({status:'active',revoked:true,samples:[{status:'validated'}]})).toBe(false);});
});
