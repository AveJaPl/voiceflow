# VoiceFlow na Apple: wydanie publiczne, jeden silnik, mniej opcji

Data: 2026-09-14 · Status: **plan do decyzji** · Zakres: macOS + iOS + relay + landing.
Linux/Windows/Android (Filip, Bonczur) poza zakresem, poza punktami styku (API
serwera, format historii).

---

## 1. Stan faktyczny (sprawdzony w kodzie i na tym Macu, 2026-09-14)

**Gałęzie.** Cała praca Apple siedzi na `origin/worktree-ios-remote-mac` (42 commity,
ostatni 2026-08-14), niezmergowana. `origin/main` poszedł dalej (Windows 0.6.2,
2026-09-11, Bonczur). Lokalny `main` jest 1 commit za. Konflikt merge'a: tylko
`CHANGELOG.md`/`README.md`; katalogi `macos/ ios/ relay/ shared/` są rozłączne.

**Rozmiar.** macOS 15 tys. linii Swifta, iOS 6 tys., relay 1,4 tys. JS, `shared/wire`
0,9 tys.

**Silnik macOS.** whisper.cpp linkowany **wprost z Homebrew** — `otool -L` na
`~/Applications/VoiceFlow.app` pokazuje `/opt/homebrew/opt/whisper-cpp/lib/libwhisper.1.dylib`
i `/opt/homebrew/opt/ggml/...`. Na Macu bez `brew install whisper-cpp` apka nie
wystartuje. **To jest pierwszy blokier publicznego wydania**, przed czymkolwiek innym.
Backendy Metal ładowane z `/opt/homebrew/opt/ggml/libexec` (fallback na
`Contents/Resources/ggml-backends`, którego release nie wypełnia).

**RAM.** Proces z modelem `small-q5_1` (bieżące ustawienie): `phys_footprint` **527 MB**
(szczyt 543 MB), z czego Δ379 MB to sam model (`~/Library/Logs/VoiceFlow/voiceflow.log`).
Model siedzi w pamięci od startu do zamknięcia apki, także gdy przez godziny nic nie
dyktujesz. Z `large-v3-turbo-q5` będzie ~1,0–1,2 GB (szacunek z rozmiaru pliku 574 MB
plus bufory Metalu; nie mierzone). Na 16 GB to jest odczuwalne, ale to nie RAM jest
problemem, tylko fakt, że model nigdy nie jest zwalniany.

**Silnik iOS.** `SFSpeechRecognizer(pl-PL)` on-device w kontenerze apki. Rozszerzenie
klawiatury **nie ma dostępu do mikrofonu** (twarde ograniczenie iOS, potwierdzone
2026-08-10) — stąd przepływ klawiatura → `voiceflow://dictate` → apka → powrót i
`insertText` z App Group. Ten przepływ zostaje, bo innego nie ma.

**Nowe API Apple nie pomoże.** `SpeechTranscriber.supportedLocales` na tym Macu
(macOS 26.6.2): de, en, es, fr, it, ja, ko, pt, zh, yue. **Polskiego nie ma.**
Whisper pozostaje jedyną drogą do dobrej jakości po polsku na obu platformach.

**WhisperKit** (argmax-oss-swift v1.0, 2026-05, MIT): whisper na Core ML / Neural
Engine, iOS 17+/macOS 14+, `large-v3-turbo` na iPhone 15 Pro ~7× szybciej niż czas
rzeczywisty, streaming <200 ms do pierwszego słowa (dane producenta, nie nasz pomiar).
Android już ma whisper.cpp na urządzeniu (IME, modele q5_1) — iOS jest jedyną
platformą, która dziś nie liczy whisperem.

**Relay / konta.** `voiceflow-relay` działa na **Contabo**, które jest wypowiedziane
na **30.09.2026**. Buduje z mirrora na prywatnym GitHubie (`Plonkawojciech/voiceflow-apple`),
bo GitHub App Coolify nie widzi `AveJaPl`. Rejestracja wyłącznie przez `ADMIN_SECRET`
(usługa prywatna). To trzeba przenieść niezależnie od reszty planu.

