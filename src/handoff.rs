//! Handoff: the agent passes the conversation to another agent, which
//! carries on in the same session — the same history, the same person's
//! words, the same budget. One agent is active at a time.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::{
    agent::{Agent, Event, RunControl, Start, Turn},
    budget::Meter,
    error::{Error, Result},
    message::Message,
    session::Session,
    tool::{Effect, Tool, ToolContext, ToolSpec},
};

/// Handoffs in one run before it is stopped as a loop.
pub const MAX_HOPS: usize = 5;

pub struct Handoff {
    spec: ToolSpec,
    agent: Arc<Agent>,
}

impl Handoff {
    /// A tool named `name` that hands the conversation to `agent`. The next
    /// agent asks the same person (it inherits the approver unless it has its own).
    pub fn to(name: &str, description: &str, agent: Agent) -> Self {
        Self {
            spec: ToolSpec {
                name: name.to_string(),
                description: format!("Hand this conversation to another agent: {description}"),
                schema: json!({
                    "type": "object",
                    "properties": {"note": {"type": "string", "description": "Anything the next agent should know."}},
                }),
                effect: Effect::Read,
                guarded_args: Vec::new(),
                parallel_safe: false,
                delegates: false,
                foreign: false,
            },
            agent: Arc::new(agent),
        }
    }
}

#[async_trait]
impl Tool for Handoff {
    fn spec(&self) -> &ToolSpec {
        &self.spec
    }

    /// Fails closed outside a loop: there is no conversation to hand over.
    async fn call(&self, _args: Value) -> std::result::Result<String, String> {
        Err("a handoff runs only inside an agent's loop".into())
    }

    async fn call_in(&self, _args: Value, context: &ToolContext) -> std::result::Result<String, String> {
        let mut slot = context.handoff.lock().expect("handoff lock");
        if let Some((taken, _)) = &*slot {
            return Err(format!("The conversation is already being handed to {taken}; only one handoff per turn."));
        }
        *slot = Some((self.spec.name.clone(), self.agent.clone()));
        Ok(format!("Handed the conversation to {}.", self.spec.name))
    }
}

