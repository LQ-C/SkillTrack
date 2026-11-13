import { createClient } from 'npm:@supabase/supabase-js@2';

// Test-only hosted Checkout. No card data or Stripe secret is sent to Flutter.
const headers = {'Access-Control-Allow-Origin':'*',
  'Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type, stripe-signature',
  'Access-Control-Allow-Methods':'GET, POST, OPTIONS', 'Content-Type':'application/json'};
const reply = (status:number,message:string,extra:Record<string,unknown>={}) =>
  new Response(JSON.stringify({message,...extra}),{status,headers});

async function validSignature(raw:string,header:string,secret:string):Promise<boolean> {
  if(header.length>4096) return false;
  const parts=header.split(',').map(p=>p.trim().split('='));
  const timestamp=parts.find(p=>p[0]==='t')?.[1];
  if(!timestamp || !/^\d+$/.test(timestamp) || Math.abs(Date.now()/1000-Number(timestamp))>300) return false;
  const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const digest=new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(`${timestamp}.${raw}`)));
  return parts.filter(p=>p[0]==='v1' && /^[0-9a-f]{64}$/i.test(p[1]??'')).some(p=>{
    let difference=0;for(let i=0;i<digest.length;i++) difference|=digest[i]^parseInt(p[1].slice(i*2,i*2+2),16);
    return difference===0;
  });
}

