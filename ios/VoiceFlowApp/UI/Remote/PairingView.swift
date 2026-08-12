import AVFoundation
import SwiftUI

/// Parowanie telefonu z Makiem — trzy drogi do tych samych
/// `RemoteCredentials`: konto (`AccountSection`), kod QR z Maca i wpisanie
/// adresu z tokenem ręcznie. `RemoteSession` nie zna między nimi różnicy.
struct PairingView: View {
    @ObservedObject var session: RemoteSession
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var token = ""
    @State private var scanning = false
    @State private var scanError: String?

    var body: some View {
        ZStack {
            VFColor.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PAROWANIE Z MAKIEM").vfEyebrow()
                        Text("Zeskanuj kod QR z Ustawień VoiceFlow na Macu albo wpisz dane ręcznie.")
                            .font(VFFont.body(12.5))
                            .foregroundStyle(VFColor.faint)
                    }
                    .padding(.top, 12)

                    // Logowanie kontem — ten sam komponent co na górze Ustawień
                    // (`AccountSection`), żeby nie było dwóch kopii `POST /login`.
                    AccountSection(remote: session) { dismiss() }

                    Text("ALBO ZESKANUJ KOD Z MACA").vfEyebrow()

                    if scanning {
                        QRScannerView { payload in
                            guard let credentials = RemotePairing.parseQR(payload) else {
                                // Aparat widzi wszystkie kody w kadrze — kod z paczki
                                // albo biletu nie może po cichu podmienić poświadczeń.
                                scanError = "To nie jest kod parowania VoiceFlow."
                                return
                            }
                            scanning = false
                            scanError = nil
                            apply(credentials)
                        }
                        .frame(height: 260)
                        .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))

                        Button("Przerwij skanowanie") { scanning = false }
                            .buttonStyle(VFOutlineButtonStyle())
                    } else {
                        Button("Skanuj kod QR") {
                            scanError = nil
                            scanning = true
                        }
                        .buttonStyle(VFOutlineButtonStyle(solid: true))
                    }

                    if let scanError {
                        Text(scanError)
                            .font(VFFont.body(12.5))
                            .foregroundStyle(VFColor.text)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("RĘCZNIE").vfEyebrow()
                        field("Adres relaya", text: $host, placeholder: "wss://relay.programo.pl")
                        field("Token parowania", text: $token, placeholder: "z POST /pair")
                        Button("Zapisz i połącz") {
                            apply(RemoteCredentials(
                                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                                token: token.trimmingCharacters(in: .whitespacesAndNewlines)
                            ))
                        }
                        .buttonStyle(VFOutlineButtonStyle())
                        .disabled(host.isEmpty || token.isEmpty)
                    }

                    if session.isPaired {
                        Button("Usuń sparowanie") {
                            session.updateCredentials(nil)
                            dismiss()
                        }
                        .buttonStyle(VFOutlineButtonStyle())
                    }

                    Text("Token pozwala zdalnie wpisywać tekst w oknach Twojego Maca. Trzymamy go w Keychainie i nie wysyłamy nigdzie poza relayem.")
                        .font(VFFont.body(12))
                        .foregroundStyle(VFColor.faint)
                }
                .padding(24)
            }
        }
        .navigationTitle("Parowanie")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(VFFont.body(12))
                .foregroundStyle(VFColor.muted)
            TextField(placeholder, text: text)
                .font(VFFont.mono(13))
                .foregroundStyle(VFColor.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(VFColor.surfaceSolid)
                .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
        }
    }

    private func apply(_ credentials: RemoteCredentials) {
        guard RemotePairing.relayURL(credentials) != nil else {
            scanError = "Adres relaya jest nieprawidłowy."
            return
        }
        session.updateCredentials(credentials)
        dismiss()
    }
}

/// Skaner kodów QR. Osobny `UIViewControllerRepresentable`, bo SwiftUI nie ma
/// natywnego czytnika, a `DataScannerViewController` (VisionKit) wymaga Neural
/// Engine i nie działa w symulatorze — czego akurat tutaj potrzebujemy najbardziej,
/// bo cała ścieżka parowania musi dać się przejść bez fizycznego urządzenia.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        /// Jeden kod na sesję skanowania — bez tego kamera wywołuje callback
        /// kilkadziesiąt razy na sekundę na tym samym kodzie.
        private var alreadyReported = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput objects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !alreadyReported,
                  let object = objects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let payload = object.stringValue
            else { return }
            alreadyReported = true
            DispatchQueue.main.async { [onCode] in onCode(payload) }
        }
    }

    final class ScannerController: UIViewController {
        weak var delegate: AVCaptureMetadataOutputObjectsDelegate?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = UIColor(VFColor.surfaceSolid)

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else { return showUnavailable() }

            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return showUnavailable() }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer

            // `startRunning()` blokuje wywołujący wątek — na głównym objawia się
            // zamrożeniem UI na ułamek sekundy przy każdym otwarciu skanera.
            Task.detached { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            Task.detached { [session] in session.stopRunning() }
        }

        /// Symulator nie ma aparatu — zamiast czarnego prostokąta bez wyjaśnienia
        /// mówimy wprost, że trzeba użyć pól poniżej.
        private func showUnavailable() {
            let label = UILabel()
            label.text = "Aparat niedostępny — wpisz dane ręcznie poniżej."
            label.textColor = UIColor(VFColor.muted)
            label.font = UIFont(name: "Inter-Regular", size: 13) ?? .systemFont(ofSize: 13)
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            ])
        }
    }
}
