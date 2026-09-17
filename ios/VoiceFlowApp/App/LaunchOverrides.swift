import Foundation

/// Furtki testowe sterowane argumentami uruchomienia — **wyłącznie w buildzie Debug**.
///
/// Onboarding wymaga przejścia przez systemowe Ustawienia i testu mikrofonu na
/// żywo (symulator nie ma mikrofonu), więc przebieg weryfikacyjny w symulatorze
/// musi umieć go ominąć:
///
/// ```
/// xcrun simctl launch <UDID> io.github.avejapl.voiceflow.ios -vfSkipOnboarding YES
/// ```
///
/// `UserDefaults.standard` czyta argumenty uruchomienia postaci `-klucz wartość`
/// automatycznie — to standardowy mechanizm Foundation, nie hack. W buildzie
/// Release właściwość jest stałą `false` i kompilator wycina zależny kod.
enum LaunchOverrides {
    static var keyboardPreview: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "vfKeyboardPreview")
        #else
        false
        #endif
    }
    static var transcribeFixture: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "vfTranscribeFixture")
        #else
        false
        #endif
    }
    static var skipModelPreparation: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "vfSkipModelPreparation")
        #else
        return false
        #endif
    }
    static var skipOnboarding: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "vfSkipOnboarding")
        #else
        return false
        #endif
    }
}