Deno.serve(async(request:Request)=>{
  if(request.method==='OPTIONS') return new Response('ok',{headers});
  if(request.method==='GET') return new Response(
    'SkillTrack test checkout finished. Return to SkillTrack and tap Refresh payment status. Access is unlocked only after the server verifies payment. No real money is charged.',
    {headers:{'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store'}});
  if(request.method!=='POST') return reply(405,'Method not allowed.');
  try {
    const projectUrl=Deno.env.get('SUPABASE_URL')!;
    const anon=Deno.env.get('SUPABASE_ANON_KEY')!;
    const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const stripeKey=Deno.env.get('STRIPE_TEST_SECRET_KEY')??'';
    if(!stripeKey.startsWith('sk_test_')) return reply(503,'Stripe test payments are not configured yet. Contact the app administrator.');
    const admin=createClient(projectUrl,service,{auth:{persistSession:false,autoRefreshToken:false}});
    async function stripe(path:string,body?:URLSearchParams,idempotency?:string) {
      const response=await fetch(`https://api.stripe.com/v1/${path}`,{
        method:body?'POST':'GET',headers:{Authorization:`Bearer ${stripeKey}`,
          'Stripe-Version':'2026-10-28.endive',...(body?{'Content-Type':'application/x-www-form-urlencoded'}:{}),
          ...(idempotency?{'Idempotency-Key':idempotency}:{})},body:body?.toString()});
      if(!response.ok) throw new Error('Stripe request failed');
      return await response.json();
    }
    async function settle(session:any,status:string) {
      if(session.livemode!==false || !session.id?.startsWith('cs_test_') || !session.metadata?.order_id) throw new Error('Invalid test payment');
      const {error}=await admin.rpc('settle_mentor_payment',{
        p_order:session.metadata.order_id,p_session:session.id,
        p_intent:typeof session.payment_intent==='string'?session.payment_intent:null,
        p_amount:session.amount_total,p_currency:session.currency,p_status:status});
      if(error) throw error;
    }
    const signature=request.headers.get('Stripe-Signature');
    if(signature || new URL(request.url).searchParams.has('webhook')) {
      const signingSecret=Deno.env.get('STRIPE_TEST_WEBHOOK_SECRET')??'';
      if(!signingSecret.startsWith('whsec_')) return reply(503,'Webhook is not configured.');
      const raw=await request.text();
      if(raw.length>262144 || !signature || !await validSignature(raw,signature,signingSecret)) return reply(400,'Invalid webhook signature.');
      const event=JSON.parse(raw);
      if(event.livemode!==false) return reply(400,'Only test events are supported.');
      const object=event.data?.object;
      if(['checkout.session.completed','checkout.session.async_payment_succeeded'].includes(event.type)) {
        const session=await stripe(`checkout/sessions/${encodeURIComponent(object.id)}`);
        if(session.payment_status==='paid') await settle(session,'paid');
      } else if(['checkout.session.expired','checkout.session.async_payment_failed'].includes(event.type)) {
        await settle(object,event.type==='checkout.session.expired'?'expired':'failed');
      } else if(event.type==='charge.refunded' && object.refunded===true) {
        const {error}=await admin.rpc('refund_mentor_payment',{p_intent:object.payment_intent,p_amount:object.amount,p_currency:object.currency});
        if(error) throw error;
      }
      return reply(200,'Event received.');
    }
    const authorization=request.headers.get('Authorization');
    if(!authorization?.startsWith('Bearer ')) return reply(401,'Sign in first.');
    const caller=createClient(projectUrl,anon,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
    const {data:{user},error:authError}=await caller.auth.getUser(authorization.slice(7));
    if(authError || !user?.email_confirmed_at) return reply(401,'Sign in with a verified account.');
    const body=await request.json();
    if(body.action==='refresh') {
      const {data:pending,error}=await admin.from('mentor_payments').select('checkout_session_id')
        .eq('learner_id',user.id).eq('status','pending').limit(10);
      if(error) throw error;
      for(const order of pending??[]) {
        if(!order.checkout_session_id) continue;
        const session=await stripe(`checkout/sessions/${encodeURIComponent(order.checkout_session_id)}`);
        if(session.payment_status==='paid') await settle(session,'paid');
        else if(session.status==='expired') await settle(session,'expired');
      }
      return reply(200,'Payment status refreshed.');
    }
    if(body.action!=='checkout' || typeof body.mentor_id!=='string' || !/^[0-9a-f-]{36}$/i.test(body.mentor_id)) return reply(400,'Choose a mentor.');
    const {data:prepared,error}=await caller.rpc('prepare_mentor_checkout',{p_mentor:body.mentor_id});
    if(error) return reply(400,error.code==='P0001'?error.message:'Could not prepare checkout.');
    const order=Array.isArray(prepared)?prepared[0]:prepared;
    if(!order?.id || order.learner_id!==user.id || order.is_test!==true || order.currency!=='myr') throw new Error('Invalid checkout order');
    if(order.checkout_session_id && order.checkout_url) {
      const existing=await stripe(`checkout/sessions/${encodeURIComponent(order.checkout_session_id)}`);
      if(existing.payment_status==='paid') { await settle(existing,'paid');return reply(200,'Payment verified.',{paid:true}); }
      if(existing.status==='expired') {await settle(existing,'expired');return reply(409,'Checkout expired. Please try again.');}
      return reply(200,'Continue test checkout.',{url:order.checkout_url});
    }
    const returnUrl=`${projectUrl}/functions/v1/mentor-payments`;
    const params=new URLSearchParams({mode:'payment','payment_method_types[0]':'card',
      'line_items[0][price_data][currency]':'myr','line_items[0][price_data][unit_amount]':String(order.amount),
      'line_items[0][price_data][product_data][name]':`SkillTrack test package: ${order.mentor_name}`,
      'line_items[0][price_data][product_data][description]':'One session credit plus access to this mentor’s published materials. Test mode only.',
      'line_items[0][quantity]':'1','metadata[order_id]':order.id,
      client_reference_id:order.id,success_url:`${returnUrl}?result=success`,cancel_url:`${returnUrl}?result=cancelled`});
    const session=await stripe('checkout/sessions',params,`skilltrack-test-${order.id}`);
    if(session.livemode!==false || !session.id?.startsWith('cs_test_') || typeof session.url!=='string' || !session.url.startsWith('https://checkout.stripe.com/')) throw new Error('Invalid test checkout');
    const {error:recordError}=await admin.rpc('record_mentor_checkout',{p_order:order.id,p_session:session.id,p_url:session.url});
    if(recordError) throw recordError;
    return reply(200,'Test checkout ready.',{url:session.url});
  } catch {
    return reply(500,'Could not process this test payment. Your access has not been changed. Please try again.');
  }
});
