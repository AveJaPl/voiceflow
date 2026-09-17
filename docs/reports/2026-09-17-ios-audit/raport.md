# VoiceFlow iOS — test z 17 września 2026

Raport historyczny dla builda 3. Późniejsze zmiany opisuje [raport builda 5](../2026-09-17-ios-update/raport.md).

VoiceFlow 1.0 (3), Debug, commit `a474a60892b6c9bf3f2bde38baa5ca0fd6ec59a1`. Zbudowano, zainstalowano przez devicectl i uruchomiono na fizycznym iPhonie 16 Pro Wojtka, iOS 27.0 beta. Nie zmieniano kodu aplikacji.

Instalacja i uruchomienie są potwierdzone. Nagrywanie mikrofonem, rozpoznawanie w tle i wstawianie tekstu do obcej aplikacji na telefonie pozostają do sprawdzenia. Poniższe zrzuty pochodzą z symulatora iOS 26.3.

## Błędy odtworzone w interfejsie

### 1. Samouczek ogłasza sukces po błędzie dyktowania (P2)

Odtworzenie: otworzyć samouczek, przejść do Ustawień i wrócić bez dodawania klawiatury, wybrać „Pomiń ten krok”, uruchomić test bez gotowego modelu, a po komunikacie błędu nacisnąć „Dalej”.

Wynik: ekran mówi „GOTOWE” i „Klawiatura VoiceFlow jest skonfigurowana”. Następny ekran pokazuje jednocześnie „Klawiatura włączona: NIE” oraz „Pełny dostęp: NIE”. Użytkownik dostaje nieprawdziwe potwierdzenie konfiguracji.

W teście wyłączono przygotowanie modelu argumentem Debug `-vfSkipModelPreparation YES`; pozwala to odtworzyć stan bez gotowego modelu bez pobierania danych. Sam brak modelu nie jest tutaj zgłaszanym błędem. Błędem jest komunikat sukcesu mimo nieudanej próby i pominiętej konfiguracji.

Dowody: [błąd próby](01-test-error.jpg), [fałszywy sukces](02-false-success.jpg), [rzeczywisty stan klawiatury](03-keyboard-disabled.jpg).

Przyczyna: `ios/VoiceFlowApp/UI/OnboardingView.swift:310` przechodzi dalej bez sprawdzenia wyniku, a linia 339 bezwarunkowo potwierdza konfigurację. Osobna ścieżka w liniach 76–79 kończy samouczek już po pierwszym uruchomieniu rozszerzenia, bez próby dyktowania; tę ścieżkę potwierdza kod, nie test UI.

Poprawka: rozdzielić „Pomiń test” od udanej konfiguracji; komunikat końcowy powinien odpowiadać temu, co faktycznie sprawdzono.

### 2. Ręczne ukończenie samouczka znika po restarcie (P2)

Po ścieżce z punktu 1 nacisnąć „Zacznij korzystać”, zamknąć proces aplikacji i otworzyć ją ponownie. Zamiast głównego ekranu wraca „SKONFIGURUJMY KLAWIATURĘ”. Odtworzono w symulatorze bez czyszczenia danych aplikacji.

Dotyczy użytkownika, który pominął konfigurację i chce korzystać z „Dyktuj teraz” oraz kopiowania tekstu. Po każdym restarcie musi ponownie przechodzić samouczek.

Przyczyna: `ios/VoiceFlowApp/App/VoiceFlowApp.swift:34` odczytuje tylko historyczne uruchomienie klawiatury, a linia 51 zapisuje ręczne ukończenie wyłącznie do `@State`.

Poprawka: trwale zapisać ukończenie lub świadome pominięcie samouczka niezależnie od stanu klawiatury.

### 3. Instrukcja testu opisuje inne działanie niż obecny silnik (P3)

Krok 4 obiecuje „tekst pojawiający się na żywo”; przed pierwszym nagraniem oraz po błędzie braku modelu karta pokazuje „Apple, na urządzeniu”. Zrzut [01-test-error.jpg](01-test-error.jpg) potwierdza oba komunikaty.

Kod `ios/VoiceFlowApp/Core/DictationEngine.swift:97` wymaga gotowego WhisperKit, a rozpoznawanie rozpoczyna dopiero `stop()` (linia 225). Nie ma automatycznego przejścia na Apple Speech. Domyślne `backend = .apple` tworzy mylącą etykietę. Dodatkowo krok 2 w `OnboardingView.swift:135` mówi o mikrofonie „w klawiaturze”, choć aktualny przepływ nagrywa w aplikacji kontenerowej.

Poprawka: instrukcja „Powiedz zdanie i zakończ nagrywanie; wtedy pojawi się tekst”, nazwa wybranego modelu lub „Model niegotowy” oraz spójne wyjaśnienie roli Pełnego dostępu.

