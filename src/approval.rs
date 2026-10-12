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
}

#[async_trait]
pub trait Approver: Send + Sync {
    async fn approve(&self, request: &ApprovalRequest) -> bool;
}

/// The default: nothing that needs a person runs until the app supplies one.
pub struct DenyAll;

#[async_trait]
impl Approver for DenyAll {
    async fn approve(&self, _: &ApprovalRequest) -> bool {
        false
    }
}

pub struct FnApprover<F>(pub F);

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
        ApprovalRequest { tool: "send_email".into(), effect: Effect::Outbound, preview: "p".into(), reason: "r".into() }
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
