// Service worker MyTunigo — volontairement minimal.
// Objectif : permettre l'installation de l'app et un chargement plus rapide/
// résilient de la coquille (index.html + assets statiques), SANS jamais
// mettre en cache les appels Supabase (prix, disponibilités, réservations…)
// qui doivent toujours refléter les données les plus fraîches.

const CACHE_NAME = 'mytunigo-shell-v1';
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
