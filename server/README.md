# Własny serwer transkrypcji

Opcjonalny. VoiceFlow liczy whispera na urządzeniu (Mac: Metal, iPhone:
Neural Engine) i to jest domyślna, najszybsza droga. Serwer ma sens, gdy
urządzenie jest za słabe (stary laptop, tani telefon) albo gdy chcesz
jeden mocny komputer dla kilku osób.

```bash
cd server
docker compose up -d
curl -F file=@probka.wav -F language=pl http://localhost:8090/v1/audio/transcriptions
# → {"text":"Dzień dobry, chciałbym dzisiaj porozmawiać o planach na przyszły tydzień."}
```

W apce: **Ustawienia → Zaawansowane → Serwer transkrypcji** → `http://<adres>:8090`.
Puste pole = liczenie lokalne.

## Kontrakt

`POST /v1/audio/transcriptions`, `multipart/form-data`:

| pole | wartość |
|---|---|
| `file` | WAV 16 kHz mono (apki wysyłają dokładnie to; z `--convert` serwer przyjmie też m4a/mp3) |
| `language` | `pl` |
| `prompt` | słownik użytkownika, przecinkami — jak `initial_prompt` w whisper.cpp |
| `response_format` | `json` |

Odpowiedź: `{"text": "..."}`. Ten sam kształt co OpenAI, więc pod to pole
podłączysz też `faster-whisper-server`, Speaches albo płatne API
(`https://api.openai.com`, `https://api.groq.com/openai` — wtedy w apce
podaj też klucz).

## Mac jako serwer dla telefonu

Nie trzeba Dockera: aplikacja na Macu ma w Zaawansowanych przełącznik
„Udostępnij silnik w sieci lokalnej” — wystawia ten sam kontrakt na porcie
8090 i ogłasza się przez Bonjour (`_voiceflow-asr._tcp`). iPhone w tej samej
sieci widzi Maca na liście i liczy na jego GPU zamiast na własnej baterii.

## Prywatność

Nagranie idzie na serwer, który wskażesz — i tylko tam. Serwer z tego
katalogu niczego nie zapisuje na dysk poza modelem.
