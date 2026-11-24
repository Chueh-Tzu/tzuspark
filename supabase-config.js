window.TZUSPARK_SUPABASE = {
  url: "https://pomcueasjwovjbdvzcsa.supabase.co",
  anonKey: "sb_publishable__oyT7E0sCrwmR-fowkAAsA_JUBREYC8"
};

window.tzCreateClient = function () {
  const cfg = window.TZUSPARK_SUPABASE || {};
  if (!cfg.url || !cfg.anonKey || !window.supabase) return null;
  return window.supabase.createClient(cfg.url, cfg.anonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true
    }
  });
};
