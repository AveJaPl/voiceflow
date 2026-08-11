# macsim — referencyjny Mac dla VoiceFlow

`macsim` jest procesem Node udającym stronę macOS protokołu z
`shared/wire/ControlFrames.swift`. Pozwala przetestować kartę „Mac” w iOS zanim
powstanie aplikacja macOS: podaje listę okien, zrzut JPEG, żywy tekst terminala,
odbiera PCM i odsyła udawaną transkrypcję.

Nie dotyka prawdziwych okien, mikrofonu ani schowka. Jest bezpiecznym peerem do
testów oraz wykonywalną specyfikacją zachowania prawdziwej strony Maca.

## Instalacja i testy

```bash
cd tools/macsim
npm install
npm test
```

Test integracyjny podnosi rzeczywisty relay i dwa WebSockety, ale wyłącznie na
`127.0.0.1` i porcie efemerycznym.

## Ręczny przebieg z lokalnym relayem

W pierwszym terminalu uruchom relay (z katalogu repozytorium):

```bash
cd relay
npm install
ADMIN_SECRET=local-dev-secret PORT=8091 node server.js
```

W drugim terminalu utwórz token. Skopiuj wartość pola `token` z odpowiedzi.

```bash
curl -X POST http://127.0.0.1:8091/pair \
  -H 'authorization: Bearer local-dev-secret'
```

W trzecim terminalu uruchom symulator, wklejając ten token:

```bash
cd tools/macsim
npm install
node server.js --relay ws://127.0.0.1:8091 --token <token>
```

Opcjonalny prosty klient telefonu przechodzi przez `hello`, subskrypcję,
podniesienie Terminala, `start`, PCM, `end` i `injected`:

```bash
node scripts/fake-phone.js ws://127.0.0.1:8091 <token>
```

Przy pierwszym starcie `server.js` materializuje
`assets/desktop.jpg`: to wbudowany, poprawny JPEG bez zależności graficznej.
Nagłówek `screenshot` zawsze jest wysyłany bezpośrednio przed jego pojedynczą
ramką binarną.

## Scenariusze

Domyślny scenariusz to `happy`. Podaj `--scenario <nazwa>` przy uruchomieniu.

| Scenariusz | Co udowadnia |
| --- | --- |
| `happy` | Normalna ścieżka: focus, `started`, preview i `injected`. |
| `windowGone` | Pierwszy `start` zwraca `windowGone` oraz świeże `windows`; nie ma `started`. |
| `focusFailed` | Pierwszy `start` zwraca `focusFailed`; nie ma `started`. |
| `busy` | Każdy `start` zwraca `busy`; nie ma `started`. |
| `silent` | `start` nie dostaje nigdy `started`, więc telefon może sprawdzić timeout 1,5 s. |
| `dropMidUtterance` | Około 1,5 s po `started` symulator zrywa WebSocket. |
| `noCaps` | `hello` deklaruje wszystkie trzy możliwości jako `false`, a screenshot, tekst terminala i ruch okna dostają `unsupported`. |

## Dla implementatora strony Maca

To jest wykonywalna specyfikacja: jeśli Twoja implementacja Maca przechodzi te
same scenariusze i zachowuje kolejność ramek, aplikacja iOS zadziała. Szczególnie
ważne są: `started` wyłącznie po sukcesie atomowego focusu, monotoniczne
`generation`, ignorowanie PCM poza `start`…`end` oraz sąsiedztwo
`screenshot` → JPEG-binarny.
