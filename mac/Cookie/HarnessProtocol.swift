//
//  HarnessProtocol.swift
//  Cookie
//
//  The lines `cookie serve` speaks: one JSON object per line on stdin and
//  stdout. Shapes follow the core's src/serve.rs. Foundation only, so
//  the decoder can be checked on its own (HarnessWire.selfCheck).
//

import Foundation

/// One line from the helper. Every field but `type` depends on the kind.
struct HarnessLine: Decodable {
    let type: String
    /// The run it belongs to. Some errors name none.
    let run: String?
    /// approval / tool_call: the id to answer with.
    let id: String?
    /// tool_call: which tool, and its arguments (Cookie's tools take strings only).
    let name: String?
    /// tool_call: the arguments as JSON values (strings, numbers, arrays, objects).
    let args: [String: Any]?
    let event: HarnessEvent?
    let answer: String?
    let message: String?
    // approval
    let tool: String?
    let effect: String?
    let preview: String?
    let reason: String?
    /// approval: guarded values the person didn't write (`arg = value`).
    let fromData: [String]?
    /// approval: every action of one turn, when there are several.
    let items: [Item]?

    struct Item: Decodable {
        let tool: String?
        let effect: String?
        let preview: String?
        let reason: String?
        let from_data: [String]?
    }

    enum CodingKeys: String, CodingKey { case type, run, id, name, args, event, answer, message, tool, effect, preview, reason, from_data, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        // `run` can be null on a refused line; treat anything but a string as none.
        run = try? c.decodeIfPresent(String.self, forKey: .run)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        args = (try? c.decodeIfPresent(JSONValue.self, forKey: .args))?.value as? [String: Any]
        event = try c.decodeIfPresent(HarnessEvent.self, forKey: .event)
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        effect = try c.decodeIfPresent(String.self, forKey: .effect)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        fromData = try? c.decodeIfPresent([String].self, forKey: .from_data)
        items = try? c.decodeIfPresent([Item].self, forKey: .items)
    }
}

/// `{"type": "text_delta", "data": "…"}` or `{"type": "tool_call_started", "data": {…}}`.
/// New kinds may appear; anything unknown is kept by name and ignored.
struct HarnessEvent: Decodable {
    let type: String
    /// text_delta
    let text: String?
    /// tool_call_started (name), asked_person (tool), enkeon_unavailable / compaction_failed (reason)
    let detail: Detail?

    struct Detail: Decodable {
        let name: String?
        let tool: String?
        let reason: String?
    }

    enum CodingKeys: String, CodingKey { case type, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        text = try? c.decode(String.self, forKey: .data)
        detail = try? c.decode(Detail.self, forKey: .data)
    }
}

/// What Cookie sends. `run` refuses unknown fields, so only these are ever written.
enum HarnessRequest {
    struct Tool: Encodable {
        let name: String
        let description: String
        let effect: String
        /// Arguments that must come from the person's own words (serve.rs `guard`).
        var `guard`: [String] = []
        /// JSON Schema of the arguments; nil = any object.
        var schema: Schema?
        var parallel_safe = true
    }

    struct Schema: Encodable {
        var type = "object"
        let properties: [String: Property]
        let required: [String]
    }

    struct Property: Encodable {
        var type = "string"
        let description: String
    }

    /// One picture; the harness sends all of a run's images as one untrusted
    /// message right after the input. `caption` rides just before it, untrusted too.
    struct Image: Encodable {
        let media_type: String
        /// Base64.
        let data: String
        /// `screen` or `file`; one source per run.
        let source: String
        let caption: String
    }

    /// An earlier turn: `user` is the person's words, `assistant` Cookie's reply,
    /// `untrusted` when that reply was built from a screenshot or file.
    struct Turn: Encodable, Equatable {
        let role: String
        let text: String
        let untrusted: Bool
    }

    struct Run: Encodable {
        let type = "run"
        let id: String
        let model: String
        let input: String
        let instructions: String
        let tools: [Tool]
        let images: [Image]
        /// Earlier turns of this chat (serve.rs `history`), oldest first.
        let history: [Turn]
        /// A value Cookie found (on screen, in a file) is put to the person on
        /// the card, marked, instead of being refused.
        let confirm_data = true
        /// A task on the Mac takes many steps (look, act, look again).
        let budget = Budget(max_steps: 80)
        /// cookie-tools and cookie-py from this bundle (serve.rs `mcp`).
        let mcp: [MCP] = CookieServers.all(bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
        /// The skills folder shipped in the app (serve.rs `skills`), when present.
        let skills: String? = CookieSkills.directoryForHarness()

        struct Budget: Encodable { let max_steps: Int }
        /// nil leaves Enkeon to the helper's environment (on with ENKEON_API_KEY); false turns it off.
        let enkeon: Bool?
    }

    /// A quick question (hover to explain): one model call, no tools, MCP, skills, history or Enkeon.
    struct Ask: Encodable {
        let type = "run"
        let id: String
        let model: String
        let input: String
        let instructions: String
        let images: [Image]
        let budget = Run.Budget(max_steps: 1)
        let enkeon = false
    }

