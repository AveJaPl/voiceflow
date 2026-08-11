# iOS: zdalny podgląd i sterowanie Makiem (zakładka „Mac")

Data: 2026-08-11 · Status: **w budowie** · Zakres: **wyłącznie apka iOS + kontrakt sieciowy**

Aplikacja desktopowa i pipeline transkrypcji są poza zakresem — buduje je równolegle
inny agent. Wszystko, czego ta funkcja wymaga po stronie Maca, jest tu opisane jako
**kontrakt** (§4), nie jako implementacja. Kontrakt jest jednym plikiem Swifta
dołączanym przez oba projekty, więc nie ma jak się rozjechać po cichu.

---

## 1. Decyzje Wojtka (2026-08-11) — wiążące

| decyzja | konsekwencja dla tego planu |
|---|---|
| **Konta robi inny agent** | Nie dotykam parowania ani relaya. Apka iOS trzyma host + token w Keychainie i tyle; gdy pojawią się konta, podmienia się `PairingStore` i nic więcej. **Zero zmian w `relay/`** — żeby nie wejść w drogę tamtej pracy. |
| **QR do szybkiego logowania** | Skaner QR wchodzi, ale jako *sposób wpisania host+token*, nie jako system kont. Kompatybilny z tym, co dowiezie tamten agent. |
| **Podgląd nie musi być ciągły** | Model „na żądanie + push przy zmianie układu", nie strumień. Szczegóły i analiza w §3. |
| **Tylko terminale, zapomnij o przeglądarkach** | Zero AppleScriptu do Chrome/Safari. Cała inteligencja treści idzie w Terminal.app i iTerm2. Okna innych aplikacji są na liście i można je podnieść, ale nie mają podglądu treści. |
| **Tylko iPhone** | `TARGETED_DEVICE_FAMILY` zostaje `"1"`. Layout nie udaje adaptacyjnego. |

---

## 2. Stan faktyczny (zweryfikowany w kodzie)

Działa i jest przetestowane:

- `relay/src/relayHub.js` — WS pass-through `mac` ↔ `phone`, token, 20 testów.
- `macos/…/RemoteMicClient.swift` — Mac odbiera PCM (Int16 LE, mono, 16 kHz) i wpina
  go w istniejący `SessionController`; odsyła `{"type":"focus",…}`.
- `macos/…/FocusProbe.swift` — wie, że Terminal, iTerm2, VS Code, Cursor, Claude
  Desktop, Slack, Discord i Notion **muszą** dostać schowek + ⌘V zamiast pisania
  znak po znaku.

Nie istnieje nigdzie (sprawdzone `grep`-em po całym repo): enumeracja okien
(`CGWindowList` / `SCShareableContent` / `AXWindows`), sterowanie oknami, jakikolwiek
kod sieciowy w apce iOS, target WidgetKit.

Twarde ograniczenie, którego nie ruszamy: **rozszerzenie klawiatury iOS nie ma dostępu
do mikrofonu** (`com.apple.coreaudio.avfaudio 2003329396`, potwierdzone na żywo
2026-08-10). Klawiatura zostaje dokładnie taka, jaka jest.

---

## 3. Podgląd Maca — analiza, o którą prosiłeś

