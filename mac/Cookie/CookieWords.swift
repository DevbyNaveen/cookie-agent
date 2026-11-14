//
//  CookieWords.swift
//  Cookie
//
//  Enkeon Voice's pages in Cookie's console. Your words: Home (pace, streak, timeline), Dictionary,
//  Snippets, Styles. Memory: Notes and Context. Same views as the standalone app, Cookie's look.
//

import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, notes, meetings, dictionary, snippets, styles, context, connections, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .notes: return "Notes"
        case .meetings: return "Meetings"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .styles: return "Styles"
        case .context: return "Context"
        case .connections: return "Connections"
        case .settings: return "Settings"
        }
    }

    /// The Phosphor icon, as in the web Console.
    var icon: String {
        switch self {
        case .home: return "House"
        case .notes: return "Brain"
        case .meetings: return "ChatCircleText"
        case .dictionary: return "BookOpenText"
        case .snippets: return "Scissors"
        case .styles: return "TextAa"
        case .context: return "GitDiff"
        case .connections: return "Plugs"
        case .settings: return "GearSix"
        }
    }

    static let yourWords: [Page] = [.home, .dictionary, .snippets, .styles]
    static let memory: [Page] = [.notes, .context]
}

/// One of the two sections, with its tabs.
struct CookieWordsSection: View {
    @ObservedObject var model: AppModel
    let tabs: [Page]

    var body: some View {
        let page = tabs.contains(model.page) ? model.page : tabs[0]
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { page }, set: { model.page = $0 })) {
                ForEach(tabs) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.top, 14).padding(.bottom, 6)
            Group {
                switch page {
                case .home: HomeView(openDictionary: { model.page = .dictionary })
                case .dictionary: DictionaryView()
                case .snippets: SnippetsView()
                case .styles: StylesView()
                case .notes: NotesView()
                case .context: ContextView()
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environmentObject(model)
    }
}
