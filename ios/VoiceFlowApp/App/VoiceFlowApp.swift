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
    @State private var launchedForDictation = false
    @State private var dictationSessionID = UUID()

    var body: some View {
        ZStack {
            VFColor.background.ignoresSafeArea()
            if onboardingDone {
                MainTabView()
            } else {
                OnboardingView { withAnimation(.easeOut(duration: 0.3)) { onboardingDone = true } }
            }
        }
        .fullScreenCover(isPresented: $launchedForDictation) {
            KeyboardHandoffView { launchedForDictation = false }
                .id(dictationSessionID)
        }
        .onOpenURL { url in
            guard url.scheme == "voiceflow", url.host == "dictate" else { return }
            onboardingDone = true
            dictationSessionID = UUID()
            launchedForDictation = true
        }
    }
}

/// Cztery zakładki (redesign 2026-08-12, decyzja Wojtka): Pulpit z podsumowaniem
/// konta, Mac, Historia z serwera i Ustawienia. Ekran „Dyktuj” zniknął — na
/// telefonie dyktuje się z klawiatury (patrz `RootView`), a nie z osobnej karty
/// w apce.
struct MainTabView: View {
    /// Jedna sesja na całą apkę, trzymana tutaj, a nie w `RemoteView` — inaczej
    /// każde wejście w zakładkę zaczynałoby połączenie od zera. Pulpit i
    /// Historia biorą stąd też poświadczenia konta do HTTP API.
    @StateObject private var remote = RemoteSession()

    var body: some View {
        TabView {
            NavigationStack { DashboardView(remote: remote) }
                .tabItem { Label("Pulpit", systemImage: "square.grid.2x2") }
            // Zakładka pojawia się DOPIERO po sparowaniu. Pokazywanie jej
            // wcześniej znaczyłoby pokazywanie ekranu, który umie tylko
            // powiedzieć „najpierw sparuj" — a od tego są Ustawienia.
            if remote.isPaired {
                NavigationStack { RemoteView(session: remote) }
                    .tabItem { Label("Mac", systemImage: "macbook.and.iphone") }
            }
            NavigationStack { HistoryView(remote: remote) }
                .tabItem { Label("Historia", systemImage: "clock") }
            NavigationStack { SettingsView(remote: remote) }
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
