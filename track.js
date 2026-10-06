// Cookie-less visit counter: sends only the page path (no IP, no identifiers) once per
// browser tab session per page. Skips bots and the signed-in studio owner.
(function () {
  try {
    var url = window.SUPABASE_URL, key = window.SUPABASE_ANON_KEY;
    if (!url || !key) return;
    if (navigator.webdriver || /bot|crawl|spider|slurp|preview|headless|lighthouse/i.test(navigator.userAgent)) return;
    if (/^(localhost|127\.|0\.0\.0\.0)/.test(location.hostname)) return;
    // don't count the studio owner (a Supabase session in this browser means signed in to /admin)
    for (var i = 0; i < localStorage.length; i++) {
      var k = localStorage.key(i);
      if (k && /^sb-.*-auth-token$/.test(k)) return;
    }
    var path = location.pathname.replace(/index\.html$/, '') || '/';
    var flag = 'cq_seen:' + path;
    if (sessionStorage.getItem(flag)) return;
    sessionStorage.setItem(flag, '1');
    fetch(url + '/rest/v1/rpc/track_view', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: key, Authorization: 'Bearer ' + key },
      body: JSON.stringify({ p_path: path }),
      keepalive: true
    }).catch(function () {});
  } catch (e) { /* never break the page */ }
})();
