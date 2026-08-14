import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Zrzut CAŁEGO biurka — wszystkich ekranów naraz, złożonych w jeden obrazek w
/// takim układzie, w jakim stoją na biurku.
///
/// Dlaczego wszystkie, a nie sam główny (zmiana 2026-08-14): na telefonie ten
/// obrazek jest sposobem wybierania okna, a nie ozdobą. Zrzut jednego ekranu
/// znaczy, że połowa terminali nie ma w co dać się stuknąć — a to dokładnie ta
/// połowa, której nie widać własnymi oczami.
///
/// ScreenCaptureKit, bo `CGDisplayCreateImage` już nie istnieje w SDK. Wymaga
/// uprawnienia „Nagrywanie ekranu"; jego brak zgłaszamy z góry przez
/// `MacCaps.screenshot`.
@MainActor
enum ScreenshotProvider {

    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// JPEG całego biurka, przeskalowany do maks. `maxWidth` pikseli szerokości.
    /// Nagłówek niesie POKRYTY OBSZAR w punktach (globalne współrzędne
    /// CoreGraphics) — telefon przelicza po nim położenie okien na piksele.
    static func captureMainDisplay(
        maxWidth: Int = 1400, quality: CGFloat = 0.55
    ) async -> (header: ScreenshotHeader, data: Data)? {
        guard isPermitted else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !content.displays.isEmpty else { return nil }

            // Obszar wspólny wszystkich ekranów w układzie CG (początek w lewym
            // górnym rogu ekranu głównego, Y rośnie w dół).
            let area = content.displays.reduce(CGRect.null) { $0.union($1.frame) }
            guard area.width > 0, area.height > 0 else { return nil }

            let scale = min(1, Double(maxWidth) / Double(area.width))
            let pixelWidth = Int(area.width * scale)
            let pixelHeight = Int(area.height * scale)

            guard let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }

            // Tło ma znaczenie: przy dwóch ekranach różnej wysokości zostaje
            // pusty pas, który musi wyglądać jak brak ekranu, a nie jak śmieci.
            context.setFillColor(CGColor(gray: 0.06, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

            for display in content.displays {
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int(Double(display.width) * scale))
                configuration.height = max(1, Int(Double(display.height) * scale))
                configuration.showsCursor = false
                let filter = SCContentFilter(display: display, excludingWindows: [])
                guard let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration
                ) else { continue }

                // `SCDisplay.frame` jest JUŻ w układzie CoreGraphics (początek
                // w lewym górnym rogu ekranu głównego, Y w dół) — tym samym, w
                // którym przychodzą okna. Zmierzone sondą 2026-08-14: własna
                // „poprawka" na układ AppKitu odwracała to drugi raz i obszar
                // wychodził (0,−956), przez co terminale z drugiego ekranu
                // lądowały pod dolną krawędzią obrazka (102%).
                let frame = display.frame
                let topOffset = frame.minY - area.minY
                context.draw(image, in: CGRect(
                    x: (frame.minX - area.minX) * scale,
                    // CGContext liczy Y od DOŁU, a obszar mierzymy od góry.
                    y: Double(pixelHeight) - (topOffset + frame.height) * scale,
                    width: frame.width * scale,
                    height: frame.height * scale
                ))
            }

            guard let composed = context.makeImage() else { return nil }
            let rep = NSBitmapImageRep(cgImage: composed)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
                return nil
            }

            let header = ScreenshotHeader(
                generation: 0, // uzupełnia RemoteControlHub — on zna bieżącą generację
                w: composed.width,
                h: composed.height,
                bytes: jpeg.count,
                areaX: Int(area.minX), areaY: Int(area.minY),
                areaW: Int(area.width), areaH: Int(area.height)
            )
            return (header, jpeg)
        } catch {
            DebugLog.write("RemoteDesktop", "zrzut ekranu nie powiódł się: \(error.localizedDescription)")
            return nil
        }
    }

}
