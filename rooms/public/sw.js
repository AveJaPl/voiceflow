/**
 * Service worker: tyle, ile trzeba, żeby przypięta tablica otwierała się od razu.
 *
 * Powłoka (strona, ikony, tło) z pamięci; dane — NIGDY. Ranking z pamięci
 * podręcznej pokazywałby wynik sprzed godziny jako bieżący, a to gorsze niż
 * pusty ekran, bo wygląda na prawdę.
 */
const SHELL = 'voiceflow-pokoj-v2';
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

  const store = (response) => {
    if (response.ok) {
      const copy = response.clone();
      caches.open(SHELL).then((cache) => cache.put(event.request, copy));
    }
    return response;
  };

  // SAMA STRONA zawsze najpierw z sieci. Odwrotna kolejność znaczyła, że po
  // wdrożeniu widać poprzednią wersję aż do kolejnego otwarcia — czyli „wypchnąłem,
  // a nic się nie zmieniło". Pamięć jest tu wyłącznie zapasem na brak sieci.
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request).then(store).catch(() =>
        caches.match('/', { ignoreSearch: true }).then((hit) => hit ?? Response.error()),
      ),
    );
    return;
  }

  // Reszta — ikony, tło, marmur — nie zmienia się, więc z pamięci od razu,
  // a świeższa wersja dociąga się w tle na następny raz.
  event.respondWith(
    caches.match(event.request, { ignoreSearch: true }).then((hit) =>
      hit || fetch(event.request).then(store),
    ),
  );
});
