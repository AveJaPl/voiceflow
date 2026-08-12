import AVFoundation
import Foundation
import Speech
import os.log

private let log = Logger(subsystem: "io.github.avejapl.voiceflow.ios", category: "DictationEngine")

/// Silnik dyktowania ekranu w SAMEJ apce — plan B z
/// docs/plans/ios-voiceflow-app.md §3 (jeśli mikrofon w rozszerzeniu
/// klawiatury nie zadziała po Full Access, to jest ścieżka zapasowa: user
/// dyktuje tutaj, kopiuje/wkleja gdzie trzeba). Działa niezależnie od wyniku
/// tego testu, bo kontener ma normalne uprawnienia apki (mikrofon +
/// rozpoznawanie mowy z Ustawień), bez limitów pamięci i bez wymogu Full
/// Access, które dotyczą TYLKO rozszerzeń klawiatury.
///
/// Ten sam silnik ASR co klawiatura: `SFSpeechRecognizer(pl-PL)`,
/// `requiresOnDeviceRecognition = true` (potwierdzone sondą 0c — polski
/// działa on-device, za darmo, patrz plan §1).
@MainActor
final class ContainerDictationEngine: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var liveText: String = ""

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pl-PL"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Ustawiane na starcie sesji przez `toggle(recordToHistory:)`, czytane
    /// w `stop()` niezależnie od tego, CO wywołało zatrzymanie (ręczny tap,
    /// `isFinal` z rozpoznawania, czy błąd) — zapis do historii zależy
    /// wyłącznie od tej flagi, nie od ścieżki zatrzymania.
    private var recordToHistory = true

    /// `recordToHistory`: NIE zapisuj do historii, gdy to tylko test w kroku
    /// (d) onboardingu (patrz `DictationCardView`) — tam liczy się wyłącznie
    /// dowód "działa na żywo", nie treść do zachowania.
    func toggle(recordToHistory: Bool = true) {
        switch state {
        case .listening:
            stop()
        default:
            self.recordToHistory = recordToHistory
            start()
        }
    }

    private func start() {
        guard let recognizer, recognizer.isAvailable else {
            state = .error("Rozpoznawanie mowy niedostępne dla pl-PL na tym urządzeniu.")
            return
        }

        state = .requestingPermission
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor in
                guard let self else { return }
                guard authStatus == .authorized else {
                    self.state = .error("Brak zgody na rozpoznawanie mowy — włącz ją w Ustawieniach.")
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.state = .error("Brak zgody na mikrofon — włącz ją w Ustawieniach.")
                            return
                        }
                        self.beginRecording()
                    }
                }
            }
        }
    }

    private func beginRecording() {
        liveText = ""
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .error("Nie udało się skonfigurować sesji audio: \(error.localizedDescription)")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 13, *) {
            req.requiresOnDeviceRecognition = true
        }
        request = req

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            state = .error("AVAudioEngine.start() nie powiódł się: \(error.localizedDescription)")
            log.error("AVAudioEngine.start() failed: \(error.localizedDescription)")
            return
        }

        state = .listening
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.liveText = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.stop()
                    }
                }
                if let error {
                    log.error("recognitionTask error: \(error.localizedDescription)")
                    self.stop()
                }
            }
        }
    }

    private func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if recordToHistory, !liveText.isEmpty {
            DictationHistoryStore.append(DictationEntry(text: liveText, source: .containerApp))
            // Kopia do historii KONTA — z niej czyta Pulpit i zakładka
            // Historia (i Mac, przez to samo konto). Best-effort: brak sieci
            // albo brak zalogowania nie może zepsuć dyktowania, wpis lokalny
            // już jest.
            uploadToAccountHistory(text: liveText)
        }
        state = .idle
    }

    private func uploadToAccountHistory(text: String) {
        guard let credentials = KeychainCredentialStore().load() else { return }
        Task {
            try? await AccountAPI.postHistory(
                credentials: credentials, text: text,
                createdAt: Date(), durationSeconds: 0, source: "phone"
            )
        }
    }
}