    /// A stdio MCP server for one run: effects per tool, guarded arguments per tool.
    struct MCP: Encodable, Equatable {
        let command: String
        let args: [String]
        let effects: [String: String]
        let guards: [String: [String]]
    }

    struct Approve: Encodable {
        let type = "approve"
        let id: String
        let allow: Answer

        /// One boolean for a single action, one per action for a batch.
        enum Answer: Encodable {
            case one(Bool)
            case each([Bool])

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .one(let yes): try container.encode(yes)
                case .each(let answers): try container.encode(answers)
                }
            }
        }
    }

    static func approve(id: String, answers: [Bool]) -> Approve {
        Approve(id: id, allow: answers.count == 1 ? .one(answers[0]) : .each(answers))
    }

    struct ToolResult: Encodable {
        let type = "tool_result"
        let id: String
        let output: String
        let is_error: Bool
    }

    struct Cancel: Encodable { let type = "cancel" }

    /// Open the connection to the model's host ahead of a run (serve.rs `warm`); answered on
    /// its own line, which Cookie doesn't wait for.
    struct Warm: Encodable {
        let type = "warm"
        let id: String
        let model: String
    }
}

enum HarnessWire {
    /// Bytes in, whole lines out. A partial line waits for the rest.
    struct LineBuffer {
        private var pending = Data()

        mutating func append(_ data: Data) -> [Data] {
            pending.append(data)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                if !line.isEmpty { lines.append(Data(line)) }
                pending = Data(pending[pending.index(after: newline)...])
            }
            return lines
        }
    }

    static func encode<T: Encodable>(_ message: T) -> Data {
        // ponytail: these types hold only strings and bools; encoding them can't fail
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var data = (try? encoder.encode(message)) ?? Data()
        data.append(0x0A)
        return data
    }

    static func decode(_ line: Data) -> HarnessLine? {
        try? JSONDecoder().decode(HarnessLine.self, from: line)
    }

    /// Lines as the harness writes them (serve.rs tests), split across reads.
    static func selfCheck() {
        var buffer = LineBuffer()
        let stream = """
        {"type":"event","run":"r1","event":{"type":"text_delta","data":"hel"}}
        {"type":"event","run":"r1","event":{"type":"tool_call_started","data":{"id":"c1","name":"read_screen"}}}
        {"type":"approval","run":"r1","id":"a3","tool":"send_email","effect":"outbound","preview":"to anna@x.com","reason":"sends"}
        {"type":"tool_call","run":"r1","id":"t4","name":"read_screen","args":{}}
        {"type":"error","run":null,"message":"nothing is waiting for `t9`"}
        {"type":"event","run":"r1","event":{"type":"usage","data":{"input_tokens":3}}}
        {"type":"done","run":"r1","answer":"hello [POINT:none]"}

        """
        let bytes = Data(stream.utf8)
        let cut = bytes.count / 3
        let lines = buffer.append(bytes[..<cut]) + buffer.append(bytes[cut...])
        let decoded = lines.compactMap(decode)
        precondition(decoded.count == 7, "every line decodes")
        precondition(decoded[0].event?.text == "hel")
        precondition(decoded[1].event?.detail?.name == "read_screen")
        precondition(decoded[2].type == "approval" && decoded[2].id == "a3" && decoded[2].effect == "outbound")
        precondition(decoded[3].type == "tool_call" && decoded[3].id == "t4" && decoded[3].name == "read_screen")
        precondition(decoded[4].run == nil && decoded[4].message?.contains("t9") == true)
        precondition(decoded[5].event?.type == "usage" && decoded[5].event?.text == nil)
        precondition(decoded[6].answer == "hello [POINT:none]")

        let run = String(decoding: encode(HarnessRequest.Run(id: "r1", model: "ollama:qwen3", input: "hi", instructions: "", tools: [], images: [], history: [], enkeon: false)), as: UTF8.self)
        precondition(run.hasSuffix("\n") && run.contains("\"type\":\"run\"") && run.contains("\"enkeon\":false"))
        let on = String(decoding: encode(HarnessRequest.Run(id: "r2", model: "x:y", input: "hi", instructions: "", tools: [],
            images: [.init(media_type: "image/jpeg", data: "AA==", source: "screen", caption: "UNTRUSTED screen content")], history: [], enkeon: nil)), as: UTF8.self)
        precondition(!on.contains("enkeon") && on.contains("\"media_type\":\"image/jpeg\""), "nil enkeon is left out")
        print("HarnessWire self-check passed")
    }
}

/// Any JSON value, decoded into Foundation types (String, Double, Bool, [Any], [String: Any], NSNull).
struct JSONValue: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let n = try? c.decode(Double.self) { value = n }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([JSONValue].self) { value = a.map(\.value) }
        else if let o = try? c.decode([String: JSONValue].self) { value = o.mapValues(\.value) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON") }
    }
}
