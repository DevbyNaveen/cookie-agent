//! Data: SQL over the world's CSV files and SQLite databases (`sqlite3`).
//!
//! A query names its tables as CSV files in the world (`tables: {"sales":
//! "data/sales.csv"}`), which are loaded into a fresh in-memory database for
//! that query only; or it runs on a `.sqlite`/`.db` file in the world.
//! Reading queries are reads; `save` writes a query's result as a CSV file.

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::engine::{s, ActionSpec, Ctx, Effect, Engine};

pub struct Data;

/// A table name SQLite takes without quoting.
fn table_name(n: &str) -> bool {
    !n.is_empty() && n.len() <= 40 && n.chars().next().is_some_and(|c| c.is_ascii_alphabetic()) && n.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// A query that only reads: one statement starting with SELECT or WITH.
pub fn reads_only(sql: &str) -> bool {
    let t = sql.trim().trim_end_matches(';').trim().to_ascii_lowercase();
    (t.starts_with("select") || t.starts_with("with")) && !t.contains(';')
}

impl Data {
    async fn query(&self, ctx: &Ctx, args: &Value, csv_out: bool) -> Result<String, String> {
        let sqlite = super::tool(&["sqlite3"]).ok_or("The data engine uses sqlite3; it isn't on this machine.")?;
        let sql = s(args, "sql")?;
        if !reads_only(sql) {
            return Err("A query here only reads: one SELECT (or WITH … SELECT).".into());
        }
        let mut script = String::new();
        script.push_str(if csv_out { ".mode csv\n.headers on\n" } else { ".mode json\n" });
        let db = match args["db"].as_str() {
            Some(d) => ctx.path(d)?.to_string_lossy().to_string(),
            None => ":memory:".into(),
        };
        if let Some(tables) = args["tables"].as_object() {
            for (name, file) in tables {
                if !table_name(name) {
                    return Err(format!("“{name}” isn't a table name (letters, digits, _)."));
                }
                let f = ctx.path(file.as_str().ok_or("Each table is a CSV path.")?)?;
                script.push_str(&format!(".import --csv '{}' {name}\n", f.to_string_lossy().replace('\'', "''")));
            }
        }
        script.push_str(sql.trim().trim_end_matches(';'));
        script.push_str(";\n");
        // A file is opened read-only; the in-memory database must take the imports.
        let mut cmd = tokio::process::Command::new(&sqlite);
        if db != ":memory:" {
            cmd.arg("-readonly");
        }
        let mut child = cmd.arg(&db).current_dir(&ctx.files).stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped()).kill_on_drop(true).spawn().map_err(|e| e.to_string())?;
        use tokio::io::AsyncWriteExt;
        child.stdin.take().ok_or("sqlite3 has no input")?.write_all(script.as_bytes()).await.map_err(|e| e.to_string())?;
        let out = tokio::time::timeout(std::time::Duration::from_secs(60), child.wait_with_output()).await.map_err(|_| "The query took over a minute.")?.map_err(|e| e.to_string())?;
        let err = String::from_utf8_lossy(&out.stderr);
        if !out.status.success() || err.contains("Error") {
            return Err(format!("sqlite3: {}", err.trim().chars().take(600).collect::<String>()));
        }
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    }
}

#[async_trait]
impl Engine for Data {
    fn name(&self) -> &'static str {
        "data"
    }

    fn actions(&self) -> Vec<ActionSpec> {
        let base = json!({"sql": {"type": "string"}, "tables": {"type": "object", "description": "table name → CSV path in the world"}, "db": {"type": "string", "description": "a .sqlite file in the world, instead of tables"}});
        let mut save = base.clone();
        save["to"] = json!({"type": "string"});
        vec![
            ActionSpec::new("data", "query", "Run one SELECT over CSV files (as tables) or a SQLite file; rows come back as JSON.", json!({"type": "object", "properties": base, "required": ["sql"]}), Effect::Read),
            ActionSpec::new("data", "save", "Run one SELECT and write the result as a CSV file in the world.", json!({"type": "object", "properties": save, "required": ["sql", "to"]}), Effect::Local),
        ]
    }

    async fn call(&self, ctx: &Ctx, action: &str, args: &Value) -> Result<Value, String> {
        match action {
            "query" => {
                let out = self.query(ctx, args, false).await?;
                let rows: Value = if out.trim().is_empty() { json!([]) } else { serde_json::from_str(&out).map_err(|e| e.to_string())? };
                let n = rows.as_array().map(|a| a.len()).unwrap_or(0);
                let rows = Value::Array(rows.as_array().cloned().unwrap_or_default().into_iter().take(1_000).collect());
                Ok(json!({"rows": rows, "count": n}))
            }
            "save" => {
                let out = self.query(ctx, args, true).await?;
                let to = s(args, "to")?;
                std::fs::write(ctx.path(to)?, out).map_err(|e| e.to_string())?;
                Ok(json!({"written": to}))
            }
            other => Err(format!("The data engine has no action {other}.")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_reading_queries() {
        assert!(reads_only("SELECT * FROM t"));
        assert!(reads_only("with x as (select 1) select * from x;"));
        assert!(!reads_only("DELETE FROM t"));
        assert!(!reads_only("select 1; drop table t"));
    }

    #[tokio::test]
    async fn sql_over_a_csv() {
        if crate::engines::tool(&["sqlite3"]).is_none() {
            return;
        }
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("sales.csv"), "who,amount\nana,10\nbo,32\nana,5\n").unwrap();
        let ctx = Ctx { world: "w".into(), files: d.path().to_path_buf(), state: d.path().join(".parallax"), home: d.path().join("home") };
        let r = Data.call(&ctx, "query", &json!({"sql": "select who, sum(amount) as total from sales group by who order by total desc", "tables": {"sales": "sales.csv"}})).await.unwrap();
        assert_eq!(r["rows"][0]["who"], "bo");
        assert_eq!(r["rows"][1]["total"], 15);
    }
}
