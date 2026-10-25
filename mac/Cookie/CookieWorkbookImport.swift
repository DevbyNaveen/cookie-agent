import Foundation

/// Imports the first worksheet. Formatting, macros and unsupported formulas are not executed.
enum CookieWorkbookImport {
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
            if required && process.terminationStatus != 0 { throw CookieWorkspaceStore.Failure("The workbook is missing its first worksheet.") }
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
        let parser = XMLParser(data: try entry("xl/worksheets/sheet1.xml"))
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
        init(strings: [String]) { self.strings = strings }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "c" { address = attributes["r"] ?? ""; type = attributes["t"] ?? ""; value = ""; formula = "" }
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
            if !formula.isEmpty { grid[row][column] = "=" + formula }
            else if type == "s" {
                guard let index = Int(value), strings.indices.contains(index) else { invalid = true; parser.abortParsing(); return }
                grid[row][column] = strings[index]
            } else { grid[row][column] = value }
        }
    }
}
