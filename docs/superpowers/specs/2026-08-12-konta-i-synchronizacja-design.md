# Konta i synchronizacja słownika oraz statystyk

Kamień 2 pokoi, odłożony świadomie w
[specyfikacji pokoi](2026-08-11-pokoje-i-sesje-design.md). Dziś tożsamością jest
token urządzenia, więc telefon byłby w rankingu osobnym zawodnikiem, a słownik
trzeba by przepisywać ręcznie na każdej maszynie.

## Cel

Jedna osoba, wiele urządzeń. Słownik i statystyki widziane wszędzie tak samo,
bez przepisywania.

## Czego to NIE obejmuje

**Treść dyktowań zostaje lokalnie.** W `dictations` nie ma i nie będzie kolumny
na tekst; historia mieszka w `history.jsonl` na maszynie, na której padła.
Zmierzone: 415 wpisów to 272 KB i milisekunda odczytu, a przy limicie 20 000 —
11,8 MB i 78 ms. Plik nie jest problemem do rozwiązania i Postgres by go nie
rozwiązał. Postgres rozwiązuje inny problem: jedna osoba, wiele urządzeń.

Decyzja o wysyłaniu treści na serwer jest jedyną w tym projekcie, której nie da
się cofnąć po cichu, i nie jest częścią tej specyfikacji.

## Rozstrzygnięta zmiana wobec pierwotnego planu: kod parowania zamiast maila

Specyfikacja pokoi zakładała link magiczny przez `mail.pbdevs.com`. Sprawdziłem
tę usługę: odpowiada, ale jest aplikacją Next.js, a jej API nie jest w tym
repozytorium udokumentowane ani nigdzie użyte. Budowanie logowania na kontrakcie,
którego nie znam i nie mogę przetestować, dałoby funkcję działającą „chyba".

Dlatego v1 loguje **kodem parowania**, a nie mailem:

1. Pierwsze urządzenie tworzy konto — bez maila, bez hasła. Dostaje token konta.
2. Na zalogowanym urządzeniu prosisz o kod parowania: sześć znaków, ważny 10 minut,
   jednorazowy.
3. Na nowym urządzeniu podajesz ten kod. Urządzenie dołącza do konta i dostaje
   własny długoterminowy token.

To pasuje do sytuacji, w której ta funkcja jest w ogóle potrzebna: oba urządzenia
masz w rękach. Mail dokładamy, gdy pojawi się potrzeba odzyskania konta na
maszynie, do której nie masz dostępu — i wtedy znając już API poczty.

Bez hasła nie ma czego wykraść ani resetować. Utrata wszystkich urządzeń oznacza
utratę konta; przy danych, o których mowa (słownik i liczby), to jest akceptowalne
i lepsze niż udawanie odzyskiwania, którego nie umiemy zrobić.

## Model danych

Dwie nowe tabele i jedna kolumna:

```
accounts        id, created_at
account_devices account_id, device_id           (urządzenie należy do konta)
pairings        code, account_id, expires_at, used_at
vocabulary      account_id, term, added_at      (słownik jest wspólny dla konta)
```

`devices` zostaje bez zmian — urządzenie działa dalej bez konta, tak jak dziś.
Konto jest czymś, co się dokłada, a nie warunkiem używania voiceflow.

Ranking liczy się nadal per urządzenie, ale gdy urządzenia należą do jednego
konta, tablica sumuje je pod jedną osobą. Bez tego telefon i laptop ścigałyby się
ze sobą.

## Statystyki

Dziś statystyki liczą się z `history.jsonl`, czyli obejmują **wszystkie**
dyktowania, także poza pokojem. Żeby były te same na telefonie, muszą jechać na
serwer — ale wyłącznie jako liczby: znacznik czasu, liczba słów, sekundy.

Nowa tabela `dictation_stats` (account_id, at, words, seconds) zamiast dokładania
kolumn do `dictations`: tamta tabela należy do sesji pokoju i ma inny cykl życia.

Wysyłka jest przyrostowa i best-effort — statystyka, która nie doleciała, nie
może opóźnić ani zablokować dyktowania. Tak samo jak dziś przy pokoju.

## Słownik

Najprostsza część i największa wygoda: lista terminów, wspólna dla konta.
Klient przy starcie pobiera i scala z lokalnym `config.yaml`, przy zmianie
wysyła. Konflikt rozstrzyga suma zbiorów — słownik to zbiór nazw własnych,
a nie dokument, więc scalanie przez unię jest poprawne i nie gubi niczego.

## Kolejność i to, czego nie da się dziś zobaczyć

**Ta funkcja nie ma dziś konsumenta.** Filip ma jedno urządzenie, Wojtek i Jakub
to inne osoby, a aplikacji na telefon nie ma. Zbudowanie kont dziś niczego nie
zmieni na ekranie — odblokuje dopiero to, co przyjdzie po nich.

Stąd kolejność: serwer (konta, parowanie, słownik), potem CLI i demon na
Linuksie, potem statystyki, a klient mobilny na końcu — bo dopiero on czyni tę
pracę widoczną.

## Testy

- parowanie: kod jednorazowy, wygasa, nie da się użyć dwa razy, obcy kod odrzucony;
- scalanie słownika: unia bez duplikatów, wielkość liter, terminy z polskimi znakami;
- ranking: dwa urządzenia jednego konta liczą się jako jedna osoba;
- statystyki: wysyłka przyrostowa nie dubluje wpisów po ponownym połączeniu.
