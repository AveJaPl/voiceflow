import SwiftUI

/// Podgląd pulpitu Maca z KLIKALNYMI oknami terminali.
///
/// To jest właściwy sposób wybierania celu na telefonie: widzisz swój ekran i
/// stukasz w to okno, o które chodzi, zamiast zgadywać po nazwie z listy.
/// Zaznaczone okno świeci TU, na telefonie, dokładnie tak samo jak na ekranie
/// Maca — bez tego wiadomo, co jest zaznaczone, tylko na jednym z dwóch
/// urządzeń (zgłoszone przez Wojtka 2026-08-14).
///
/// PRZELICZENIE WSPÓŁRZĘDNYCH: zrzut obejmuje EKRAN GŁÓWNY, a `WireWindow`
/// niesie globalne współrzędne CoreGraphics, w których ekran główny zaczyna się
/// w (0,0). Wystarczy więc podzielić przez jego rozmiar i pomnożyć przez rozmiar
/// obrazka — skalowanie zrzutu (Mac zsyła go zmniejszonego) nie ma znaczenia,
/// bo liczymy na ułamkach. Okna z drugiego monitora wypadają poza 0…1 i są
/// pomijane: nie ma ich na tym obrazku, więc nie ma czego podświetlać.
struct MacScreenPreview: View {
    let image: UIImage
    /// Rozmiar ekranu głównego w punktach (z ramki `windows`).
    let display: WireDisplay?
    let terminals: [WireWindow]
    let selectedID: String?
    let onSelect: (WireWindow) -> Void

    var body: some View {
        GeometryReader { geometry in
            let frame = fittedImageFrame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                ForEach(Array(placements(in: frame).enumerated()), id: \.element.window.id) { index, placement in
                    hotspot(placement, number: index + 1)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(VFColor.surfaceSolid)
        .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
    }

    private struct Placement {
        let window: WireWindow
        let rect: CGRect
    }

    /// Gdzie NAPRAWDĘ leży obrazek w widoku: `aspectRatio(.fit)` zostawia pasy
    /// po bokach albo nad i pod, a prostokąty okien muszą trafić w obrazek, nie
    /// w te pasy.
    private func fittedImageFrame(in size: CGSize) -> CGRect {
        let imageRatio = image.size.width / max(image.size.height, 1)
        let boxRatio = size.width / max(size.height, 1)
        if imageRatio > boxRatio {
            let height = size.width / imageRatio
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        } else {
            let width = size.height * imageRatio
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
    }

    private func placements(in frame: CGRect) -> [Placement] {
        guard let display, display.w > 0, display.h > 0 else { return [] }
        return terminals.compactMap { window in
            let x = CGFloat(window.x) / CGFloat(display.w)
            let y = CGFloat(window.y) / CGFloat(display.h)
            let w = CGFloat(window.w) / CGFloat(display.w)
            let h = CGFloat(window.h) / CGFloat(display.h)
            // Okno z drugiego monitora — na tym obrazku go nie ma.
            guard x > -0.2, y > -0.2, x < 1, y < 1, w > 0.01, h > 0.01 else { return nil }
            return Placement(window: window, rect: CGRect(
                x: frame.minX + x * frame.width,
                y: frame.minY + y * frame.height,
                width: min(w, 1 - x) * frame.width,
                height: min(h, 1 - y) * frame.height
            ))
        }
    }

    private func hotspot(_ placement: Placement, number: Int) -> some View {
        let selected = placement.window.id == selectedID
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(selected ? Color.white.opacity(0.14) : Color.clear)
                .overlay(
                    Rectangle().stroke(
                        selected ? Color.white : Color.white.opacity(0.35),
                        lineWidth: selected ? 2.5 : 1
                    )
                )
            Text("\(number)")
                .font(VFFont.mono(10))
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(width: 18, height: 18)
                .background(selected ? Color.white : Color.black.opacity(0.55))
                .padding(4)
        }
        .frame(width: placement.rect.width, height: placement.rect.height)
        .offset(x: placement.rect.minX, y: placement.rect.minY)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(placement.window) }
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}