Twoja intuicja („odchodzę od komputera, układ okien się nie zmienia, po co ciągły
strumień") jest słuszna, ale jedno założenie wymaga poprawki, a przy okazji wychodzi
rozwiązanie lepsze niż zrzuty ekranu.

### 3.1 Poprawka: na macOS nie ma „zrzutu bez nagrywania ekranu"

Od macOS Catalina **każde** programowe przechwycenie obrazu ekranu — jedna klatka,
`CGWindowListCreateImage`, `SCScreenshotManager`, cokolwiek — wymaga uprawnienia TCC
**„Nagrywanie ekranu"**. Nie ma słabszego uprawnienia dla „tylko jednego screena".

To zmienia mniej, niż się wydaje: **nazwa uprawnienia jest myląca, nic nie jest
nagrywane.** Zgoda jest jednorazowa, a my robimy pojedyncze klatki na żądanie.
Landmina do zapamiętania: **przy pierwszym nadaniu tego uprawnienia macOS wymaga
restartu aplikacji** — bez tego pierwszy zrzut wraca czarny albo pusty i wygląda jak
bug w kodzie.

Konsekwencja projektowa: **funkcja musi działać bez tego uprawnienia.** Zrzut jest
wzbogaceniem, nie fundamentem. Bez zgody mapka rysuje schematyczne prostokąty z
tytułami — i to wystarcza, żeby rozpoznać rozstawienie.

### 3.2 Odkrycie, które zmienia projekt: terminal da się czytać jako TEKST

Zweryfikowane na żywo na tym Macu, 2026-08-11:

```bash
osascript -e 'tell application "Terminal" to return (get contents of selected tab of window 1)'
# → zwrócił żywą zawartość tej sesji Claude Code
osascript -e 'tell application "Terminal" to return (count of windows)'   # → 6
```

Dla Twojego jedynego przypadku użycia — promptowanie Clauda w terminalu — to jest
**wyraźnie lepsze niż piksele**:

| | zrzut ekranu terminala | tekst przez AppleScript |
|---|---|---|
| czytelność na iPhonie | pulpit 3456 px skalowany do 390 pt — tekst nieczytelny; potrzebny crop w retinie i tak ~150 KB | natywny monospace, dowolny rozmiar czcionki |
| waga jednego odświeżenia | 60–150 KB | **2–8 KB** |
| uprawnienie | Nagrywanie ekranu | Automatyzacja dla Terminala (jeden prompt) |
| można zaznaczyć / skopiować | nie | tak |
| odświeżanie co 1,5 s | nierealne przez komórkę | bez problemu |

Terminal.app: `contents of selected tab of window N` (widoczny ekran) i `history`
(cały bufor). iTerm2: `contents of current session of window N`. Oba zainstalowane —
Wojtek pracuje dziś w Terminal.app (6 okien), iTerm jest w `/Applications`.

### 3.3 Wynikowy model: trzy warstwy, każda z własną częstotliwością

**Warstwa 1 — układ okien (tekst, zdarzeniowo).** Lista okien: aplikacja, tytuł,
prostokąt, kolejność nakładania, które na froncie. ~1 KB. Wysyłana po połączeniu i
przy **zdarzeniu** zmiany (`AXObserver` + `NSWorkspace`, debounce 150 ms). Zero
odpytywania w pętli. To jest szkielet całej funkcji i jedyna warstwa obowiązkowa.

**Warstwa 2 — zrzut pulpitu (piksele, rzadko).** JEDEN zrzut całego pulpitu, nie N
miniatur okien: jedno przechwycenie, jeden payload, a telefon i tak ma prostokąty z
warstwy 1, więc sam narysuje na nim etykiety i obszary dotyku. Skalowany do ~1200 px
szerokości, JPEG q0.6 → 60–120 KB. Wysyłany: przy wejściu w zakładkę, na pociągnięcie
w dół, i push przy zmianie układu (debounce 1 s). **Nigdy jako strumień.**

**Warstwa 3 — treść terminala (tekst, na żywo).** Tylko dla **wybranego** okna
terminala i tylko gdy zakładka „Mac" jest na pierwszym planie telefonu: ostatnie ~200
linii, odświeżane co 1,5 s, wysyłane **tylko gdy skrót treści się zmienił**. To jest
ta funkcja, dla której to wszystko powstaje: widzisz, co Claude wypisuje, i dyktujesz
odpowiedź.

**Sterowanie ruchem trzyma telefon, nie Mac.** Ramka `subscribe` mówi wprost, czego
telefon w tej chwili chce (`windows` / `screenshot` / `terminal: "<id okna>"`), a
`unsubscribe` leci przy wyjściu z zakładki i przy przejściu apki w tło. Mac bez
subskrypcji nie wysyła nic poza odpowiedziami na komendy. Bateria obu urządzeń jest
tu funkcją poprawności protokołu, nie przypadku.

---

## 4. Kontrakt sieciowy

Kanał: ten sam WebSocket przez relay, którego używa zdalny mikrofon. **Relay jest
pass-through — nowe typy ramek nie wymagają w nim żadnej zmiany kodu.**

### 4.1 Zasada podziału ramek

- **Tekstowe** = JSON sterujący, w obie strony.
- **Binarne telefon → Mac** = wyłącznie PCM audio (Int16 LE, mono, 16 kHz).
- **Binarne Mac → telefon** = wyłącznie bajty obrazu, **zawsze bezpośrednio po**
  ramce `screenshot`, która opisuje, co idzie. WebSocket gwarantuje kolejność, więc
  nagłówek-potem-bajty jest jednoznaczny. **Żadnego base64 w JSON** — to +33% na
  ścieżce, na której najbardziej boli.

### 4.2 Źródło prawdy

`shared/wire/ControlFrames.swift` — jeden plik, zero zależności od UIKit/AppKit,
dołączany przez `sources:` w **obu** `project.yml`. Nieznany typ ramki dekoduje się
do `.unknown(type:)` zamiast rzucać wyjątkiem — starsza apka nie może się wywrócić o
nowszego Maca.

`tests/wire/*.json` — utrwalone ramki, dekodowane przez testy jednostkowe **obu**
platform. Kontrakt, który rozjeżdża się cicho, jest gorszy niż brak kontraktu.

### 4.3 Mac → telefon

```jsonc
{ "type":"hello", "protocol":1, "mac":"MacBook Wojtka",
  "caps":{ "screenshot":true, "terminalText":true, "move":true } }

{ "type":"windows", "generation":42,
  "displays":[{ "id":1, "w":3456, "h":2234, "main":true }],
  "windows":[
    { "id":"812:0", "app":"Terminal", "bundleID":"com.apple.Terminal",
      "title":"claude — ~/Programo/voiceflow", "display":1,
      "x":0, "y":0, "w":1728, "h":2234, "z":0,
      "focused":true, "minimized":false,
      "kind":"terminal",        // terminal | other  → telefon wie, gdzie jest podgląd treści
      "inject":"clipboard" }    // z FocusProbe: clipboard | liveTyping
  ] }

{ "type":"screenshot", "generation":42, "format":"jpeg", "w":1200, "h":776, "bytes":81234 }
// ...zaraz po tym JEDNA ramka binarna z bajtami JPEG

{ "type":"terminal", "id":"812:0", "generation":42, "seq":7,
  "lines":["…","…"] }

{ "type":"focus",    "app":"Terminal", "window":"claude — …" }
{ "type":"started",  "target":"812:0" }
{ "type":"preview",  "text":"napisz test do…" }
{ "type":"injected", "target":"812:0", "text":"…", "via":"clipboard" }
{ "type":"error",    "code":"windowGone", "message":"…", "target":"812:0" }
```

Kody błędów: `windowGone`, `focusFailed`, `busy`, `notPermitted`, `unsupported`,
`timeout`, `mac_offline` (ten ostatni pochodzi z relaya, nie z Maca — apka musi go
obsłużyć tak samo).

### 4.4 Telefon → Mac

```jsonc
{ "type":"hello", "protocol":1, "device":"iPhone Wojtka" }
{ "type":"subscribe", "windows":true, "screenshot":true, "terminal":"812:0" }
{ "type":"unsubscribe" }
{ "type":"requestWindows" }
{ "type":"requestScreenshot" }
{ "type":"focusWindow", "id":"812:0", "generation":42 }
{ "type":"moveWindow",  "id":"812:0", "generation":42, "x":1728, "y":0, "w":1728, "h":2234 }
{ "type":"start", "target":"812:0", "generation":42 }   // `target` opcjonalny — bez niego stare zachowanie
{ "type":"end" }
{ "type":"cancel" }
{ "type":"key", "chord":"return" }                      // return | escape | cmdReturn | ctrlC
```

### 4.5 Sekwencja, która nie może wsadzić tekstu w złe okno

Naiwna wersja (telefon osobno prosi o focus, osobno otwiera mikrofon) ma wyścig:
zaczynasz mówić, zanim okno wyszło na front, i prompt do Clauda ląduje w Slacku.
Dlatego **cała sekwencja jest atomowa po stronie Maca**:

```
telefon: przytrzymanie karty
  ├─ NATYCHMIAST otwiera mikrofon i BUFORUJE PCM lokalnie (max 2 s, nie wysyła)
  └─ wysyła {"start", target:"812:0", generation:42}

Mac po `start` z targetem:
  1. generation nieaktualna?      → error windowGone + świeża ramka `windows`
  2. okno nie istnieje?           → error windowGone + świeża ramka `windows`
  3. sesja zajęta (skrót lokalny)?→ error busy
  4. AXRaise(okno) + activate()
  5. weryfikacja w pętli do 500 ms: front == cel?
       nie → error focusFailed    (NIE otwiera sesji, NIC nie wstrzykuje)
  6. sessionController.beginUtterance()
  7. → {"started", target}

telefon po `started`: wypycha bufor i strumieniuje dalej
telefon po `error`:   kasuje bufor, wibracja błędu, ZERO nagrywania
```

Bufor istnieje po to, żeby nie zgubić pierwszego słowa — round-trip przez relay to
60–150 ms, czyli dokładnie „napi…szesz".

**Druga weryfikacja, przed samym wstrzyknięciem.** Jeśli front przestał być celem
(ruszyłeś myszką, wyskoczyło powiadomienie): jedna próba ponownego `AXRaise` +
weryfikacja, a jeśli dalej nie ten — **tekst nie leci nigdzie**, ląduje w pillu na
Macu i wraca do telefonu jako `focusFailed` razem z treścią, żeby nie przepadła.

Zasada: **lepiej nie wstawić niż wstawić w złe okno.**

### 4.6 Enter — wymaganie ukryte w opisie

„Promptować do Clauda w terminalu" to tekst **plus** zatwierdzenie; bez Entera prompt
siedzi w linii i czeka na klawiaturę Maca. Stąd ramka `key` i przycisk **„Wyślij ⏎"**
pod podglądem. Automatyczny Enter po dyktowaniu jest osobnym przełącznikiem,
**domyślnie wyłączonym** — automat w terminalu odpala polecenia, których nie zdążyłeś
przeczytać.

---

## 5. Skąd Mac bierze listę okien (kontrakt dla implementatora strony Maca)

**Accessibility, nie ScreenCaptureKit** — VoiceFlow już ma uprawnienie Dostępności do
wstrzykiwania tekstu, więc warstwa 1 rusza bez ani jednego nowego dialogu. Kolejność
nakładania (z-order) dokłada `CGWindowList`, który bez Nagrywania ekranu nadal zwraca
`kCGWindowNumber`, `kCGWindowOwnerPID` i `kCGWindowBounds` — tylko bez tytułów. Więc:
**AX daje tytuły i sterowanie, CGWindowList daje kolejność**, sklejane po PID +
prostokącie.

Landminy (do wpisania w prompt implementatora):

1. **AX potrafi zawiesić wątek** na nieodpowiadającej aplikacji.
   `AXUIElementSetMessagingTimeout(app, 0.2)` obowiązkowo, enumeracja poza głównym
   wątkiem. Test regresji: `kill -STOP` na procesie — lista musi dalej się odświeżać.
2. **Nie enumerować wszystkiego** — tylko `runningApplications` z
   `activationPolicy == .regular` (~10–20 procesów).
3. **Nie odpytywać w pętli** — `AXObserver` na `kAXWindowCreated`,
   `kAXUIElementDestroyed`, `kAXTitleChanged`, `kAXFocusedWindowChanged`.
4. **Spaces są publicznie niedostępne** — nie da się ich wymienić ani przełączyć.
   Podniesienie okna z innego pulpitu i tak przełącza go automatycznie.
5. **`CGWindowID` nie da się publicznie zmapować na `AXUIElement`**
   (`_AXUIElementGetWindow` jest prywatne — nie używamy). Stąd własny identyfikator
   `"<pid>:<axIndex>"` ważny w obrębie jednej **generacji** migawki; każda komenda
   niesie `generation`, a nieaktualna dostaje `windowGone` zamiast trafić w losowe
   okno.
6. **Terminal ↔ AppleScript**: okna Terminal.app/iTerm2 mają w AppleScripcie
   `bounds`, więc dopasowanie do okna z AX idzie po prostokącie + tytule, bez
   prywatnych API.

---

## 6. Aplikacja mobilna

### 6.1 Nawigacja

`MainTabView` dostaje czwartą zakładkę: **Dyktuj · Mac · Historia · Ustawienia**.
Zakładka **nie pojawia się**, dopóki nie ma sparowanego Maca — zamiast martwego
ekranu z komunikatem. Parowanie żyje w Ustawieniach.

**Klawiatura, onboarding, „Dyktuj" i „Historia" zostają nietknięte.** Ryzyko regresji
w jedynej rzeczy, która dziś działa, jest niedopuszczalne.

### 6.2 Ekran „Mac"

```
┌──────────────────────────────────────┐
│ MacBook Wojtka          ● połączony  │
├──────────────────────────────────────┤
│ ┌──────────────┬───────────────────┐ │  MAPKA — zrzut pulpitu jako podkład
│ │  Terminal    │      Cursor       │ │  (gdy jest) + prostokąty okien
│ │  claude — …  │  RemoteSession…   │ │  z warstwy 1; podświetlony = front
│ └──────────────┴───────────────────┘ │
├──────────────────────────────────────┤
│ ▸ Terminal    claude — ~/voiceflow   │  LISTA — ten sam zbiór, czytelnie
│   Cursor      RemoteSession.swift    │
├──────────────────────────────────────┤
│  ⌗ podgląd terminala                 │  WARSTWA 3 — monospace, auto-scroll
│  ● Estalo — CRM …                    │  tylko dla wybranego okna terminala
│  > napisz test do RemoteMicClient    │
├──────────────────────────────────────┤
│  Cel: Terminal — claude              │
│  ┌────────────────────────────────┐  │
│  │   ● przytrzymaj, aby mówić     │  │
│  └────────────────────────────────┘  │
│  „napisz test do…"      [ Wyślij ⏎ ] │
└──────────────────────────────────────┘
```

Gesty na karcie (mapka i lista mają identyczny zestaw — jeden `WindowCard`, dwa
layouty):

| gest | działanie |
|---|---|
| **tap** | `focusWindow` — okno na front; jeśli to terminal, subskrybuje jego treść |
| **przytrzymanie** | dyktowanie do tego okna, puszczenie = koniec (główna ścieżka) |
| **dwuklik** | to samo, ale w trybie „naciśnij / naciśnij" — dla długich promptów |
| **przeciągnięcie na mapce** | `moveWindow` z przyciąganiem do połówek i ćwiartek |

Haptyka jest funkcjonalna, nie ozdobna: `.impact(.medium)` **dopiero** na `started`
(to jest sygnał „mów"), `.success` na `injected`, `.error` na każdy `error`. Bez
patrzenia na ekran wiesz, czy mikrofon naprawdę żyje.

### 6.3 Maszyna stanów `RemoteSession`

```
disconnected → connecting → connected
                              ├─ idle
                              ├─ arming     (wysłano start, czekam na started, buforuję)
                              ├─ streaming  (przyszło started, wypycham audio)
                              ├─ finishing  (wysłano end, czekam na injected)
                              └─ failed(code) → wraca do idle po 2 s
```

Jedna wypowiedź naraz; wejście w `arming` przy zajętej sesji jest **ignorowane**, nie
kolejkowane — kolejka promptów głosowych to funkcja, której nikt nie zamawiał, a każda
kolejka to nowe źródło błędów.

**Timeouty są obowiązkowe:** `arming` bez `started` przez 1,5 s → `failed(timeout)` i
kasowanie bufora. `finishing` bez `injected` przez 10 s → `failed(timeout)` z
zachowaniem podglądu tekstu. Brak timeoutu daje ekran wiszący na „nagrywam…", gdy Mac
zasnął — najgorszy tryb awarii, bo wygląda jak działanie.

Tło i przerwania: sesja żyje **tylko na pierwszym planie**; wejście w tło w trakcie
`streaming` wysyła `cancel` (nie ciche urwanie strumienia), tak samo przerwanie
`AVAudioSession`. Kategoria `.record`, tryb `.speech` — nic nie odtwarzamy.

### 6.4 Nowe pliki

```
shared/wire/ControlFrames.swift        // WSPÓLNE z macOS — jedno źródło prawdy
ios/VoiceFlowApp/Remote/
  RemoteSession.swift                  // maszyna stanów, timeouty, reconnect
  ControlTransport.swift               // protokół + WebSocket (LAN podmieni się później)
  MicStreamer.swift                    // AVAudioEngine → PCM Int16 16 kHz + bufor 2 s
  RemotePairing.swift                  // host + token w Keychainie
ios/VoiceFlowApp/UI/Remote/
  RemoteView.swift · DesktopMapView.swift · WindowCard.swift
  TerminalPreview.swift · PairingView.swift
tools/macsim/                          // referencyjny peer Maca (Node) do weryfikacji
```

Zmiany w istniejących: `VoiceFlowApp.swift` (jedna zakładka), `SettingsView.swift`
(sekcja parowania), `ios/project.yml` (`sources: ../shared/wire`, uprawnienie
kamery). **Nic więcej.**

---

## 7. Jak to jest weryfikowane bez gotowej apki macOS

Strony Maca nie ma i nie powstanie w tym zadaniu — więc powstaje **`tools/macsim/`**:
referencyjny peer w Node, który mówi tym samym kontraktem (serwuje listę okien, zrzut,
tekst terminala, przyjmuje `start`/audio/`end`, odsyła `started`/`preview`/`injected`,
umie na żądanie zwrócić `windowGone`, `focusFailed`, `busy` i zerwać połączenie).

Daje to dwie rzeczy naraz: apkę iOS **przetestowaną end-to-end w symulatorze już
teraz**, i gotowy zestaw testów kontraktu dla tego, kto będzie pisał stronę Maca.

Kryteria (dowód = output komend i zrzuty, nie deklaracje):

- `xcodebuild test` zielony, w tym testy dekodowania fixture'ów `tests/wire/*.json`;
- symulator + lokalny relay + `macsim`: lista okien się pokazuje, tap podnosi właściwe
  okno, przytrzymanie dyktuje do celu, podgląd terminala się odświeża;
- `macsim --scenario windowGone` → **zero** wstrzykniętego tekstu, czytelny błąd;
- `macsim --scenario focusFailed` → to samo;
- zerwanie połączenia w trakcie mówienia → obie strony wracają do `idle`, żaden stan
  nie wisi;
- `arming` bez odpowiedzi → `failed(timeout)` po 1,5 s, bufor wyczyszczony.

---

## 8. Ryzyka

| ryzyko | dlaczego realne | co robimy |
|---|---|---|
| **Tekst w złym oknie** | wyścig raise↔inject, okno zamknięte między migawką a komendą | `generation` + dwie weryfikacje focusu + zasada „lepiej nie wstawić" (§4.5) |
| **AX zawiesza enumerację** | nieodpowiadająca aplikacja blokuje wywołanie bez limitu | messaging timeout 0,2 s + wątek poboczny + test z `kill -STOP` (§5) |
| **Wiszące „nagrywam"** | Mac uśpiony, telefon bez odpowiedzi | twarde timeouty `arming`/`finishing` (§6.3) |
| **Czarny pierwszy zrzut** | macOS wymaga restartu po nadaniu Nagrywania ekranu | wykrycie braku zgody + jasny komunikat „zrestartuj VoiceFlow", nie cichy czarny obraz |
| **Kradzież tokenu = zdalna kontrola Maca** | kanał pozwala pisać i naciskać Enter w dowolnym oknie | Keychain po obu stronach, funkcja domyślnie wyłączona, osobna zgoda na sterowanie, widoczny wskaźnik na Macu, unieważnienie jednym kliknięciem |
| **Regresja w klawiaturze** | jedyna działająca dziś ścieżka | nowe pliki + jedna linia w `MainTabView`; testy `PendingInsert`/`TextDiffer` zostają zielone |
| **Rozjazd kontraktu iOS↔macOS** | dwa projekty, dwóch autorów | jeden `shared/wire/ControlFrames.swift` + fixture'y w testach obu platform |
| **Kolizja z pracą nad kontami** | inny agent dotyka parowania i relaya | **zero zmian w `relay/`**; parowanie schowane za `RemotePairing`, do podmiany jedną klasą |

## 9. Landminy znalezione na żywym przebiegu (2026-08-11)

Obie znalezione dopiero przy realnym uruchomieniu przeciw `macsim` — **żadnej z nich
nie mógł złapać test jednostkowy**, i obie objawiały się identycznie: ekran wisiał na
„łączę…" bez jednego wpisu w logu.

1. **Zakleszczenie powitania.** Pierwsza wersja transportu ogłaszała „połączono"
   dopiero po PIERWSZEJ odebranej ramce (żeby nie kłamać, skoro `resume()` wraca
   przed uściskiem dłoni). Ale telefon wysyła `hello` dopiero po „połączono", a Mac
   odzywa się dopiero po `hello` — obie strony czekały na siebie w nieskończoność.
   Atrapa transportu w testach z definicji nie ma uścisku dłoni, więc testy były
   zielone. **Rozwiązanie:** `URLSessionWebSocketDelegate.didOpenWithProtocol` —
   jedyny publiczny sygnał, że połączenie naprawdę stoi.

2. **ATS ucina `ws://` bez błędu.** App Transport Security odrzuca nieszyfrowane
   połączenie, nie zgłaszając niczego, co dałoby się zalogować. Produkcyjny relay
   chodzi po `wss://`, więc problem dotyczy wyłącznie testów lokalnych — ale bez
   `NSAppTransportSecurity → NSAllowsLocalNetworking` nie da się przetestować apki
   przeciw relayowi na `127.0.0.1`. To jest też warunek konieczny dla bezpośredniego
   połączenia po LAN z §6. **Nie** użyto `NSAllowsArbitraryLoads` — ruch do internetu
   dalej musi być szyfrowany.

3. **`xcrun simctl privacy … grant` ubija apkę.** Nadanie zgody na mikrofon
   restartuje proces. Kolejny gest po tym trafia w SpringBoard, nie w apkę — łatwo
   wziąć to za awarię własnego kodu.

Wnioski procesowe, warte zapamiętania poza tym projektem: **przebieg na żywo złapał
dwa błędy, których 58 zielonych testów nie widziało**, a raport delegowanego agenta
(Codex, `tools/macsim`) deklarował 15/15 przy jednym teście „pominiętym z powodu
piaskownicy" — poza piaskownicą ten test **nie przechodził** (błąd w rusztowaniu
testu: `waiters.splice(...)` zwraca tablicę). Pominięcie warunkowe potrafi zamaskować
realną porażkę.

## 10. Dług świadomy

Relay widzi audio i prompty w postaci jawnej (stoi na Twoim VM, ruch po `wss://`).
Docelowo: X25519 przy parowaniu + ChaCha20-Poly1305 na ramkach, relay dalej
pass-through. Nie wchodzi w to zadanie, ale gdyby VoiceFlow miał kiedyś być publiczny,
to jest pierwsza rzecz do zrobienia.
