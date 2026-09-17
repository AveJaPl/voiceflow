import SwiftUI

struct SettingsView: View {
    @ObservedObject var models: WhisperModelStore
    @ObservedObject var account: AccountSession
    private var words: Binding<String> { Binding(
        get: { account.vocabulary.joined(separator: "\n") },
        set: { account.updateVocabulary(Array($0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).prefix(100))) }) }
    @State private var language = UserDefaults.standard.string(forKey: "voiceflow.dictationLanguage") ?? "auto"
    @State private var automatic = KeyboardSessionStore.automaticallyInsert

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                AccountSection(remote: account)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("MODEL ROZPOZNAWANIA").vfEyebrow()
                        ModelStatusView(models: models)
                        if models.availableModels.count > 1 {
                            VStack(spacing: 0) {
                                ForEach(models.availableModels) { model in
                                    Button {
                                        models.select(model)
                                    } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: model == models.selected ? "largecircle.fill.circle" : "circle")
                                                .foregroundStyle(model == models.selected ? VFColor.text : VFColor.faint)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text("\(model.title) · \(model.approximateMB) MB")
                                                    .font(VFFont.body(13, weight: .semibold))
                                                    .foregroundStyle(VFColor.text)
                                                Text(model.detail)
                                                    .font(VFFont.body(12))
                                                    .foregroundStyle(VFColor.faint)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            Spacer()
                                        }
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 12)
                                    }
                                    .buttonStyle(.plain)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(VFColor.border).frame(height: 1).padding(.horizontal, 18)
                                    }
                                }
                            }
                            .background(VFColor.surface)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(VFColor.border, lineWidth: 1))
                        }
                        Text("Wybrany automatycznie pod ten telefon. Zmiana pobiera inny model; poprzedni zostaje na dysku.")
                            .font(VFFont.body(12))
                            .foregroundStyle(VFColor.faint)
                    }


                VStack(alignment: .leading, spacing: 10) {
                    Text("JĘZYK").vfEyebrow()
                    Picker("Język dyktowania", selection: $language) {
                        Text("Polski + English").tag("auto")
                        Text("Polski").tag("pl")
                        Text("English").tag("en")
                    }.pickerStyle(.menu)
                    Text("Automatyczny wybór języka. Nazwy własne dodaj do słownika poniżej.")
                        .font(VFFont.body(12)).foregroundStyle(VFColor.muted)
                }
                Toggle("Automatycznie wklejaj tekst", isOn: $automatic)
                Text("Po rozpoznaniu tekst zastąpi zaznaczenie lub pojawi się przy kursorze w polu, z którego zaczynasz dyktowanie.").font(VFFont.body(12)).foregroundStyle(VFColor.muted)
                VStack(alignment: .leading, spacing: 10) {
                    Text("WŁASNY SŁOWNIK").vfEyebrow()
                    Text("Jedno słowo lub nazwa w wierszu, np. Programo. Zmiany działają od następnego dyktowania.")
                        .font(VFFont.body(12)).foregroundStyle(VFColor.muted)
                    TextEditor(text: words).font(VFFont.body(15)).frame(height: 150)
                        .scrollContentBackground(.hidden).padding(12).background(VFColor.surfaceSolid)
                        .accessibilityLabel("Własne słowa")
                }
                Link("Prywatność", destination: URL(string: "https://voiceflow.pbdevs.com/pl/prywatnosc")!)
                Text("Audio jest przetwarzane na telefonie. Po zalogowaniu tekst nowych dyktowań i słownik synchronizują się z kontem. Dyktowanie działa też bez konta i internetu.")
                    .font(VFFont.body(12)).foregroundStyle(VFColor.muted)
            }.padding(24)
        }.background(VFColor.background).navigationTitle("Ustawienia")
        .onAppear { automatic = KeyboardSessionStore.automaticallyInsert }
        .onChange(of: language) { _, value in
            if value == "auto" { UserDefaults.standard.removeObject(forKey: "voiceflow.dictationLanguage") }
            else { UserDefaults.standard.set(value, forKey: "voiceflow.dictationLanguage") }
        }
        .onChange(of: automatic) { _, value in AppGroup.defaults.set(value, forKey: KeyboardSessionStore.automaticInsertionKey) }
    }
}
