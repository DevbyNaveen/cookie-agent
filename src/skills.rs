//! Agent Skills (`SKILL.md`): offered through one `use_skill` tool whose
//! description lists them, loaded only when the model asks. Nothing is added
//! to the developer's instructions.

use std::{
    fs,
    path::{Path, PathBuf},
};

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::{
    error::{Error, Result},
    tool::{Effect, Tool, ToolSpec},
};

#[derive(Debug, Clone, PartialEq)]
pub struct Skill {
    pub name: String,
    pub description: String,
    pub path: PathBuf,
    body: String,
}

#[derive(Debug, Clone, Default)]
pub struct Skills {
    skills: Vec<Skill>,
}

/// `---` frontmatter of `key: value` lines (values may be quoted), then the body.
fn parse(text: &str, path: &Path) -> Result<Skill> {
    let fail = |why: &str| Error::Skill(format!("{}: {why}", path.display()));
    let rest = text.strip_prefix("---").ok_or_else(|| fail("must start with --- frontmatter"))?;
    let end = rest.find("\n---").ok_or_else(|| fail("frontmatter is not closed with ---"))?;
    let (front, body) = (&rest[..end], &rest[end + 4..]);
    let field = |key: &str| {
        front.lines().find_map(|line| {
            let (k, v) = line.split_once(':')?;
            (k.trim() == key).then(|| v.trim().trim_matches('"').trim_matches('\'').to_string())
        })
    };
    let name = field("name").filter(|n| !n.is_empty()).ok_or_else(|| fail("frontmatter needs a name"))?;
    let description = field("description").filter(|d| !d.is_empty()).ok_or_else(|| fail("frontmatter needs a description"))?;
    Ok(Skill { name, description, path: path.to_path_buf(), body: body.trim().to_string() })
}

impl Skills {
    /// Every `<dir>/*/SKILL.md`. Folders without one are skipped.
    pub fn from_dir(dir: impl AsRef<Path>) -> Result<Self> {
        let mut skills: Vec<Skill> = Vec::new();
        for entry in fs::read_dir(dir.as_ref())? {
            let path = entry?.path().join("SKILL.md");
            if !path.is_file() {
                continue;
            }
            let skill = parse(&fs::read_to_string(&path)?, &path)?;
            if skills.iter().any(|s| s.name == skill.name) {
                return Err(Error::Skill(format!("two skills are called `{}`", skill.name)));
            }
            skills.push(skill);
        }
        skills.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(Self { skills })
    }

    pub fn list(&self) -> &[Skill] {
        &self.skills
    }

    /// The `use_skill` tool: its description lists every skill; calling it
    /// returns one skill's instructions.
    pub fn tool(&self) -> SkillTool {
        let listing: Vec<String> = self.skills.iter().map(|s| format!("- {}: {}", s.name, s.description)).collect();
        let names: Vec<&str> = self.skills.iter().map(|s| s.name.as_str()).collect();
        SkillTool {
            spec: ToolSpec {
                name: "use_skill".into(),
                description: format!("Load a skill's full instructions when the task needs it. Available skills:\n{}", listing.join("\n")),
                schema: json!({"type": "object", "properties": {"name": {"type": "string", "enum": names}}, "required": ["name"]}),
                effect: Effect::Read,
                guarded_args: Vec::new(),
                parallel_safe: true,
            },
            skills: self.skills.clone(),
        }
    }
}

pub struct SkillTool {
    spec: ToolSpec,
    skills: Vec<Skill>,
}

#[async_trait]
impl Tool for SkillTool {
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    async fn call(&self, args: Value) -> std::result::Result<String, String> {
        let name = args["name"].as_str().unwrap_or_default();
        self.skills
            .iter()
            .find(|s| s.name == name)
            .map(|s| s.body.clone())
            .ok_or_else(|| format!("There is no skill called `{name}`."))
    }
}

/// `<dir>/AGENTS.md`, if there is one. Pass it to `Agent::instructions`
/// yourself; the harness never adds it on its own.
pub fn read_agents_md(dir: impl AsRef<Path>) -> Result<Option<String>> {
    match fs::read_to_string(dir.as_ref().join("AGENTS.md")) {
        Ok(text) => Ok(Some(text)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tool::{Effect, Tool};
    use serde_json::json;

    fn write(dir: &std::path::Path, folder: &str, text: &str) {
        std::fs::create_dir_all(dir.join(folder)).unwrap();
        std::fs::write(dir.join(folder).join("SKILL.md"), text).unwrap();
    }

    #[tokio::test]
    async fn offers_skills_by_description_and_loads_one_on_request() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "pdf", "---\nname: pdf\ndescription: \"Fill and read PDF forms\"\n---\n# PDF\nUse the form tool.\n");
        write(dir.path(), "brand", "---\nname: brand-voice\ndescription: Write in the company's voice\nlicense: MIT\n---\nShort sentences.\n");
        std::fs::create_dir_all(dir.path().join("empty")).unwrap();
        let skills = Skills::from_dir(dir.path()).unwrap();
        let tool = skills.tool();
        assert_eq!(tool.spec().name, "use_skill");
        assert_eq!(tool.spec().effect, Effect::Read);
        assert!(tool.spec().description.contains("- brand-voice: Write in the company's voice"));
        assert!(tool.spec().description.contains("- pdf: Fill and read PDF forms"));
        assert_eq!(tool.spec().schema["properties"]["name"]["enum"], json!(["brand-voice", "pdf"]));
        assert_eq!(tool.call(json!({"name": "pdf"})).await.unwrap(), "# PDF\nUse the form tool.");
        assert!(tool.call(json!({"name": "nope"})).await.is_err());
    }

    #[test]
    fn a_skill_without_a_name_or_description_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "bad", "---\nname: bad\n---\nbody\n");
        assert!(matches!(Skills::from_dir(dir.path()), Err(crate::Error::Skill(m)) if m.contains("description")));
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "plain", "no frontmatter at all");
        assert!(Skills::from_dir(dir.path()).is_err());
    }

    #[test]
    fn two_skills_with_the_same_name_are_an_error() {
        let dir = tempfile::tempdir().unwrap();
        write(dir.path(), "a", "---\nname: same\ndescription: one\n---\nx\n");
        write(dir.path(), "b", "---\nname: same\ndescription: two\n---\ny\n");
        assert!(Skills::from_dir(dir.path()).is_err());
    }

    #[test]
    fn reads_agents_md_when_there_is_one() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(read_agents_md(dir.path()).unwrap(), None);
        std::fs::write(dir.path().join("AGENTS.md"), "Run tests with cargo test.").unwrap();
        assert_eq!(read_agents_md(dir.path()).unwrap().as_deref(), Some("Run tests with cargo test."));
    }
}
