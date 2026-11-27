//! When an agent's model is out of reach (an outage, overload, throttling),
//! the job goes on with a backup instead of failing: the harness tries the
//! backups in order (`Agent::fallback_models`) and says so (`Event::FellBack`),
//! and the chat shows "Switched to Opus 5.5: Sonnet 5.5 was out of reach".
//!
//! The backup is the person's own choice when they set one (Settings → the
//! agent's model, `agent.backup_model`). Otherwise Cookie picks it from what
//! this Mac can reach: the same model on another route first (Anthropic, your
//! AWS account, Enkeon), then the next Claude tier on the same route. A model
//! with no key here is never picked, and nothing outside Claude is guessed.

/// The backups for `model`, best first (at most three), from what can be reached.
pub(crate) fn backups(model: &str, chosen: Option<&str>, routes: &Routes) -> Vec<String> {
    if let Some(c) = chosen.map(str::trim).filter(|c| !c.is_empty() && *c != model) {
        return vec![c.to_string()];
    }
    let Some((provider, name)) = model.split_once(':') else { return Vec::new() };
    let Some((region, base)) = claude(provider, name) else { return Vec::new() };
    let on = |route: &str, base: &str| -> Option<String> {
        match route {
            "anthropic" if routes.anthropic => Some(format!("anthropic:{base}")),
            "bedrock" if routes.bedrock => Some(format!("bedrock:{}.anthropic.{base}", region_for(base, &region))),
            "enkeon" if routes.enkeon => Some(format!("enkeon:{}.anthropic.{base}", region_for(base, &region))),
            _ => None,
        }
    };
    let mut out: Vec<String> = Vec::new();
    // The same model, another way in: an outage is usually one provider's.
    for route in ["anthropic", "bedrock", "enkeon"].into_iter().filter(|r| *r != provider) {
        out.extend(on(route, &base));
    }
    // Then a neighbouring tier where this one runs.
    if let Some(next) = sibling(&base) {
        out.extend(on(provider, &next));
    }
    out.retain(|m| m != model);
    out.dedup();
    out.truncate(3);
    out
}

/// Which ways to a model this Mac has right now.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct Routes {
    pub anthropic: bool,
    pub bedrock: bool,
    pub enkeon: bool,
}

impl Routes {
    pub(crate) fn here() -> Self {
        let set = |v: &str| std::env::var(v).is_ok_and(|x| !x.trim().is_empty());
        Routes {
            anthropic: set("ANTHROPIC_API_KEY"),
            bedrock: set("AWS_ACCESS_KEY_ID") && set("AWS_SECRET_ACCESS_KEY"),
            enkeon: set("ENKEON_MODEL_BASE") && set("ENKEON_MODEL_KEY"),
        }
    }
}

/// A Claude model's region prefix (Bedrock and Enkeon) and its plain name.
fn claude(provider: &str, name: &str) -> Option<(String, String)> {
    match provider {
        "anthropic" => name.starts_with("claude-").then(|| ("eu".to_string(), name.to_string())),
        "bedrock" | "enkeon" => {
            let (region, rest) = name.split_once(".anthropic.")?;
            let base = rest.split(['-', ':']).collect::<Vec<_>>();
            // `claude-haiku-4-5-20251001-v1:0` keeps its dated id; the plain name is what Anthropic serves too.
            let plain = if rest.contains("-v1") { base.iter().take(4).cloned().collect::<Vec<_>>().join("-") } else { rest.to_string() };
            plain.starts_with("claude-").then(|| (region.to_string(), plain))
        }
        _ => None,
    }
}

/// Fable is offered only worldwide on AWS; the rest stay where they were (the EU by default).
fn region_for(base: &str, region: &str) -> String {
    if base.contains("fable") { "global".into() } else if region == "global" { "eu".into() } else { region.into() }
}

/// The next tier to try: Sonnet ↔ Opus, Haiku → Sonnet, Fable → Opus, same generation.
fn sibling(base: &str) -> Option<String> {
    // `claude-sonnet-5-5`: the tier, then the generation.
    let mut parts = base.splitn(3, '-');
    let (_, tier, version) = (parts.next()?, parts.next()?, parts.next().filter(|v| !v.is_empty())?);
    Some(match tier {
        "sonnet" => format!("claude-opus-{version}"),
        "opus" | "haiku" => format!("claude-sonnet-{version}"),
        "fable" => "claude-opus-5-5".to_string(),
        _ => return None,
    })
}

