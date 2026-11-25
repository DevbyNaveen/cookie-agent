//! Boards: a live board the person and their agents work on together.
//!
//! Columns of cards (To do, Doing, Waiting on you, Done by default). An agent
//! keeps one with its `board` tool as it works (makes it, adds cards, moves
//! them, adds notes), so the person watches progress instead of reading
//! reports; the person drags cards, adds and edits them in the chat's board
//! view. Several agents can share one, so a team works one project. Each
//! change is written whole (`util::write_json`) and announced
//! (`TeamEvent::Board`), so every open view updates at once.
//!
//! A board is Cookie's own: changing it sends, deletes or pays nothing
//! outside, so the tool needs no yes. Only the person deletes a board.

use std::sync::{Arc, Weak};

use cookie_harness::tool::{tool, Effect, Tool};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::events::TeamEvent;
use crate::{util, Team};

pub const DEFAULT_COLUMNS: [&str; 4] = ["To do", "Doing", "Waiting on you", "Done"];
const MAX_BOARDS: usize = 50;
const MAX_CARDS: usize = 300;
const TITLE_MAX: usize = 200;
const NOTES_MAX: usize = 4000;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Card {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub notes: String,
    pub column: String,
    /// Who made or last moved it: an agent's id, or `you`.
    pub by: String,
    pub at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Board {
    pub id: String,
    pub title: String,
    pub columns: Vec<String>,
    pub cards: Vec<Card>,
    pub created_by: String,
    pub at: u64,
    pub updated_at: u64,
}

impl Board {
    /// A column by name, any case; the first one when none is named.
    fn column(&self, name: Option<&str>) -> Result<String, String> {
        match name.map(str::trim).filter(|n| !n.is_empty()) {
            None => Ok(self.columns[0].clone()),
            Some(n) => self.columns.iter().find(|c| c.eq_ignore_ascii_case(n)).cloned().ok_or_else(|| format!("This board's columns are: {}.", self.columns.join(", "))),
        }
    }

    fn card_mut(&mut self, id: &str) -> Result<&mut Card, String> {
        let id = id.trim();
        let i = self.cards.iter().position(|c| c.id == id || c.title.eq_ignore_ascii_case(id)).ok_or("No card by that id or title on this board.")?;
        Ok(&mut self.cards[i])
    }

    /// One line per column, for a model to read.
    pub fn summary(&self) -> String {
        let mut s = format!("Board “{}” ({})\n", self.title, self.id);
        for col in &self.columns {
            let cards: Vec<String> = self.cards.iter().filter(|c| &c.column == col).map(|c| format!("{} [{}]", c.title, c.id)).collect();
            s.push_str(&format!("- {col}: {}\n", if cards.is_empty() { "(empty)".into() } else { cards.join("; ") }));
        }
        s
    }
}

fn clip_title(t: &str) -> Result<String, String> {
    let t = t.trim();
    if t.is_empty() {
        return Err("Give it a title.".into());
    }
    Ok(util::clip(t, TITLE_MAX))
}

impl Team {
    fn boards_dir(&self) -> std::path::PathBuf {
        self.paths.root.join("boards")
    }

    fn board_path(&self, id: &str) -> Option<std::path::PathBuf> {
        id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-').then(|| self.boards_dir().join(format!("{id}.json")))
    }

    /// Every board, most recently changed first.
    pub fn boards(&self) -> Vec<Board> {
        let mut out: Vec<Board> = std::fs::read_dir(self.boards_dir())
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .filter_map(|e| serde_json::from_slice(&std::fs::read(e.path()).ok()?).ok())
            .collect();
        out.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        out
    }

    /// A board by its id, or by its title (any case).
    pub fn board(&self, id_or_title: &str) -> Result<Board, String> {
        let k = id_or_title.trim();
        if let Some(p) = self.board_path(k) {
            if let Ok(b) = std::fs::read(&p) {
                return serde_json::from_slice(&b).map_err(|e| e.to_string());
            }
        }
        self.boards().into_iter().find(|b| b.title.eq_ignore_ascii_case(k)).ok_or_else(|| format!("No board called “{k}”."))
    }

    fn save_board(&self, b: &mut Board) -> Result<(), String> {
        b.updated_at = util::now();
        let p = self.board_path(&b.id).ok_or("Not a board id.")?;
        std::fs::create_dir_all(self.boards_dir()).map_err(|e| e.to_string())?;
        util::write_json(&p, b)?;
        self.emit(TeamEvent::Board { id: b.id.clone() });
        Ok(())
    }

    pub fn create_board(&self, title: &str, columns: Option<Vec<String>>, by: &str) -> Result<Board, String> {
        if self.boards().len() >= MAX_BOARDS {
            return Err(format!("{MAX_BOARDS} boards is the most: finish or delete one first."));
        }
        let title = clip_title(title)?;
        let columns: Vec<String> = match columns {
            Some(c) => c.into_iter().map(|c| util::clip(c.trim(), 40)).filter(|c| !c.is_empty()).collect(),
            None => DEFAULT_COLUMNS.iter().map(|c| c.to_string()).collect(),
        };
        if !(2..=8).contains(&columns.len()) {
            return Err("A board has 2 to 8 columns.".into());
        }
        let now = util::now();
        let mut b = Board { id: util::new_id(&title), title, columns, cards: Vec::new(), created_by: by.into(), at: now, updated_at: now };
        self.save_board(&mut b)?;
        Ok(b)
    }

    pub fn add_card(&self, board: &str, title: &str, notes: &str, column: Option<&str>, by: &str) -> Result<(Board, Card), String> {
        let mut b = self.board(board)?;
        if b.cards.len() >= MAX_CARDS {
            return Err(format!("{MAX_CARDS} cards is the most on one board."));
        }
        let card = Card { id: util::new_id("card"), title: clip_title(title)?, notes: util::clip(notes.trim(), NOTES_MAX), column: b.column(column)?, by: by.into(), at: util::now() };
        b.cards.push(card.clone());
        self.save_board(&mut b)?;
        Ok((b, card))
    }

    pub fn move_card(&self, board: &str, card: &str, column: &str, before: Option<&str>, by: &str) -> Result<Board, String> {
        let mut b = self.board(board)?;
        let col = b.column(Some(column))?;
        let c = b.card_mut(card)?;
        c.column = col;
        c.by = by.into();
        c.at = util::now();
        let moved = c.clone();
        // Its place among the cards: before another, or at the end of its column.
        b.cards.retain(|x| x.id != moved.id);
        let at = before.and_then(|id| b.cards.iter().position(|x| x.id == id)).unwrap_or(b.cards.len());
        b.cards.insert(at, moved);
        self.save_board(&mut b)?;
        Ok(b)
    }

    pub fn edit_card(&self, board: &str, card: &str, title: Option<&str>, notes: Option<&str>, by: &str) -> Result<Board, String> {
        let mut b = self.board(board)?;
        let c = b.card_mut(card)?;
        if let Some(t) = title {
            c.title = clip_title(t)?;
        }
        if let Some(n) = notes {
            c.notes = util::clip(n.trim(), NOTES_MAX);
        }
        c.by = by.into();
        c.at = util::now();
        self.save_board(&mut b)?;
        Ok(b)
    }

    pub fn delete_card(&self, board: &str, card: &str) -> Result<Board, String> {
        let mut b = self.board(board)?;
        let id = b.card_mut(card)?.id.clone();
        b.cards.retain(|c| c.id != id);
        self.save_board(&mut b)?;
        Ok(b)
    }

    /// Only the person deletes a board.
    pub fn delete_board(&self, id: &str) -> Result<(), String> {
        let b = self.board(id)?;
        let p = self.board_path(&b.id).ok_or("Not a board id.")?;
        std::fs::remove_file(p).map_err(|e| e.to_string())?;
        self.emit(TeamEvent::Board { id: b.id });
        Ok(())
    }
}

/// The `board` tool: an agent keeps a board as it works.
pub(crate) fn board_tool(team: Weak<Team>, agent: String) -> Arc<dyn Tool> {
    Arc::new(tool(
        "board",
        "Keep a board the person can watch and change: columns of cards (default To do, Doing, Waiting on you, Done). Use one \
         for work with several parts or that lasts beyond this chat: make it, add a card per part, move cards as you go, put \
         what the person must decide in Waiting on you. Show it in your answer with a ```board block holding its id. \
         Actions: list, read (board), create (title, columns?), add (board, title, notes?, column?), move (board, card, column), \
         edit (board, card, title?, notes?). A board or card is named by its id or title.",
        json!({"type": "object", "properties": {
            "action": {"type": "string", "enum": ["list", "read", "create", "add", "move", "edit"]},
            "board": {"type": "string"},
            "title": {"type": "string"},
            "notes": {"type": "string"},
            "column": {"type": "string"},
            "card": {"type": "string"},
            "columns": {"type": "array", "items": {"type": "string"}, "minItems": 2, "maxItems": 8}
        }, "required": ["action"]}),
        // Cookie's own board: nothing outside changes, so no yes is needed.
        Effect::Read,
        move |args: Value| {
            let (team, agent) = (team.clone(), agent.clone());
            async move {
                let team = team.upgrade().ok_or("Cookie is closing.")?;
                let s = |k: &str| args[k].as_str().unwrap_or("").to_string();
                let board = s("board");
                match s("action").as_str() {
                    "list" => {
                        let bs = team.boards();
                        Ok(if bs.is_empty() { "No boards yet.".into() } else { bs.iter().map(|b| format!("“{}” ({}), {} cards", b.title, b.id, b.cards.len())).collect::<Vec<_>>().join("\n") })
                    }
                    "read" => Ok(team.board(&board)?.summary()),
                    "create" => {
                        let cols = args["columns"].as_array().map(|a| a.iter().filter_map(|c| c.as_str().map(str::to_string)).collect());
                        let b = team.create_board(&s("title"), cols, &agent)?;
                        Ok(format!("Made board “{}” ({}). Columns: {}. Show it with:\n```board\n{}\n```", b.title, b.id, b.columns.join(", "), b.id))
                    }
                    "add" => {
                        let (b, c) = team.add_card(&board, &s("title"), &s("notes"), args["column"].as_str(), &agent)?;
                        Ok(format!("Added “{}” [{}] to {} on “{}”.", c.title, c.id, c.column, b.title))
                    }
                    "move" => {
                        let b = team.move_card(&board, &s("card"), &s("column"), None, &agent)?;
                        Ok(format!("Moved. {}", b.summary()))
                    }
                    "edit" => {
                        let b = team.edit_card(&board, &s("card"), args["title"].as_str(), args["notes"].as_str(), &agent)?;
                        Ok(format!("Updated the card on “{}”.", b.title))
                    }
                    other => Err(format!("`{other}` isn't a board action: list, read, create, add, move or edit.")),
                }
            }
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_board_keeps_cards_in_its_columns_and_moves_them() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        let b = team.create_board("Launch", None, "w").unwrap();
        assert_eq!(b.columns, DEFAULT_COLUMNS);
        let (_, c) = team.add_card(&b.id, "Write the note", "", None, "w").unwrap();
        assert_eq!(c.column, "To do", "a card starts in the first column");
        team.add_card("launch", "Pick the date", "", Some("waiting on you"), "w").unwrap();
        let b = team.move_card(&b.id, &c.id, "doing", None, "you").unwrap();
        let moved = b.cards.iter().find(|x| x.id == c.id).unwrap();
        assert_eq!((moved.column.as_str(), moved.by.as_str()), ("Doing", "you"));
        assert!(team.move_card(&b.id, &c.id, "Nowhere", None, "w").unwrap_err().contains("columns are"));
        let b = team.edit_card(&b.id, "Write the note", None, Some("Draft in notes.md"), "w").unwrap();
        assert!(b.summary().contains("- Doing: Write the note"));
        assert_eq!(b.cards.iter().find(|x| x.id == c.id).unwrap().notes, "Draft in notes.md");
        team.delete_card(&b.id, &c.id).unwrap();
        assert_eq!(team.board(&b.id).unwrap().cards.len(), 1);
        team.delete_board(&b.id).unwrap();
        assert!(team.boards().is_empty());
    }

    #[test]
    fn what_a_board_refuses() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        assert!(team.create_board(" ", None, "w").is_err());
        assert!(team.create_board("x", Some(vec!["one".into()]), "w").unwrap_err().contains("2 to 8"));
        assert!(team.board("../../etc/passwd").is_err(), "an id never names a path outside the boards folder");
        let b = team.create_board("Ship", Some(vec!["Now".into(), "Later".into()]), "w").unwrap();
        assert!(team.add_card(&b.id, "", "", None, "w").is_err());
    }
}
