import SwiftUI

/// Treść terminala z Maca — jako TEKST, nie jako zrzut ekranu.
///
/// To jest powód, dla którego cała ta zakładka powstała: widzisz, co Claude
/// wypisuje w terminalu, i dyktujesz odpowiedź. Zrzut ekranu terminala
/// przeskalowany z 3456 px na szerokość telefonu jest nieczytelny; tekst jest
/// czytelny w dowolnym rozmiarze, waży 3 KB zamiast 100 KB i nie wymaga od Maca
/// uprawnienia do przechwytywania ekranu (plan §3.2).
struct TerminalPreview: View {
    let title: String
    let lines: [String]

    /// Ostatnia linia bywa pusta (prompt czekający na wejście) — trzymanie na
    /// niej kotwicy przewijania powoduje, że widok „ucieka" pod pustą linię.
    private var anchoredLines: [String] {
        var result = lines
        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true, result.count > 1 {
            result.removeLast()
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PODGLĄD TERMINALA").vfEyebrow()
                Spacer()
                Text(title)
                    .font(VFFont.mono(10))
                    .foregroundStyle(VFColor.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().overlay(VFColor.border)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(anchoredLines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line)
                                .font(VFFont.mono(10))
                                .foregroundStyle(VFColor.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: anchoredLines.count) { _, count in
                    // Terminal czyta się od dołu — nowa linia ma być widoczna
                    // bez przewijania palcem.
                    guard count > 0 else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            .frame(height: 180)
        }
        .background(VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }
}
