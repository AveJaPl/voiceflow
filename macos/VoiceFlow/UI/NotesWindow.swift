import SwiftUI
import AppKit

/// Źródło notatek dla okna. Realny `NotesStore` (Model/) będzie konformował
/// do tego protokołu — kontrakt to lista + usuwanie, reszta (szukajka,
/// zaznaczenie) żyje w widoku.
protocol NotesProviding: ObservableObject {
    var notes: [PreviewNote] { get }
    func delete(_ note: PreviewNote)
}

/// Atrapa do podglądu — trzyma notatki w pamięci.
final class MockNotesStore: NotesProviding {
    @Published private(set) var notes: [PreviewNote]

    init(notes: [PreviewNote] = []) {
        self.notes = notes
    }

    func delete(_ note: PreviewNote) {
        notes.removeAll { $0.id == note.id }
    }
}

/// Lista chronologiczna + szukajka + podgląd. Klawiatura: strzałki (lista
/// SwiftUI dostaje to za darmo), ⌘F (fokus na pole szukajki), ⌘C (kopiuj
/// zaznaczoną), delete (usuń zaznaczoną).
struct NotesWindow<Store: NotesProviding>: View {
    @ObservedObject var store: Store
    @State private var query: String = ""
    @State private var selection: PreviewNote.ID?
    @FocusState private var searchFocused: Bool
    @State private var copiedFeedback = false
    // Wymuszone na `.all` — poza normalnym cyklem życia Scene (to okno
    // otwiera drugi agent ręcznie z menu bar) `.automatic` potrafi uznać, że
    // nie zna rozmiaru okna i schować sidebar całkowicie.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var filtered: [PreviewNote] {
        let sorted = store.notes.sorted { $0.date > $1.date }
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.finalText.localizedCaseInsensitiveContains(query)
                || $0.targetApp.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedNote: PreviewNote? {
        filtered.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Notatki")
        .frame(minWidth: 640, minHeight: 420)
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        )
    }

    private var sidebar: some View {
        sidebarContent
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Szukaj w notatkach", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .padding(10)

            if filtered.isEmpty {
                emptyState
            } else {
                List(filtered, selection: $selection) { note in
                    NoteRow(note: note)
                        .tag(note.id)
                        .contextMenu {
                            Button("Kopiuj") { copy(note) }
                            Button("Usuń", role: .destructive) { delete(note) }
                        }
                }
                .listStyle(.sidebar)
                .onDeleteCommand {
                    if let note = selectedNote { delete(note) }
                }
            }
        }
        .frame(minWidth: 260)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "Brak notatek" : "Nic nie pasuje do \"\(query)\"")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if query.isEmpty {
                Text("Podyktowana notatka pojawi się tutaj.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    @ViewBuilder
    private var detail: some View {
        if let note = selectedNote {
            NoteDetail(note: note, copiedFeedback: $copiedFeedback, onCopy: { copy(note) }, onDelete: { delete(note) })
                .background(
                    Button("") { copy(note) }
                        .keyboardShortcut("c", modifiers: .command)
                        .hidden()
                )
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Wybierz notatkę")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func copy(_ note: PreviewNote) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.finalText, forType: .string)
        copiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedFeedback = false }
    }

    private func delete(_ note: PreviewNote) {
        if selection == note.id { selection = nil }
        store.delete(note)
    }
}

private struct NoteRow: View {
    let note: PreviewNote

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.finalText)
                .font(.system(size: 13))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(note.targetApp)
                Text("·")
                Text(note.date, style: .time)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct NoteDetail: View {
    let note: PreviewNote
    @Binding var copiedFeedback: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.targetApp)
                        .font(.system(size: 13, weight: .semibold))
                    Text(note.date, style: .date) + Text(" · ") + Text(formattedDuration)
                }
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

                Spacer()

                Button {
                    onCopy()
                } label: {
                    Label(copiedFeedback ? "Skopiowano" : "Kopiuj", systemImage: copiedFeedback ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Usuń", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }

            Divider()

            ScrollView {
                Text(note.finalText)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(20)
    }

    private var formattedDuration: String {
        let seconds = Int(note.duration.rounded())
        return "\(seconds) s"
    }
}
