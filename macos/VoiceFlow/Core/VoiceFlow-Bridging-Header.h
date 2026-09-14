// Bridging header — whisper.cpp jest C, nie Swift Package. Nagłówki i
// biblioteka statyczna pochodzą z third_party/whisper-macos, które buduje
// tools/build-whisper-macos.sh z submodułu android/third_party/whisper.cpp
// (jedna przypięta wersja whisper.cpp dla Androida i Maca).
//
// Wcześniej linkowaliśmy wprost przeciw Homebrew (`brew install whisper-cpp`);
// to blokowało dystrybucję — gotowa .app nie startowała bez Homebrew.
//
// Typy C stąd są PRYWATNE dla WhisperContext.swift — reszta apki (i testy
// przez @testable import) widzą wyłącznie typy natywne Swifta.
#include <whisper.h>
#include <ggml-backend.h>
