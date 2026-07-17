import {createClient} from 'npm:@supabase/supabase-js@2';

const projectUrl=Deno.env.get('SUPABASE_URL')!;
const serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const sharedSecret=Deno.env.get('WATCHDOG_SHARED_SECRET')!;
const githubToken=Deno.env.get('GITHUB_WATCHDOG_TOKEN')!;
const repository=Deno.env.get('GITHUB_WATCHDOG_REPOSITORY')||'PanDory1992/fadewell-hq';
const workflow=Deno.env.get('GITHUB_WATCHDOG_WORKFLOW')||'vinted-cloud-sync.yml';
const db=createClient(projectUrl,serviceKey,{auth:{persistSession:false}});
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{'content-type':'application/json','cache-control':'no-store'}});

async function sameSecret(left:string,right:string){
  if(!left||!right)return false;
  const encoder=new TextEncoder(),[a,b]=await Promise.all([
    crypto.subtle.digest('SHA-256',encoder.encode(left)),
    crypto.subtle.digest('SHA-256',encoder.encode(right))
  ]);
  return new Uint8Array(a).every((value,index)=>value===new Uint8Array(b)[index]);
}

Deno.serve(async request=>{
  if(request.method!=='POST')return json({error:'Method not allowed'},405);
  const supplied=(request.headers.get('authorization')||'').replace(/^Bearer\s+/i,'');
  if(!await sameSecret(supplied,sharedSecret))return json({error:'Forbidden'},403);
  if(!githubToken)return json({error:'GitHub watchdog token is not configured'},503);

  const{data:claim,error:claimError}=await db.rpc('claim_hq_vinted_watchdog_dispatch',{p_stale_after_minutes:35,p_cooldown_minutes:10});
  if(claimError)return json({error:claimError.message},500);
  if(!claim.accepted)return json({status:'skipped',...claim});

  const response=await fetch(`https://api.github.com/repos/${repository}/actions/workflows/${workflow}/dispatches`,{
    method:'POST',
    headers:{
      accept:'application/vnd.github+json',
      authorization:`Bearer ${githubToken}`,
      'content-type':'application/json',
      'user-agent':'fadewell-vinted-watchdog',
      'x-github-api-version':'2022-11-28'
    },
    body:JSON.stringify({ref:'main',inputs:{mode:'watchdog'}}),
    signal:AbortSignal.timeout(15000)
  }).catch(error=>new Response(String(error),{status:599}));

  if(!response.ok){
    const detail=(await response.text()).replace(/\s+/g,' ').slice(0,500);
    const message=`GitHub workflow dispatch HTTP ${response.status}: ${detail}`;
    await db.rpc('record_hq_vinted_watchdog_dispatch_error',{p_error:message});
    return json({status:'dispatch_failed',error:message},502);
  }

  return json({status:'dispatched',source:'EXTERNAL_WATCHDOG',...claim},202);
});
