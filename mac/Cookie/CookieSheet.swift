import Foundation

struct CookieSheet {
    enum Value: Equatable { case success(Double), failure(String) }
    let grid: [[String]]
    private let evaluation = Evaluation()
    /// Bounds the work of one sheet's evaluation: every cell read counts, so a sheet of a thousand
    /// rows with a column of full-column totals stays well inside it.
    static let readBudget = 1_000_000
    private final class Evaluation {
        var remaining = CookieSheet.readBudget
        var cache: [Int: Value] = [:]
    }
    init(grid: [[String]]) { self.grid = grid }
    static func address(_ row: Int, _ column: Int) -> String {
        var index = column + 1, letters = ""
        while index > 0 { index -= 1; letters = String(UnicodeScalar(65 + index % 26)!) + letters; index /= 26 }
        return letters + String(row + 1)
    }
    /// "B2", or "$B$2" / "B$2": the `$` only anchors a reference when a formula is copied.
    static func coordinate(_ address: String) -> (Int, Int)? {
        let address = address.replacingOccurrences(of: "$", with: "")
        let letters = address.uppercased().prefix(while: { $0 >= "A" && $0 <= "Z" })
        guard !letters.isEmpty, letters.count <= 3, let row = Int(address.dropFirst(letters.count)), row > 0, row <= 1000 else { return nil }
        let column = letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 }
        guard column <= 50 else { return nil }
        return (row - 1, column - 1)
    }
    func display(_ row: Int, _ column: Int) -> String {
        guard grid.indices.contains(row), grid[row].indices.contains(column) else { return "" }
        let raw = grid[row][column]
        guard raw.hasPrefix("=") else { return raw }
        switch value(row: row, column: column) {
        case .success(let value): return value.formatted(.number.precision(.fractionLength(0...8)))
        case .failure(let error): return error
        }
    }
    private func text(_ row: Int, _ column: Int) -> String? {
        guard grid.indices.contains(row), grid[row].indices.contains(column) else { return nil }
        return grid[row][column].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func value(row: Int, column: Int) -> Value { value(row: row, column: column, visited: []) }
    private func value(row: Int, column: Int, visited: Set<Int>) -> Value {
        let key = row * 1024 + column
        guard !visited.contains(key), visited.count < 100 else { return .failure("#CYCLE!") }
        // Counted before the cache: a range over cached cells is still work.
        evaluation.remaining -= 1
        guard evaluation.remaining >= 0 else { return .failure("#LIMIT!") }
        if let cached = evaluation.cache[key] { return cached }
        guard let text = text(row, column) else { return .failure("#REF!") }
        let result: Value
        if text.isEmpty { result = .success(0) }
        else if !text.hasPrefix("=") { result = Double(text).map(Value.success) ?? .failure("#VALUE!") }
        else {
            do {
                let parser = FormulaParser(String(text.dropFirst()), skipsInRange: { reference in
                    // Like a spreadsheet: a range's empty and text cells are left out; its errors are not.
                    guard let (r, c) = Self.coordinate(reference), let cell = self.text(r, c) else { return true }
                    return cell.isEmpty || (!cell.hasPrefix("=") && Double(cell) == nil)
                }) { reference in
                    guard let (row, column) = Self.coordinate(reference) else { throw FormulaError("#REF!") }
                    switch value(row: row, column: column, visited: visited.union([key])) {
                    case .success(let number): return number
                    case .failure(let error): throw FormulaError(error)
                    }
                }
                let number = try parser.parse()
                result = number.isFinite ? .success(number) : .failure("#NUM!")
            } catch { result = .failure((error as? FormulaError)?.message ?? "#ERROR!") }
        }
        // A cycle depends on the path it was found on, so it isn't kept.
        if result != .failure("#CYCLE!") { evaluation.cache[key] = result }
        return result
    }
}

