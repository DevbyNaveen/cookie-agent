//
//  CookieServers.swift
//  Cookie
//
//  The MCP servers Cookie brings to every run, from inside its own bundle:
//  cookie-tools (spreadsheets, documents, pages, CSV) and cookie-py (web
//  pages and decks, on the bundled Python). Both may only write inside the
//  person's Desktop, Documents and Downloads. A web address the model found
//  in content the person didn't write is guarded: it is put to the person on
//  the card (SECURITY.md "Acting" 2), since an address can carry data out.
//

import Foundation

enum CookieServers {
    /// Where files may be written and read.
    static func roots(home: URL) -> [String] {
        ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0).path }
    }

    /// The servers present in this bundle. A missing one is left out (a dev
    /// build without vendor/python), never started half-way.
    static func all(bundle: URL, home: URL, exists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> [HarnessRequest.MCP] {
        let rootArgs = roots(home: home).flatMap { ["--root", $0] }
        var servers: [HarnessRequest.MCP] = []
        let tools = bundle.appendingPathComponent("Contents/Helpers/cookie-tools").path
        if exists(tools) {
            servers.append(.init(command: tools, args: rootArgs, effects: [
                "make_spreadsheet": "write", "edit_spreadsheet": "write", "make_document": "write",
                "make_page": "write", "make_csv": "write",
                "read_spreadsheet": "read", "read_document": "read",
            ], guards: [:]))
        }
        let python = bundle.appendingPathComponent("Contents/Resources/python/bin/python3").path
        let server = bundle.appendingPathComponent("Contents/Resources/cookie-py/server.py").path
        if exists(python) {
            // -I: ignore the environment and user site; -B: never write bytecode into the signed app.
            servers.append(.init(command: python, args: ["-I", "-B", server] + rootArgs, effects: [
                "fetch_page": "read", "fetch_pages": "read", "check_quote": "read", "make_deck": "write",
            ], guards: ["fetch_page": ["url"], "fetch_pages": ["urls"], "check_quote": ["url"]]))
        }
        return servers
    }
}
