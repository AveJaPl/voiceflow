# Audyt VoiceFlow Apple, 16 września 2026

> Raport z pierwszego etapu audytu. Bieżące wersje, nowy pill, lokalną historię i stan wydań opisuje [raport dostarczenia](2026-09-16-dictation-delivery.md).

Zakres: raport wydania, spokojniejszy pill, integracje iOS/macOS, serwery i mobilny web. Bez nagrywania, bez restartu używanej aplikacji Mac i bez akceptowania umów Apple. Początek: `apple/2.0`, `e77af0e`; istniejące zmiany dwóch Info.plist iOS pozostają poza commitem audytu.

## Co potwierdziłem

| Twierdzenie | Dowód i wynik |
|---|---|
| Rekord VoiceFlow Dictation istnieje | ASC API: Apple ID 6811954812, bundle io.github.avejapl.voiceflow.ios, SKU VOICEFLOW-IOS-2026, język pl. |
| Developer ID Application istnieje | ASC API i Keychain; zespół H7DS3ZG67S, ważność do 1 lutego 2027. |
| mac-v0.7.0 opublikowane i notaryzowane | ZIP pobrany z publicznego GitHuba; SHA-256 zgodne z metadanymi wydania; Gatekeeper: accepted, Notarized Developer ID. |
| Paczka jest wersją 0.7.0 | Nie: wewnętrzne CFBundleShortVersionString = 0.6.0. Tag wskazuje kod main, nie używaną gałąź Apple. |
| iOS 0.6.0 (1) przesłano | ASC API: VALID, uploaded 14 września, identyfikator buildu zgodny z raportem. |
| TestFlight jest gotowy | Nie: MISSING_EXPORT_COMPLIANCE dla testów wewnętrznych i zewnętrznych, brak grup testerów. |
| App Store jest w recenzji | Nie: rekord wersji 1.0 ma PREPARE_FOR_SUBMISSION; opis, keywords i support URL puste. |
| Landing udostępnia nową wersję Mac | Live strona nadal mówi „alfa ze źródeł”. Sam bezpośredni plik DMG odpowiada HTTP 200. |
| Pokoje i relay działają | Oba /health odpowiadają OK. iPhone Simulator pobrał rzeczywisty ranking; trybu produkcyjnego pokoju nie zmieniałem. |

Historycznego błędu pobierania w Chrome, komunikatu o dostępie w ASC i wcześniejszych dotknięć symulatora nie da się potwierdzić samym stanem bieżącym. Umowy Apple nie akceptowałem.

## Poprawki

Pill: wzmocnienie wizualne 6 → 2,5, maksymalna wysokość 22 → 14 pt, atak wygładzania 0,55 → 0,25, animacja bez sprężystego odbicia, spokojniejsza cisza i zerowanie starej fali przy nowej sesji. Mikrofon oraz parametry rozpoznawania pozostają bez zmian. Porównanie wyrenderowałem z rzeczywistych widoków SwiftUI dla sztucznych poziomów RMS, bez okna i mikrofonu. Miernik iOS dostał tę samą łagodniejszą skalę.

Wydania Mac: wersja Info.plist pochodzi z MARKETING_VERSION; skrypt sprawdza ją przed publikacją, wskazuje SHA źródeł i wymaga czystych źródeł Apple. Updater odrzuca paczki z inną wersją lub bundle ID, pomija prerelease, blokuje równoległe instalacje, czeka na bezczynność bez wymuszonego restartu po limicie i zachowuje poprzednią kopię do odzyskania. Celuje w faktyczne miejsce instalacji.

iOS: identyfikator ładowania chroni stan przed starymi zadaniami po zmianie modelu. Nagranie zachowuje swój model do końca, ignoruje opóźnione bufory ze starej sesji, kończy się przy limicie 5 minut i pokazuje błędy transkrypcji. Wyjście z ekranu anuluje sesję i sprząta audio; ekran ma przycisk Zamknij również po błędzie. Apple fallback nie zapisuje ponownie historii z opóźnionych callbacków. Odpowiedź starego pokoju nie nadpisuje nowego kodu. Kolor tekstów pomocniczych zmieniono z #55555C na #85858D (kontrast na #161618: 2,44 → 4,94).

