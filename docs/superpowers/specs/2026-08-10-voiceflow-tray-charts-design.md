# Wskaźnik statystyk mówienia: emoji w etykiecie + wykresy w menu

Data: 2026-08-10

## Kontekst

Pierwsza iteracja wskaźnika (spec `2026-08-10-voiceflow-tray-stats-design.md`,
zaimplementowana i scalona do `main`) pokazuje w pasku `"12 min · 340 słów"`
i po kliknięciu rozwija trzy linijki tekstu: tydzień/miesiąc/rok. Po
przetestowaniu na żywo Filip poprosił o dwie poprawki:

1. Etykieta w pasku jest za długa — słowo „słów" jest zbędne.
2. Rozwijane menu powinno pokazywać wykresy (rytm godzinowy dzisiaj,
   rytm dzienny z ostatnich dwóch tygodni), nie tylko liczby.

## Etykieta

`"58 min · 💬 7,8k"` — emoji dymka zamiast słowa „słów", liczba nadal przez
`compact_number()`. Zmiana wyłącznie w `build_payload()`
(`src/voiceflow/tray.py`): dotychczasowe `f"{duration} · {words} słów"` dla
etykiety „dziś" staje się `f"{duration} · 💬 {words}"`. Trzy linijki
podsumowania (tydzień/miesiąc/rok) zostają bez zmian — dotyczy to tylko
etykiety w pasku, nie tekstu w menu.

## Protokół demon ↔ ikona (v2)

Payload JSON wysyłany przez `Tray.update()` rośnie o dwa nowe klucze,
zamiast płaskiej listy `"menu"`:

```json
{
  "label": "58 min · 💬 7,8k",
  "summary": ["Ten tydzień: 3 godz. 10 min · 1,2 k słów", "Ten miesiąc: ...", "Ten rok: ..."],
  "hourly": [0, 0, 3, 12, 45, 0, ...],
  "daily": [{"date": "2026-07-28", "words": 340}, {"date": "2026-07-29", "words": 0}, ...]
}
```

- `summary` — to, co wcześniej nazywało się `"menu"`: trzy gotowe stringi
  tydzień/miesiąc/rok, bez zmian w formacie ani treści.
- `hourly` — dokładnie 24 liczby całkowite, indeks = godzina lokalna
  (0–23), wartość = suma słów wypowiedzianych w tej godzinie **dzisiaj**.
