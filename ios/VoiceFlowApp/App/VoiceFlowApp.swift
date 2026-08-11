import SwiftUI

@main
struct VoiceFlowApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Routing: dopóki onboarding nie jest ukończony, pokazujemy prowadzony
/// tutorial (`OnboardingView`, wzorzec Wispr Flow — wyjaśnienie → Ustawienia
/// → przełączenie klawiatury → test dyktowania na żywo → gotowe). Ukończenie
/// przychodzi z DWÓCH źródeł, oba wołają `onComplete`:
///   1. automatyczna detekcja przez App Group — klawiatura faktycznie
///      wystartowała choć raz (patrz `AppGroup.swift`), może wyprzedzić
///      tutorial na dowolnym kroku;
///   2. user ręcznie doszedł do końca prowadzonego tutorialu.
/// To jest realny sufit automatyzacji opisany w
/// docs/plans/ios-voiceflow-app.md §3 — nie ma trzeciej, "twardszej" opcji.
///
/// TRZECIE źródło routingu, PIVOT #2 (§7): `voiceflow://dictate` z
/// klawiatury (`extensionContext?.open`, patrz `KeyboardViewController`) —
/// ma pierwszeństwo przed onboardingiem/tabami, bo user otworzył apkę PO TO
/// żeby dyktować OD RAZU, nie żeby przechodzić tutorial jeszcze raz.
/// `dictationSessionID` zmienia się przy KAŻDYM takim otwarciu (nawet gdy
/// apka już działa w tle) — `.id(_:)` wymusza świeży `KeyboardHandoffView`
/// (nowa sesja nagrywania), zamiast pokazywania poprzedniego ekranu "Gotowe".
struct RootView: View {
    @State private var onboardingDone = AppGroup.defaults.bool(forKey: AppGroupKeys.keyboardHasLaunched)
    @State private var launchedForDictation = false
    @State private var dictationSessionID = UUID()

    var body: some View {
        ZStack {
            VFColor.background.ignoresSafeArea()
            if launchedForDictation {
                KeyboardHandoffView()
                    .id(dictationSessionID)
            } else if onboardingDone {
                MainTabView()
            } else {
                OnboardingView { withAnimation(.easeOut(duration: 0.3)) { onboardingDone = true } }
            }
        }
        .onOpenURL { url in
            guard url.scheme == "voiceflow", url.host == "dictate" else { return }
            onboardingDone = true
            dictationSessionID = UUID()
            launchedForDictation = true
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { DictationView() }
                .tabItem { Label("Dyktuj", systemImage: "mic") }
            NavigationStack { HistoryView() }
                .tabItem { Label("Historia", systemImage: "clock") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Ustawienia", systemImage: "gearshape") }
        }
        .tint(VFColor.text)
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(VFColor.surfaceSolid)
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}
