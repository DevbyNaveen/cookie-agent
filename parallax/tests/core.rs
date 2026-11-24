//! The core, end to end: worlds, the four verbs, thinking ahead, scripts, races, the wall.

use parallax::race::Attempt;
use parallax::{Parallax, Step};
use serde_json::json;

fn write(path: &str, text: &str) -> Step {
    Step { engine: "files".into(), action: "write".into(), args: json!({"path": path, "text": text}) }
}

#[tokio::test]
async fn a_race_keeps_the_attempt_its_test_passes() {
    let d = tempfile::tempdir().unwrap();
    let px = Parallax::open(d.path()).unwrap();
    let w = px.worlds.create("race", None, "t").unwrap().id;
    let attempts = vec![
        Attempt { label: "wrong".into(), steps: vec![write("answer.txt", "41")], script: None },
        Attempt { label: "right".into(), steps: vec![write("answer.txt", "42"), write("notes.txt", "why")], script: None },
        Attempt { label: "right and small".into(), steps: vec![write("answer.txt", "42")], script: None },
    ];
    let r = px.race(&w, attempts, "grep -qx 42 answer.txt").await.unwrap();
    assert_eq!(r["winner"], "right and small", "passing, and the fewest files changed");
    let f = px.worlds.files(&w).unwrap();
    assert_eq!(std::fs::read_to_string(f.join("answer.txt")).unwrap(), "42");
    assert!(!f.join("notes.txt").exists());
    // Keeping the winner is itself undoable.
    let change = r["change"].as_str().unwrap();
    px.undo(change).unwrap();
    assert!(!f.join("answer.txt").exists());
    assert_eq!(px.worlds.list().len(), 1, "the losing forks are gone");
}

#[tokio::test]
async fn a_step_guessed_ahead_is_used_only_when_it_is_exactly_the_next_step() {
    let d = tempfile::tempdir().unwrap();
    let px = Parallax::open(d.path()).unwrap();
    let w = px.worlds.create("ahead", None, "t").unwrap().id;
    px.act(&w, &write("a.txt", "one"), Some(write("b.txt", "two"))).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    let next = px.act(&w, &write("b.txt", "two"), None).await.unwrap();
    assert!(next.from_ahead, "done ahead and used");
    assert_eq!(std::fs::read_to_string(px.worlds.files(&w).unwrap().join("b.txt")).unwrap(), "two");
    // A different next step: the guess is thrown away, the real step done.
    px.act(&w, &write("c.txt", "x"), Some(write("d.txt", "guess"))).await.unwrap();
    let other = px.act(&w, &write("d.txt", "real"), None).await.unwrap();
    assert!(!other.from_ahead);
    assert_eq!(std::fs::read_to_string(px.worlds.files(&w).unwrap().join("d.txt")).unwrap(), "real");
    // And an ahead step is undoable like any other.
    px.undo(next.change.as_deref().unwrap()).unwrap();
    assert!(!px.worlds.files(&w).unwrap().join("b.txt").exists());
}

#[tokio::test]
async fn a_script_calls_engines_and_is_undone_as_one_change() {
    let d = tempfile::tempdir().unwrap();
    let px = Parallax::open(d.path()).unwrap();
    let w = px.worlds.create("script", None, "t").unwrap().id;
    let code = "from parallax import *\nsheet_create(path='s.sheet.json', columns=['item','qty','price'])\nsheet_set(path='s.sheet.json', cells={'A2':'pens','B2':'3','C2':'2','D2':'=B2*C2'})\nprint(sheet_get(path='s.sheet.json', range='D2')['value'])\nopen('notes.txt','w').write('by hand')\n";
    let out = px.script(&w, code).await.unwrap();
    assert!(out.contains("6"), "{out}");
    let f = px.worlds.files(&w).unwrap();
    assert!(f.join("s.sheet.json").exists() && f.join("notes.txt").exists());
    let change = out.lines().find_map(|l| l.strip_prefix("(undo it all with change ").map(|c| c.trim_end_matches(')').to_string())).unwrap();
    px.undo(&change).unwrap();
    assert!(!f.join("s.sheet.json").exists() && !f.join("notes.txt").exists(), "the whole script undone");
}

#[tokio::test]
async fn the_wall_runs_an_outside_action_once_on_a_yes_and_never_on_a_no() {
    let d = tempfile::tempdir().unwrap();
    let px = Parallax::open(d.path()).unwrap();
    let w = px.worlds.create("wall", None, "t").unwrap().id;
    let go = Step { engine: "hosting".into(), action: "rollback".into(), args: json!({"app": "shop"}) };
    let held = px.act(&w, &go, None).await.unwrap();
    let id = held.waiting.unwrap();
    let refused = px.decide(&id, false, "person").await.unwrap();
    assert_eq!(refused["state"], "refused");
    assert!(px.decide(&id, true, "person").await.is_err(), "decided once");
    let held = px.act(&w, &go, None).await.unwrap();
    let r = px.decide(&held.waiting.unwrap(), true, "person").await.unwrap();
    assert_eq!(r["state"], "failed", "it ran, and said honestly that nothing was live to roll back");
    assert!(px.ledger.verify().unwrap() >= 4);
}