- `daily` — dokładnie 14 obiektów `{"date": "YYYY-MM-DD", "words": int}`,
  od najstarszego dnia do dzisiaj (ten sam zakres co istniejący wykres
  „Słowa dziennie" w apce ustawień).

`hourly`/`daily` to surowe liczby — nazwy dni tygodnia, formatowanie osi,
wyróżnianie „dziś"/„teraz" liczy sam skrypt ikony (ma `datetime` pod ręką).
`Tray`/`build_payload()` w `src/voiceflow/tray.py` zostają "głupie": tylko
agregują i serializują, zero wiedzy o rysowaniu.

## Nowe funkcje w `src/voiceflow/statlib.py`

Dwie doklejki do istniejącego modułu (ten sam plik z pierwszej iteracji,
te same konwencje: operują na `Record`, nie na `Mapping`):

- `hourly_word_totals(records: Iterable[Record], *, today: date | None = None) -> list[int]`
  — gęsta lista 24 elementów (indeks = godzina 0–23), sumująca `words` dla
  rekordów z dzisiejszą `record_date(...)`, pogrupowanych po godzinie
  lokalnego czasu dyktowania. Wymaga wydzielenia istniejącej logiki
  parsowania czasu z `record_date()` do prywatnej pomocniczej funkcji
  `_local_datetime(record: Record) -> datetime` (dziś `record_date()` od
  razu ucina wynik do `.date()` — potrzebujemy tej samej logiki, ale z
  dostępem do godziny). `record_date()` staje się jednolinijkowym
  wrapperem `_local_datetime(record).date()`; zachowanie identyczne,
  zero zmian w istniejących testach.
- `daily_series(records: Iterable[Record], days: int, *, today: date | None = None) -> list[tuple[date, int]]`
  — gęsta, malejąco-do-dziś lista `(dzień, suma_słów)` długości `days`,
  z zerami dla dni bez dyktowania. To port funkcji o tej samej nazwie i
  sygnaturze z `app/voiceflow_app/statlib.py` (tam operuje na
  `Mapping`/`HistoryRecord`), z tego samego powodu co reszta modułu:
  `app/voiceflow_app` i `src/voiceflow` żyją w różnych interpreterach
  Pythona bez wspólnej ścieżki importu (patrz pierwszy spec).

## `src/voiceflow/tray.py`

`build_payload()` rozszerzony o wywołanie `hourly_word_totals()` i
`daily_series(records, 14)`, serializowane do kluczy `hourly`/`daily`
opisanych wyżej. `Tray.update()` zmienia sygnaturę z
`update(self, label: str, menu: list[str])` na
`update(self, label: str, summary: list[str], hourly: list[int], daily: list[tuple[date, int]])`
— cztery jawne parametry zamiast jednego payloadu-słownika, żeby wywołania
w `daemon.py` zostały czytelne i typowane; serializacja JSON (w tym
konwersja `date` → `"YYYY-MM-DD"`) dzieje się wewnątrz `Tray.update()`.

## `scripts/voiceflow-tray.py`

Dwa nowe wykresy słupkowe w rozwijanym menu, w tej kolejności pod trzema
istniejącymi linijkami tekstu:

1. **„Dziś godzinowo"** — 24 wąskie słupki, wysokość = słowa w danej
   godzinie; oś X podpisana co 4 godziny (`0, 4, 8, 12, 16, 20`); bieżąca
   godzina wyróżniona (jaśniejszy słupek), tak jak „dziś" jest wyróżnione
   na wykresie 14-dniowym w apce ustawień.
2. **„Słowa dziennie · 14 dni"** — bezpośredni port istniejącego wykresu
   z `app/voiceflow_app/pages/stats.py` (`_draw_bars`): zaokrąglone górne
   rogi słupków, etykieta dnia tygodnia pod każdym, liczba nad najwyższym
   słupkiem, dzisiejszy dzień wyróżniony. Ta sama matematyka rysowania,
   ale osadzona w `Gtk.DrawingArea` **GTK3** (sygnał `draw(widget, cr)`,
   rozmiar przez `widget.get_allocated_width()/height()`) zamiast GTK4
   (`set_draw_func(area, cr, width, height)`) — inny toolkit, trzeba
   przepisać sygnaturę, nie da się skopiować 1:1.

Oba wykresy to osadzone widgety wewnątrz `Gtk.MenuItem` (menu item
zawierający `Gtk.DrawingArea` zamiast tekstu) — nietypowe dla natywnego
menu AppIndicatora, więc wymaga ręcznej weryfikacji wizualnej na żywym
pasku (patrz Testowanie). Skrypt liczy nazwy dni tygodnia (`DAY_NAMES`,
ten sam skrót co w apce: `pn, wt, śr, cz, pt, sob, nd`) i godziny lokalnie
z surowych danych `daily`/`hourly`.

## Menu — finalny układ

1. Ten tydzień: … (tekst)
2. Ten miesiąc: … (tekst)
3. Ten rok: … (tekst)
4. Dziś godzinowo (wykres, 24 słupki)
5. Słowa dziennie · 14 dni (wykres, port z apki)

## Testowanie

- `hourly_word_totals()` i `daily_series()` dostają pełne testy
  jednostkowe w `tests/test_statlib.py`, tym samym stylem co istniejące
  funkcje (dzień z aktywnością o różnych godzinach, dzień bez aktywności,
  granica dnia/strefy czasowej, `days=14` z lukami).
- `build_payload()` testy w `tests/test_tray.py` rozszerzone o asercje na
  `summary`/`hourly`/`daily` (długości list, wartości dla znanego zestawu
  rekordów).
- `Tray.update()` testy zaktualizowane pod nową sygnaturę (4 argumenty
  zamiast 2), stub-proces nadal loguje surowy JSON — bez zmian w
  mechanizmie testowania procesu.
- `scripts/voiceflow-tray.py` — jak dotąd, bez testów automatycznych
  (wymaga PyGObject + realnego ekranu). Weryfikacja manualna: uruchomić
  skrypt ręcznie, wysłać payload z przykładowymi `hourly`/`daily`,
  sprawdzić że oba wykresy renderują się czytelnie w wąskim menu paska
  GNOME (rozmiar menu, brak przycinania, kolory w trybie ciemnym paska).

## Poza zakresem

- Wykres „tygodniowy" (osobna agregacja po tygodniach, nie dniach) —
  14-dniowy wykres dzienny już pokazuje rytm tygodnia, Filip potwierdził
  że to wystarczy na razie.
- Zmiana wizualnego stylu istniejącego wykresu z apki ustawień — port
  1:1 matematyki rysowania, nie redesign.
- Interaktywność wykresów w menu (tooltips, klikalność słupków) — apka
  ustawień ma tooltip na mapie aktywności, tray tego nie replikuje.