impl Agent {
    /// Run turns, following handoffs: each next agent continues the same
    /// session with the same meter, budget and trust.
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn drive(
        &self,
        session: &mut Session,
        input: Message,
        control: &RunControl,
        on_event: &mut (dyn FnMut(Event) + Send),
        open: &mut Vec<String>,
        start: Start,
        meter: &mut Meter,
    ) -> Result<String> {
        let mut input = Some(input);
        let mut start = start;
        let mut next: Option<Arc<Agent>> = None;
        for _ in 0..=MAX_HOPS {
            let agent: &Agent = next.as_deref().unwrap_or(self);
            let (provenance, budget, depth, ceiling) = (start.provenance.clone(), start.budget, start.depth, start.ceiling.clone());
            let approver = agent.approver.clone().or(start.inherited_approver.clone());
            match agent.turns(session, input.take(), control, on_event, open, start, meter).await? {
                Turn::Answer(answer) => return Ok(answer),
                Turn::HandOff(name, to) => {
                    // A new turn for the next agent: it may use another provider,
                    // which can't continue a tool turn it did not start (thinking
                    // blocks, signatures). Visible in the session, never the person's.
                    session.append(Message::delegated(format!("(The conversation is now with {name}.)"))).await?;
                    on_event(Event::HandedOff { to: name });
                    let extra = to.enkeon_tools(depth > 0, &control.cancel, on_event).await?;
                    // The next agent's own limits apply too: the stricter of each.
                    let budget = budget.min(&to.budget);
                    start = Start { provenance, budget, depth, extra, ceiling, inherited_approver: approver };
                    next = Some(to);
                }
            }
        }
        Err(Error::Loop(format!("handoff: the agents handed the conversation on more than {MAX_HOPS} times")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        agent::{Agent, Event},
        approval::{ApprovalRequest, FnApprover},
        providers::scripted::Scripted,
        tool::{tool, Effect},
        Message, RunControl, Session,
    };
    use serde_json::json;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    fn scripted(script: Vec<crate::provider::ModelResponse>) -> (Arc<Scripted>, Agent) {
        let p = Arc::new(Scripted::new(script));
        (p.clone(), Agent::with_provider(p, "m"))
    }

    #[tokio::test]
    async fn the_next_agent_carries_on_in_the_same_conversation() {
        let (billing_p, billing) = scripted(vec![Scripted::text("Your invoice is 40 EUR.")]);
        let (_, front) = scripted(vec![Scripted::call("h1", "billing", json!({"note": "asks about an invoice"}))]);
        let front = front.tool(Handoff::to("billing", "Questions about invoices", billing));
        let mut session = Session::in_memory();
        let mut events = Vec::new();
        let answer = front
            .run_streaming(&mut session, Message::user("how much is my invoice?"), &RunControl::default(), &mut |e| events.push(e))
            .await
            .unwrap();
        assert_eq!(answer, "Your invoice is 40 EUR.");
        let saw = &billing_p.seen()[0];
        assert_eq!(saw[0].text(), "how much is my invoice?", "the whole conversation, not a fresh context");
        assert!(events.iter().any(|e| matches!(e, Event::HandedOff { to } if to == "billing")));
    }

    #[tokio::test]
    async fn the_person_words_stay_credited_after_a_handoff() {
        let sent = Arc::new(AtomicUsize::new(0));
        let count = sent.clone();
        let send = tool("send_email", "Send", json!({"type": "object"}), Effect::Outbound, move |_| {
            let count = count.clone();
            async move {
                count.fetch_add(1, Ordering::SeqCst);
                Ok("sent".to_string())
            }
        })
        .guard("to");
        let (_, mailer) = scripted(vec![Scripted::call("e1", "send_email", json!({"to": "anna@x.com"})), Scripted::text("sent")]);
        let mailer = mailer.tool(send);
        let (_, front) = scripted(vec![Scripted::call("h1", "mailer", json!({}))]);
        let front = front.tool(Handoff::to("mailer", "Sends email", mailer)).approver(FnApprover(|_: &ApprovalRequest| true));
        front.run("email anna@x.com").await.unwrap();
        assert_eq!(sent.load(Ordering::SeqCst), 1, "anna was typed by the person, and the approver carried over");
    }

    #[tokio::test]
    async fn agents_handing_back_and_forth_forever_are_stopped() {
        let ping = || {
            let (_, a) = scripted((0..10).map(|i| Scripted::call(&format!("h{i}"), "other", json!({}))).collect());
            a
        };
        let inner = ping().tool(Handoff::to("other", "x", ping().tool(Handoff::to("other", "x", ping().tool(Handoff::to("other", "x", ping().tool(Handoff::to("other", "x", ping().tool(Handoff::to("other", "x", ping().tool(Handoff::to("other", "x", ping()))))))))))));
        assert!(matches!(inner.run("go").await, Err(crate::Error::Loop(m)) if m.contains("handoff")));
    }

    #[tokio::test]
    async fn the_next_agent_s_own_limits_apply() {
        let (_, strict) = scripted(vec![Scripted::text("never")]);
        let strict = strict.budget(crate::Budget { max_steps: 1, max_tokens: 1_000_000, max_dollars: None });
        let (_, front) = scripted(vec![Scripted::call("h1", "strict", json!({}))]);
        let front = front.tool(Handoff::to("strict", "x", strict));
        assert!(matches!(front.run("go").await, Err(crate::Error::Budget(_))));
    }

    #[tokio::test]
    async fn only_one_handoff_per_turn() {
        let (_, a) = scripted(vec![Scripted::text("from a")]);
        let (_, b) = scripted(vec![Scripted::text("from b")]);
        let (p, front) = scripted(vec![Scripted::call_many(&[("h1", "a", json!({})), ("h2", "b", json!({}))])]);
        let front = front.tool(Handoff::to("a", "x", a)).tool(Handoff::to("b", "x", b));
        let mut session = Session::in_memory();
        let answer = front.run_streaming(&mut session, Message::user("go"), &RunControl::default(), &mut |_| {}).await.unwrap();
        assert_eq!(answer, "from a");
        let results = session.messages()[2].content().to_vec();
        assert!(matches!(&results[1], crate::message::Content::ToolResult { is_error: true, output, .. } if output.contains("only one handoff")));
        let _ = p;
    }

    #[tokio::test]
    async fn the_next_agent_starts_a_fresh_turn() {
        let (p, next) = scripted(vec![Scripted::text("done")]);
        let (_, front) = scripted(vec![Scripted::call("h1", "next", json!({}))]);
        let front = front.tool(Handoff::to("next", "x", next));
        front.run("go").await.unwrap();
        let saw = &p.seen()[0];
        let last = saw.last().unwrap();
        assert_eq!(last.role(), crate::message::Role::User);
        assert!(last.content().iter().all(|c| matches!(c, crate::message::Content::Text { .. })), "not a tool result: a new turn");
        assert!(!last.origin().is_untrusted() && last.origin() != &crate::Origin::User, "a note, not the person's words");
    }
}
