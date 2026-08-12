import SwiftUI

/// Logowanie kontem — JEDEN komponent używany w dwóch miejscach: na górze
/// Ustawień (główna droga) i w ekranie parowania obok kodu QR. Wcześniej ta
/// logika mieszkała w `PairingView`; siedzi tu, żeby nie było dwóch kopii
/// `POST /login` rozjeżdżających się w czasie.
///
/// Zalogowanie = te same `RemoteCredentials`, które dawał kod QR, więc
/// „wyloguj" jest tym samym co „usuń sparowanie" — token konta JEST tokenem
/// parowania i apka nie ma stanu „zalogowany, ale niesparowany".
struct AccountSection: View {
    @ObservedObject var remote: RemoteSession
    /// Wołane po udanym logowaniu — np. żeby zamknąć ekran parowania.
    var onLoggedIn: (() -> Void)? = nil

    @State private var email = ""
    @State private var password = ""
    @State private var loggingIn = false
    @State private var errorText: String?
    @State private var knownEmail = AccountIdentity.email

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("KONTO").vfEyebrow()

            if remote.isPaired {
                Text(statusText)
                    .font(VFFont.body(12.5))
                    .foregroundStyle(VFColor.faint)
                Button("Wyloguj") {
                    AccountIdentity.email = nil
                    knownEmail = nil
                    remote.updateCredentials(nil)
                }
                .buttonStyle(VFOutlineButtonStyle())
            } else {
                Text("Zaloguj się kontem VoiceFlow, żeby zobaczyć swoją historię dyktowań i połączyć się z Makiem.")
                    .font(VFFont.body(12.5))
                    .foregroundStyle(VFColor.faint)
                field("E-mail", text: $email, placeholder: "ty@przyklad.pl")
                secureField("Hasło", text: $password)
                Button(loggingIn ? "Loguję…" : "Zaloguj") {
                    Task { await logIn() }
                }
                .buttonStyle(VFOutlineButtonStyle(solid: true))
                .disabled(email.isEmpty || password.isEmpty || loggingIn)
            }

            if let errorText {
                Text(errorText)
                    .font(VFFont.body(12.5))
                    .foregroundStyle(VFColor.text)
            }
        }
        .onAppear { knownEmail = AccountIdentity.email }
    }

    private var statusText: String {
        if let knownEmail, !knownEmail.isEmpty {
            return "Zalogowano jako \(knownEmail)."
        }
        return "Połączono kodem QR, bez konta — historia wymaga zalogowania."
    }

    private func logIn() async {
        loggingIn = true
        errorText = nil
        defer { loggingIn = false }
        let address = email.trimmingCharacters(in: .whitespaces)
        do {
            let token = try await AccountAPI.logIn(email: address, password: password)
            let credentials = RemoteCredentials(host: AccountAPI.defaultHost, token: token)
            guard RemotePairing.relayURL(credentials) != nil else {
                errorText = "Adres relaya jest nieprawidłowy."
                return
            }
            password = ""
            AccountIdentity.email = address
            knownEmail = address
            remote.updateCredentials(credentials)
            onLoggedIn?()
        } catch let failure as AccountAPI.Failure {
            errorText = failure == .unauthorized ? "Zły e-mail albo hasło." : failure.message
        } catch {
            errorText = error.localizedDescription
        }
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
                .keyboardType(.emailAddress)
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
}
