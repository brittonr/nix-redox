/* Direct-header hosts do not need this fallback. Pages first visits reload once. */
(() => {
  const VERSION = 'redox-isolation-v1';
  if (typeof window === 'undefined') {
    self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
    self.addEventListener('message', event => {
      if (event.data?.type === 'redox-isolation-version') event.ports[0]?.postMessage({version: VERSION, scope: self.registration.scope});
    });
    self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
    self.addEventListener('fetch', event => {
      const request = event.request;
      if (new URL(request.url).origin !== self.location.origin) return;
      event.respondWith((async () => {
        // only-if-cached/same-origin is valid for Chromium's document cache probes.
        if (request.cache === 'only-if-cached' && request.mode !== 'same-origin') return fetch(request);
        const path = new URL(request.url).pathname;
        const immutable = (/\/assets\/[a-f0-9]{64}\//.test(path) || /\/revisions\/[^/]+\//.test(path)) && !path.endsWith('/coi-serviceworker.js');
        const requestHeaders = new Headers(request.headers);
        if (!immutable) {
          requestHeaders.delete('If-Modified-Since');
          requestHeaders.delete('If-None-Match');
        }
        const response = await fetch(immutable ? request : new Request(request, {cache:'no-store', headers:requestHeaders}));
        if (response.type === 'opaque' || response.status === 0) return response;
        const headers = new Headers(response.headers);
        headers.set('Cross-Origin-Opener-Policy', 'same-origin');
        headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
        headers.set('Cross-Origin-Resource-Policy', 'same-origin');
        headers.set('Cache-Control', immutable && response.ok ? 'public, max-age=31536000, immutable' : 'no-store');
        return new Response(response.body, {status: response.status, statusText: response.statusText, headers});
      })());
    });
    return;
  }
  async function bounded(promise, phase) {
    let timer;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`Isolation worker ${phase} timed out after 15 seconds.`)), 15000);
      })]);
    } finally { clearTimeout(timer); }
  }
  window.redoxIsolationReady = (async () => {
    if (window.crossOriginIsolated) return {isolated: true, method: navigator.serviceWorker?.controller ? 'service-worker' : 'headers'};
    if (!window.isSecureContext || !('serviceWorker' in navigator)) {
      throw new Error('Cross-origin isolation unavailable: use HTTPS or localhost and a COOP/COEP host; service workers are unsupported here.');
    }
    const script = document.currentScript?.src || new URL('coi-serviceworker.js', location.href).href;
    const url = new URL(script);
    const scope = new URL('./', url).href;
    const key = `${VERSION}:${scope}`;
    // A failed SW-controlled reload must never become an infinite reload loop.
    const previous = sessionStorage.getItem(key);
    if (previous === 'reloaded') {
      throw new Error('Isolation service worker controlled reload did not enable crossOriginIsolated. Use a host with COOP: same-origin and COEP: require-corp, or clear this origin site data (including session storage and service workers) and reload.');
    }
    const registration = await bounded(navigator.serviceWorker.register(url.href, {scope, updateViaCache: 'none'}), 'registration');
    await bounded(registration.update(), 'update');
    await Promise.race([
      new Promise((resolve, reject) => {
        const timer = setTimeout(() => { cleanup(); reject(new Error('Isolation service worker control timed out after 15 seconds.')); }, 15000);
        const cleanup = () => { clearTimeout(timer); navigator.serviceWorker.removeEventListener('controllerchange', check); };
        const check = () => {
          if (navigator.serviceWorker.controller?.scriptURL === url.href) { cleanup(); resolve(); }
        };
        navigator.serviceWorker.addEventListener('controllerchange', check);
        check();
      }),
      navigator.serviceWorker.ready.then(ready => {
        if (ready.scope !== scope) throw new Error(`Isolation worker scope mismatch: ${ready.scope}, expected ${scope}`);
        if (navigator.serviceWorker.controller?.scriptURL === url.href) return;
        return new Promise(() => {});
      }),
    ]);
    if (navigator.serviceWorker.controller?.scriptURL !== url.href) throw new Error('The isolation worker does not control this revision URL.');
    sessionStorage.setItem(key, 'reloaded');
    location.reload();
    // Deliberately never resolves in the old document; no guest may boot there.
    return new Promise(() => {});
  })();
  window.redoxIsolationReady.catch(error => {
    window.dispatchEvent(new CustomEvent('redox-isolation-error', {detail: error.message}));
    console.error(error);
  });
})();