**Pigułka (pill).** Waveform w `.listening`: 24 słupki z historii RMS. Dwa problemy
z Twojego zgłoszenia mają konkretne przyczyny w `macos/VoiceFlow/UI/PillView.swift`:
- „kreska idzie do góry przy ciszy": `WaveformView` rysuje `HStack` wewnątrz
  `GeometryReader`, a `GeometryReader` kładzie zawartość w **lewym górnym rogu**.
  Przy ciszy słupki mają 2 px, cały `HStack` ma 2 px wysokości i siedzi u góry ramki
  120×20. Przy mowie rośnie w dół. Poprawka to jedna linia (`frame(maxWidth:
  .infinity, maxHeight: .infinity)` / wyrównanie do środka), plus słupki rysowane
  symetrycznie od osi.
- „mało dynamiczne": jeden skalar RMS na bufor, bez ataku/opadania, bez pasm, bez
  sprężyny na słupek; przy ciszy brak stanu „oddychania".

**Opcje w apkach.** macOS ma 5 stron (Przegląd, Historia, Pokój, Słownik, Ustawienia)
i ~30 kluczy ustawień, w tym: ducking, skrót wyciszania Discorda, Discord Rich
Presence, zdalny mikrofon, pokoje (7 kluczy), ambient/komendy głosowe, izolacja
mikrofonu, wybór silnika Apple/whisper. Do tego okno Notatek, licznik użycia Claude'a,
NowPlaying, zdalne sterowanie pulpitem (zrzuty ekranu, lista okien, tekst terminala,
przełączanie Spaces, wysyłanie skrótów). iOS ma 5 zakładek: Pulpit, **Mac**, Historia,
**Pokoje**, Ustawienia. Zakładka Mac to ~2 tys. linii (RemoteSession, MacControlView,
DesktopMap, TerminalPreview, MicStreamer) plus ~1,5 tys. po stronie Maca
(`Core/RemoteDesktop/`, `RemoteMicClient`).

---

## 2. Pytanie o VM: gdzie ma liczyć whisper

Rozważane warianty dla Twoich trzech urządzeń (Twój Mac, iPhone, Mac Bartka):

| wariant | opóźnienie po puszczeniu skrótu | koszt | prywatność | działa bez sieci |
|---|---|---|---|---|
| A. każde urządzenie liczy u siebie (dziś Mac; iPhone po zmianie na WhisperKit) | Mac Metal: 0,2–0,5 s zmierzone; iPhone 15 Pro turbo: ~1 s szacunek | 0 | audio nie opuszcza urządzenia | tak |
| B. serwer na VM (netcup RS 2000, 8 rdzeni EPYC, **bez GPU**, 16 GB dzielone z prodem Coolify) | CPU turbo-q5 na 30-sekundowym oknie: rząd 2–5 s (szacunek, nie mierzone) + sieć 0,1–0,3 s | ~1,5 GB RAM stale + piki CPU na prodzie | audio idzie na VM | nie |
| C. Twój Mac jako serwer dla iPhone'a i Maca Bartka (przez relay lub LAN/Tailscale) | jak A dla Twojego Maca + sieć | 0 | audio idzie na Twój Mac | nie, gdy Mac śpi |

**Rekomendacja: A jako domyślne i jedyne wymagane, B/C jako opcjonalny „własny
serwer” pod jednym polem adresu.** Powody:

1. VM bez GPU jest **wolniejsza** niż Metal na Macu i ANE na iPhonie. Przeniesienie
   liczenia na VM to regresja czasu oczekiwania, nie poprawa. Do tego to prod z 19
   apkami — whisper na 8 rdzeniach kładzie przez kilka sekund wszystko inne.
2. iPhone i tak musi umieć liczyć sam (Mac śpi, jesteś poza domem, brak sieci) —
   więc silnik lokalny na iOS jest obowiązkowy, a serwer tylko dodatkiem.
3. Dla publicznego wydania „audio nigdy nie opuszcza urządzenia” jest całą obietnicą
   produktu (tak brzmi README Linuksa). Serwer jako domyślna droga tę obietnicę psuje.
4. „Ogarnia 2–3 urządzenia” to nie jest problem liczenia, tylko **synchronizacji
   historii i słownika** między urządzeniami — i to załatwia konto (relay), które już
   jest, nie serwer transkrypcji.

Co z RAM-em na Macu: **zwalnianie modelu po bezczynności** (np. 10 min bez dyktowania
→ `WhisperContext` zwolniony, RSS spada do ~60 MB; następne wciśnięcie skrótu ładuje
model w tle — `small` w 0,4 s zmierzone, turbo do zmierzenia; pigułka pokazuje
„Ładuję model…” zamiast udawać, że słucha). To załatwia 90% problemu bez żadnego
serwera.

