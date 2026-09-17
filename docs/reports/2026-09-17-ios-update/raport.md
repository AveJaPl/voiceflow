# VoiceFlow iOS 1.0 (5) — zmiany i weryfikacja

Aktualizacja klawiatury, konta i przygotowania modelu z 17 września 2026. Telefon testowy: iPhone 16 Pro, iOS 27.0 beta. Testy interfejsu: symulator iOS 26.3. Wersję Release 1.0 (5) zainstalowano przez devicectl i uruchomiono na fizycznym iPhonie o 11:38 CEST, bez argumentów testowych.

## Klawiatura

- Poprzedniego wyniku nie trzeba wklejać przed kolejnym dyktowaniem. „Nowe dyktowanie” i „Wklej tekst” są osobnymi przyciskami.
- Długi wynik ma przewijany podgląd. Ręczne wklejenie nie jest powtarzane automatycznie.
- Ustawienia zawierają automatyczne wklejanie. Wynik trafia przez textDocumentProxy do bieżącego zaznaczenia/kursora w tym samym dokumencie, z którego rozpoczęto dyktowanie. Spóźniony wynik innej sesji nie może wkleić się automatycznie.
- Szary pill ze wspólną falą VoiceWaveform, stan „Domykam…”, globus tylko wtedy, kiedy wymaga go needsInputModeSwitchKey.
- Mikrofon jest uruchamiany jawnie w aplikacji. Dopóki sesja jest aktywna, następne dyktowania klawiatura rozpoczyna przez App Group bez otwierania aplikacji.
- Sesja trwa podczas widoczności klawiatury i wygasa 30 sekund po jej schowaniu. Pierwszy powrót z aplikacji do klawiatury ma 60 sekund. Jest też przycisk „Wyłącz sesję”. Poza dyktowaniem próbki audio są odrzucane przed konwersją, bez zapisu i rozpoznawania.

[iOS nie udostępnia mikrofonu rozszerzeniom klawiatury](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html). Po wygaśnięciu sesji lub zamknięciu aplikacji aktywacja mikrofonu nadal wymaga przejścia do VoiceFlow. Nie ma obietnicy pierwszego startu bez przełączenia aplikacji.

Zrzuty rzeczywistego komponentu klawiatury w widoku Debug, z syntetycznym wynikiem i poziomem dźwięku: [wynik](keyboard-result.jpg), [nagrywanie](keyboard-recording.jpg), [domykanie](keyboard-processing.jpg). Nie są dowodem działania mikrofonu ani wstawiania tekstu w Messengerze.

## Model

Zachowano large-v3-turbo. Zmieniono wykonanie encodera na CPU, decoder pozostaje CPU/ANE. Specjalizacja encodera na ANE zatrzymywała przygotowanie na wiele minut na testowym iOS 27. Pobrane pliki nie są już kasowane przy dowolnym błędzie ładowania; ścieżka modelu jest odnajdywana także po zmianie kontenera przy aktualizacji aplikacji.

Usunięto osobny prewarm, który dla encodera CPU wykonywał kosztowne ładowanie dwa razy. Przygotowanie ma licznik, limit 5 minut i komunikat ponowienia, bez cichej zamiany modelu na mniejszy.

Przygotowanie może kontynuować pracę przez BGContinuedProcessingTask na iOS 26+. [Czas i zasoby przyznaje system](https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados). W fizycznym teście model wykonywał kolejne etapy po przejściu do Ustawień, ale iOS przerwał zadanie po 45 sekundach. Kolejne próby zostały przerwane w tle po 66 i 40 sekundach. To potwierdza rozpoczęcie pracy w tle oraz obsługę przerwania, nie pełne ukończenie w tle.

Wcześniejsza wersja CPU z dodatkowym prewarm osiągnęła gotowość po 83 sekundach. Limit 60 sekund dla pierwszego przygotowania dużego modelu nie został potwierdzony. Kolejny test końcowej optymalizacji wymaga pozostawienia aplikacji na ekranie; nie zastępujemy pomiaru deklaracją.

## Jakość słów

Na fizycznym iPhonie próbka PL o długości 4,292 s została rozpoznana w 2,741 s: „Dzień dobry, chciałbym dzisiaj porozmawiać o planach na przyszły tydzień.” Wynik jest identyczny z whisper.cpp large-v3-turbo-q5 na Macu dla tego samego pliku. To wąski test, nie dowód równej jakości przy dowolnej mowie i szumie.

Dodatkowe próbki PL i EN przygotowano, ale test na telefonie przerwało przygotowanie modelu. Mac pomylił w drugiej próbce nazwę „Programo” ze słowem „programu”; słownik konta pomaga podać nazwy własne, ale nie gwarantuje ich poprawnego rozpoznania.

## Konto

W Ustawieniach przywrócono logowanie istniejącym e-mailem i hasłem Maca, historię konta, odświeżanie i słownik. Nowe dyktowania mają kolejkę przypisaną do konta aktywnego w chwili nagrania. Wylogowanie/zalogowanie na inne konto nie przenosi kolejki ani słownika do nowego właściciela. Niepewna wysyłka jest najpierw uzgadniana z historią, bez ślepego ponawiania POST.

Nie importujemy starych anonimowych dyktowań automatycznie. Ekran pobiera ostatnie 500 wpisów. Logowanie prawdziwym kontem i synchronizacja między urządzeniami wymagają jeszcze testu użytkownika. Mac wysyła historię do relaya, ale jego dotychczasowy lokalny ekran historii nie pobiera wpisów telefonu — do pełnego podglądu w obu kierunkach potrzebna jest również aktualizacja Maca. Nie podmieniano działającej aplikacji Mac.

## Sprawdzenie

- 34 testy zaliczone, 0 błędów; 1 pominięty test ASR wymagający modelu w symulatorze. Sprawdzone m.in. izolacja kont, niepewne wysyłki, wygasanie sesji, świeżość wyników, zmiana dokumentu, bramka audio i kolejne dyktowanie bez wklejania.
- Build Debug urządzenia, Release urządzenia i symulatora zakończone powodzeniem. Ostrzeżenia: alias allowBluetooth oraz adnotacja Sendable w synchronicznym callbacku konwersji AVAudioPCMBuffer.
- Wynik, nagrywanie i domykanie obejrzane w symulatorze; nowy start działa bez wcześniejszego wklejenia.
- Do odbioru na telefonie: dwa kolejne dyktowania w Messengerze, ręczne oraz automatyczne zastąpienie zaznaczenia, schowanie klawiatury na 30 s, ponowne wznowienie i rzeczywiste logowanie kontem.

Dane pomiarów i pełne logi są lokalnie w `/tmp/voiceflow-ios-audit-20260917/`; testy: `FinalTests.xcresult`.
