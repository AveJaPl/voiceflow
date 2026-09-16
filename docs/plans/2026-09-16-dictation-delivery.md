# VoiceFlow: stan dostarczenia 16 września 2026

Ten dokument aktualizuje wcześniejszy audyt Apple i plan uproszczenia produktu.

## Poprzedni raport: co było prawdą

- Rekord ASC, certyfikat Developer ID, podpis/notaryzacja i publiczne pliki Mac oraz upload iOS były rzeczywiste.
- Publiczny Mac `mac-v0.7.0` miał jednak wewnętrzną wersję `0.6.0`, a tag wskazywał inną gałąź niż źródła Apple. Naprawiono wersjonowanie i przypinanie wydania do źródeł.
- Stary iOS `0.6.0 (1)` był przetworzony, ale blokowała go deklaracja eksportowa. Nie oznaczał gotowego TestFlight ani publikacji w App Store.
- Twierdzeń o historycznych kliknięciach, błędzie pobierania Chrome i komunikacie dostępu ASC nie da się potwierdzić stanem bieżącym.

## Mac: opublikowane 0.8.0

[Pobierz DMG](https://github.com/AveJaPl/voiceflow/releases/download/mac-v0.8.0/VoiceFlow-mac.dmg).
Źródła: `e6699b37fe573b8f3a29aca2f1914e297dabc0a3`, gałąź `apple/2.0`.

- Stały, kompaktowy pill: ciemne tło, brak rozmycia i skaczącego rozmiaru podczas nagrywania.
- Fala rysowana 30 razy na sekundę niezależnie od rozpoznawania; osobny ruch kresek, szybki atak, łagodny zanik i ograniczenie amplitudy.
- Fn+Z podczas trzymania Fn przełącza trwającą sesję w tryb ciągły, zamiast natychmiast ją kończyć. Ignorowane są nadmiarowe zwolnienia klawisza. Puszczenie skrótu w czasie kończenia poprzedniej sesji usuwa oczekujące nagranie.
- Zmiana modelu i języka obowiązuje od kolejnego nagrania; automatyczne wykrywanie języka dla nowych instalacji, własny słownik i prostsze ustawienia.
- Pierwsze uruchomienie otwiera konfigurację. Model domyślny zależy od RAM-u; większe modele nadal można wybrać ręcznie.
- Nie podmieniano ani nie restartowano używanej instalacji. ZIP dla automatycznej aktualizacji nie został opublikowany, aby stary updater nie uruchomił restartu w trakcie pracy użytkownika.

Podpis Developer ID: H7DS3ZG67S; wersja wewnętrzna 0.8.0; Gatekeeper i stapler poprawne.
Notaryzacja aplikacji: `7170b34b-3243-4481-b9ca-07892667f0e6`, Accepted.
Notaryzacja DMG: `0d05de0b-64e9-4c38-a1e8-6ce075abbbe0`, Accepted.
SHA-256 DMG: `7f49a35c8a9d21cea673492019996e45f92ffe547d9552ee8828f3a860113d0d`.
GitHub potwierdza ten sam digest; stary adres `releases/latest/download/VoiceFlow-mac.dmg` odpowiada HTTP 200 i zwraca 4 419 642 bajty.

## iPhone: zaimplementowane, jeszcze przed pełnym odbiorem

- Trzy zakładki: Klawiatura, lokalna Historia, Ustawienia. Dyktowanie bez konta.
- Model można wybrać i zmienić; język automatyczny, polski lub angielski; własne słowa przekazywane do dekodera.
- Klawiatura głosowa: Start/Stop, fala, ręczne wstawienie i przełącznik automatycznego wstawiania.
- Aplikacja nagrywa, rozszerzenie odczytuje stan i wydaje polecenie Stop przez App Group. Automatyczne wstawianie ograniczono do świeżego wyniku i tego samego pola; wynik nie powinien zostać wstawiony dwukrotnie. Przy odtworzeniu rozszerzenia pozostaje ręczne wstawienie.
- Włączono nagrywanie w tle tylko dla uruchomionej przez użytkownika sesji. Nie utrzymujemy mikrofonu stale aktywnego.
- Nie ma automatycznego przejścia na Apple Speech w trakcie pobierania modelu; UI wymaga gotowego modelu.
- Końcowy przegląd wykrył niedozwolone połączenie `.record` i `.duckOthers`. Usunięto je w obu silnikach audio oraz poprawiono wywołanie aktywacji sesji. [Dokumentacja Apple](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/duckothers).

Apple nie daje rozszerzeniom klawiatury dostępu do mikrofonu. Nagrywanie zaczyna się w aplikacji VoiceFlow, a użytkownik wraca do swojego pola tekstowego. Automatyczne otwarcie kontenera zależy od iOS; jest instrukcja ręcznego przełączenia. Nie obiecujemy identycznego zachowania w każdej aplikacji ani w polach haseł. [Ograniczenia klawiatur Apple](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html).

Build 1.0 (2) przesłano i przetworzono: VALID, READY_FOR_BETA_TESTING, bez blokady eksportowej. Po końcowej poprawce audio zbudowano i przesłano **1.0 (3)**: ARCHIVE SUCCEEDED, EXPORT SUCCEEDED, UPLOAD SUCCEEDED; Delivery `18a09f0a-650b-4fa4-bf65-2dee2e97061b`, źródła `6e740f2`. Build 3 został przetworzony: VALID, READY_FOR_BETA_TESTING, READY_FOR_BETA_SUBMISSION, bez blokady eksportowej. Przypięto go do wersji sklepowej 1.0 zamiast buildu 2. Gotowość do testów nie oznacza udostępnienia testerom ani zatwierdzenia przez App Store. Opis PL, słowa kluczowe, subtitle, support, marketing i privacy URL zapisane w ASC. Wersja sklepu pozostaje PREPARE_FOR_SUBMISSION.

Instalacja developerska na fizycznym iPhonie nie powiodła się: DeviceLocked, następnie urządzenie niedostępne. Podpisana paczka 1.0 (3) czeka w `ios/build/device-1.0-3/VoiceFlow.ipa`, ale nie ma potwierdzenia instalacji ani testu na telefonie.

## Sprawdzenia i granice

- Mac: 10 testów logiki (skrót i updater) przeszło w izolowanym SwiftPM, bez uruchamiania aplikacji i jej skrótów.
- iOS: 22 testy przeszły, 0 błędów, 1 test audio pominięty. Testy obejmują świeżość sesji, warunki pojedynczego wstawiania i skalę miernika. Wykonano je przed końcową korektą konfiguracji audio.
- Mac Release oraz iOS archive/export przeszły. Fala została wyrenderowana z rzeczywistych widoków dla sztucznych poziomów ciszy, zwykłej i głośnej mowy; nie jest to test mikrofonu.
- Symulator: sprawdzono główne ekrany, wybór modelu/języka, własny słownik i przełącznik wstawiania. Włączono rozszerzenie w ustawieniach testowego symulatora, ale nie potwierdzono pełnego renderowania i wstawiania tekstu przez rozszerzenie. Klawiatura ekranowa nie pojawiała się, a późniejsze uruchamianie aplikacji w symulatorze zawieszało się; własny symulator wyłączono.
- Nie nagrywano głosu, nie testowano rzeczywistej transkrypcji, pracy audio w tle ani wklejania do obcej aplikacji. Nie zmierzono baterii, RAM-u ani opóźnień na iPhonie. Nie jest to dowód bezbłędności ani optymalności.
- Web PL/EN lokalnie: 390×844 i 1440×900, bez poziomego przepełnienia, poprawne lokalne zasoby i odnośniki. Własny serwer podglądu zakończono.

## Co blokuje końcowy cel

1. Publiczny App Store: odbiór mikrofonu i klawiatury na fizycznym telefonie, zrzuty App Store, potwierdzenie deklaracji prywatności, wiek i ewentualna umowa Apple, potem recenzja Apple. Nie wysłano aplikacji do recenzji i nie dodawano testerów.
2. Nowy landing PL/EN jest w repo, ale nie został wdrożony. Host strony `135.181.253.104` nie jest dostępnym Coolify relaya; brak potwierdzonego klucza SSH/ścieżki wdrożenia. Nie obchodzono kontroli hosta i nie zmieniano DNS. Dotychczasowy link pobierania Mac już prowadzi do 0.8.0.
3. Poprawiony Mac trzeba uruchomić po ręcznej instalacji w dogodnym momencie; działającej wersji nie aktualizowano podczas pracy użytkownika.

Następne kroki: odblokowany iPhone i test uzgodnionego nagrania, dostęp do właściwego hostingu landingu, domknięcie formularzy i recenzji Apple. Zrzuty sklepowe powinny pochodzić z odebranego przepływu, nie udawać zakończonego testu głosu.

Podpis paczki developerskiej 1.0 (3) zweryfikowano przez codesign --verify --deep --strict. SHA-256 wysłanego IPA: `4f9228cae88eec6dbf3df05444449e6a3208eea599a9946bfba43a35acb8bee1`.