## Problem stwierdzony w kodzie, do potwierdzenia na telefonie

### 4. Zmiana automatycznego wstawiania nie odświeża istniejącej klawiatury (P2)

Warunek: proces rozszerzenia klawiatury pozostaje w pamięci. Włączyć klawiaturę z aktywnym „Automatycznie”, przejść do ustawień VoiceFlow, wyłączyć „Automatycznie wstawiaj tekst”, wrócić do tego samego pola i rozpocząć nowe dyktowanie.

`KeyboardPanelModel.automatic` w `ios/VoiceFlowKeyboard/KeyboardViewController.swift:12` czyta preferencję tylko przy tworzeniu obiektu. `viewWillAppear` (linia 46) i `refresh` (linia 65) jej nie odczytują ponownie, a warunek wstawiania w linii 78 korzysta ze starej wartości. Analogicznie ekran ustawień ma własny `@State` w `ios/VoiceFlowApp/UI/SettingsView.swift:7`.

Skutek wynikający z kodu: zachowane rozszerzenie może nadal automatycznie wstawiać tekst mimo wyłączenia tej opcji w aplikacji. Nie odtworzono tego z rzeczywistym dyktowaniem na iPhonie.

Poprawka: odświeżać wspólną preferencję przy aktywacji obu interfejsów i odczytać aktualną wartość przed automatycznym wstawieniem.

## Weryfikacja techniczna

- Build na fizyczne urządzenie: `BUILD SUCCEEDED`; instalacja i uruchomienie przez devicectl zakończone powodzeniem około 10:21 czasu polskiego.
- Symulator: build i start poprawne; testy: 22 zaliczone, 0 błędów, 1 pominięty. Testy sprawdzają m.in. świeżość wyniku i warunki jednokrotnego wstawiania, ale nie obejmują opisanych błędów samouczka.
- Próba uruchomienia istniejącego testu polskiego pliku WAV na iPhonie zakończyła się przed wykonaniem: „Tool-hosted testing is unavailable on device destinations”. `VoiceFlowTests` w `ios/project.yml:141` nie ma aplikacji hostującej. Ten sam test pomija symulator i każe uruchomić go na urządzeniu, więc obecna konfiguracja uniemożliwia jego wykonanie w obu miejscach. Potrzebny osobny target testów z hostem lub inny testowy program na urządzenie.
- Logi lokalne: `/tmp/voiceflow-ios-audit-20260917/device-build.log`, `install.json`, `launch.json`, `device-test.log`; testy: `/tmp/voiceflow-ios-audit-20260917/LogicTests.xcresult`.

## Krótka wiadomość do przekazania

Sprawdziliśmy VoiceFlow iOS 1.0 (3). Aplikacja jest już zainstalowana i uruchomiona na moim iPhonie 16 Pro. W samouczku są błędy: potrafi pokazać „skonfigurowane” po nieudanym teście, nie pamięta ręcznego zakończenia bez uruchomienia klawiatury, a instrukcja obiecuje tekst na żywo, mimo że rozpoznawanie zaczyna się po zatrzymaniu nagrania. W kodzie widać też brak odświeżania opcji automatycznego wstawiania pomiędzy aplikacją i klawiaturą. Ten ostatni przypadek wymaga jeszcze próby na telefonie. Testy logiki przechodzą, ale nie potwierdzają działania mikrofonu ani całego przepływu w innej aplikacji.

## Próba na iPhonie

Najpierw poczekać na status modelu „GOTOWY”. W aplikacji wybrać „Dyktuj teraz”, powiedzieć „Jutro o piętnastej zadzwonię do Marka w sprawie Programo”, zakończyć nagranie i sprawdzić tekst oraz Historię.

Następnie dodać VoiceFlow w Ustawieniach iOS → Ogólne → Klawiatura → Klawiatury, włączyć Pełny dostęp i otworzyć pustą notatkę. Przełączyć klawiaturę na VoiceFlow, rozpocząć dyktowanie, a jeśli aplikacja sama się nie otworzy, otworzyć ją ręcznie i nacisnąć „Dyktuj teraz”. Po rozpoczęciu wrócić do notatki gestem przełączania aplikacji, dokończyć zdanie i nacisnąć „Koniec dyktowania”. Sprawdzić, czy tekst pojawia się raz i we właściwym polu; w razie braku automatycznego wstawienia sprawdzić „Wstaw tekst”.

Przy błędzie zapisać: dokładny krok, komunikat, wybrany model, status modelu i czas oczekiwania. Krótkie nagranie ekranu ułatwi odtworzenie. Nie wpisywać do testu prywatnych danych.

Instalacja developerska na tym iPhonie nie jest linkiem instalacyjnym dla znajomego. W tej sesji nie udostępniano TestFlight ani nie wysyłano nikomu wiadomości.
