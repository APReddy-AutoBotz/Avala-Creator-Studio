import { NextResponse } from 'next/server';
import { PrepareIdentityUploadInputSchema } from '@creator/contracts';
import { CreatorHttpError,creatorErrorResponse,readJsonBody,requireCreatorAuthority,throwForRpcError } from '../../../../../../../lib/server/authority';
type RouteContext=Readonly<{params:Promise<{profileId:string}>}>;
export async function POST(request:Request,context:RouteContext){
 try{
  const {profileId}=await context.params; const parsed=PrepareIdentityUploadInputSchema.safeParse(await readJsonBody(request));
  if(!parsed.success) throw new CreatorHttpError(400,'VALIDATION_FAILED','Upload details are invalid.');
  const {client}=await requireCreatorAuthority();
  const {data,error}=await client.rpc('creator_prepare_identity_upload',{p_profile_id:profileId,p_file_name:parsed.data.fileName,p_mime_type:parsed.data.mimeType,p_byte_length:parsed.data.byteLength,p_sha256:parsed.data.sha256,p_client_request_id:parsed.data.clientRequestId});
  throwForRpcError(error);
  if(!data||typeof data!=='object'||Array.isArray(data)) throw new CreatorHttpError(502,'AUTHORITY_RESPONSE_INVALID','Upload authority returned an invalid response.');
  const record=data as Record<string,unknown>;
  if(typeof record.object_path!=='string'||typeof record.expires_at!=='string') throw new CreatorHttpError(502,'AUTHORITY_RESPONSE_INVALID','Upload authority returned an invalid response.');
  return NextResponse.json({objectPath:record.object_path,expiresAt:record.expires_at});
 }catch(error){return creatorErrorResponse(error);}
}
