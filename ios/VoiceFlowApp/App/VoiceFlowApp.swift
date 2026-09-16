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
/// docs/plans/ios-voiceflow-app.md §3 — nie ma trzeciej, „twardszej” opcji.
///
/// TRZECIE źródło routingu, PIVOT #2 (§7): `voiceflow://dictate` z klawiatury
/// (`extensionContext?.open`, patrz `KeyboardViewController`). Po redesignie
/// (2026-08-12) dyktowanie NIE jest już zakładką — jest ekranem modalnym nad
/// całą apką, bo klawiatura to jedyna droga, którą się w nie wchodzi: user
/// otworzył apkę PO TO, żeby dyktować OD RAZU, a po skończeniu wraca do
/// poprzedniej aplikacji albo zamyka ekran i ląduje na Pulpicie.
/// `dictationSessionID` zmienia się przy KAŻDYM takim otwarciu (nawet gdy apka
/// już działa w tle) — `.id(_:)` wymusza świeży `KeyboardHandoffView` (nowa
/// sesja nagrywania), zamiast pokazywania poprzedniego ekranu „Gotowe”.
struct RootView: View {
    @State private var onboardingDone = AppGroup.defaults.bool(forKey: AppGroupKeys.keyboardHasLaunched)
        || LaunchOverrides.skipOnboarding
    /// Model whisper zaczyna się pobierać/ładować od razu po starcie apki —
    /// żeby był gotowy, zanim ktoś pierwszy raz stuknie mikrofon.
    @ObservedObject private var models = WhisperModelStore.shared
    @State private var launchedForDictation = false
    @State private var dictationSessionID = UUID()

    var body: some View {
        ZStack {
            VFColor.background.ignoresSafeArea()
            if onboardingDone {
                MainTabView {
                    dictationSessionID = UUID()
                    launchedForDictation = true
                }
            } else {
                OnboardingView { withAnimation(.easeOut(duration: 0.3)) { onboardingDone = true } }
            }
        }
        .fullScreenCover(isPresented: $launchedForDictation) {
            KeyboardHandoffView { launchedForDictation = false }
                .id(dictationSessionID)
        }
        .onAppear { if !LaunchOverrides.skipModelPreparation { models.prepare() } }
        .onOpenURL { url in
            guard url.scheme == "voiceflow", url.host == "dictate" else { return }
            onboardingDone = true
            dictationSessionID = UUID()
            launchedForDictation = true
        }
    }
}

/// Zakładki (decyzja Wojtka 2026-09-14): Klawiatura, Historia, Pokoje,
/// Ustawienia. Zakładka „Mac” (zdalne sterowanie komputerem z telefonu)
/// zniknęła razem z całym kodem pod nią — telefon jest klawiaturą głosową,
/// nie pilotem. Dyktuje się z klawiatury (patrz `RootView`) albo przyciskiem
/// „Dyktuj teraz” na pierwszej zakładce.
struct MainTabView: View {
    /// Konto trzymane tutaj, a nie per ekran — Historia i Pulpit biorą stąd
    /// poświadczenia do HTTP API.
    @StateObject private var account = AccountSession()
    @ObservedObject private var models = WhisperModelStore.shared
    var onDictate: () -> Void

    var body: some View {
        TabView {
            NavigationStack { KeyboardTabView(models: models, onDictate: onDictate) }
                .tabItem { Label("Klawiatura", systemImage: "keyboard") }
            NavigationStack { HistoryView(remote: account) }
                .tabItem { Label("Historia", systemImage: "clock") }
            NavigationStack { RoomsView() }
                .tabItem { Label("Pokoje", systemImage: "person.2") }
            NavigationStack { SettingsView(remote: account, models: models) }
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
