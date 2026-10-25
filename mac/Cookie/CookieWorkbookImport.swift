import Foundation

/// Imports the first worksheet in tab order. Formatting, macros and unsupported formulas are not executed.
enum CookieWorkbookImport {
    /// A shared formula as written for its first cell, moved to another cell: references without a
    /// `$` move with it (ECMA-376 §18.3.1.40, the `si` group). Text in quotes is left alone.
    static func shift(_ formula: String, rows: Int, columns: Int) -> String {
        let reference = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])(\$?)([A-Za-z]{1,3})(\$?)([0-9]+)(?![A-Za-z0-9_(])"#)
        var result = "", inQuotes = false
        for (index, part) in formula.components(separatedBy: "\"").enumerated() {
            if index > 0 { result += "\"" }
            defer { inQuotes.toggle() }
            guard !inQuotes else { result += part; continue }
            let text = part as NSString
            var out = "", last = 0
            for match in reference.matches(in: part, range: NSRange(location: 0, length: text.length)) {
                out += text.substring(with: NSRange(location: last, length: match.range.location - last))
                let columnAnchor = text.substring(with: match.range(at: 1)), letters = text.substring(with: match.range(at: 2)).uppercased()
                let rowAnchor = text.substring(with: match.range(at: 3)), row = Int(text.substring(with: match.range(at: 4))) ?? 0
                var column = letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
                if columnAnchor.isEmpty { column += columns }
                let newRow = rowAnchor.isEmpty ? row + rows : row
                if column < 0 || newRow < 1 { out += "#REF!" } else {
                    let moved = CookieSheet.address(newRow - 1, column)
                    let movedLetters = moved.prefix(while: { $0.isLetter })
                    out += columnAnchor + movedLetters + rowAnchor + String(newRow)
                }
                last = match.range.location + match.range.length
            }
            result += out + text.substring(from: last)
        }
        return result
    }

    /// The worksheet the first tab names: workbook.xml's first <sheet>, through its relationship.
    static func firstSheetPath(workbook: Data, relationships: Data) -> String? {
        final class First: NSObject, XMLParserDelegate {
            var id: String?, targets: [String: String] = [:]
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                if name == "sheet", id == nil { id = attributes.first { $0.key == "r:id" || $0.key.hasSuffix(":id") }?.value }
                if name == "Relationship", let rid = attributes["Id"], let target = attributes["Target"] { targets[rid] = target }
            }
        }
        let first = First()
        for data in [workbook, relationships] {
            let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = first
            guard parser.parse() else { return nil }
        }
        guard let id = first.id, let target = first.targets[id] else { return nil }
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        // Only a worksheet inside the package's xl/worksheets folder.
        guard path.range(of: #"^xl/worksheets/[A-Za-z0-9_]+\.xml$"#, options: .regularExpression) != nil else { return nil }
        return path
    }

    static func load(_ url: URL) throws -> [[String]] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else { throw CookieWorkspaceStore.Failure("Import workbooks up to 20 MB.") }
        func entry(_ name: String, required: Bool = true) throws -> Data {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", url.path, name]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            var data = Data()
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 65536)
                if chunk.isEmpty { break }
                data.append(chunk)
                if data.count > 3_000_000 { process.terminate(); pipe.fileHandleForReading.closeFile(); throw CookieWorkspaceStore.Failure("Worksheet is too large to import.") }
            }
            process.waitUntilExit()
            if required && process.terminationStatus != 0 { throw CookieWorkspaceStore.Failure("The workbook is missing \(name).") }
            guard String(data: data, encoding: .utf8)?.localizedCaseInsensitiveContains("<!DOCTYPE") != true else { throw CookieWorkspaceStore.Failure("Workbook XML declarations are unsupported.") }
            return data
        }
        let sharedData = try entry("xl/sharedStrings.xml", required: false)
        let strings = Strings()
        if !sharedData.isEmpty {
            let parser = XMLParser(data: sharedData); parser.shouldResolveExternalEntities = false; parser.delegate = strings
            guard parser.parse() else { throw CookieWorkspaceStore.Failure("Workbook shared strings are invalid.") }
        }
        let reader = Sheet(strings: strings.values)
        guard let sheetPath = firstSheetPath(workbook: try entry("xl/workbook.xml"), relationships: try entry("xl/_rels/workbook.xml.rels")) else {
            throw CookieWorkspaceStore.Failure("The workbook doesn't say which worksheet comes first.")
        }
        let parser = XMLParser(data: try entry(sheetPath))
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), !reader.invalid else { throw CookieWorkspaceStore.Failure("Import supports the first sheet, up to 1,000 rows and 50 columns.") }
        return reader.grid
    }
    private final class Strings: NSObject, XMLParserDelegate {
        var values: [String] = [], current = "", reading = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "si" { current = "" }; if name == "t" { reading = true }
        }
        func parser(_ parser: XMLParser, foundCharacters text: String) { if reading { current += text } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { reading = false }; if name == "si" { values.append(current) }
        }
    }
    private final class Sheet: NSObject, XMLParserDelegate {
        let strings: [String]
        var grid: [[String]] = [], invalid = false
        private var address = "", type = "", value = "", formula = "", reading = ""
        /// A cell that uses a shared formula (`<f t="shared" si="n"/>`, empty) or an array formula's range.
        private var sharedIndex: String?, arrayRange: String?
        /// Each shared formula's text and the cell it was written for, by `si`.
        private var shared: [String: (formula: String, row: Int, column: Int)] = [:]
        /// The cells a multi-cell array formula fills, its own included: Cookie can't recalculate those.
        private var arrayCells: [(rows: ClosedRange<Int>, columns: ClosedRange<Int>, origin: (Int, Int))] = []
        init(strings: [String]) { self.strings = strings }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "c" { address = attributes["r"] ?? ""; type = attributes["t"] ?? ""; value = ""; formula = ""; sharedIndex = nil; arrayRange = nil }
            if name == "f" {
                if attributes["t"] == "shared" { sharedIndex = attributes["si"] }
                if attributes["t"] == "array" { arrayRange = attributes["ref"] }
            }
            if ["v", "t", "f"].contains(name) { reading = name }
        }
        func parser(_ parser: XMLParser, foundCharacters text: String) {
            if reading == "f" { formula += text } else if reading == "v" || reading == "t" { value += text }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if ["v", "t", "f"].contains(name) { reading = "" }
            guard name == "c" else { return }
            guard let (row, column) = CookieSheet.coordinate(address) else { invalid = true; parser.abortParsing(); return }
            while grid.count <= row { grid.append([]) }
            while grid[row].count <= column { grid[row].append("") }
            if let si = sharedIndex {
                if !formula.isEmpty { shared[si] = (formula, row, column) }
                else if let master = shared[si] {
                    formula = CookieWorkbookImport.shift(master.formula, rows: row - master.row, columns: column - master.column)
                } else { invalid = true; parser.abortParsing(); return }
            }
            if let range = arrayRange, !formula.isEmpty {
                let ends = range.split(separator: ":").compactMap { CookieSheet.coordinate(String($0)) }
                if ends.count == 2, ends[0] != ends[1], ends[0].0 <= ends[1].0, ends[0].1 <= ends[1].1 {
                    arrayCells.append((ends[0].0...ends[1].0, ends[0].1...ends[1].1, (row, column)))
                    formula = ""
                }
            }
            if !formula.isEmpty { grid[row][column] = "=" + formula }
            else if arrayCells.contains(where: { $0.rows.contains(row) && $0.columns.contains(column) }) {
                // Part of an array formula's output, which Cookie can't recalculate: an error, never a
                // number that looks live but won't change.
                grid[row][column] = "=ARRAY()"
            }
            else if type == "s" {
                guard let index = Int(value), strings.indices.contains(index) else { invalid = true; parser.abortParsing(); return }
                grid[row][column] = strings[index]
            } else { grid[row][column] = value }
        }
    }
}
