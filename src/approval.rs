//! A person saying yes. Outbound and destroy never run without one.

use async_trait::async_trait;

use crate::tool::Effect;

#[derive(Debug, Clone, PartialEq)]
pub struct ApprovalRequest {
    pub tool: String,
    pub effect: Effect,
    /// What will actually happen: recipient, content, diff, amount.
    pub preview: String,
    pub reason: String,
    /// Guarded values the person didn't write (`arg = value`); empty when
    /// every value was theirs. Show these: they are what to check.
    pub from_data: Vec<String>,
}

#[async_trait]
pub trait Approver: Send + Sync {
    async fn approve(&self, request: &ApprovalRequest) -> bool;

    /// Every action of one turn that needs a person, put to them together (one
    /// card); one answer per request, in order. The default asks one by one.
    async fn approve_batch(&self, requests: &[ApprovalRequest]) -> Vec<bool> {
        let mut answers = Vec::with_capacity(requests.len());
        for request in requests {
            answers.push(self.approve(request).await);
        }
        answers
    }

    /// Whether a person answers (not a rule or a script). Only a person's
    /// approvals can earn trust (see `EarnedTrust`).
    fn is_person(&self) -> bool {
        false
    }
}

/// The default: nothing that needs a person runs until the app supplies one.
pub struct DenyAll;

#[async_trait]
impl Approver for DenyAll {
    async fn approve(&self, _: &ApprovalRequest) -> bool {
        false
    }
}

/// Answers with a function — a rule, a test, a script. Its yeses never earn
/// trust; use `PersonApprover` when the function asks a person.
pub struct FnApprover<F>(pub F);

/// A function that shows the request to a person and returns their answer
/// (your app's approval UI). Its approvals can earn trust.
pub struct PersonApprover<F>(pub F);

#[async_trait]
impl<F> Approver for PersonApprover<F>
where
    F: Fn(&ApprovalRequest) -> bool + Send + Sync,
{
    async fn approve(&self, request: &ApprovalRequest) -> bool {
        (self.0)(request)
    }

    fn is_person(&self) -> bool {
        true
    }
}

#[async_trait]
impl<F> Approver for FnApprover<F>
where
    F: Fn(&ApprovalRequest) -> bool + Send + Sync,
{
    async fn approve(&self, request: &ApprovalRequest) -> bool {
        (self.0)(request)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tool::Effect;

    fn request() -> ApprovalRequest {
        ApprovalRequest { tool: "send_email".into(), effect: Effect::Outbound, preview: "p".into(), reason: "r".into(), from_data: vec![] }
    }

    #[tokio::test]
    async fn the_default_approver_says_no() {
        assert!(!DenyAll.approve(&request()).await);
    }

    #[tokio::test]
    async fn a_closure_can_approve() {
        assert!(FnApprover(|r: &ApprovalRequest| r.tool == "send_email").approve(&request()).await);
    }
}
