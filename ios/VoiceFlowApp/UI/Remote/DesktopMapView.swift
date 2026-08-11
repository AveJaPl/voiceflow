import SwiftUI

/// Dokąd trafi okno upuszczone w danym punkcie ekranu Maca.
///
/// Czysta logika, celowo bez SwiftUI: przeciąganie palcem po miniaturze pulpitu
/// nigdy nie będzie precyzyjne, więc okno nie ląduje „tam, gdzie puściłeś", tylko
/// w najbliższym sensownym miejscu. Zamknięty zbiór miejsc zamiast dowolnych
/// współrzędnych to jedyny sposób, żeby wynik był przewidywalny.
enum DesktopSnap {
    struct Rect: Equatable {
        let x: Int, y: Int, w: Int, h: Int
    }

    /// Ćwiartki tylko wtedy, gdy palec jest wyraźnie w rogu; środek ekranu
    /// (pionowy pas 40–60%) oznacza „połowa", a nie ćwiartka — inaczej prawie
    /// każde upuszczenie kończyłoby się ćwiartką przez przypadek.
    static func target(dropAt point: CGPoint, in display: WireDisplay) -> Rect {
        let w = display.w, h = display.h
        let fx = point.x, fy = point.y

        let left = fx < 0.5
        let halfW = w / 2

        // Pas środkowy w pionie → połowa ekranu na pełnej wysokości.
        if fy > 0.35, fy < 0.65 {
            return Rect(x: left ? 0 : halfW, y: 0, w: halfW, h: h)
        }

        let top = fy < 0.5
        let halfH = h / 2
        return Rect(x: left ? 0 : halfW, y: top ? 0 : halfH, w: halfW, h: halfH)
    }

    /// Prostokąt obejmujący wszystkie ekrany — układ współrzędnych mapki.
    /// Gdy Mac nie przysłał ekranów (starsza wersja), bierzemy obrys okien, żeby
    /// mapka nadal miała sens zamiast zapaść się do zera.
    static func bounds(displays: [WireDisplay], windows: [WireWindow]) -> CGSize {
        if let widest = displays.map(\.w).max(), let tallest = displays.map(\.h).max(), widest > 0, tallest > 0 {
            return CGSize(width: CGFloat(widest), height: CGFloat(tallest))
        }
        let right = windows.map { $0.x + $0.w }.max() ?? 1
        let bottom = windows.map { $0.y + $0.h }.max() ?? 1
        return CGSize(width: CGFloat(max(right, 1)), height: CGFloat(max(bottom, 1)))
    }
}

/// Mapka pulpitu: prostokąty okien w prawdziwych proporcjach, opcjonalnie na tle
/// zrzutu ekranu.
///
/// Zrzut jest TŁEM, nie treścią — etykiety i obszary dotyku rysujemy z listy
/// okien, bo to ona jest źródłem prawdy i działa też wtedy, gdy Mac nie ma
/// uprawnienia do przechwytywania ekranu (plan §3.1). Bez zrzutu mapka nadal
/// pokazuje rozstawienie; ze zrzutem dodatkowo widać, co jest w oknach.
struct DesktopMapView: View {
    let windows: [WireWindow]
    let displays: [WireDisplay]
    let screenshot: Data?
    let selectedID: String?
    let targetID: String?

    let onTap: (WireWindow) -> Void
    let onHoldBegan: (WireWindow) -> Void
    let onHoldEnded: (WireWindow) -> Void
    let onDoubleTap: (WireWindow) -> Void
    let onMove: (WireWindow, DesktopSnap.Rect) -> Void

    @State private var dragging: (id: String, point: CGPoint)?

    var body: some View {
        let desktop = DesktopSnap.bounds(displays: displays, windows: windows)
        let aspect = desktop.width / max(desktop.height, 1)

        GeometryReader { geo in
            let scale = geo.size.width / desktop.width

            ZStack(alignment: .topLeading) {
                Rectangle().fill(VFColor.surfaceSolid)

                if let screenshot, let image = UIImage(data: screenshot) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .opacity(0.55)   // przyciemnione, żeby etykiety zostały czytelne
                }

                // Od najniższego do najwyższego — okno na wierzchu ma być na wierzchu.
                ForEach(windows.sorted { $0.z > $1.z }) { window in
                    tile(window, scale: scale)
                }

                if let dragging, let display = displays.first ?? implicitDisplay(desktop) {
                    ghost(for: DesktopSnap.target(dropAt: dragging.point, in: display), scale: scale)
                }
            }
            .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    private func implicitDisplay(_ size: CGSize) -> WireDisplay? {
        WireDisplay(id: 0, w: Int(size.width), h: Int(size.height), main: true)
    }

    private func tile(_ window: WireWindow, scale: CGFloat) -> some View {
        let isSelected = window.id == selectedID
        let isTarget = window.id == targetID

        return VStack(alignment: .leading, spacing: 2) {
            Text(window.app)
                .font(VFFont.body(11, weight: .semibold))
                .foregroundStyle(VFColor.text)
                .lineLimit(1)
            Text(window.displayTitle)
                .font(VFFont.mono(9))
                .foregroundStyle(VFColor.muted)
                .lineLimit(2)
        }
        .padding(6)
        .frame(
            width: max(CGFloat(window.w) * scale, 44),
            height: max(CGFloat(window.h) * scale, 36),
            alignment: .topLeading
        )
        .background(window.focused ? VFColor.surfaceSolid : VFColor.background.opacity(0.82))
        .overlay(
            Rectangle().stroke(
                isTarget ? VFColor.text : (isSelected ? VFColor.muted : VFColor.border),
                lineWidth: isTarget ? 2 : 1
            )
        )
        .offset(x: CGFloat(window.x) * scale, y: CGFloat(window.y) * scale)
        .opacity(dragging?.id == window.id ? 0.4 : 1)
        .windowGestures(
            onTap: { onTap(window) },
            onHoldBegan: { onHoldBegan(window) },
            onHoldEnded: { onHoldEnded(window) },
            onDoubleTap: { onDoubleTap(window) }
        )
        .simultaneousGesture(moveGesture(for: window, scale: scale))
    }

    private func moveGesture(for window: WireWindow, scale: CGFloat) -> some Gesture {
        // `minimumDistance: 20` — przypadkowe drgnięcie palca przy dotknięciu nie
        // może przestawić okna na Macu. Przesunięcie musi być intencjonalne.
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let desktop = DesktopSnap.bounds(displays: displays, windows: windows)
                let x = (CGFloat(window.x) * scale + value.location.x) / (desktop.width * scale)
                let y = (CGFloat(window.y) * scale + value.location.y) / (desktop.height * scale)
                dragging = (window.id, CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)))
            }
            .onEnded { _ in
                defer { dragging = nil }
                guard let dragging, dragging.id == window.id else { return }
                let desktop = DesktopSnap.bounds(displays: displays, windows: windows)
                guard let display = displays.first ?? implicitDisplay(desktop) else { return }
                onMove(window, DesktopSnap.target(dropAt: dragging.point, in: display))
            }
    }

    private func ghost(for rect: DesktopSnap.Rect, scale: CGFloat) -> some View {
        Rectangle()
            .stroke(VFColor.text, style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
            .frame(width: CGFloat(rect.w) * scale, height: CGFloat(rect.h) * scale)
            .offset(x: CGFloat(rect.x) * scale, y: CGFloat(rect.y) * scale)
            .allowsHitTesting(false)
    }
}
