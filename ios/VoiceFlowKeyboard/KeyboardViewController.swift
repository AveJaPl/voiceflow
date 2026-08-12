import UIKit

/// Rozszerzenie klawiatury VoiceFlow. PIVOT #2 2026-08-10 (docs/plans/
/// ios-voiceflow-app.md §7): mikrofon w rozszerzeniu klawiatury jest
/// ZABLOKOWANY przez sandbox iOS, potwierdzone na żywo (`AVAudioEngine
/// .start()` rzuca `com.apple.coreaudio.avfaudio 2003329396` mimo Full
/// Access) — to twardy mur platformy, ten sam, który zmusza Wispr Flow do
/// ekranu "swipe back to your app". Dlatego ta klawiatura WRACA do wersji
/// "tylko przycisk na środku, bez fizycznej klawiatury" (kod bazowy: commit
/// 991f3b4, sprzed odrzuconego pivotu QWERTY) i NIE zawiera już żadnego
/// wywołania ASR — mikrofon działa w apce kontenerowej (`ContainerDictation
/// Engine`, apka NIE jest sandboxowana jak rozszerzenie).
///
/// Nowy przepływ (jedyny działający na iOS, patrz plan §7):
///   1. Tap mikrofonu → `extensionContext?.open(voiceflow://dictate)`.
///   2. Apka kontenerowa nagrywa, zapisuje finalny tekst do App Group
///      (`AppGroupKeys.pendingInsertText` / `.pendingInsertAt`).
///   3. User przesuwa z powrotem gestem systemowym.
///   4. TU, w `viewWillAppear`: jeśli tekst jest świeży (`PendingInsert
///      .shouldInsert`), wstawiamy go automatycznie i czyścimy flagi —
///      użytkownik nic nie klika.
///
/// `@objc(KeyboardViewController)` jest KRYTYCZNE, nie ozdobą: `Info.plist`
/// (`NSExtensionPrincipalClass`) wskazuje gołą nazwę `KeyboardViewController`,
/// ale Swift bez tej adnotacji eksponuje klasę do Objective-C (którego iOS
/// używa do znalezienia rozszerzenia) pod nazwą Z PREFIKSEM MODUŁU
/// (`VoiceFlowKeyboard.KeyboardViewController`). System nie znajdzie klasy,
/// przełączenie na klawiaturę nic nie zrobi — BEZ ŻADNEGO błędu czy logu,
/// bo rozszerzenie nigdy się nie uruchamia. Zaobserwowane na żywo 2026-08-10:
/// „przytrzymuję 🌐, wybieram VoiceFlow, nic się nie dzieje".
@objc(KeyboardViewController)
final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let micIcon = UIImageView(image: UIImage(systemName: "mic.fill"))
    private let nextKeyboardButton = UIButton(type: .system)
    private let nextKeyboardLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Jedyny sygnał, jaki kontener może kiedykolwiek zaobserwować, że
        // klawiatura została dodana i faktycznie otwarta — patrz
        // AppGroup.swift i RootView w kontenerze.
        AppGroup.defaults.set(true, forKey: AppGroupKeys.keyboardHasLaunched)

        buildUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        AppGroup.defaults.set(hasFullAccess, forKey: AppGroupKeys.keyboardHasFullAccessObserved)

        if insertPendingTextIfFresh() {
            renderInserted()
        } else if !hasFullAccess {
            renderNoFullAccess()
        } else {
            renderIdle()
        }
    }

    override func textWillChange(_ textInput: UITextInput?) {}
    override func textDidChange(_ textInput: UITextInput?) {}

    // MARK: - Wstawianie tekstu czekającego z apki kontenerowej

    /// `@discardableResult`, żeby `viewWillAppear` mógł od razu przełączyć
    /// UI na stan "Wstawiono" bez osobnego odczytu App Group.
    @discardableResult
    private func insertPendingTextIfFresh() -> Bool {
        let defaults = AppGroup.defaults
        let text = defaults.string(forKey: AppGroupKeys.pendingInsertText)
        let insertedAt = defaults.object(forKey: AppGroupKeys.pendingInsertAt) as? Date

        guard PendingInsert.shouldInsert(text: text, insertedAt: insertedAt, now: Date()) else {
            return false
        }

        textDocumentProxy.insertText(text!)
        // Czyścimy OD RAZU — inaczej kolejny `viewWillAppear` (np. user
        // chowa i pokazuje klawiaturę ponownie) wstawiłby ten sam tekst
        // drugi raz.
        defaults.removeObject(forKey: AppGroupKeys.pendingInsertText)
        defaults.removeObject(forKey: AppGroupKeys.pendingInsertAt)
        return true
    }

    // MARK: - UI

    private func buildUI() {
        let bg = UIColor(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1)
        let text = UIColor(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1)
        let muted = UIColor(red: 0x9A / 255, green: 0x9A / 255, blue: 0xA2 / 255, alpha: 1)
        let surfaceSolid = UIColor(red: 0x16 / 255, green: 0x16 / 255, blue: 0x18 / 255, alpha: 1)
        let border = UIColor(red: 0x28 / 255, green: 0x28 / 255, blue: 0x2C / 255, alpha: 1)

        view.backgroundColor = bg
        view.heightAnchor.constraint(equalToConstant: 216).isActive = true

        statusLabel.text = "Dotknij, aby dyktować"
        statusLabel.font = UIFont(name: "Archivo-SemiBold", size: 17) ?? .systemFont(ofSize: 17, weight: .semibold)
        statusLabel.textColor = text
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.7
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        hintLabel.text = "VoiceFlow • dyktowanie na urządzeniu"
        hintLabel.font = UIFont(name: "Inter-Regular", size: 12) ?? .systemFont(ofSize: 12)
        hintLabel.textColor = muted
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        micButton.backgroundColor = surfaceSolid
        micButton.layer.cornerRadius = 34
        micButton.layer.borderWidth = 1.5
        micButton.layer.borderColor = border.cgColor
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        view.addSubview(micButton)

        micIcon.tintColor = text
        micIcon.contentMode = .scaleAspectFit
        micIcon.translatesAutoresizingMaskIntoConstraints = false
        micIcon.isUserInteractionEnabled = false
        micButton.addSubview(micIcon)

        // Podpisany przycisk zmiany klawiatury zamiast gołej, 30×30 ikonki —
        // ta sama akcja systemowa (`handleInputModeList`), ale widoczna.
        nextKeyboardButton.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboardButton.tintColor = text
        nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        view.addSubview(nextKeyboardButton)

        nextKeyboardLabel.text = "Zmień klawiaturę"
        nextKeyboardLabel.font = UIFont(name: "Inter-Regular", size: 11) ?? .systemFont(ofSize: 11)
        nextKeyboardLabel.textColor = muted
        nextKeyboardLabel.translatesAutoresizingMaskIntoConstraints = false
        nextKeyboardLabel.isUserInteractionEnabled = false
        view.addSubview(nextKeyboardLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            hintLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            micButton.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 16),
            micButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            micButton.widthAnchor.constraint(equalToConstant: 68),
            micButton.heightAnchor.constraint(equalToConstant: 68),

            micIcon.centerXAnchor.constraint(equalTo: micButton.centerXAnchor),
            micIcon.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            micIcon.widthAnchor.constraint(equalToConstant: 26),
            micIcon.heightAnchor.constraint(equalToConstant: 26),

            nextKeyboardButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            nextKeyboardButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            nextKeyboardButton.widthAnchor.constraint(equalToConstant: 34),
            nextKeyboardButton.heightAnchor.constraint(equalToConstant: 34),

            nextKeyboardLabel.centerYAnchor.constraint(equalTo: nextKeyboardButton.centerYAnchor),
            nextKeyboardLabel.leadingAnchor.constraint(equalTo: nextKeyboardButton.trailingAnchor, constant: 8),
        ])
    }

    @objc private func micTapped() {
        guard hasFullAccess else {
            renderNoFullAccess()
            return
        }
        guard let url = URL(string: "voiceflow://dictate") else { return }
        // UWAGA, mur platformy #2 (2026-08-12, zaobserwowane na fizycznym
        // iPhone 16 Pro): `extensionContext?.open(...)` z ROZSZERZENIA
        // KLAWIATURY po cichu NIE robi nic — Apple honoruje to API z widgetów
        // i innych rozszerzeń, ale nie z klawiatur (completion dostaje false,
        // zero błędu, zero logu). Objaw u użytkownika: „stukam w mikrofon i
        // nic". Jedyna działająca droga to klasyczne przejście po łańcuchu
        // responderów do UIApplication i wywołanie `openURL:` selektorem —
        // ten sam mechanizm, na którym stoją wszystkie klawiatury dyktujące.
        extensionContext?.open(url) { [weak self] success in
            guard !success else { return }
            DispatchQueue.main.async { self?.openViaResponderChain(url) }
        }
    }

    private func openViaResponderChain(_ url: URL) {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), !(current is UIViewController) {
                current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
        statusLabel.text = "Nie mogę otworzyć aplikacji"
    }

    private func renderIdle() {
        let text = UIColor(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1)
        let surfaceSolid = UIColor(red: 0x16 / 255, green: 0x16 / 255, blue: 0x18 / 255, alpha: 1)
        statusLabel.text = "Dotknij, aby dyktować"
        hintLabel.text = "VoiceFlow • dyktowanie na urządzeniu"
        micButton.backgroundColor = surfaceSolid
        micIcon.tintColor = text
        micIcon.image = UIImage(systemName: "mic.fill")
    }

    private func renderNoFullAccess() {
        let text = UIColor(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1)
        let surfaceSolid = UIColor(red: 0x16 / 255, green: 0x16 / 255, blue: 0x18 / 255, alpha: 1)
        statusLabel.text = "Włącz Pełny dostęp"
        hintLabel.text = "Ustawienia → Klawiatura → VoiceFlow → Pełny dostęp"
        micButton.backgroundColor = surfaceSolid
        micIcon.tintColor = text
        micIcon.image = UIImage(systemName: "lock.fill")
    }

    /// Krótki, jednorazowy stan po automatycznym wstawieniu tekstu — czysto
    /// informacyjny, znika przy następnym pokazaniu klawiatury (`renderIdle`
    /// bierze górę, bo flagi App Group są już wyczyszczone).
    private func renderInserted() {
        let bg = UIColor(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1)
        let text = UIColor(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1)
        statusLabel.text = "Wstawiono"
        hintLabel.text = "VoiceFlow • dyktowanie na urządzeniu"
        micButton.backgroundColor = text
        micIcon.tintColor = bg
        micIcon.image = UIImage(systemName: "checkmark")
    }
}
