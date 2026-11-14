import AppKit
import Combine
import EnkeonVoiceKit
import SwiftUI

/// Your words, faded, right at the text cursor: live while you talk, then waiting for Tab (type it)
/// or Esc (keep it in Enkeon). A see-through panel that never takes focus or clicks. When the app
/// doesn't say where its cursor is (terminals, many Electron apps), the words sit in a small card
/// just above the bar instead.
final class CursorPreviewPanel: NSPanel {
    private static let size = NSSize(width: 640, height: 260)
    private let model: AppModel
    private var watching: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        let host = NSHostingView(rootView: CursorPreview().environmentObject(model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        contentView = host
        let completer = model.completer
        watching = completer.$caret.combineLatest(completer.$suggestion, completer.$revision)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] caret, suggestion, revision in
                // A fix hangs just below the line it changes; a suggestion sits at the cursor.
                self?.follow(caret: caret, showing: caret != nil && (suggestion != nil || revision != nil), below: revision != nil)
            }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func follow(caret: CGRect?, showing: Bool, below: Bool = false) {
        guard showing else { return orderOut(nil) }
        if let caret, let screen = NSScreen.screens.first(where: { $0.frame.intersects(caret) }) {
            // The text's first line starts at the cursor; the panel hangs down from there. A fix
            // starts under the line, a little left, so the words it changes stay visible.
            let x = min(below ? max(screen.visibleFrame.minX, caret.minX - 220) : caret.minX + 2, screen.visibleFrame.maxX - Self.size.width)
            setFrameOrigin(NSPoint(x: x, y: (below ? caret.minY - 6 : caret.maxY) - Self.size.height))
        } else {
            return orderOut(nil)
        }
        orderFrontRegardless()
    }
}

private struct CursorPreview: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let revision = model.completer.revision {
            RevisionCard(revision: revision)
        } else if let suggestion = model.completer.suggestion, let caret = model.completer.caret {
            completion(suggestion, caretHeight: caret.height, source: model.completer.source)
        }
    }

    /// The rest of your sentence, faded, with a small Tab key after it.
    private func completion(_ text: String, caretHeight: CGFloat, source: SentenceCompleter.Source) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.system(size: min(22, max(12, caretHeight * 0.78))))
                .foregroundStyle(Color(white: 0.5).opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            // "yours": the words come from what you wrote before, not from the model.
            Text(source == .memory ? "tab · \(model.completer.sourceLabel ?? "memory")" : source == .phrase ? "tab · yours" : "tab").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 5).frame(height: 15)
                .background(Theme.accent.opacity(0.75), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity)
    }
}

/// A change to words already typed: the corrected text with what changed tinted, what kind of
/// change it is, and the keys. While the model writes, a quiet "Fixing…".
private struct RevisionCard: View {
    let revision: SentenceCompleter.Revision

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                PhosphorIcon(name: icon, size: 13).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 12)
                if revision.revised != nil {
                    key("tab")
                    Text("replace").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    Text("esc").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55)).padding(.leading, 4)
                }
            }
            if let revised = revision.revised {
                marked(revised)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .lineLimit(9)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let note = revision.note {
                Text(note).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            } else {
                Text(revision.original).font(.system(size: 14)).foregroundStyle(.white.opacity(0.35))
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    .modifier(Shimmer())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: 560, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.55)))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.18), value: revision.revised)
    }

    private var title: String {
        let working = revision.revised == nil && revision.note == nil
        switch revision.kind {
        case .spelling: return "Spelling"
        case .fix: return working ? "Fixing…" : "Fix"
        }
    }

    private var icon: String {
        switch revision.kind {
        case .spelling: return "TextAa"
        case .fix: return "CheckCircle"
        }
    }

    /// The new text, with the words that changed in the accent colour.
    private func marked(_ revised: String) -> Text {
        Proofreader.changes(from: revision.original, to: revised).reduce(Text("")) { text, piece in
            text + Text(piece.text).foregroundColor(piece.changed ? Theme.accent : .white.opacity(0.88))
        }
    }

    private func key(_ label: String) -> some View {
        Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 5).frame(height: 16)
            .background(Theme.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// A slow light sweep across text the model is working on.
private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.4)
                    .offset(x: phase * proxy.size.width)
            }
            .mask(content)
        }
        .onAppear { withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.2 } }
    }
}