private struct FormulaError: Error { let message: String; init(_ message: String) { self.message = message } }
private final class FormulaParser {
    private let tokens: [String]
    private var index = 0
    private var depth = 0
    private let resolve: (String) throws -> Double
    private let skipsInRange: (String) -> Bool
    init(_ text: String, skipsInRange: @escaping (String) -> Bool, resolve: @escaping (String) throws -> Double) {
        // A reference with its `$` anchors ($B$2, B$2) is one token; the anchors don't change its value.
        let expression = try! NSRegularExpression(pattern: #"\$?[A-Za-z]{1,3}\$[0-9]+|\$[A-Za-z]{1,3}[0-9]+|[A-Za-z]+[0-9]*|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)|[^\s]"#)
        tokens = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range, in: text)!]).uppercased().replacingOccurrences(of: "$", with: "") }
        self.resolve = resolve
        self.skipsInRange = skipsInRange
    }
    private var next: String { index < tokens.count ? tokens[index] : "" }
    @discardableResult private func take(_ token: String) -> Bool { if next == token { index += 1; return true }; return false }
    func parse() throws -> Double {
        guard tokens.count <= 1000 else { throw FormulaError("#LIMIT!") }
        let result = try expression()
        guard index == tokens.count else { throw FormulaError("#ERROR!") }
        return result
    }
    private func expression() throws -> Double {
        var result = try product()
        while next == "+" || next == "-" { let plus = take("+"); if !plus { index += 1 }; let value = try product(); result = plus ? result + value : result - value }
        return result
    }
    private func product() throws -> Double {
        var result = try atom()
        while next == "*" || next == "/" {
            let multiply = take("*"); if !multiply { index += 1 }
            let value = try atom()
            if !multiply && value == 0 { throw FormulaError("#DIV/0!") }
            result = multiply ? result * value : result / value
        }
        return result
    }
    private func atom() throws -> Double {
        depth += 1; defer { depth -= 1 }
        guard depth < 80 else { throw FormulaError("#LIMIT!") }
        if take("-") { return try -atom() }
        if take("+") { return try atom() }
        if take("(") { let value = try expression(); guard take(")") else { throw FormulaError("#ERROR!") }; return value }
        let token = next; index += 1
        if let number = Double(token) { return number }
        if take("(") {
            guard ["SUM", "AVERAGE", "MIN", "MAX", "COUNT"].contains(token) else { throw FormulaError("#NAME?") }
            var values: [Double] = []
            repeat {
                if index + 1 < tokens.count, tokens[index + 1] == ":" {
                    let start = next; index += 2; let end = next; index += 1
                    guard let (r1, c1) = CookieSheet.coordinate(start), let (r2, c2) = CookieSheet.coordinate(end), r1 <= r2, c1 <= c2 else { throw FormulaError("#REF!") }
                    guard (r2 - r1 + 1) * (c2 - c1 + 1) <= 10000 else { throw FormulaError("#LIMIT!") }
                    for row in r1...r2 { for column in c1...c2 {
                        let reference = CookieSheet.address(row, column)
                        if skipsInRange(reference) { continue }
                        values.append(try resolve(reference))
                    } }
                } else { values.append(try expression()) }
            } while take(",")
            guard take(")") else { throw FormulaError("#ERROR!") }
            switch token {
            case "SUM": return values.reduce(0, +)
            case "AVERAGE":
                guard !values.isEmpty else { throw FormulaError("#DIV/0!") }
                return values.reduce(0, +) / Double(values.count)
            case "MIN": return values.min() ?? 0
            case "MAX": return values.max() ?? 0
            default: return Double(values.count)
            }
        }
        return try resolve(token)
    }
}

/// Small standards-based XLSX writer: stored ZIP entries, no external runtime or shell.
enum CookieWorkbookExport {
    /// Written as a number only when the number reads back as the same text: "007", "+15551234",
    /// "1e3" and " 12" stay text, as they were typed.
    static func isPlainNumber(_ raw: String) -> Bool {
        raw.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil && Double(raw)?.isFinite == true
    }
    static func data(_ grid: [[String]]) -> Data {
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let sheet = CookieSheet(grid: grid)
        let rows = grid.enumerated().map { row, cells in
            "<row r=\"\(row + 1)\">" + cells.enumerated().map { column, raw in
                let ref = CookieSheet.address(row, column)
                if raw.hasPrefix("=") {
                    let cached: String
                    if case .success(let number) = sheet.value(row: row, column: column) { cached = "<v>\(number)</v>" } else { cached = "" }
                    return "<c r=\"\(ref)\"><f>\(escape(String(raw.dropFirst())))</f>\(cached)</c>"
                }
                if isPlainNumber(raw) { return "<c r=\"\(ref)\"><v>\(raw)</v></c>" }
                return "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(raw))</t></is></c>"
            }.joined() + "</row>"
        }.joined()
        let files: [(String, String)] = [
            ("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>"),
            ("_rels/.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"),
            ("xl/workbook.xml", "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets><calcPr fullCalcOnLoad=\"1\"/></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
            ("xl/worksheets/sheet1.xml", "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rows)</sheetData></worksheet>")]
        return zip(files.map { ($0.0, Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + $0.1).utf8)) })
    }
    static func zip(_ files: [(String, Data)]) -> Data {
        var output = Data(), directory = Data()
        func append(_ value: UInt32, bytes: Int, to data: inout Data) { for index in 0..<bytes { data.append(UInt8((value >> (index * 8)) & 255)) } }
        for (name, bytes) in files {
            let filename = Data(name.utf8), offset = UInt32(output.count), size = UInt32(bytes.count)
            var crc: UInt32 = 0xffffffff
            for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }; crc ^= 0xffffffff
            append(0x04034b50, bytes: 4, to: &output)
            for value: UInt32 in [20, 0, 0, 0, 0] { append(value, bytes: 2, to: &output) }
            for value in [crc, size, size] { append(value, bytes: 4, to: &output) }
            append(UInt32(filename.count), bytes: 2, to: &output); append(0, bytes: 2, to: &output)
            output.append(filename); output.append(bytes)
            append(0x02014b50, bytes: 4, to: &directory)
            for value: UInt32 in [20, 20, 0, 0, 0, 0] { append(value, bytes: 2, to: &directory) }
            for value in [crc, size, size] { append(value, bytes: 4, to: &directory) }
            for value in [UInt32(filename.count), 0, 0, 0, 0] { append(value, bytes: 2, to: &directory) }
            append(0, bytes: 4, to: &directory); append(offset, bytes: 4, to: &directory); directory.append(filename)
        }
        let start = UInt32(output.count); output.append(directory)
        append(0x06054b50, bytes: 4, to: &output)
        for value: UInt32 in [0, 0, UInt32(files.count), UInt32(files.count)] { append(value, bytes: 2, to: &output) }
        append(UInt32(directory.count), bytes: 4, to: &output); append(start, bytes: 4, to: &output); append(0, bytes: 2, to: &output)
        return output
    }
}