Klawiatura iOS: usunięty responder-chain `openURL:`. Po odmowie otwarcia kontenera pokazuje instrukcję ręcznego otwarcia VoiceFlow i wybrania Dyktuj teraz. To naprawia cichy brak reakcji; nie dowodzi automatycznego uruchamiania z klawiatury. Ograniczenie opisuje [Apple DTS](https://developer.apple.com/forums/thread/764570). Pełny flow z dyktowaniem na fizycznym iPhonie nadal wymaga osobnego testu.

Web PL/EN: stabilne linki do wydań per platforma, poprawny stan iOS, boczne marginesy hero na telefonie, usunięte obietnice braku synchronizacji tekstu i nieistniejącego zdalnego serwera w iOS. Polityka prywatności opisuje konto, tekst historii, słownik, pokoje, własny serwer, modele i połączenia strony. To korekta faktów technicznych, nie pełny odbiór prawny dokumentu. README i komunikaty iOS odpowiadają tym ograniczeniom.

## Weryfikacja

- macOS Release: build przeszedł; podpis poprawny, brak zależności /opt/homebrew i /usr/local. Paczka dystrybucyjna 0.7.1: aplikacja i DMG notaryzowane (Accepted), stapling poprawny. DMG i ZIP w macos/build/release-0.7.1. Nie publikowano do kanału aktualizacji i nie podmieniano działającej aplikacji.
- Updater: 2 testy regresji przeszły. Uruchomione jako izolowany pakiet SwiftPM z rzeczywistym UpdateChecker.swift i atrapą loggera, aby nie uruchamiać hosta aplikacji ani jego skrótów. Testy są też w docelowym VoiceFlowTests.
- iOS: build przeszedł; XcodeBuildMCP test_sim: 19 passed, 0 failed, 1 skipped. Pominięty test WhisperKit wymaga urządzenia; nie jest dowodem jakości rozpoznawania.
- iPhone 16e, iOS 26.3: Klawiatura, Historia bez konta, Pokoje z prawdziwą tablicą i Ustawienia sprawdzone przez XcodeBuildMCP. Debug pomija onboarding i pobieranie modelu; nagrywania nie uruchamiałem.
- Relay: 43/43; Rooms: 77/77. To lokalne testy serwerów, nie dowód zalogowanej synchronizacji na produkcji.
- Web: live i lokalny render; PL/EN przy 390×844 i 1440×900 bez poziomego przepełnienia. Lokalne odnośniki i zasoby w czterech dokumentach istnieją. Mac DMG i Windows BAT odpowiadają HTTP 200.
- Podstawą progu kontrastu jest [WCAG 1.4.3](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html). Nie wykonano pełnego audytu dostępności całej aplikacji.

## Co pozostaje przed publicznym wydaniem

1. Zatwierdzić deklarację Export Compliance w ASC, przygotować grupę testerów, opis, support URL i zrzuty; uzgodnić wersję App Store 1.0 z wersją przeznaczonego do niej buildu. Obecna 0.6.0 (1) nie zawiera tego audytu.
2. Sprawdzić fizyczny iPhone: rzeczywiste dyktowanie, limit/przerwania audio, powrót z kontenera i pojedyncze wstawienie tekstu, a także historię na zalogowanym koncie. Na prośbę użytkownika nie robiono tych testów.
3. Wdrożyć site/ na właściwy serwer. DNS strony i rooms wskazuje inny host niż dostępny Coolify relaya; próba SSH zakończyła się brakiem zweryfikowanego klucza hosta. Nie omijano weryfikacji ani nie zmieniano DNS.
4. Udostępnić poprawione wydanie Mac w uzgodnionym momencie. Obecnie działającej aplikacji nie restartowano, a publiczny updater nie dostał nowej paczki.

Nie potwierdzam, że „wszystko jest optymalne”. Architektura lokalnego rozpoznawania i wspólnego modelu jest uzasadniona, ale wydajności, baterii, RAM-u i jakości mowy na telefonie nie mierzono. Brak konta nadal oznacza brak historii w zakładce Historia. iPad nie jest wspieranym targetem; render w symulatorze iPada nie oznacza wsparcia.
