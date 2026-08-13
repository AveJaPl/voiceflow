/**
 * Service worker: tyle, ile trzeba, żeby przypięta tablica otwierała się od razu.
 *
 * Powłoka (strona, ikony, tło) z pamięci; dane — NIGDY. Ranking z pamięci
 * podręcznej pokazywałby wynik sprzed godziny jako bieżący, a to gorsze niż
 * pusty ekran, bo wygląda na prawdę.
 */
const SHELL = 'voiceflow-pokoj-v1';
const FILES = [
  '/',
  '/manifest.webmanifest',
  '/assets/bg-relief.webp',
  '/assets/laurel.webp',
  '/assets/favicon.svg',
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(SHELL).then((cache) => cache.addAll(FILES)));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(names.filter((name) => name !== SHELL).map((name) => caches.delete(name))),
    ),
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== location.origin) return;
  // Dane zawsze z sieci. Brak sieci to brak danych i strona sama to powie.
  if (url.pathname.startsWith('/api/')) return;

  event.respondWith(
    caches.match(event.request, { ignoreSearch: true }).then((hit) => {
      const fresh = fetch(event.request)
        .then((response) => {
          if (response.ok) {
            const copy = response.clone();
            caches.open(SHELL).then((cache) => cache.put(event.request, copy));
          }
          return response;
        })
        .catch(() => hit);
      // Z pamięci od razu, ale w tle i tak pobierz świeższą wersję.
      return hit || fresh;
    }),
  );
});
