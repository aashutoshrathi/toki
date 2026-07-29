// Toki Remote Control service worker: caches the static app shell so the UI loads
// offline and installs as a PWA. Agent data lives on the Mac over a different origin
// and is never touched here.
const CACHE = "toki-rc-v2";
const SHELL = [
  "./",
  "index.html",
  "styles.css",
  "app.js",
  "markdown.js",
  "favicon.svg",
  "manifest.webmanifest",
  "icon-192.png",
  "icon-512.png",
  "apple-touch-icon.png",
];

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
      for (const client of list) {
        if ("focus" in client) return client.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow("./");
    })
  );
});

self.addEventListener("fetch", event => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  // Only the static shell is ours. Agent API calls (cross-origin over the tailnet, or same-origin
  // when Toki serves the UI directly) must always hit the network, never a cache.
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith("/api/")) return;

  // Network-first for the whole shell so index.html and app.js/styles.css never fall out of
  // sync after a deploy. The cache is only an offline fallback.
  event.respondWith(
    fetch(request)
      .then(response => {
        if (response.ok) caches.open(CACHE).then(cache => cache.put(request, response.clone()));
        return response;
      })
      .catch(() =>
        caches.match(request).then(hit =>
          hit || (request.mode === "navigate" ? caches.match("index.html") : Response.error())
        )
      )
  );
});
