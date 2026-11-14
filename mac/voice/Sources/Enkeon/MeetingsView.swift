import AppKit
import SwiftUI
import EnkeonVoiceKit

struct MeetingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var reviewing: MeetingInsight?
    @State private var deleting = false
    @State private var tab = "Notes"
    @AppStorage("enkeon.memory.writingBranch") private var writingBranch = ""
    private var meetings: MeetingModel { model.meetings }
    var body: some View {
        PageColumn {
            PageTitle(title: "Meetings") {
                if meetings.isActive { MeetingControls().environmentObject(model) }
                else { Button("New meeting", systemImage: "plus") { meetings.showSetup = true }.buttonStyle(SecondaryButton()) }
            }
            if let error = meetings.error {
                HStack { Text(error).foregroundStyle(.orange); Spacer(); Button("Dismiss") { meetings.error = nil } }.font(.callout)
            }
            if let notice = meetings.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            if !writingBranch.isEmpty {
                HStack {
                    Text("Writing memory: \(writingBranch)").font(.caption)
                    Button("Use all branches") { writingBranch = ""; model.completer.resetMemory() }.font(.caption)
                }
            }
                if let record = meetings.current {
                    VStack(alignment: .leading, spacing: 12) {
                        Button { meetings.selected = nil } label: {
                            Label("All meetings", systemImage: "chevron.left")
                        }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                        HStack {
                            Text(record.title).font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                            Spacer()
                            Button("Export") { meetings.export(record) }.buttonStyle(SecondaryButton())
                            Button("Delete", role: .destructive) { deleting = true }.disabled(meetings.isActive || meetings.busy || meetings.pending > 0)
                        }
                        if !record.branch.isEmpty {
                            Button("Use \(record.branch) memory while writing") {
                                UserDefaults.standard.set(record.branch, forKey: "enkeon.memory.writingBranch")
                                model.completer.resetMemory()
                            }.font(.caption)
                        }
                        Text(record.started, format: .dateTime.month(.wide).day().year().hour().minute())
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        TabStrip(tabs: [("Notes", "Notes"), ("Transcript", "Transcript"), ("Follow-up", "Follow-up")], selection: $tab) { EmptyView() }
                        if tab == "Transcript" {
                            HStack {
                                Text("Sources are audio tracks, not identified speakers.").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Retry audio") { Task { await meetings.retryAudio(record.id) } }.disabled(meetings.pending > 0)
                            }
                            ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 14) {
                                        ForEach(record.segments) { segment in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("\(segment.timestamp) · \(segment.source)\(segment.isGap ? " · Gap" : "")").font(.caption.weight(.medium)).foregroundStyle(segment.isGap ? .orange : .secondary)
                                                Text(segment.text).textSelection(.enabled)
                                            }.id(segment.id).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }.padding(8)
                                }
                            }
                        } else if tab == "Follow-up" {
                            Text("A draft for your review. Enkeon never sends it automatically.").font(.caption).foregroundStyle(.secondary)
                            Button("Build draft from notes") { meetings.draftFollowUp(record.id) }.disabled(record.insights.isEmpty)
                            TextEditor(text: Binding(get: { meetings.current?.draft ?? "" }, set: { meetings.updateDraft(record.id, text: $0) }))
                            Button("Copy draft") { copy(record.draft) }.disabled(record.draft.isEmpty)
                        } else {
                            Toggle(isOn: $model.meetings.cloudConsent) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("AI notes").font(.system(size: 13, weight: .medium))
                                    Text("Share transcript excerpts with Haiku only when you request notes.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                }
                            }.toggleStyle(.switch).controlSize(.small).tint(Theme.accent).padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                            HStack {
                                Button(meetings.busy ? "Preparing notes…" : "Generate notes") { Task { await meetings.generateNotes() } }
                                    .disabled(meetings.busy || !meetings.cloudConsent || record.segments.isEmpty || meetings.pending > 0)
                                if meetings.pending > 0 { ProgressView().controlSize(.small); Text("Transcribing \(meetings.pending) audio chunks").font(.caption) }
                            }
                            if record.segments.contains(where: \.isGap) { Text("This meeting has gaps. Notes cover only the available transcript.").font(.callout).foregroundStyle(.orange) }
                            if record.insights.isEmpty { EmptyState(icon: "NotePencil", title: "Your meeting, remembered", message: "Generate source-linked notes from the transcript. Review decisions and actions before saving them to memory.") }
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    ForEach(record.insights) { insight in
                                        VStack(alignment: .leading, spacing: 7) {
                                            Text(insight.kind).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                                            Text(insight.text).textSelection(.enabled)
                                            ForEach(record.segments.filter { insight.segmentIDs.contains($0.id) }) { segment in
                                                DisclosureGroup("Source · \(segment.timestamp) · \(segment.source)") { Text(segment.text).font(.callout).textSelection(.enabled) }
                                            }
                                            Button(insight.savedMemoryID == nil ? "Review for memory" : "Saved to memory") { reviewing = insight }
                                                .disabled(insight.savedMemoryID != nil || record.branch.isEmpty || !model.account.isSignedIn)
                                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                            }
                            if record.branch.isEmpty { Text("No memory branch was selected for this meeting. Its transcript stays local.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if meetings.records.isEmpty {
                    introduction
                } else {
                    library
                }
        }
        .sheet(item: $reviewing) { insight in
            if let record = meetings.current { MeetingMemoryReview(insight: insight, record: record).environmentObject(model) }
        }
        .confirmationDialog("Delete this meeting and any pending audio from this Mac? Memories already saved to Enkeon remain in Enkeon.", isPresented: $deleting) {
            Button("Delete meeting", role: .destructive) { if let id = meetings.selected { meetings.delete(id) } }
        }
    }
    private var introduction: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HeroBanner(headline: Text("Be here. ") + Text("Remember it later.").italic(),
                           message: "Capture the conversation, revisit what matters, and turn decisions into memory.") {
                    Button("Start your first meeting") { meetings.showSetup = true }.buttonStyle(HeroButton())
                }
                VStack(alignment: .leading, spacing: 0) {
                    feature("Waveform", title: "Stay in the conversation", message: "Capture your microphone and meeting audio, with a transcript on your Mac.")
                    feature("ChatCircleText", title: "Pick up where you left off", message: "Request a catch-up, then trace decisions and actions back to the transcript.")
                    feature("Brain", title: "Make the useful parts last", message: "Review what to save to Enkeon memory, or copy a follow-up draft.")
                }.padding(8).background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                Label("You choose when transcript excerpts are shared for AI notes.", systemImage: "lock")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func feature(_ icon: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            PhosphorIcon(name: icon, size: 21).foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40).background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 2)
            Spacer(minLength: 0)
        }.padding(16)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Your conversations").font(.system(size: 14, weight: .medium))
                Spacer()
                SearchToggle(query: $model.meetings.search)
            }
            let records = meetings.records.filter { meetings.search.isEmpty || ($0.title + $0.transcript).localizedCaseInsensitiveContains(meetings.search) }
            if records.isEmpty {
                EmptyState(icon: "MagnifyingGlass", title: "No matching meetings", message: "Try another title or a phrase from the transcript.")
            } else {
                ListBox(items: records) { record in
                    Button { meetings.selected = record.id; tab = "Notes" } label: {
                        HStack(spacing: 14) {
                            PhosphorIcon(name: "ChatCircleText", size: 20).foregroundStyle(Theme.accent)
                                .frame(width: 42, height: 42).background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                Text(record.started, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Text(record.status.capitalized).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiary)
                        }.padding(14).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

struct MeetingSetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                PhosphorIcon(name: "Waveform", size: 24).foregroundStyle(Theme.accent)
                    .frame(width: 48, height: 48).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Start a meeting").font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                    Text("Be present. Keep the details.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Meeting name").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                TextField("e.g. Weekly team catch-up", text: $model.meetings.title)
                    .textFieldStyle(.plain).font(.system(size: 14)).padding(13)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Meeting name")
            }
            VStack(alignment: .leading, spacing: 20) {
                Toggle(isOn: $model.meetings.includeSystem) {
                    setting("Microphone", title: "Include meeting audio", message: "Capture sound from this Mac too. Your microphone is always included.")
                }.toggleStyle(.switch).controlSize(.small)
                VStack(alignment: .leading, spacing: 10) {
                    setting("Brain", title: "Memory destination", message: model.account.isSignedIn ? "Choose a branch for memories you review and save." : "Connect Enkeon to save reviewed notes to memory.")
                    Picker("Memory destination", selection: $model.meetings.branch) {
                        Text("Keep on this Mac").tag("")
                        ForEach(branches, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle(isOn: $model.meetings.cloudConsent) {
                    setting("Sparkle", title: "AI notes", message: "Allow transcript excerpts to go to Haiku when you request notes or a catch-up.")
                }.toggleStyle(.switch).controlSize(.small)
            }.padding(18).background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            DisclosureGroup {
                Text("Audio stays on this Mac until transcribed, then is deleted. Failed audio is kept for retry. Transcripts stay until you delete the meeting. macOS asks for microphone and screen/audio capture permission; no screen images are saved. Headphones help avoid capturing speakers twice.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            } label: {
                Text("Privacy & recording").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            Text("Let everyone know before recording.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            if let error = model.meetings.error { Text(error).foregroundStyle(Theme.warning).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") {
                    if model.meetings.phase == .preparing { model.meetings.cancelPreparation() }
                    else { dismiss() }
                }.buttonStyle(SecondaryButton()).keyboardShortcut(.cancelAction).disabled(model.meetings.activeID != nil)
                Spacer()
                if model.meetings.phase == .preparing { ProgressView().controlSize(.small) }
                Button(model.meetings.phase == .preparing ? "Preparing…" : "Start meeting") {
                    Task { await model.meetings.start() }
                }.buttonStyle(PrimaryButton()).disabled(model.meetings.isActive)
            }
        }.padding(30).frame(width: 520).tint(Theme.accent)
        .interactiveDismissDisabled(model.meetings.isActive)
        .task {
            guard model.account.isSignedIn else { return }
            branches = (try? await EnkeonClient.shared.branchNames()) ?? []
        }
    }

    private func setting(_ icon: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PhosphorIcon(name: icon, size: 18).foregroundStyle(Theme.accent).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MeetingControls: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(model.meetings.phase == .recording ? Color.red : Color.orange).frame(width: 7, height: 7)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(model.meetings.phase == .preparing ? "Preparing" : model.meetings.phase == .stopping ? "Stopping" : model.meetings.phase == .paused ? "Paused" : MeetingSegment.time(context.date.timeIntervalSince(model.meetings.active?.started ?? context.date)))
                    .monospacedDigit().font(.caption)
            }
            if model.meetings.phase == .recording {
                Button { model.meetings.pause() } label: { Image(systemName: "pause.fill") }.help("Pause recording")
            } else if model.meetings.phase == .paused {
                Button { model.meetings.resume() } label: { Image(systemName: "play.fill") }.help("Resume recording")
            }
            Button { Task { await model.meetings.stop() } } label: { Image(systemName: "stop.fill") }.help("Stop meeting")
                .disabled(model.meetings.phase == .preparing || model.meetings.phase == .stopping)
        }
    }
}

struct MeetingMemoryReview: View {
    let insight: MeetingInsight
    let record: MeetingRecord
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var previousID = ""
    @State private var related: [EnkeonClient.MemoryCandidate] = []
    @State private var checked = false
    @State private var lookupFailed = false
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review memory").font(.title2.weight(.semibold))
            Text("Save to \(record.branch) · \(record.title)").font(.callout)
            TextEditor(text: $text).frame(height: 100)
            Text("Related memory — check for an older decision before adding a new one").font(.caption)
            if !checked { ProgressView("Checking existing memory…") }
            if lookupFailed { Text("Could not check existing memory. Close and retry before saving.").foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Button { previousID = "" } label: { Label("Save as a new memory", systemImage: previousID.isEmpty ? "checkmark.circle.fill" : "circle") }
                    ForEach(related) { memory in
                        Button { previousID = memory.revisionID ?? "" } label: {
                            Label("Revise: \(memory.statement)", systemImage: previousID == memory.revisionID ? "checkmark.circle.fill" : "circle")
                                .multilineTextAlignment(.leading)
                        }
                    }
                }.buttonStyle(.plain).font(.callout)
            }.frame(height: 120)
            if let error = model.meetings.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                Button(saving ? "Saving…" : "Save reviewed memory") {
                    saving = true
                    Task {
                        await model.meetings.saveMemory(insight, record: record, text: text,
                            updates: previousID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : previousID.trimmingCharacters(in: .whitespacesAndNewlines))
                        saving = false
                        if model.meetings.records.first(where: { $0.id == record.id })?.insights.first(where: { $0.id == insight.id })?.savedMemoryID != nil { dismiss() }
                    }
                }.disabled(saving || !checked || lookupFailed || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520)
        .task {
            text = insight.text
            do {
                let candidates = EnkeonClient.memoryCandidates(fromRecall: try await EnkeonClient.shared.recallMeeting(query: insight.text, branch: record.branch))
                guard candidates.allSatisfy({ $0.revisionID != nil }) else {
                    lookupFailed = true; checked = true; return
                }
                related = candidates
            }
            catch { lookupFailed = true }
            checked = true
        }
    }
}

