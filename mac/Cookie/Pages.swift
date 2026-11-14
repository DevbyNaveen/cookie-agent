import AppKit
import EnkeonVoiceKit
import SwiftUI

// MARK: - Dictionary

struct DictionaryView: View {
    @EnvironmentObject private var model: AppModel
    enum Tab: Hashable { case all, yours, enkeon, learned }
    enum Source: String { case yours = "Yours", enkeon = "From Enkeon", learned = "Learned" }
    struct Word: Identifiable { let text: String; let source: Source; var id: String { source.rawValue + text } }

    @State private var tab: Tab = .all
    @State private var query = ""
    @State private var adding = false
    @State private var newWord = ""

    var body: some View {
        PageColumn {
            PageTitle(title: "Dictionary") {
                Button("Add new") { withAnimation(Theme.settle) { adding = true } }.buttonStyle(PrimaryButton())
            }
            TabStrip(tabs: [(.all, "All"), (.yours, "Yours"), (.enkeon, "From Enkeon"), (.learned, "Learned")], selection: $tab) {
                SearchToggle(query: $query)
            }
            HeroBanner(headline: Text("Enkeon spells the way ") + Text("you").italic() + Text(" do."),
                       message: "Add a name, a product or your team's jargon once, or fix a word after dictating, and every dictation spells it right. Signed in, your Enkeon projects are added on their own.",
                       dismissKey: "enkeon.hero.dictionary") {
                HStack(spacing: 8) {
                    Button("Add new word") { withAnimation(Theme.settle) { adding = true } }.buttonStyle(HeroButton())
                    ForEach(heroWords, id: \.self) { HeroChip(text: $0) }
                }
            }
            if adding { addRow }
            if words.isEmpty {
                EmptyState(icon: "BookOpenText", title: query.isEmpty ? "No words yet" : "Nothing matches “\(query)”",
                           message: tab == .learned ? "Words you fix by hand after dictating show up here, for you to add."
                                                    : "Add the names and terms you say often.")
            } else {
                ListBox(items: words) { WordRow(word: $0) }
            }
        }
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            TextField("A name, product or term, spelled the way you want it", text: $newWord)
                .textFieldStyle(.plain).font(.system(size: 14))
                .onSubmit(add)
            Button("Cancel") { withAnimation(Theme.settle) { adding = false; newWord = "" } }.buttonStyle(SecondaryButton())
            Button("Add", action: add).buttonStyle(PrimaryButton()).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent.opacity(0.6)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func add() {
        model.addTerm(newWord)
        newWord = ""
        withAnimation(Theme.settle) { adding = false }
    }

    private var heroWords: [String] {
        let mine = model.vocabularyTerms
        return Array((mine.isEmpty ? ["Halvorsen", "Enkeon", "Priya", "Brightline"] : mine).prefix(4))
    }

    private var words: [Word] {
        var all: [Word] = []
        if tab == .all || tab == .learned { all += model.learned.map { Word(text: $0, source: .learned) } }
        if tab == .all || tab == .yours { all += model.vocabularyTerms.map { Word(text: $0, source: .yours) } }
        if tab == .all || tab == .enkeon { all += model.enkeonTerms.map { Word(text: $0, source: .enkeon) } }
        return query.isEmpty ? all : all.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }
}

private struct WordRow: View {
    @EnvironmentObject private var model: AppModel
    let word: DictionaryView.Word
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text(word.text).font(.system(size: 14)).foregroundStyle(Theme.text)
            Spacer()
            switch word.source {
            case .learned:
                Button("Dismiss") { model.dismissLearned(word.text) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                Button("Add") { model.acceptLearned(word.text) }.buttonStyle(PrimaryButton())
            case .yours:
                if hovering {
                    Button { model.removeTerm(word.text) } label: { PhosphorIcon(name: "Trash", size: 14).foregroundStyle(Theme.secondary) }
                        .buttonStyle(.plain).help("Remove")
                }
                SourceTag(text: word.source.rawValue, tint: Theme.secondary)
            case .enkeon:
                SourceTag(text: word.source.rawValue, tint: Theme.accent)
            }
        }
        .padding(.horizontal, 18).frame(minHeight: 52)
        .background(Theme.text.opacity(hovering ? 0.03 : 0))
        .onHover { hovering = $0 }
    }
}

struct SourceTag: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
            .padding(.horizontal, 8).frame(height: 22)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Snippets

