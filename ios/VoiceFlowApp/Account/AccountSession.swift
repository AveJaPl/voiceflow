import Combine
import Foundation

/// Konto na telefonie: token z Keychaina i nic więcej. Do 2026-09-14 tę rolę
/// pełnił `RemoteSession`, który poza kontem trzymał WebSocket do Maca,
/// strumień mikrofonu i podgląd okien — wszystko wycięte razem z zakładką
/// „Mac”. Zostało to, czego potrzebują Historia i Pulpit: „czy jest konto”
/// i poświadczenia do REST-owego `AccountAPI`.
@MainActor
final class AccountSession: ObservableObject {
    @Published private(set) var credentials: RemoteCredentials?

    private let store: RemoteCredentialStoring

    init(store: RemoteCredentialStoring = KeychainCredentialStore()) {
        self.store = store
        self.credentials = store.load()
    }

    var isPaired: Bool { credentials != nil }
    var accountCredentials: RemoteCredentials? { credentials }

    func updateCredentials(_ new: RemoteCredentials?) {
        if let new { store.save(new) } else { store.clear() }
        credentials = new
    }
}
