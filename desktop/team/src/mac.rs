//! Your Mac's own apps: Reminders, Notes, Calendar, Contacts and Messages,
//! for agents you give the "Mac apps" grant.
//!
//! Each tool runs a fixed AppleScript through `osascript`, with the agent's
//! values passed as arguments (`on run argv`), never pasted into the script:
//! a reminder titled `" & do shell script "…` stays a title. macOS asks you
//! once per app before Cookie may use it. Reading is free; adding or changing
//! asks you like any other change; sending a message always asks.

use std::sync::Arc;
use std::time::Duration;

use cookie_harness::tool::{tool, Effect, Tool};
use serde_json::{json, Value};

/// Build a date from numbers in AppleScript, independent of the Mac's locale.
const DATE_FN: &str = r#"
on mkdate(y, m, d, hh, mm)
  set t to current date
  set day of t to 1
  set year of t to (y as integer)
  set month of t to (m as integer)
  set day of t to (d as integer)
  set hours of t to (hh as integer)
  set minutes of t to (mm as integer)
  set seconds of t to 0
  return t
end mkdate
on iso(t)
  if t is missing value then return ""
  set pad to {"0", ""}
  set m to (month of t as integer)
  set d to day of t
  set hh to hours of t
  set mm to minutes of t
  return (year of t as string) & "-" & text -2 thru -1 of ("0" & m) & "-" & text -2 thru -1 of ("0" & d) & " " & text -2 thru -1 of ("0" & hh) & ":" & text -2 thru -1 of ("0" & mm)
end iso
"#;

const REMINDERS_LIST: &str = r#"
on run argv
  set wanted to item 1 of argv
  set out to ""
  tell application "Reminders"
    if wanted is "" then
      set ls to every list
    else
      set ls to (every list whose name is wanted)
    end if
    repeat with l in ls
      repeat with r in (reminders of l whose completed is false)
        set out to out & (name of l) & tab & (name of r) & tab & my iso(due date of r) & linefeed
      end repeat
    end repeat
  end tell
  return out
end run
"#;

const REMINDERS_ADD: &str = r#"
on run argv
  set {title, listName, notesText, y, m, d, hh, mm} to argv
  tell application "Reminders"
    if listName is "" then
      set l to default list
    else
      set l to first list whose name is listName
    end if
    set props to {name:title, body:notesText}
    set r to make new reminder at end of reminders of l with properties props
    if y is not "" then set due date of r to my mkdate(y, m, d, hh, mm)
  end tell
  return "Added to " & (name of l)
end run
"#;

const REMINDERS_DONE: &str = r#"
on run argv
  set title to item 1 of argv
  tell application "Reminders"
    set hits to (every reminder whose name is title and completed is false)
    if (count of hits) is 0 then return "none"
    set completed of item 1 of hits to true
  end tell
  return "done"
end run
"#;

const NOTES_SEARCH: &str = r#"
on run argv
  set q to item 1 of argv
  set out to ""
  tell application "Notes"
    set hits to (every note whose name contains q or plaintext contains q)
    set n to 0
    repeat with x in hits
      set n to n + 1
      if n > 15 then exit repeat
      set body to plaintext of x
      if (length of body) > 300 then set body to text 1 thru 300 of body
      set out to out & (name of x) & tab & (my iso(modification date of x)) & tab & body & linefeed & "---" & linefeed
    end repeat
  end tell
  return out
end run
"#;

const NOTES_READ: &str = r#"
on run argv
  set title to item 1 of argv
  tell application "Notes"
    set hits to (every note whose name is title)
    if (count of hits) is 0 then return ""
    return plaintext of item 1 of hits
  end tell
end run
"#;

const NOTES_CREATE: &str = r#"
on run argv
  set {title, body, folderName} to argv
  tell application "Notes"
    if folderName is "" then
      set f to default folder of default account
    else
      set f to first folder whose name is folderName
    end if
    make new note at f with properties {name:title, body:body}
  end tell
  return "created"
end run
"#;