struct SnippetsView: View {
    @EnvironmentObject private var model: AppModel
    enum Tab: Hashable { case all, text, memory }
    @State private var tab: Tab = .all
    @State private var query = ""
    @State private var editing: Snippet?

    var body: some View {
        PageColumn {
            PageTitle(title: "Snippets") {
                Button("Add new") { editing = Snippet(cue: "", kind: .text, body: "") }.buttonStyle(PrimaryButton())
            }
            TabStrip(tabs: [(.all, "All"), (.text, "Text"), (.memory, "From memory")], selection: $tab) { SearchToggle(query: $query) }
            HeroBanner(headline: Text("The stuff ") + Text("you").italic() + Text(" shouldn't have to re-type."),
                       message: "Save text you type often, then say its cue to drop it in. A memory snippet types what Enkeon holds right now, and “from memory …” fills in anything else you saved.",
                       dismissKey: "enkeon.hero.snippets") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach([("my calendar link", "https://cal.com/you"), ("intro email", "Hi — great to meet you. Here's a quick…"),
                             ("Halvorsen pricing", "From memory: what you agreed")], id: \.0) { cue, text in
                        HStack(spacing: 8) { HeroChip(text: "“\(cue)”", italic: true); HeroChip(text: text) }
                    }
                    Button("Add new snippet") { editing = Snippet(cue: "", kind: .text, body: "") }.buttonStyle(HeroButton()).padding(.top, 4)
                }
            }
            if !offers.isEmpty && query.isEmpty {
                RowsBox(title: "You type these often") {
                    ForEach(offers, id: \.self) { sentence in
                        HStack(spacing: 12) {
                            PhosphorIcon(name: "NotePencil", size: 15).foregroundStyle(Theme.accent)
                            Text(sentence).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(2)
                            Spacer(minLength: 12)
                            Button("Dismiss") { model.phrases.dismissFrequent(sentence); model.objectWillChange.send() }
                                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            Button("Make a snippet") { editing = Snippet(cue: "", kind: .text, body: sentence) }.buttonStyle(SecondaryButton())
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                    }
                }
            }
            if snippets.isEmpty {
                EmptyState(icon: "Scissors", title: query.isEmpty ? "No snippets yet" : "Nothing matches “\(query)”",
                           message: "Dictate just the cue and the text goes in instead.")
            } else {
                ListBox(items: snippets) { SnippetRow(snippet: $0) { editing = $0 } }
            }
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet) { model.snippets.save($0); editing = nil } cancel: { editing = nil }
        }
    }

    /// Sentences you've typed five times or more that aren't snippets yet.
    private var offers: [String] {
        let saved = Set(model.snippets.snippets.map(\.body))
        return Array(model.phrases.frequent().filter { !saved.contains($0) }.prefix(5))
    }

    private var snippets: [Snippet] {
        model.snippets.snippets.filter { tab == .all || (tab == .text ? $0.kind == .text : $0.kind == .memory) }
            .filter { query.isEmpty || $0.cue.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query) }
    }
}

private struct SnippetRow: View {
    @EnvironmentObject private var model: AppModel
    let snippet: Snippet
    let edit: (Snippet) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            PhosphorIcon(name: snippet.kind == .memory ? "Brain" : "Scissors", size: 15)
                .foregroundStyle(snippet.kind == .memory ? Theme.accent : Theme.secondary)
            (Text(snippet.cue).foregroundStyle(Theme.text) + Text("  →  ").foregroundStyle(Theme.tertiary)
             + Text(snippet.kind == .memory ? "from memory: \(snippet.body)" : snippet.body).foregroundStyle(Theme.secondary))
                .font(.system(size: 14)).lineLimit(1)
            Spacer()
            if hovering {
                Button { edit(snippet) } label: { PhosphorIcon(name: "PencilSimple", size: 14).foregroundStyle(Theme.secondary) }
                    .buttonStyle(.plain).help("Edit")
                Button { model.snippets.delete(snippet) } label: { PhosphorIcon(name: "Trash", size: 14).foregroundStyle(Theme.secondary) }
                    .buttonStyle(.plain).help("Delete")
            }
        }
        .padding(.horizontal, 18).frame(minHeight: 52)
        .background(Theme.text.opacity(hovering ? 0.03 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { edit(snippet) }
    }
}

// MARK: - Styles

