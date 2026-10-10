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
      body: JSON.stringify({ p_path: path, p_referrer: referrerBucket() }),
      keepalive: true
    }).catch(function () {});
  } catch (e) { /* never break the page */ }

  // Where the visit came from, reduced to a coarse source name. Only a hostname-style
  // label is ever sent (never a full URL, query string or anything personal). An explicit
  // ?utm_source=... on a link you share wins, so you can tag individual posts.
  function referrerBucket() {
    try {
      var utm = (new URLSearchParams(location.search).get('utm_source') || '').toLowerCase().replace(/[^a-z0-9.-]/g, '').slice(0, 40);
      if (utm) return utm;
      if (!document.referrer) return 'direct';
      var host = new URL(document.referrer).hostname.toLowerCase().replace(/^(www|m|l|lm|mobile)\./, '');
      if (!host || host === location.hostname.toLowerCase().replace(/^www\./, '')) return 'direct';
      var known = [
        [/(^|\.)google\./, 'google'], [/(^|\.)bing\.com$/, 'bing'], [/duckduckgo\.com$/, 'duckduckgo'],
        [/(^|\.)instagram\.com$/, 'instagram'], [/(^|\.)facebook\.com$|(^|\.)fb\.com$/, 'facebook'],
        [/(^|\.)tiktok\.com$/, 'tiktok'], [/(^|\.)reddit\.com$/, 'reddit'], [/(^|\.)pinterest\./, 'pinterest'],
        [/(^|\.)(twitter|x)\.com$|^t\.co$/, 'x-twitter'], [/(^|\.)bsky\.app$/, 'bluesky'],
        [/(^|\.)tumblr\.com$/, 'tumblr'], [/(^|\.)youtube\.com$|^youtu\.be$/, 'youtube'], [/(^|\.)threads\.net$/, 'threads']
      ];
      for (var j = 0; j < known.length; j++) if (known[j][0].test(host)) return known[j][1];
      return host.replace(/[^a-z0-9.-]/g, '').slice(0, 60) || 'direct';
    } catch (e) { return 'direct'; }
  }
})();
