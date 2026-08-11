import SwiftUI

/// Gesty karty okna — JEDNO miejsce, w którym są zdefiniowane, wspólne dla mapki
/// i dla listy. Rozdzielenie ich na dwa widoki skończyłoby się tym, że mapka i
/// lista zachowują się inaczej pod palcem, a to jest dokładnie ten rodzaj różnicy,
/// którego nikt nie zauważa przy pisaniu i wszyscy zauważają przy używaniu.
struct WindowGestures: ViewModifier {
    let onTap: () -> Void
    let onHoldBegan: () -> Void
    let onHoldEnded: () -> Void
    let onDoubleTap: () -> Void

    @State private var isHolding = false
    /// Puszczenie palca po przytrzymaniu generuje TAKŻE zwykłe tapnięcie.
    /// Bez tej blokady każde dyktowanie kończyłoby się dodatkowym `focusWindow`.
    @State private var holdEndedAt: Date?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onDoubleTap() }
            .onTapGesture {
                if let holdEndedAt, Date().timeIntervalSince(holdEndedAt) < 0.4 { return }
                onTap()
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.3)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        // `.second` = długie przytrzymanie rozpoznane, palec wciąż na ekranie.
                        if case .second(true, _) = value, !isHolding {
                            isHolding = true
                            onHoldBegan()
                        }
                    }
                    .onEnded { _ in
                        guard isHolding else { return }
                        isHolding = false
                        holdEndedAt = Date()
                        onHoldEnded()
                    }
            )
    }
}

extension View {
    func windowGestures(
        onTap: @escaping () -> Void,
        onHoldBegan: @escaping () -> Void,
        onHoldEnded: @escaping () -> Void,
        onDoubleTap: @escaping () -> Void
    ) -> some View {
        modifier(WindowGestures(
            onTap: onTap, onHoldBegan: onHoldBegan,
            onHoldEnded: onHoldEnded, onDoubleTap: onDoubleTap
        ))
    }
}

/// Wiersz listy okien. Świadomie czytelniejszy niż prostokąt na mapce: przy
/// czterech oknach mapka wystarcza, przy dwunastu tytuły na niej są nie do
/// odczytania i lista jest jedynym użytecznym widokiem.
struct WindowRow: View {
    let window: WireWindow
    let isSelected: Bool
    let isTarget: Bool

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(window.focused ? VFColor.text : VFColor.faint)
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(window.app)
                        .font(VFFont.body(14, weight: .semibold))
                        .foregroundStyle(VFColor.text)
                    if window.isTerminal {
                        Text("TERMINAL")
                            .font(VFFont.mono(9))
                            .foregroundStyle(VFColor.muted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
                    }
                    if window.minimized {
                        Text("ZWINIĘTE")
                            .font(VFFont.mono(9))
                            .foregroundStyle(VFColor.faint)
                    }
                }
                Text(window.displayTitle)
                    .font(VFFont.body(12))
                    .foregroundStyle(VFColor.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if isTarget {
                Text("CEL")
                    .font(VFFont.mono(9))
                    .foregroundStyle(VFColor.background)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(VFColor.text)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(isSelected ? VFColor.surfaceSolid : Color.clear)
        .overlay(
            Rectangle()
                .stroke(isSelected ? VFColor.border : Color.clear, lineWidth: 1)
        )
    }
}