/// The model a run hands over to when it gets stuck (`Agent::escalate_to`): the
/// strongest Claude on the same route, when this one isn't it already. Haiku
/// and Sonnet go to Opus; Opus goes to Fable; Fable has nowhere further.
pub(crate) fn stronger(model: &str) -> Option<String> {
    let (provider, name) = model.split_once(':')?;
    let (region, base) = claude(provider, name)?;
    let mut parts = base.splitn(3, '-');
    let (_, tier, version) = (parts.next()?, parts.next()?, parts.next().filter(|v| !v.is_empty())?);
    let up = match tier {
        "haiku" | "sonnet" => format!("claude-opus-{version}"),
        "opus" => "claude-fable-5-2".to_string(),
        _ => return None,
    };
    Some(match provider {
        "anthropic" => format!("anthropic:{up}"),
        route => format!("{route}:{}.anthropic.{up}", region_for(&up, &region)),
    })
}

/// The tier below `model` on the same route, for routine steps: Fable to Opus, Opus to Sonnet,
/// Sonnet to Haiku. Haiku has nothing below it.
pub(crate) fn cheaper(model: &str) -> Option<String> {
    let (provider, name) = model.split_once(':')?;
    let (region, base) = claude(provider, name)?;
    let mut parts = base.splitn(3, '-');
    let (_, tier, version) = (parts.next()?, parts.next()?, parts.next().filter(|v| !v.is_empty())?);
    let down = match tier {
        "fable" => "claude-opus-5-5".to_string(),
        "opus" => format!("claude-sonnet-{version}"),
        "sonnet" => format!("claude-haiku-{version}"),
        _ => return None,
    };
    Some(match provider {
        "anthropic" => format!("anthropic:{down}"),
        route => format!("{route}:{}.anthropic.{down}", region_for(&down, &region)),
    })
}

/// The family a model comes from: Claude on any route is one family; OpenAI, Gemini and a
/// local model each another. A judge from another family doesn't share its blind spots.
pub(crate) fn family(model: &str) -> &'static str {
    let (provider, name) = model.split_once(':').unwrap_or(("", model));
    match provider {
        "anthropic" => "claude",
        "bedrock" | "enkeon" if name.contains("anthropic.") || name.contains("claude") => "claude",
        "bedrock" | "enkeon" => "other-cloud",
        "openai" => "openai",
        "gemini" => "gemini",
        "ollama" => "local",
        // Through OpenRouter, a model is its lab's.
        "openrouter" => match name.split('/').next().unwrap_or("") {
            "anthropic" => "claude",
            "openai" => "openai",
            "google" => "gemini",
            "" => "unknown",
            _ => "other-lab",
        },
        _ => "unknown",
    }
}

/// A judge for `model` from another family, among the models this person already set up
/// (their agents, backups and checker), never one guessed by name.
pub(crate) fn other_family<'a>(model: &str, set_up: impl IntoIterator<Item = &'a String>) -> Option<String> {
    let mine = family(model);
    set_up.into_iter().find(|m| family(m) != mine && family(m) != "unknown").cloned()
}

