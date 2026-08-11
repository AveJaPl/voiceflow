import Foundation

/// Furtki testowe sterowane argumentami uruchomienia — **wyłącznie w buildzie Debug**.
///
/// Po co to istnieje: zakładki „Mac" nie da się zweryfikować w symulatorze bez nich.
/// Onboarding wymaga przejścia przez systemowe Ustawienia i testu mikrofonu na żywo
/// (symulator nie ma mikrofonu), a parowanie wymaga zeskanowania kodu QR (symulator
/// nie ma aparatu). Bez tej furtki każdy przebieg weryfikacyjny kończyłby się
/// klikaniem na oślep albo — gorzej — uznaniem „skoro się kompiluje, to działa".
///
/// `UserDefaults.standard` czyta argumenty uruchomienia postaci `-klucz wartość`
/// automatycznie, więc nie ma tu żadnego własnego parsowania: to jest standardowy
/// mechanizm Foundation, nie hack.
///
/// ```
/// xcrun simctl launch <UDID> io.github.avejapl.voiceflow.ios \
///   -vfSkipOnboarding YES \
///   -vfRemoteHost ws://127.0.0.1:8091 -vfRemoteToken <token>
/// ```
///
/// W buildzie Release wszystkie te właściwości są stałymi `false`/`nil` i kompilator
/// wycina zależny od nich kod — na urządzeniu Wojtka nie ma jak ich włączyć.
enum LaunchOverrides {

    static var skipOnboarding: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "vfSkipOnboarding")
        #else
        return false
        #endif
    }

    /// Poświadczenia podane przy starcie — omijają skaner QR, którego symulator
    /// nie ma. NIE są zapisywane w Keychainie: żyją tylko w tym uruchomieniu, więc
    /// przebieg testowy nie zostawia po sobie sparowanego urządzenia.
    static var credentials: RemoteCredentials? {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: "vfRemoteHost"),
              let token = defaults.string(forKey: "vfRemoteToken"),
              !host.isEmpty, !token.isEmpty
        else { return nil }
        return RemoteCredentials(host: host, token: token)
        #else
        return nil
        #endif
    }
}
