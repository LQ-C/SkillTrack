import { clearOwnedFolder, resourceCleanupBuckets } from './storage_cleanup.ts';
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
  const authorization = request.headers.get('Authorization');
  if (!authorization?.startsWith('Bearer ')) return reply(401, 'Sign in first.');
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const adminKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const caller = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: { user }, error } = await caller.auth.getUser(authorization.slice(7));
    if (error || !user?.email) return reply(401, 'Sign in first.');
    const body = await request.json();
    if (typeof body.password !== 'string' || body.password.length < 1 || body.password.length > 128) {
      return reply(400, 'Enter your current password.');
    }
    // Authenticate on the server. Never trust a user ID or a client-only password check.
    const { data: verified, error: passwordError } = await caller.auth.signInWithPassword({
      email: user.email, password: body.password,
    });
    if (passwordError || verified.user?.id !== user.id) return reply(403, 'Password could not be verified.');
    const admin = createClient(url, adminKey, { auth: { persistSession: false, autoRefreshToken: false } });
    // Auth cannot remove a user who still owns Storage objects. Qualification
    // files live in a flat, private per-user folder and must be removed via the
    // Storage API (deleting storage.objects rows would leave the binary files).
    const { data: buckets, error: bucketError } = await admin.storage.listBuckets();
    if (bucketError) return reply(500, 'Could not prepare account deletion. Try again later.');
    if (buckets.some(bucket => bucket.id === 'mentor-qualifications')) {
      const qualifications = admin.storage.from('mentor-qualifications');
      // Registration evidence is uploaded before a user ID exists, so its
      // private path is recorded separately from the normal per-user folder.
      const { data: application, error: applicationError } = await admin.from('tutor_profiles')
        .select('qualification_path').eq('user_id', user.id).maybeSingle();
      if (applicationError && applicationError.code !== '42P01' && applicationError.code !== 'PGRST205') {
        return reply(500, 'Could not prepare qualification cleanup. Try again later.');
      }
      const { data: signupEvidence, error: signupEvidenceError } = await admin.from('mentor_signup_uploads')
        .select('qualification_path').eq('user_id', user.id).maybeSingle();
      if (signupEvidenceError && !['42P01','PGRST205'].includes(signupEvidenceError.code)) {
        return reply(500, 'Could not prepare qualification cleanup. Try again later.');
      }
      const registrationPaths = [...new Set([application?.qualification_path, signupEvidence?.qualification_path]
        .filter((path): path is string => typeof path === 'string' && path.startsWith('registration-')))];
      if (registrationPaths.length) {
        const { error: evidenceError } = await qualifications.remove(registrationPaths);
        if (evidenceError) return reply(500, 'Could not remove qualification documents. Try again later.');
      }
      while (true) {
        const { data: files, error: listError } = await qualifications.list(user.id, { limit: 100, offset: 0 });
        if (listError) return reply(500, 'Could not remove qualification documents. Try again later.');
        if (!files.length) break;
        const { error: removeError } = await qualifications.remove(files.map(file => `${user.id}/${file.name}`));
        if (removeError) return reply(500, 'Could not remove qualification documents. Try again later.');
      }
    }
    // The caller has already reauthenticated above. Traverse only their UUID
    // prefix in known private buckets; never delete another user's objects.
    for (const bucket of resourceCleanupBuckets) {
      await clearOwnedFolder(admin.storage.from(bucket), user.id);
    }
    const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
    if (deleteError) return reply(500, 'Could not delete your account. Try again later.');
    return reply(200, 'Account deleted.');
  } catch (_) {
    return reply(400, 'Could not complete the account deletion request.');
  }
});