/// "Sonnet 5.5" from any route's id, for the words on screen.
pub(crate) fn short(model: &str) -> String {
    let name = model.split_once(':').map(|(_, n)| n).unwrap_or(model);
    let name = name.rsplit(".anthropic.").next().unwrap_or(name);
    let parts: Vec<&str> = name.split('-').collect();
    if parts.first() == Some(&"claude") && parts.len() >= 3 {
        let tier = parts[1];
        let mut t = tier.chars();
        let tier = t.next().map(|c| c.to_uppercase().collect::<String>() + t.as_str()).unwrap_or_default();
        let major = parts[2];
        let minor = parts.get(3).filter(|m| m.len() <= 2 && m.chars().all(|c| c.is_ascii_digit()));
        return match minor { Some(m) => format!("{tier} {major}.{m}"), None => format!("{tier} {major}") };
    }
    name.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routine_steps_go_one_tier_down() {
        assert_eq!(cheaper("anthropic:claude-sonnet-5-5").as_deref(), Some("anthropic:claude-haiku-5-5"));
        assert_eq!(cheaper("anthropic:claude-fable-5-2").as_deref(), Some("anthropic:claude-opus-5-5"));
        assert_eq!(cheaper("anthropic:claude-haiku-5-5"), None);
    }

    #[test]
    fn a_judge_comes_from_another_family_the_person_already_uses() {
        let set_up = vec!["anthropic:claude-opus-5-5".to_string(), "bedrock:eu.anthropic.claude-sonnet-4-6".to_string(), "openai:gpt-6".to_string()];
        assert_eq!(other_family("anthropic:claude-sonnet-5-5", &set_up).as_deref(), Some("openai:gpt-6"));
        assert_eq!(other_family("openai:gpt-6", &set_up).as_deref(), Some("anthropic:claude-opus-5-5"));
        assert_eq!(other_family("anthropic:claude-sonnet-5-5", &set_up[..2]), None, "all Claude: no other family to use");
        assert_eq!(family("openrouter:anthropic/claude-sonnet-4.5"), "claude", "through OpenRouter, still Claude");
        assert_eq!(family("openrouter:google/gemini-2.5-pro"), "gemini");
    }

    #[test]
    fn a_stuck_run_goes_up_one_tier_on_the_same_route() {
        assert_eq!(stronger("anthropic:claude-sonnet-5-5").as_deref(), Some("anthropic:claude-opus-5-5"));
        assert_eq!(stronger("anthropic:claude-opus-5-5").as_deref(), Some("anthropic:claude-fable-5-2"));
        assert_eq!(stronger("bedrock:eu.anthropic.claude-haiku-5-5").as_deref(), Some("bedrock:eu.anthropic.claude-opus-5-5"));
        assert_eq!(stronger("anthropic:claude-fable-5-2"), None, "nowhere further");
        assert_eq!(stronger("openai:gpt-6"), None, "nothing outside Claude is guessed");
    }

    const ALL: Routes = Routes { anthropic: true, bedrock: true, enkeon: true };

    #[test]
    fn the_same_model_another_way_in_comes_first() {
        assert_eq!(
            backups("anthropic:claude-sonnet-5-5", None, &ALL),
            vec!["bedrock:eu.anthropic.claude-sonnet-5-5", "enkeon:eu.anthropic.claude-sonnet-5-5", "anthropic:claude-opus-5-5"]
        );
        assert_eq!(backups("enkeon:eu.anthropic.claude-sonnet-5-5", None, &ALL)[0], "anthropic:claude-sonnet-5-5");
    }

    #[test]
    fn only_routes_this_mac_has_and_never_a_guess_outside_claude() {
        let only_key = Routes { anthropic: true, ..Routes::default() };
        assert_eq!(backups("anthropic:claude-sonnet-5-5", None, &only_key), vec!["anthropic:claude-opus-5-5"]);
        assert!(backups("openai:gpt-6", None, &ALL).is_empty());
        assert!(backups("ollama:llama4", None, &ALL).is_empty());
    }

    #[test]
    fn the_persons_choice_wins_and_fable_runs_worldwide() {
        assert_eq!(backups("anthropic:claude-sonnet-5-5", Some("openai:gpt-6"), &ALL), vec!["openai:gpt-6"]);
        assert_eq!(backups("anthropic:claude-fable-5-2", None, &ALL)[0], "bedrock:global.anthropic.claude-fable-5-2");
        assert_eq!(backups("bedrock:eu.anthropic.claude-haiku-4-5-20251001-v1:0", None, &ALL)[0], "anthropic:claude-haiku-4-5");
    }

    #[test]
    fn names_read_as_people_say_them() {
        assert_eq!(short("anthropic:claude-sonnet-5-5"), "Sonnet 5.5");
        assert_eq!(short("bedrock:global.anthropic.claude-fable-5-2"), "Fable 5.2");
        assert_eq!(short("openai:gpt-6"), "gpt-6");
    }
}
