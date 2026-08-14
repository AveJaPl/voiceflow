import SwiftUI

/// Gest przycisku „MÓW": **przytrzymanie = mówisz póki trzymasz**, a **krótkie
/// stuknięcie = przełącznik** (start / stop).
///
/// DLACZEGO NIE DWUKLIK (zmiana 2026-08-14 po zgłoszeniu z żywego użycia:
/// „zrobił się zatrzask, ale nie mogłem tego odkliknąć"): `onTapGesture(count: 2)`
/// wymaga dwóch stuknięć w ~250 ms i przegrywa z gestem przytrzymania na tym
/// samym widoku — a przy zatrzasku widok w tym czasie zmienia tło i animuje
/// się, co potrafi zgubić rozpoznawanie w połowie. Efekt: zatrzask dawało się
/// włączyć, ale nie dawało wyłączyć, czyli najgorszy możliwy stan dla przycisku
/// od mikrofonu. Jedno stuknięcie nie ma z czym przegrać i jest tym, co człowiek
/// robi odruchowo, żeby przerwać.
///
/// Rozstrzygnięcie „stuknięcie czy przytrzymanie" liczymy sami, od dotknięcia:
/// jeśli palec został dłużej niż `holdThreshold`, to przytrzymanie (i puszczenie
/// kończy wypowiedź); jeśli krócej — stuknięcie (przełącznik).
struct PushToTalkGesture: ViewModifier {
    /// Po tylu sekundach trzymania traktujemy dotyk jako „mów, póki trzymam".
    var holdThreshold: TimeInterval = 0.32
    let onTap: () -> Void
    let onHoldBegan: () -> Void
    let onHoldEnded: () -> Void

    @State private var isPressed = false
    @State private var isHolding = false
    @State private var holdTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        // `onChanged` sypie zdarzeniami przy każdym drgnięciu
                        // palca — interesuje nas WYŁĄCZNIE pierwsze.
                        guard !isPressed else { return }
                        isPressed = true
                        holdTask?.cancel()
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: UInt64(holdThreshold * 1_000_000_000))
                            guard !Task.isCancelled, isPressed else { return }
                            isHolding = true
                            onHoldBegan()
                        }
                    }
                    .onEnded { _ in
                        holdTask?.cancel()
                        holdTask = nil
                        isPressed = false
                        if isHolding {
                            isHolding = false
                            onHoldEnded()
                        } else {
                            onTap()
                        }
                    }
            )
    }
}

extension View {
    func pushToTalkGesture(
        onTap: @escaping () -> Void,
        onHoldBegan: @escaping () -> Void,
        onHoldEnded: @escaping () -> Void
    ) -> some View {
        modifier(PushToTalkGesture(onTap: onTap, onHoldBegan: onHoldBegan, onHoldEnded: onHoldEnded))
    }
}
