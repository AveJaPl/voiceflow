"""Word timings for the demo voice track, from the same model voiceflow uses.

Run from the repository root:  uv run python demo/words.py
The animation's live preview shows, at each one-second tick, exactly the words
this transcription places before that moment — what the real preview would see.
"""

import json
from pathlib import Path

from faster_whisper import WhisperModel

HERE = Path(__file__).parent
model = WhisperModel("large-v3-turbo", device="cpu", compute_type="int8")
segments, _info = model.transcribe(
    str(HERE / "public" / "voice.mp3"), language="en", word_timestamps=True, beam_size=5
)
words = [
    {"w": w.word, "start": round(w.start, 3), "end": round(w.end, 3)}
    for segment in segments
    for w in segment.words
]
(HERE / "src").mkdir(exist_ok=True)
(HERE / "src" / "words.json").write_text(json.dumps(words, indent=1), encoding="utf-8")
print("".join(w["w"] for w in words))
print("last word ends at", words[-1]["end"])
