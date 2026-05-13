use super::{PolicyContext, PolicyDecision, SwitchContext, SwitchPolicy};
use async_trait::async_trait;
use std::time::Duration;

/// FIFO policy with priority support — switch immediately on first request
/// for a non-active model, unless a higher-priority model has pending requests.
///
/// Lower priority values = higher priority. Priority 0 (None/default) is lowest.
/// A model with a lower priority value won't be switched in if a higher-priority
/// model has pending requests.
pub struct FifoPolicy {
    request_timeout: Option<Duration>,
    drain_before_switch: bool,
    min_active_duration: Duration,
    priorities: std::collections::HashMap<String, Option<u8>>,
}

impl FifoPolicy {
    pub fn new(
        request_timeout: Option<Duration>,
        drain_before_switch: bool,
        min_active_duration: Duration,
        priorities: std::collections::HashMap<String, Option<u8>>,
    ) -> Self {
        Self {
            request_timeout,
            drain_before_switch,
            min_active_duration,
            priorities,
        }
    }

    pub fn priority_for(&self, model: &str) -> Option<u8> {
        self.priorities.get(model).copied().flatten()
    }
}

impl Default for FifoPolicy {
    fn default() -> Self {
        Self::new(None, true, Duration::ZERO, std::collections::HashMap::new())
    }
}

#[async_trait]
impl SwitchPolicy for FifoPolicy {
    async fn on_pending_request(&self, ctx: &PolicyContext) -> PolicyDecision {
        // Priority-based switch decision:
        //   - target_priority < active_priority → switch (target is higher prio)
        //   - target_priority > active_priority → skip (stay on higher-prio model)
        //   - same priority or either is None → FIFO: switch immediately
        if let (Some(tp), Some(ap)) = (ctx.target_priority, ctx.active_priority) {
            if tp > ap {
                // Target is lower priority than active — skip, stay on active
                return PolicyDecision::Skip;
            }
            if tp < ap {
                // Target is higher priority — switch
                return PolicyDecision::SwitchNow;
            }
        }
        PolicyDecision::SwitchNow
    }

    async fn prepare_switch(&self, ctx: &mut SwitchContext) {
        if self.drain_before_switch {
            ctx.wait_for_in_flight().await;
        }
    }

    fn request_timeout(&self) -> Option<Duration> {
        self.request_timeout
    }

    fn min_active_duration(&self) -> Duration {
        self.min_active_duration
    }
}
