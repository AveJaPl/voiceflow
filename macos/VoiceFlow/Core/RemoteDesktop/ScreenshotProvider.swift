import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Zrzut ekranu głównego NA ŻĄDANIE (plan §3.3: żadnego ciągłego strumienia —
/// telefon prosi, Mac odpowiada jednym JPEG-iem). ScreenCaptureKit, bo
/// `CGDisplayCreateImage` już nie istnieje w SDK. Wymaga uprawnienia
/// „Nagrywanie ekranu"; jego brak zgłaszamy z góry przez `MacCaps.screenshot`,
/// żeby telefon w ogóle nie pokazywał przycisku.
@MainActor
enum ScreenshotProvider {

    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// JPEG ekranu głównego, przeskalowany do maks. `maxWidth` pikseli
    /// szerokości — telefonowi wystarcza podgląd, a pełny Retina 5K miałby
    /// kilkanaście MB na ramkę.
    static func captureMainDisplay(
        maxWidth: Int = 1200, quality: CGFloat = 0.6
    ) async -> (header: ScreenshotHeader, data: Data)? {
        guard isPermitted else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else { return nil }

            let scale = min(1, Double(maxWidth) / Double(display.width))
            let configuration = SCStreamConfiguration()
            configuration.width = Int(Double(display.width) * scale)
            configuration.height = Int(Double(display.height) * scale)
            configuration.showsCursor = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )

            let rep = NSBitmapImageRep(cgImage: image)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
                return nil
            }
            let header = ScreenshotHeader(
                generation: 0, // uzupełnia RemoteControlHub — on zna bieżącą generację
                w: image.width,
                h: image.height,
                bytes: jpeg.count
            )
            return (header, jpeg)
        } catch {
            DebugLog.write("RemoteDesktop", "zrzut ekranu nie powiódł się: \(error.localizedDescription)")
            return nil
        }
    }
}