struct StylesView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(AppModel.cleanupKey) private var cleanupOn = true
    @State private var group: AppModel.StyleGroup = .messages

    var body: some View {
        // Cookie's console is shorter than Voice's window: the style cards scroll.
        ScrollView { PageColumn {
            PageTitle(title: "Styles") {
                HStack(spacing: 10) {
                    Text("Clean-up").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    Toggle("", isOn: $cleanupOn).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
                }
                .help(model.cleanupStatus)
            }
            TabStrip(tabs: AppModel.StyleGroup.allCases.map { ($0, $0.title) }, selection: $group) { EmptyView() }
            HeroBanner(headline: Text("This style applies in ") + Text(group.title.lowercased()).italic(),
                       message: heroMessage) {
                PhosphorIcon(name: groupIcon, size: 22).foregroundStyle(.white.opacity(0.9))
                    .frame(width: 48, height: 48).background(.white.opacity(0.13), in: Circle())
            }
            if !cleanupOn || model.cleanupModel?.available == false {
                Text(cleanupOn ? "The on-device clean-up isn't available on this Mac, so styles don't apply yet." : "Clean-up is off: every app gets your words as heard.")
                    .font(.system(size: 12)).foregroundStyle(Theme.warning)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach([AppModel.Style.formal, .casual, .lowercase, .off], id: \.self) { style in
                    StyleCard(style: style, selected: model.groupStyle(group) == style) { model.setGroupStyle(style, for: group) }
                }
            }
            .disabled(!cleanupOn)
            .opacity(cleanupOn ? 1 : 0.5)
            Spacer(minLength: 0)
        } }
    }

    private var groupIcon: String {
        switch group {
        case .messages: return "ChatCircleText"
        case .work: return "Briefcase"
        case .email: return "EnvelopeSimple"
        case .code: return "Code"
        case .other: return "TextAa"
        }
    }

    private var heroMessage: String {
        switch group {
        case .messages: return "WhatsApp, Telegram, Messages and friends. Styles shape punctuation and case only; your words stay yours."
        case .work: return "Slack, Teams and your AI chats: clear, light, quick to read."
        case .email: return "Mail and Outlook: complete sentences, ready to send."
        case .code: return "Terminals and code editors get exactly what you said, so commands and code are never rewritten."
        case .other: return "Every other app you dictate into."
        }
    }
}

private struct StyleCard: View {
    let style: AppModel.Style
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(rule).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
                Text(sample)
                    .font(.system(size: 13, design: style == .off ? .monospaced : .default))
                    .foregroundStyle(.white)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(selected ? 0.95 : 0.55),
                                in: UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 3, topTrailingRadius: 12, style: .continuous))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? Theme.accent : .clear, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    private var title: String {
        switch style {
        case .formal: return "Formal."
        case .casual: return "Casual"
        case .lowercase: return "very casual"
        case .off: return "As heard"
        case .neutral: return "Clean"
        }
    }

    private var rule: String {
        switch style {
        case .formal: return "Caps + punctuation"
        case .casual: return "Caps + light punctuation"
        case .lowercase: return "No caps + light punctuation"
        case .off: return "Exactly what you said"
        case .neutral: return "Fillers out, tone kept"
        }
    }

    /// The same sentence, as each style writes it.
    private var sample: String {
        switch style {
        case .formal: return "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
        case .casual: return "Hey are you free for lunch tomorrow? Let's do 12 if that works for you"
        case .lowercase: return "hey are you free for lunch tomorrow? let's do 12 if that works for you"
        case .off: return "um hey are you free for lunch tomorrow let's do twelve if that works for you"
        case .neutral: return "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
        }
    }
}

// MARK: - Notes

