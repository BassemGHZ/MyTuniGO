// Service worker MyTunigo — volontairement minimal.
// Objectif : permettre l'installation de l'app et un chargement plus rapide/
// résilient de la coquille (index.html + assets statiques), SANS jamais
// mettre en cache les appels Supabase (prix, disponibilités, réservations…)
// qui doivent toujours refléter les données les plus fraîches.

const CACHE_NAME = 'mytunigo-shell-v2';
const SHELL_FILES = [
  './',
  './index.html',
  './manifest.json'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES)).catch(()=>{})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = event.request.url;

  // Ne jamais intercepter les appels Supabase (données en temps réel) ni les
  // requêtes non-GET (POST/PUT/DELETE) : toujours réseau direct.
  if (url.includes('supabase.co') || event.request.method !== 'GET') {
    return;
  }

  // Pour la page HTML elle-même : réseau d'abord (toujours la dernière
  // version déployée), avec la version en cache comme repli hors-ligne.
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request)
        .then((res) => {
          const resClone = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, resClone));
          return res;
        })
        .catch(() => caches.match(event.request).then((r) => r || caches.match('./index.html')))
    );
    return;
  }

  // Pour le reste (icônes, manifest, CSS/JS de CDN) : cache d'abord, puis réseau.
  event.respondWith(
    caches.match(event.request).then((cached) => cached || fetch(event.request).catch(() => cached))
  );
});

// ---------------------------------------------------------------------
// Notifications push (envoyées par l'Edge Function send-push)
// Contenu : { title, body, url, tag }
// ---------------------------------------------------------------------
self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = { title: 'MyTunigo', body: event.data ? event.data.text() : '' }; }
  const title = data.title || 'MyTunigo';
  event.waitUntil(self.registration.showNotification(title, {
    body: data.body || '',
    icon: 'icons/icon-192.png',
    badge: 'icons/icon-96.png',
    tag: data.tag || undefined,
    renotify: !!data.tag,
    data: { url: data.url || '/' }
  }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  // Seuls les liens internes au site sont ouverts
  let target;
  try {
    target = new URL((event.notification.data && event.notification.data.url) || '/', self.location.origin);
    if (target.origin !== self.location.origin) target = new URL('/', self.location.origin);
  } catch (e) { target = new URL('/', self.location.origin); }
  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const win = all.find((c) => new URL(c.url).origin === self.location.origin);
    if (win) {
      try { await win.navigate(target.href); } catch (e) {}
      return win.focus();
    }
    return self.clients.openWindow(target.href);
  })());
});

// Le navigateur a renouvelé l'abonnement : la page le réenregistrera à la
// prochaine ouverture (rattachement automatique au compte connecté).
self.addEventListener('pushsubscriptionchange', () => {});