const CALENDAR_EVENTS: &str = r#"
on run argv
  set days to (item 1 of argv) as integer
  set t0 to current date
  set t1 to t0 + days * 86400
  set out to ""
  tell application "Calendar"
    repeat with c in calendars
      repeat with e in (every event of c whose start date is greater than or equal to t0 and start date is less than or equal to t1)
        set out to out & (name of c) & tab & (summary of e) & tab & my iso(start date of e) & tab & my iso(end date of e) & linefeed
      end repeat
    end repeat
  end tell
  return out
end run
"#;

const CALENDAR_ADD: &str = r#"
on run argv
  set {title, calName, notesText, y, m, d, hh, mm, ey, em, ed, ehh, emm} to argv
  tell application "Calendar"
    if calName is "" then
      set c to first calendar whose writable is true
    else
      set c to first calendar whose name is calName
    end if
    make new event at end of events of c with properties {summary:title, description:notesText, start date:my mkdate(y, m, d, hh, mm), end date:my mkdate(ey, em, ed, ehh, emm)}
  end tell
  return "Added to " & (name of c)
end run
"#;

const CONTACTS_FIND: &str = r#"
on run argv
  set q to item 1 of argv
  set out to ""
  tell application "Contacts"
    set n to 0
    repeat with p in (every person whose name contains q)
      set n to n + 1
      if n > 10 then exit repeat
      set em to ""
      repeat with e in emails of p
        set em to em & (value of e) & " "
      end repeat
      set ph to ""
      repeat with x in phones of p
        set ph to ph & (value of x) & " "
      end repeat
      set out to out & (name of p) & tab & em & tab & ph & linefeed
    end repeat
  end tell
  return out
end run
"#;

const MESSAGES_SEND: &str = r#"
on run argv
  set {who, msg} to argv
  tell application "Messages"
    set s to 1st account whose service type = iMessage
    send msg to participant who of s
  end tell
  return "sent"
end run
"#;

/// Run one script with arguments; macOS may ask the person the first time.
async fn osa(script: &str, args: &[String]) -> Result<String, String> {
    if !cfg!(target_os = "macos") {
        return Err("Mac apps are only reachable on a Mac.".into());
    }
    let full = format!("{DATE_FN}\n{script}");
    let mut cmd = tokio::process::Command::new("/usr/bin/osascript");
    cmd.arg("-e").arg(full).args(args).kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(45), cmd.output()).await.map_err(|_| "The app took too long to answer (45 s).".to_string())?.map_err(|e| e.to_string())?;
    if out.status.success() {
        return Ok(String::from_utf8_lossy(&out.stdout).trim().to_string());
    }
    let err = String::from_utf8_lossy(&out.stderr);
    if err.contains("-1743") || err.contains("Not authorized") {
        return Err("macOS hasn't allowed Cookie to use that app. Allow it in System Settings → Privacy & Security → Automation, then try again.".into());
    }
    Err(format!("The app said: {}", err.trim().lines().last().unwrap_or("an error")))
}

/// "2026-11-25 14:30" or "2026-11-25" → [y, m, d, hh, mm].
pub(crate) fn date_parts(s: &str, default_hour: u32) -> Result<[String; 5], String> {
    let s = s.trim().replace('T', " ");
    let (day, time) = s.split_once(' ').unwrap_or((&s, ""));
    let mut d = day.split('-').map(|p| p.parse::<u32>());
    let (Some(Ok(y)), Some(Ok(m)), Some(Ok(dd)), None) = (d.next(), d.next(), d.next(), d.next()) else {
        return Err(format!("Dates look like 2026-11-25 or 2026-11-25 14:30, not {s:?}."));
    };
    let (hh, mm) = if time.is_empty() {
        (default_hour, 0)
    } else {
        let mut t = time.split(':').map(|p| p.parse::<u32>());
        match (t.next(), t.next()) {
            (Some(Ok(h)), Some(Ok(mi))) if h < 24 && mi < 60 => (h, mi),
            _ => return Err(format!("Times look like 14:30, not {time:?}.")),
        }
    };
    if !(2000..=2100).contains(&y) || !(1..=12).contains(&m) || !(1..=31).contains(&dd) {
        return Err(format!("{s:?} isn't a real date."));
    }
    Ok([y, m, dd, hh, mm].map(|n| n.to_string()))
}

