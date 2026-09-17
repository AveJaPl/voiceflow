import SwiftUI
import Combine
import UIKit

@MainActor
final class KeyboardPanelModel: ObservableObject {
    @Published var phase: KeyboardSessionSnapshot.Phase = .idle
    @Published var level: Float = 0
    @Published var message = "Włącz VoiceFlow, aby przygotować mikrofon."
    @Published var result = ""
    @Published var consumed = false
    @Published var fullAccess = false
    @Published var automatic = KeyboardSessionStore.automaticallyInsert
    @Published var ready = false
    @Published var needsGlobe = false
    @Published var openURL: URL?
    @Published var isEditing = false
    weak var editor: UITextView?
}

struct VoiceKeyboardPanel: View {
    @ObservedObject var model: KeyboardPanelModel
    let start: () -> Void
    let stop: () -> Void
    let insert: () -> Void
    let end: () -> Void
    let next: () -> Void
    var clear: () -> Void = {}
    var changed: (String) -> Void = { _ in }
    var save: () -> Void = {}
    @Environment(\.openURL) private var openURL

    private var busy: Bool { model.phase == .processing || model.phase == .preparing }

    var body: some View {
        VStack(spacing: 10) {
            if !model.result.isEmpty || model.isEditing {
                VStack(spacing: 0) {
                    HStack {
                        Button(model.isEditing ? "Gotowe" : "Edytuj") {
                            model.isEditing.toggle()
                            if !model.isEditing { save() }
                        }.font(.system(size: 13, weight: .medium))
                        Spacer()
                        if model.isEditing {
                            PasteButton(payloadType: String.self) { values in
                                model.editor?.insertText(values.joined(separator: "\n"))
                            }.labelStyle(.iconOnly).buttonBorderShape(.capsule).controlSize(.small).tint(.gray)
                        }
                        Button {
                            model.editor?.resignFirstResponder()
                            model.isEditing = false
                            clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 20))
                                .foregroundStyle(.secondary).frame(width: 36, height: 36)
                        }.accessibilityLabel("Wyczyść tekst")
                    }.padding(.leading, 12).padding(.trailing, 4)
                    if model.isEditing {
                        KeyboardDraftEditor(model: model, changed: changed)
                    } else {
                        ScrollView {
                            Text(model.result).font(.system(size: 16)).lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.bottom, 12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 100, maxHeight: model.isEditing ? 140 : .infinity)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 12) {
                    if model.phase == .recording {
                        VoiceWaveform(level: model.level, tint: .primary).frame(width: 124, height: 22)
                    }
                    if model.phase != .recording && !busy && model.fullAccess {
                        Button("Wpisz lub wklej tekst") { model.isEditing = true }.font(.system(size: 13))
                    }
                    Text(model.fullAccess ? model.message : "Włącz Pełny dostęp w Ustawieniach klawiatury VoiceFlow.")
                        .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.isEditing {
                DraftLetterKeyboard(model: model)
            } else {
                HStack(spacing: 10) {
                    Button {
                        if model.phase == .recording { stop() }
                        else {
                            start()
                            if let url = model.openURL {
                                model.openURL = nil
                                openURL(url) { accepted in
                                    if !accepted { model.message = "Otwórz VoiceFlow, włącz sesję i wróć do klawiatury."; model.phase = .idle }
                                }
                            }
                        }
                    } label: {
                        Label(model.phase == .recording ? "Zakończ" : model.ready ? "Nowe dyktowanie" : "Włącz VoiceFlow",
                              systemImage: model.phase == .recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    }.disabled(!model.fullAccess || busy)
                    if !model.result.isEmpty {
                        Button(action: insert) {
                            Text("Wklej tekst").font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(Color(uiColor: .systemBackground))
                        }.disabled(!model.fullAccess)
                    }
                }
                HStack {
                    if model.needsGlobe {
                        Button(action: next) { Image(systemName: "globe").frame(width: 36, height: 32) }
                            .accessibilityLabel("Zmień klawiaturę")
                    }
                    Text(model.automatic ? "Wklejanie automatyczne" : "Wklejanie ręczne")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if model.ready { Button("Wyłącz", action: end).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.primary)
        // The system-owned UIInputView supplies the keyboard background.
        .background(Color.clear)
    }
}

private struct KeyboardDraftEditor: UIViewRepresentable {
    @ObservedObject var model: KeyboardPanelModel
    let changed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(model: model, changed: changed) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textColor = .label
        view.tintColor = .label
        view.font = .systemFont(ofSize: 16)
        view.textContainerInset = UIEdgeInsets(top: 0, left: 8, bottom: 10, right: 8)
        view.inputView = UIView(frame: .zero)
        view.autocorrectionType = .no
        view.delegate = context.coordinator
        view.text = model.result
        model.editor = view
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != model.result { view.text = model.result }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        let model: KeyboardPanelModel
        let changed: (String) -> Void
        init(model: KeyboardPanelModel, changed: @escaping (String) -> Void) { self.model = model; self.changed = changed }
        func textViewDidChange(_ textView: UITextView) { model.result = textView.text; changed(textView.text) }
    }
}

private struct DraftLetterKeyboard: View {
    @ObservedObject var model: KeyboardPanelModel
    @State private var shift = false
    @State private var numbers = false
    private let accents: [String: String] = ["a":"ą", "c":"ć", "e":"ę", "l":"ł", "n":"ń", "o":"ó", "s":"ś", "z":"żź"]
    private var rows: [String] { numbers ? ["1234567890", "-/:;()€&@", ".,?!'\""] : ["qwertyuiop", "asdfghjkl", "zxcvbnm"] }
    private func type(_ value: String) {
        model.editor?.insertText(shift ? value.uppercased() : value)
        if shift { shift = false }
    }
    var body: some View {
        VStack(spacing: 9) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 5) {
                    if index == 2 { key(shift ? "⇧" : "⇧", width: 38) { shift.toggle() } }
                    ForEach(Array(row).map(String.init), id: \.self) { letter in
                        key(shift ? letter.uppercased() : letter) { type(letter) }
                            .contextMenu {
                                ForEach(Array(accents[letter] ?? "").map(String.init), id: \.self) { accent in
                                    Button(shift ? accent.uppercased() : accent) { type(accent) }
                                }
                            }
                    }
                    if index == 2 { key("⌫", width: 38) { model.editor?.deleteBackward() } }
                }.padding(.horizontal, index == 1 ? 14 : 0)
            }
            HStack(spacing: 5) {
                key(numbers ? "ABC" : "123", width: 48) { numbers.toggle() }
                key("spacja") { type(" ") }
                key("↵", width: 48) { type("\n") }
            }
        }.frame(height: 207)
    }
    private func key(_ title: String, width: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: title == "spacja" ? 15 : 21))
                .frame(maxWidth: width == nil ? .infinity : width, minHeight: 43)
                .frame(width: width)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
        }.buttonStyle(.plain)
    }
}
