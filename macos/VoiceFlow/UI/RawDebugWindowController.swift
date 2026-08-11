import AppKit

/// UI tymczasowe, brzydkie, wyłącznie do tego, żeby dało się odpalić i przetestować
/// rdzeń bez czekania na drugiego agenta. Ładny pill (Wispr-style) robi ktoś inny —
/// ten plik NIE jest `UI/PillView.swift` / `UI/PillWindow.swift` / `UI/NotesWindow.swift`.
final class RawDebugWindowController: NSWindowController {
    private let stateLabel = NSTextField(labelWithString: "idle")
    private let textView = NSTextView()
    private let latencyLabel = NSTextField(labelWithString: "—")
    private let notesList = NSTextView()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceFlow — debug"
        window.center()
        self.init(window: window)
        buildLayout()
    }

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        stateLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        latencyLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        latencyLabel.textColor = .secondaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.isEditable = false
        textView.font = .systemFont(ofSize: 18)
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let notesScroll = NSScrollView()
        notesScroll.hasVerticalScroller = true
        notesScroll.documentView = notesList
        notesList.isEditable = false
        notesList.font = .systemFont(ofSize: 11)

        let header = NSStackView(views: [stateLabel, latencyLabel])
        header.orientation = .horizontal
        header.distribution = .fillEqually

        let stack = NSStackView(views: [header, scroll, NSTextField(labelWithString: "Notatki:"), notesScroll])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 220),
            notesScroll.heightAnchor.constraint(equalToConstant: 100),
        ])
    }

    func update(state: String) {
        stateLabel.stringValue = "stan: \(state)"
    }

    func update(text: String) {
        textView.string = text
    }

    func update(latencyMs: Double) {
        latencyLabel.stringValue = String(format: "pierwszy tekst: %.0f ms", latencyMs)
    }

    func update(notes: [Note]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        notesList.string = notes.prefix(20).map { n in
            "[\(formatter.string(from: n.createdAt))] (\(n.targetBundleID ?? "?")) \(n.finalText)"
        }.joined(separator: "\n")
    }
}