Jeśli mimo to chcesz serwer (np. dla Maca Bartka z Intelem albo starego iPhone'a):
kontrakt to **OpenAI-compatible `POST /v1/audio/transcriptions`** (multipart WAV,
`model`, `language`, `prompt` = słownik). Pod ten kontrakt podłącza się bez żadnego
kodu: `whisper-server` z whisper.cpp, `faster-whisper-server`, Speaches, a także
płatne API (OpenAI, Groq) dla tych, którzy chcą. Nie piszemy własnego serwera —
jest gotowy w whisper.cpp (`whisper-server`) i wystarczy obraz Dockera w `server/`.
Twój Mac może ten sam endpoint wystawić w LAN z apki (przełącznik „Udostępnij silnik
w sieci lokalnej”, Bonjour `_voiceflow._tcp`) — to jest wariant C w jednym
przełączniku, bez relaya i bez zrzutów ekranu.

---

## 3. Docelowa architektura

```
                 ┌──────────────── SpeechEngine (protokół, bez zmian) ────────────────┐
                 │  LocalWhisper (Mac: whisper.cpp w pakiecie; iOS: WhisperKit)       │
                 │  RemoteWhisper (POST /v1/audio/transcriptions, adres + klucz)     │
                 │  AppleSpeech (zostaje jako fallback dla języków bez modelu)        │
                 └────────────────────────────────────────────────────────────────────┘
   macOS: skrót → nagranie → silnik → wklejenie (jak dziś)        model zwalniany po bezczynności
   iOS:   klawiatura → apka → silnik → powrót → insertText          WhisperKit, ANE

   Konto (opcjonalne, self-host): relay = historia + słownik + ustawienia między urządzeniami.
   Bez konta apka działa w 100 % lokalnie. Nie hostujemy kont dla świata.
```

Zasady:
- **Zero konfiguracji na start.** Pierwsze uruchomienie: uprawnienia → pobranie
  modelu domyślnego z paskiem postępu → skrót → test „powiedz coś”. Wszystkie inne
  opcje w „Zaawansowane”.
- **Model domyślny:** Mac Apple Silicon → `large-v3-turbo-q5` greedy (0,5 s zmierzone,
  najlepsza jakość); iPhone ≥ 15 Pro → `large-v3-turbo` (WhisperKit, quant);
  słabsze iPhone'y → `small`. Wybór automatyczny po `hw.model`/RAM, ręczny w
  Zaawansowanych.
- **Jeden kontrakt serwera** (OpenAI-compatible), jeden obraz Dockera w `server/`,
  jedno pole „Adres serwera” w Zaawansowanych. Bez relaya w tej ścieżce.
- **Konto tylko do synchronizacji.** Relay traci funkcje zdalnego pulpitu i
  zdalnego mikrofonu; zostaje: login, historia, słownik, ustawienia. Rejestracja
  publiczna wyłączona (tak jak dziś) — hostujemy dla siebie, kod jest w repo dla
  innych.
- **Dystrybucja:** iOS przez App Store; macOS przez **DMG z podpisem Developer ID +
  notaryzacja**, nie Mac App Store (sandbox MAS blokuje globalny skrót, CGEvent i
  wklejanie do cudzych okien — wszystkie apki tej klasy są poza MAS). Auto-aktualizacja
  przez istniejący `UpdateChecker` (GitHub Releases jako CDN plików; użytkownik na
  GitHub nie wchodzi, klika na landingu). Android przez Play (poza tym planem).

---

## 4. Etapy

Kolejność wynika z ryzyka: najpierw to, co blokuje wydanie i przenosiny infrastruktury
(termin 30.09), potem produkt, na końcu polerka.

### Etap 0 — porządek w repo i infrastrukturze (przed jakąkolwiek zmianą kodu)

- Merge `origin/main` → `worktree-ios-remote-mac` (konflikty tylko w CHANGELOG/README),
  rebase nie: 42 commity są już na remote.
- Relay: nowa apka Coolify na **netcup**, wolumen `/app/data` skopiowany z Contabo
  (`relay.db` + `pairing.json`), nowy adres pod własną domeną (nie `sslip.io`),
  `defaultAccountHost` w `SettingsView.swift` i iOS `AccountAPI.swift` podmieniony.
  Mirror `Plonkawojciech/voiceflow-apple` → organizacja Programo albo GitHub App
  Coolify podpięta do `AveJaPl` (Filip dodaje App do repo). Decyzja Filipa.
- Weryfikacja: login z Maca i iPhone'a na nowy relay, historia widoczna, Contabo
  wyłączone z konfiguracji.

### Etap 1 — Mac samowystarczalny (blokier wydania)

- whisper.cpp jako **Swift Package** (repo ggml-org/whisper.cpp ma `Package.swift`
  z Metalem) zamiast `-lwhisper` z Homebrew. Usunięcie `HEADER_SEARCH_PATHS`/
  `LIBRARY_SEARCH_PATHS` z `project.yml`. `loadBackends()` traci ścieżki Homebrew.
- Pomiar po zmianie na tej samej próbce (`VoiceFlowTests/Fixtures/dyktowanie-pl.wav`):
  czas ładowania, warmup, czas przebiegu końcowego dla `small` i `turbo` — porównać
  z 0,19 s / 0,5 s z pamięci. Jeśli pakiet SPM nie ładuje Metalu, to jest stop.
- Zwalnianie modelu po bezczynności (`SettingsKeys.modelIdleUnloadMinutes`, domyślnie
  10) + stan pigułki „Ładuję model…”.
- Developer ID + notaryzacja w `tools/release-mac.sh` (`codesign --options runtime`,
  `notarytool submit --wait`, `stapler`), DMG zamiast ZIP dla pierwszej instalacji,
  ZIP zostaje dla `UpdateChecker`.
- Weryfikacja: świeże konto użytkownika macOS bez Homebrew → instalacja z DMG →
  pierwsze dyktowanie działa. To jest jedyny test, który się liczy.

### Etap 2 — iOS: whisper na urządzeniu, klawiatura i nic więcej

- `WhisperKit` jako SPM, nowy `WhisperKitEngine` za tym samym protokołem co
  `ContainerDictationEngine`; `SFSpeechRecognizer` zostaje jako fallback, gdy model
  jeszcze nie pobrany.
- Pobieranie modelu w onboardingu z paskiem postępu; wybór modelu po urządzeniu.
- **Usunięcie zakładek Mac i Pokoje** oraz kodu pod nimi (`Remote/RemoteSession`,
  `MicStreamer`, `ControlTransport`, `UI/Remote/*`, `RoomsView`) — ~2,5 tys. linii
  mniej. Zostają: Pulpit (statystyki), Historia, Ustawienia (konto + model + słownik).
  Onboarding: włącz klawiaturę → Full Access → mikrofon → model → test.
- Pomiar na Twoim iPhonie: czas od puszczenia do tekstu dla 3, 10, 30 s mowy;
  zużycie baterii przy 50 dyktowaniach (Xcode Energy gauge) — WhisperKit na ANE vs
  dzisiejszy SFSpeech.
- Weryfikacja: dyktowanie w Wiadomościach, Safari i Notatkach z klawiatury; powrót
  do klawiatury i wstawienie tekstu.

### Etap 3 — Mac: mniej opcji, pigułka

- Ustawienia w dwóch warstwach: **Podstawowe** (skrót, język, model, podgląd na
  żywo, słownik, konto) i **Zaawansowane** (ducking, izolacja mikrofonu, tryb
  wklejania, serwer transkrypcji, udostępnianie silnika w LAN).
- Do decyzji (§5): Discord (mute + presence), Pokój, Ambient/komendy głosowe,
  Notatki, licznik Claude'a, NowPlaying, `Core/RemoteDesktop/*`, `RemoteMicClient`.
  Propozycja: RemoteDesktop i RemoteMic **usunąć** (iOS ich nie używa po Etapie 2),
  Discord/Ambient/Claude/NowPlaying **za flagą „Laboratorium”** wyłączoną domyślnie,
  Pokój zostaje (parytet z Linuksem, Filip tego używa), Notatki → to samo co Historia
  (jedno okno).
- Pigułka:
  - wyśrodkowanie waveformu (przyczyna w §1), słupki od osi w obie strony;
  - poziomy: atak 30 ms / opadanie 250 ms (wygładzanie wykładnicze na `AudioCapture`),
    5–7 pasm z lekkiego FFT (vDSP) zamiast jednego RMS, każdy słupek ze sprężyną
    (`.interactiveSpring`), stan ciszy = wolny „oddech” 0,9 s zamiast płaskiej kreski;
  - `.transcribing`/`.finalizing` z ciągłą animacją (nie statyczną ikoną);
  - `reduceMotion` respektowane jak dziś.
- Weryfikacja: nagranie ekranu 10 s ciszy + 10 s mowy, wysłane do Ciebie.

### Etap 4 — serwer opcjonalny (własny lub Twój Mac)

- `RemoteWhisperEngine` (macOS + iOS): `POST /v1/audio/transcriptions`, multipart
  WAV 16 kHz, `prompt` = słownik, timeout 15 s, przy błędzie fallback na lokalny.
- `server/`: `Dockerfile` na `whisper-server` z whisper.cpp + `compose.yml` z jednym
  wolumenem na modele; opis w README „własny serwer w 3 komendach”.
- Mac: „Udostępnij silnik w sieci lokalnej” — mały serwer HTTP w apce (Network
  framework) na tym samym kontrakcie, ogłaszany przez Bonjour; iPhone i Mac Bartka
  widzą go na liście bez wpisywania adresu; token wyświetlany w Ustawieniach.
- Pomiar z VM (żeby zamknąć temat liczbą, nie szacunkiem): kontener na netcup,
  `turbo-q5` na 8 rdzeniach, ta sama próbka `dyktowanie-pl.wav` — czas i obciążenie.

### Etap 5 — konto jako synchronizacja i landing

- Relay: `PUT/GET /vocabulary`, `PUT/GET /settings` (JSON), istniejąca historia bez
  zmian; usunięcie ról `mac`/`phone` z WS po Etapie 2–3 (zostaje REST). Rejestracja
  nadal za `ADMIN_SECRET`; `docker compose` w `relay/` do self-hostu.
- Landing (`site/`): sekcja „Pobierz” z trzema przyciskami (App Store, DMG, Play),
  „Jak to działa” (lokalnie, bez chmury), „Własny serwer” (jedna komenda), polityka
  prywatności per platforma (wymagana przez App Store).
- App Store: build TestFlight → recenzja. Do przygotowania: opis, zrzuty, polityka
  prywatności (już jest `site/pl/prywatnosc`), formularz Export Compliance.

### Poza planem (świadomie)

- Mac App Store — patrz §3.
- Publiczna rejestracja kont hostowana przez Programo — koszt i odpowiedzialność za
  cudze dane bez modelu przychodu.
- Zmiana silnika Maca na WhisperKit — dopiero jeśli pomiar z Etapu 1 wypadnie źle
  albo chcemy jednego silnika na obu platformach; dziś whisper.cpp na Metalu jest
  zmierzony i działa.

---

## 5. Decyzje, których potrzebuję od Ciebie

1. **VM jako serwer transkrypcji:** zgadzasz się na „lokalnie domyślnie, serwer
   opcjonalnie” (rekomendacja w §2), czy chcesz mimo wszystko serwer na netcup jako
   główną ścieżkę dla swoich trzech urządzeń?
2. **Co wypada z Maca:** RemoteDesktop + RemoteMic (usunąć), Discord/Ambient/Claude/
   NowPlaying (Laboratorium), Pokój (zostaje), Notatki (scalić z Historią)?
3. **Pokoje na iOS:** usunąć razem z zakładką Mac (propozycja), czy zostawić?
4. **Konto:** self-host only (rejestracja za sekretem, jak dziś) — potwierdź.
5. **Silnik iOS:** WhisperKit (Core ML/ANE) — potwierdź; alternatywa whisper.cpp jak
   Android (Metal, gorzej dla baterii, ale ten sam kod co Mac).
6. **Repo/mirror:** pytanie do Filipa o GitHub App Coolify na `AveJaPl/voiceflow`;
   jeśli nie — mirror w organizacji Programo.
7. **Nazwa i strona:** wydanie pod marką `voiceflow` Filipa (landing `site/` w tym
   repo) — potwierdź, że nie robimy osobnej marki Programo.

Po decyzjach: Etap 0 i 1 idą od razu (nie wymagają niczego poza pkt 6), Etap 2 w
osobnej sesji, 3–5 kolejno. Każdy etap kończy się commitem na `worktree-ios-remote-mac`
(albo nowej gałęzi `apple/2.0` po merge'u z main) i pomiarem opisanym przy etapie.
