import { createClient } from 'npm:@supabase/supabase-js@2';

const headers = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json',
};
const reply = (status: number, message: string) =>
  new Response(JSON.stringify({ message }), { status, headers });

Deno.serve(async (request: Request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers });
  if (request.method !== 'POST') return reply(405, 'Method not allowed.');
  const url = Deno.env.get('SUPABASE_URL')!;
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false, autoRefreshToken: false } });
  let token: string | undefined;
  let path: string | undefined;
  const cleanup = async () => {
    if (!token || !path) return;
    const { data, error } = await admin.from('mentor_signup_uploads').select('user_id').eq('token', token).maybeSingle();
    // Never remove evidence if signup succeeded but its HTTP response was lost.
    if (error || data?.user_id) return;
    await admin.storage.from('mentor-qualifications').remove([path]);
    await admin.from('mentor_signup_uploads').delete().eq('token', token).is('user_id', null);
  };
  try {
    const form = await request.formData();
    const text = (key: string) => String(form.get(key) ?? '').trim();
    const email = text('email').toLowerCase();
    const password = String(form.get('password') ?? '');
    const file = form.get('qualification');
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254 ||
      password.length < 8 || password.length > 128 || !/[A-Z]/.test(password) ||
      !/[a-z]/.test(password) || !/[0-9]/.test(password) || !/[^A-Za-z0-9\s]/.test(password)) {
      return reply(400, 'Enter a valid email address and a strong password.');
    }
    for (const [key, min, max] of [['name', 2, 100], ['expertise', 3, 500]] as const) {
      if (text(key).length < min || text(key).length > max) return reply(400, 'Complete your account and mentor information.');
    }
    if (!(file instanceof File) || file.size < 1 || file.size > 10485760) {
      return reply(400, 'Upload a qualification document up to 10 MB.');
    }
    const bytes = new Uint8Array(await file.arrayBuffer());
    const starts = (header: number[]) => header.every((b, i) => bytes[i] === b);
    const ext = file.name.split('.').pop()?.toLowerCase();
    const mime = ext === 'pdf' && starts([37, 80, 68, 70, 45]) ? 'application/pdf'
      : ['jpg', 'jpeg'].includes(ext ?? '') && starts([255, 216, 255]) ? 'image/jpeg'
      : ext === 'png' && starts([137, 80, 78, 71, 13, 10, 26, 10]) ? 'image/png' : null;
    if (!mime) return reply(400, 'Upload a valid PDF, JPEG or PNG qualification document.');
    token = crypto.randomUUID();
    path = `registration-${token}/qualification.${mime === 'application/pdf' ? 'pdf' : mime === 'image/png' ? 'png' : 'jpg'}`;
    const { error: uploadError } = await admin.storage.from('mentor-qualifications')
      .upload(path, bytes, { contentType: mime, upsert: false });
    if (uploadError) return reply(503, 'Could not upload your qualification. Please try again.');
    const { error: reserveError } = await admin.from('mentor_signup_uploads')
      .insert({ token, email, qualification_path: path });
    if (reserveError) { await cleanup(); return reply(503, 'Mentor registration is temporarily unavailable.'); }
    const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!,
      { auth: { persistSession: false, autoRefreshToken: false } });
    const { error: signupError } = await caller.auth.signUp({ email, password,
      options: {
        // Use the project's configured Site URL and allowed mobile callback.
        emailRedirectTo: text('redirect'),
        data: { full_name: text('name'), date_of_birth: text('birth_date'), role: 'mentor',
          mentor_upload_token: token, mentor_expertise: text('expertise') },
      },
    });
    if (signupError) {
      await cleanup();
      return reply(400, 'Could not create the account. Check your details or sign in if you already have an account.');
    }
    // Existing-email signup responses can be obfuscated. Only the database insert
    // trigger may claim this token; never attach evidence to a returned user ID.
    await cleanup();
    return reply(200, 'If your account is eligible, check your verification email. Sign in after verification to view your mentor approval status.');
  } catch (_) {
    await cleanup();
    return reply(400, 'Could not complete mentor registration. Check your details and try again.');
  }
});