struct MeetingCompanionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = "Catch-up"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(model.meetings.active?.title ?? "Meeting").font(.headline); Spacer(); Button("Open notes") { model.openMeetings() } }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    Text(health("Microphone", at: model.meetings.microphoneAt, now: context.date))
                    if model.meetings.includeSystem { Text(health("Meeting audio", at: model.meetings.systemAt, now: context.date)) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Picker("Show", selection: $filter) {
                Text("Catch-up").tag("Catch-up"); Text("Decisions").tag("Decision"); Text("Actions").tag("Action")
            }.pickerStyle(.segmented)
            Toggle("Allow Haiku to read captured transcript", isOn: $model.meetings.cloudConsent).font(.caption)
            Button(model.meetings.busy ? "Catching up…" : "Catch me up") { Task { await model.meetings.generateNotes(catchUpOnly: true) } }
                .disabled(model.meetings.busy || !model.meetings.cloudConsent)
            if let error = model.meetings.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if model.meetings.active?.segments.contains(where: \.isGap) == true { Text("Recording has gaps. Catch-up covers captured words only.").font(.caption).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.meetings.catchUp.filter { filter == "Catch-up" || $0.kind == filter }) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.text).textSelection(.enabled)
                            ForEach((model.meetings.active?.segments ?? []).filter { item.segmentIDs.contains($0.id) }) { segment in
                                DisclosureGroup("\(segment.timestamp) · \(segment.source)") { Text(segment.text).font(.caption) }
                            }
                        }
                    }
                    if model.meetings.catchUp.isEmpty { Text("Captured speech will appear here after you request a catch-up. Action owners are not inferred.").foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 240)
        }.padding(20).frame(width: 340)
    }
    private func health(_ label: String, at: Date?, now: Date) -> String {
        if model.meetings.phase == .paused { return "\(label): paused" }
        guard let at else { return "\(label): waiting for audio" }
        return now.timeIntervalSince(at) < 5 ? "\(label): receiving audio" : "\(label): no recent audio — check the source"
    }
}