fn rows(text: &str, heads: &[&str]) -> String {
    let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty() && *l != "---").collect();
    if lines.is_empty() {
        return "Nothing found.".into();
    }
    lines
        .iter()
        .take(60)
        .map(|l| l.split('\t').zip(heads).filter(|(v, _)| !v.trim().is_empty()).map(|(v, h)| format!("{h}: {}", v.trim())).collect::<Vec<_>>().join(" · "))
        .collect::<Vec<_>>()
        .join("\n")
}

fn s(args: &Value, k: &str) -> String {
    args[k].as_str().unwrap_or_default().trim().to_string()
}

pub(crate) fn tools() -> Vec<Arc<dyn Tool>> {
    let mut out: Vec<Arc<dyn Tool>> = Vec::new();
    out.push(Arc::new(tool(
        "reminders_list",
        "List open reminders in the Mac's Reminders app (all lists, or one by name).",
        json!({"type": "object", "properties": {"list": {"type": "string"}}}),
        Effect::Read,
        |a: Value| async move { osa(REMINDERS_LIST, &[s(&a, "list")]).await.map(|t| rows(&t, &["list", "reminder", "due"])) },
    )));
    out.push(Arc::new(
        tool(
            "reminders_add",
            "Add a reminder in the Mac's Reminders app. `due` like 2026-11-25 or 2026-11-25 14:30.",
            json!({"type": "object", "properties": {
                "title": {"type": "string"}, "due": {"type": "string"}, "list": {"type": "string"}, "notes": {"type": "string"}
            }, "required": ["title"]}),
            Effect::Write,
            |a: Value| async move {
                let due = s(&a, "due");
                let d = if due.is_empty() { [(); 5].map(|_| String::new()) } else { date_parts(&due, 9)? };
                let mut argv = vec![s(&a, "title"), s(&a, "list"), s(&a, "notes")];
                argv.extend(d);
                osa(REMINDERS_ADD, &argv).await
            },
        )
        .with_preview(|a| format!("Add reminder: {}{}{}", s(a, "title"), if s(a, "due").is_empty() { String::new() } else { format!(" (due {})", s(a, "due")) }, if s(a, "list").is_empty() { String::new() } else { format!(" in {}", s(a, "list")) })),
    ));
    out.push(Arc::new(
        tool(
            "reminders_complete",
            "Mark an open reminder done, by its exact title.",
            json!({"type": "object", "properties": {"title": {"type": "string"}}, "required": ["title"]}),
            Effect::Write,
            |a: Value| async move {
                match osa(REMINDERS_DONE, &[s(&a, "title")]).await?.as_str() {
                    "none" => Err("No open reminder has exactly that title.".into()),
                    _ => Ok("Marked done.".into()),
                }
            },
        )
        .with_preview(|a| format!("Mark done: {}", s(a, "title"))),
    ));
    out.push(Arc::new(tool(
        "notes_search",
        "Search the Mac's Notes app by words in a note's title or text. Returns titles and the start of each note.",
        json!({"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}),
        Effect::Read,
        |a: Value| async move {
            let t = osa(NOTES_SEARCH, &[s(&a, "query")]).await?;
            Ok(if t.trim().is_empty() { "No note matches.".into() } else { t.replace("\t", " · ") })
        },
    )));
    out.push(Arc::new(tool(
        "notes_read",
        "Read one note from the Mac's Notes app, by its exact title.",
        json!({"type": "object", "properties": {"title": {"type": "string"}}, "required": ["title"]}),
        Effect::Read,
        |a: Value| async move {
            let t = osa(NOTES_READ, &[s(&a, "title")]).await?;
            if t.is_empty() { Err("No note has exactly that title.".into()) } else { Ok(t.chars().take(30_000).collect()) }
        },
    )));
    out.push(Arc::new(
        tool(
            "notes_create",
            "Create a note in the Mac's Notes app (optionally in a folder by name).",
            json!({"type": "object", "properties": {"title": {"type": "string"}, "body": {"type": "string"}, "folder": {"type": "string"}}, "required": ["title", "body"]}),
            Effect::Write,
            |a: Value| async move {
                // Notes stores HTML: keep the agent's text as text.
                let body = s(&a, "body").replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('\n', "<br>");
                osa(NOTES_CREATE, &[s(&a, "title"), body, s(&a, "folder")]).await.map(|_| "Created the note.".into())
            },
        )
        .with_preview(|a| format!("New note: {}\n{}", s(a, "title"), crate::util::clip(&s(a, "body"), 1200))),
    ));
    out.push(Arc::new(tool(
        "calendar_events",
        "List events in the Mac's Calendar app from now through the next `days` days (default 7).",
        json!({"type": "object", "properties": {"days": {"type": "integer"}}}),
        Effect::Read,
        |a: Value| async move {
            let days = a["days"].as_u64().unwrap_or(7).clamp(1, 60).to_string();
            osa(CALENDAR_EVENTS, &[days]).await.map(|t| rows(&t, &["calendar", "event", "starts", "ends"]))
        },
    )));
    out.push(Arc::new(
        tool(
            "calendar_add",
            "Add an event to the Mac's Calendar app. `start` and `end` like 2026-11-25 14:30.",
            json!({"type": "object", "properties": {
                "title": {"type": "string"}, "start": {"type": "string"}, "end": {"type": "string"}, "calendar": {"type": "string"}, "notes": {"type": "string"}
            }, "required": ["title", "start", "end"]}),
            Effect::Write,
            |a: Value| async move {
                let mut argv = vec![s(&a, "title"), s(&a, "calendar"), s(&a, "notes")];
                argv.extend(date_parts(&s(&a, "start"), 9)?);
                argv.extend(date_parts(&s(&a, "end"), 10)?);
                osa(CALENDAR_ADD, &argv).await
            },
        )
        .with_preview(|a| format!("Add to calendar: {} · {} → {}", s(a, "title"), s(a, "start"), s(a, "end"))),
    ));
    out.push(Arc::new(tool(
        "contacts_find",
        "Find people in the Mac's Contacts app by name: their emails and phone numbers.",
        json!({"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}),
        Effect::Read,
        |a: Value| async move { osa(CONTACTS_FIND, &[s(&a, "name")]).await.map(|t| rows(&t, &["name", "email", "phone"])) },
    )));
    out.push(Arc::new(
        tool(
            "messages_send",
            "Send an iMessage from the Mac's Messages app to a phone number or Apple ID email. Always asks the person first.",
            json!({"type": "object", "properties": {"to": {"type": "string", "description": "phone number or email"}, "text": {"type": "string"}}, "required": ["to", "text"]}),
            Effect::Outbound,
            |a: Value| async move { osa(MESSAGES_SEND, &[s(&a, "to"), s(&a, "text")]).await.map(|_| "Sent.".into()) },
        )
        .with_preview(|a| format!("iMessage to {}:\n{}", s(a, "to"), crate::util::clip(&s(a, "text"), 1500)))
        .guard("to"),
    ));
    out
}

/// Every script compiles (osacompile checks syntax without running anything).
pub fn scripts() -> Vec<(&'static str, &'static str)> {
    vec![
        ("reminders_list", REMINDERS_LIST),
        ("reminders_add", REMINDERS_ADD),
        ("reminders_complete", REMINDERS_DONE),
        ("notes_search", NOTES_SEARCH),
        ("notes_read", NOTES_READ),
        ("notes_create", NOTES_CREATE),
        ("calendar_events", CALENDAR_EVENTS),
        ("calendar_add", CALENDAR_ADD),
        ("contacts_find", CONTACTS_FIND),
        ("messages_send", MESSAGES_SEND),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_parse_and_refuse_nonsense() {
        assert_eq!(date_parts("2026-11-25 14:30", 9).unwrap(), ["2026", "11", "25", "14", "30"].map(String::from));
        assert_eq!(date_parts("2026-11-25", 9).unwrap()[3], "9");
        assert!(date_parts("25/11/2026", 9).is_err());
        assert!(date_parts("2026-13-01", 9).is_err());
        assert!(date_parts("2026-11-25 25:00", 9).is_err());
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn every_script_compiles() {
        for (name, script) in scripts() {
            let path = std::env::temp_dir().join(format!("cookie-{name}.scpt"));
            let out = std::process::Command::new("/usr/bin/osacompile").arg("-o").arg(&path).arg("-e").arg(format!("{DATE_FN}\n{script}")).output().unwrap();
            let _ = std::fs::remove_file(&path);
            assert!(out.status.success(), "{name}: {}", String::from_utf8_lossy(&out.stderr));
        }
    }
}
