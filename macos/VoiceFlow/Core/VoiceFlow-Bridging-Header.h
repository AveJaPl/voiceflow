// Bridging header — whisper.cpp jest C, nie Swift Package: linkujemy wprost
// przeciw bibliotece z Homebrew (`brew install whisper-cpp`), tej samej, którą
// zmierzono w tools/probes/etap0e-whispercpp/stream_probe.c (Etap 0e).
//
// Wybór (patrz docs/plans/whisper-local-engine-pl.md §2, "wybierz tę, która daje
// działający build najszybciej i bez kruchego mostu C↔Swift"): oficjalny
// pakiet SPM ggml-org/whisper.cpp kompilowałby cały whisper.cpp+ggml od zera w
// Xcode; biblioteka z brew jest już zbudowana, sprawdzona (dokładnie ta sama,
// której użyła sonda pomiarowa) i nie wymaga sieci przy KAŻDYM buildzie. Cena:
// zależność od `brew install whisper-cpp` na maszynie, na której się buduje
// (już zainstalowane — patrz raport agenta). Do rozważenia przy dystrybucji
// na inną maszynę: embedować .dylib albo przejść na wendorowany SPM.
//
// Typy C stąd są PRYWATNE dla WhisperContext.swift — reszta apki (i testy
// przez @testable import) widzą wyłącznie typy natywne Swifta.
#include <whisper.h>
#include <ggml-backend.h>