struct NotesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var tab = 0

    var body: some View {
        PageColumn {
            PageTitle(title: "Notes") {
                Button("Open Console") { model.openConsole() }.buttonStyle(SecondaryButton())
            }
            TabStrip(tabs: [(0, "All"), (1, "Saved"), (2, "Not saved")], selection: $tab) { SearchToggle(query: $query) }
            HeroBanner(headline: Text("Say it once. ") + Text("Every").italic() + Text(" AI remembers it."),
                       message: "Hold Fn with ⇧ and speak: the thought goes to your Enkeon memory instead of the field, and Claude, ChatGPT and Cursor find it there.",
                       dismissKey: "enkeon.hero.notes") {
                HStack(spacing: 8) {
                    if model.account.isSignedIn {
                        HeroChip(text: "fn + ⇧  hold and speak")
                    } else {
                        Button("Sign in to Enkeon") { model.page = .connections }.buttonStyle(HeroButton())
                    }
                    HeroChip(text: "“Halvorsen renews every March”", italic: true)
                }
            }
            if notes.isEmpty {
                EmptyState(icon: "MemoryCards", title: query.isEmpty ? "No notes yet" : "Nothing matches “\(query)”",
                           message: "What you save with ⇧ shows up here, with whether it reached your memory.")
            } else {
                ListBox(items: notes) { NoteRow(record: $0) }
            }
        }
    }

    /// Dictations meant for memory: saved, or kept here because they couldn't be.
    private var notes: [DictationRecord] {
        model.history.records.filter { record in
            let meant = record.outcome == .remembered || (record.note ?? "").localizedCaseInsensitiveContains("enkeon memory")
                || (record.note ?? "").localizedCaseInsensitiveContains("save to enkeon") || (record.note ?? "").contains("Couldn't save to Enkeon")
            guard meant else { return false }
            switch tab {
            case 1: return record.outcome == .remembered
            case 2: return record.outcome != .remembered
            default: return true
            }
        }
        .filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
    }
}

private struct NoteRow: View {
    let record: DictationRecord

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.text).font(.system(size: 14)).foregroundStyle(Theme.text).textSelection(.enabled)
                Text("\(record.app) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            SourceTag(text: record.outcome == .remembered ? "Saved" : "Not saved",
                      tint: record.outcome == .remembered ? Theme.live : Theme.warning)
                .help(record.note ?? "")
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

// MARK: - Context

struct ContextView: View {
    @EnvironmentObject private var model: AppModel
    enum Tab: Hashable { case all, cleaned, filled, kept }
    @State private var tab: Tab = .all
    @State private var query = ""

    var body: some View {
        PageColumn {
            PageTitle("Context")
            TabStrip(tabs: [(.all, "All"), (.cleaned, "Cleaned"), (.filled, "Filled in"), (.kept, "Kept as heard")], selection: $tab) {
                SearchToggle(query: $query)
            }
            HeroBanner(headline: Text("See exactly what Enkeon ") + Text("changed").italic() + Text("."),
                       message: "Every clean-up and every fill-in, with what you said and what was typed. When the clean-up would add or drop words, your words go in as heard.",
                       dismissKey: "enkeon.hero.context") {
                HStack(spacing: 8) {
                    HeroChip(text: "\(count(.cleaned)) cleaned")
                    HeroChip(text: "\(count(.filled)) filled in")
                    HeroChip(text: "\(count(.kept)) kept as heard")
                }
            }
            if rows.isEmpty {
                EmptyState(icon: "GitDiff", title: query.isEmpty ? "No changes yet" : "Nothing matches “\(query)”",
                           message: "When the clean-up or a fill-in changes your words, the before and after show up here.")
            } else {
                ListBox(items: rows) { ChangeRow(record: $0) }
            }
        }
    }

    private func kind(_ record: DictationRecord) -> Tab? {
        guard let note = record.cleanup else { return nil }
        if note == "cleaned" { return .cleaned }
        if note.hasPrefix("filled") || note.hasPrefix("snippet") { return .filled }
        return .kept
    }

    private func count(_ tab: Tab) -> Int { model.history.records.filter { kind($0) == tab }.count }

    private var rows: [DictationRecord] {
        model.history.records.filter { record in
            guard let k = kind(record) else { return false }
            return tab == .all || k == tab
        }
        .filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || ($0.heard ?? "").localizedCaseInsensitiveContains(query) }
    }
}

// MARK: - Connections

struct RowsBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.tertiary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                Group { content }
            }
            .padding(.vertical, 6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let value: String
    var tint: Color = Theme.text

    var body: some View {
        HStack(spacing: 12) {
            PhosphorIcon(name: icon, size: 16).foregroundStyle(Theme.secondary).frame(width: 20)
            Text(title).font(.system(size: 14)).foregroundStyle(Theme.text)
            Spacer()
            Text(value).font(.system(size: 13)).foregroundStyle(tint).lineLimit(1).textSelection(.enabled)
        }
        .padding(.horizontal, 18).frame(minHeight: 50)
    }
}
