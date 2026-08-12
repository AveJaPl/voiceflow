import AVFoundation
import SwiftUI

/// Parowanie telefonu z Makiem.
///
/// UWAGA: konta użytkowników buduje równolegle inny agent. Ten ekran celowo NIE
/// jest logowaniem — wpisuje adres relaya i token, i tyle. Gdy konta wejdą,
/// zmienia się TYLKO to, skąd biorą się `RemoteCredentials`; `RemoteSession`
/// i cała zakładka „Mac" nie wiedzą o istnieniu tej różnicy.
struct PairingView: View {
    @ObservedObject var session: RemoteSession
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var token = ""
    @State private var scanning = false
    @State private var scanError: String?

    // Logowanie kontem — najprostsza droga: e-mail + hasło zamiast QR.
    @State private var email = ""
    @State private var password = ""
    @State private var loggingIn = false
    @State private var loginError: String?

    /// Publiczny relay na serwerze Wojtka (Coolify/Contabo) — domyślny dom
    /// dla logowania kontem; QR i tryb ręczny mogą wskazać dowolny inny.
    static let defaultAccountHost = "wss://o35lo8pceb0fmc10ziul6llo.161.97.135.88.sslip.io"

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

                    VStack(alignment: .leading, spacing: 10) {
                        Text("KONTO").vfEyebrow()
                        field("E-mail", text: $email, placeholder: "ty@przyklad.pl")
                        secureField("Hasło", text: $password)
                        Button(loggingIn ? "Loguję…" : "Zaloguj i połącz") {
                            Task { await logIn() }
                        }
                        .buttonStyle(VFOutlineButtonStyle(solid: true))
                        .disabled(email.isEmpty || password.isEmpty || loggingIn)
                        if let loginError {
                            Text(loginError)
                                .font(VFFont.body(12.5))
                                .foregroundStyle(VFColor.text)
                        }
                    }

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

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(VFFont.body(12))
                .foregroundStyle(VFColor.muted)
            SecureField("", text: text)
                .font(VFFont.mono(13))
                .foregroundStyle(VFColor.text)
                .padding(10)
                .background(VFColor.surfaceSolid)
                .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
        }
    }

    /// POST /login na publicznym relayu → stały token konta → te same
    /// poświadczenia, które dawał QR. Konto i QR to dwie drogi do tego
    /// samego `RemoteCredentials` — `RemoteSession` nie zna różnicy.
    private func logIn() async {
        loggingIn = true
        loginError = nil
        defer { loggingIn = false }
        let httpBase = Self.defaultAccountHost.replacingOccurrences(of: "wss://", with: "https://")
        guard let url = URL(string: "\(httpBase)/login") else {
            loginError = "Nieprawidłowy adres serwera."
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email.trimmingCharacters(in: .whitespaces),
            "password": password,
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                loginError = "Serwer nie odpowiedział."
                return
            }
            guard status == 200 else {
                loginError = status == 401
                    ? "Zły e-mail albo hasło."
                    : "Serwer zwrócił błąd \(status) — może konto jeszcze nie istnieje?"
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pairToken = object["pairToken"] as? String, !pairToken.isEmpty else {
                loginError = "Serwer odpowiedział bez tokenu."
                return
            }
            password = ""
            apply(RemoteCredentials(host: Self.defaultAccountHost, token: pairToken))
        } catch {
            loginError = "Nie mogę połączyć się z serwerem: \(error.localizedDescription)"
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
