//! Spawns the built server and speaks MCP to it over stdio.

use std::{
    io::{BufRead, BufReader, Write},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
};

use serde_json::{json, Value};

struct Server {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl Server {
    fn start(root: &std::path::Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_cookie-tools"))
            .arg("--root")
            .arg(root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        Self { child, stdin, stdout }
    }

    fn send_raw(&mut self, line: &str) {
        self.stdin.write_all(line.as_bytes()).unwrap();
        self.stdin.write_all(b"\n").unwrap();
        self.stdin.flush().unwrap();
    }

    fn recv(&mut self) -> Value {
        let mut line = String::new();
        self.stdout.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap_or_else(|e| panic!("not JSON ({e}): {line:?}"))
    }

    fn request(&mut self, id: u64, method: &str, params: Value) -> Value {
        self.send_raw(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}).to_string());
        let reply = self.recv();
        assert_eq!(reply["id"], id, "{reply}");
        assert_eq!(reply["jsonrpc"], "2.0");
        reply
    }

    fn call(&mut self, id: u64, name: &str, arguments: Value) -> (String, bool) {
        let reply = self.request(id, "tools/call", json!({"name": name, "arguments": arguments}));
        let result = &reply["result"];
        assert_eq!(result["content"][0]["type"], "text", "{reply}");
        (result["content"][0]["text"].as_str().unwrap().to_string(), result["isError"].as_bool().unwrap())
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn speaks_mcp_over_stdio() {
    let dir = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let mut server = Server::start(dir.path());

    // The harness's client asks for 2025-06-18; an older client gets its own version back.
    let init = server.request(1, "initialize", json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}}));
    assert_eq!(init["result"]["protocolVersion"], "2025-06-18");
    assert_eq!(init["result"]["serverInfo"]["name"], "cookie-tools");
    assert!(init["result"]["capabilities"]["tools"].is_object());
    server.send_raw(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#);

    assert_eq!(server.request(2, "ping", json!({}))["result"], json!({}));

    let list = server.request(3, "tools/list", json!({}));
    let tools = list["result"]["tools"].as_array().unwrap();
    let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert_eq!(
        names,
        ["make_spreadsheet", "read_spreadsheet", "edit_spreadsheet", "make_document", "read_document", "make_page", "make_csv"]
    );
    for tool in tools {
        assert_eq!(tool["inputSchema"]["type"], "object", "{tool}");
        let description = tool["description"].as_str().unwrap();
        assert!(description.contains("Never") || description.contains("never"), "{description}");
        assert!(description.chars().count() <= 2_000, "the harness cuts descriptions at 2,000 characters");
        // Reads say they are read-only; writes say they are not destructive by default.
        let read_only = tool["annotations"]["readOnlyHint"].as_bool().unwrap();
        assert_eq!(read_only, tool["name"].as_str().unwrap().starts_with("read_"));
        if !read_only {
            assert_eq!(tool["annotations"]["destructiveHint"], false);
        }
    }

    let (text, is_error) = server.call(4, "make_csv", json!({"path": "t.csv", "rows": [["a", "b,c"], [1, true]]}));
    assert!(!is_error, "{text}");
    assert!(text.contains("t.csv"), "{text}");
    assert_eq!(std::fs::read_to_string(dir.path().join("t.csv")).unwrap(), "\u{feff}a,\"b,c\"\r\n1,true\r\n");

    let (text, is_error) = server.call(5, "make_csv", json!({"path": "t.csv", "rows": [["x"]]}));
    assert!(is_error && text.contains("already exists"), "{text}");

    let escape = outside.path().join("x.csv");
    let (text, is_error) = server.call(6, "make_csv", json!({"path": escape.to_string_lossy(), "rows": [["x"]]}));
    assert!(is_error && text.contains("outside"), "{text}");
    assert!(!escape.exists());

    let (text, is_error) = server.call(7, "read_spreadsheet", json!({"path": "t.csv"}));
    assert!(!is_error && text.contains("| a | b,c |"), "{text}");

    let (text, is_error) = server.call(8, "make_spreadsheet", json!({"path": "s.xlsx", "sheets": [{"rows": [[1], [{"formula": "=A1*2"}]]}]}));
    assert!(!is_error && text.contains("Formulas will calculate when the file is opened in Excel/Numbers."), "{text}");

    // Protocol errors are JSON-RPC errors, and the server keeps going after each.
    let unknown = server.request(9, "tools/call", json!({"name": "delete_everything", "arguments": {}}));
    assert_eq!(unknown["error"]["code"], -32602);
    assert_eq!(server.request(10, "resources/list", json!({}))["error"]["code"], -32601);
    server.send_raw("{not json");
    let parse = server.recv();
    assert_eq!(parse["error"]["code"], -32700);
    assert_eq!(parse["id"], Value::Null);
    let old = server.request(11, "initialize", json!({"protocolVersion": "2024-11-05"}));
    assert_eq!(old["result"]["protocolVersion"], "2024-11-05");
    let future = server.request(12, "initialize", json!({"protocolVersion": "2099-01-01"}));
    assert_eq!(future["result"]["protocolVersion"], "2025-06-18");
}

#[test]
fn refuses_to_start_without_a_valid_root() {
    let status = Command::new(env!("CARGO_BIN_EXE_cookie-tools")).stderr(Stdio::null()).status().unwrap();
    assert_eq!(status.code(), Some(2));
    let status = Command::new(env!("CARGO_BIN_EXE_cookie-tools"))
        .args(["--root", "/definitely/not/here"])
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(2));
}
