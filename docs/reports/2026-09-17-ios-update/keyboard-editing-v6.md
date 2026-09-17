# VoiceFlow iOS 1.0 (6): uproszczenie klawiatury i edycja

Zmiany po uwagach Wojtka z 17 września:

- Bez nagłówka VoiceFlow i pillu nad wynikiem. Fala pozostaje tylko w stanie nagrywania; przetwarzanie opisuje „Domykam…”.
- Tło pochodzi z systemowego UIInputView w stylu keyboard; panel SwiftUI jest przezroczysty. Kolory tekstu i przycisków dostosowują się do jasnego/ciemnego wyglądu pola.
- Ręczne „Wklej tekst” działa wielokrotnie, także w innym dokumencie. Automatyczne wstawianie nadal działa tylko raz dla danego dyktowania i dokumentu.
- Krzyżyk wewnątrz pola czyści podgląd i zachowuje historię. Wyczyszczony wynik nie odrasta przy następnym odczycie sesji.
- „Edytuj” powiększa panel: tekst z kursorem/zaznaczeniem u góry, układ QWERTY poniżej. Są cyfry, znaki, spacja, nowa linia, kasowanie oraz polskie litery pod menu przytrzymania. To własny układ VoiceFlow, nie osadzona klawiatura Apple ani jej autokorekta.
- Można również wpisać lub wkleić tekst do pustego podglądu. Przycisk schowka korzysta z systemowego PasteButton.
- „Gotowe” lub ręczne wklejenie zapisuje zmienioną wersję w lokalnej historii. Powtórne wklejenia tej samej wersji nie tworzą duplikatów. Oryginalne dyktowanie pozostaje w historii. Edytowane wpisy są lokalne; ten patch nie dodaje ich wysyłania do konta.

Pierwszy start: dotychczas wywołanie start() z onAppear mogło trafić w UIApplication.State.inactive i zostać pominięte bez ponowienia. Ekran ponawia teraz aktywację po scenePhase.active, gdy model jest gotowy. „Włącz VoiceFlow” przygotowuje ciepły mikrofon z zamkniętą bramką audio, bez zbierania wypowiedzi. Po powrocie do klawiatury użytkownik wybiera „Nowe dyktowanie”. Nie kasujemy poprzedniego wyniku ani nie stosujemy pięciosekundowego timeoutu IPC do otwierania aplikacji. Ograniczenie iOS wymagające otwarcia aplikacji do zimnego startu mikrofonu nadal obowiązuje.

Weryfikacja: 37 testów przeszło, 0 błędów, 1 test ASR w symulatorze pominięty. Nowe testy pokrywają zachowanie edycji po restarcie rozszerzenia, trwałe wyczyszczenie i brak duplikatu historii po ponownym wklejeniu. Build symulatora oraz Release urządzenia i podpis aplikacji przeszły.

W podglądzie rzeczywistego komponentu sprawdzono edycję przez klawisze, dwukrotne kliknięcie wklejania, czyszczenie i ponowne wpisanie tekstu. [Edytor](keyboard-editor-v6.jpg), [dwa wklejenia](keyboard-repeat-paste-v6.jpg). Podgląd używa syntetycznego tekstu i nie wstawia go do Messengera. Pierwsza aktywacja mikrofonu i edycja wewnątrz rozszerzenia na fizycznym telefonie wymagają jeszcze odbioru użytkownika; nie należy utożsamiać ich z testem panelu w symulatorze.

Instalacja builda 6 o 11:54 CEST nie doszła do skutku: devicectl zwrócił error 1011, a lista urządzeń pokazała iPhone jako unavailable. Gotowy podpisany pakiet Release: `/tmp/voiceflow-ios-audit-20260917/DerivedData/Build/Products/Release-iphoneos/VoiceFlow.app`. Na telefonie pozostaje poprzedni build do czasu przywrócenia połączenia.
