pub mod common;
mod console_log;
pub mod proc;
pub mod shell;
pub mod v8_js;

use async_trait::async_trait;
use chrono::{SecondsFormat, Utc};
use hyper::{HeaderMap, Method};
use std::collections::HashMap;
use std::fs::File;
use std::io::Write;
use std::sync::{Arc, Mutex};
use tracing::warn;

#[derive(Debug, Clone)]
pub enum Action {
    Allow,
    Deny,
}

pub type HeaderRewrites = HashMap<String, String>;

#[derive(Debug, Clone)]
pub struct EvaluationResult {
    pub action: Action,
    pub context: Option<String>,
    pub max_tx_bytes: Option<u64>,
    pub header_rewrites: Option<HeaderRewrites>,
}

impl EvaluationResult {
    pub fn allow() -> Self {
        Self {
            action: Action::Allow,
            context: None,
            max_tx_bytes: None,
            header_rewrites: None,
        }
    }

    pub fn deny() -> Self {
        Self {
            action: Action::Deny,
            context: None,
            max_tx_bytes: None,
            header_rewrites: None,
        }
    }

    pub fn with_context(mut self, context: String) -> Self {
        self.context = Some(context);
        self
    }

    pub fn with_max_tx_bytes(mut self, max_tx_bytes: u64) -> Self {
        self.max_tx_bytes = Some(max_tx_bytes);
        self
    }

    pub fn with_header_rewrites(mut self, header_rewrites: HeaderRewrites) -> Self {
        self.header_rewrites = Some(header_rewrites);
        self
    }
}

/// Trait for rule engines that evaluate HTTP requests.
///
/// # Security Note
/// Implementations MUST NOT expose detailed error information in denial messages
/// that could leak system information to jailed applications. Use generic error
/// messages like "Request denied" or "Script evaluation failed" instead of
/// including system paths, error codes, or internal details.
#[async_trait]
pub trait RuleEngineTrait: Send + Sync {
    async fn evaluate(&self, method: Method, url: &str, requester_ip: &str) -> EvaluationResult {
        let headers = HeaderMap::new();
        self.evaluate_with_headers(method, url, requester_ip, &headers)
            .await
    }

    async fn evaluate_with_headers(
        &self,
        method: Method,
        url: &str,
        requester_ip: &str,
        headers: &HeaderMap,
    ) -> EvaluationResult;

    fn name(&self) -> &str;
}

pub struct LoggingRuleEngine {
    engine: Box<dyn RuleEngineTrait>,
    request_log: Option<Arc<Mutex<File>>>,
}

impl LoggingRuleEngine {
    pub fn new(engine: Box<dyn RuleEngineTrait>, request_log: Option<Arc<Mutex<File>>>) -> Self {
        Self {
            engine,
            request_log,
        }
    }
}

#[async_trait]
impl RuleEngineTrait for LoggingRuleEngine {
    async fn evaluate_with_headers(
        &self,
        method: Method,
        url: &str,
        requester_ip: &str,
        headers: &HeaderMap,
    ) -> EvaluationResult {
        let result = self
            .engine
            .evaluate_with_headers(method.clone(), url, requester_ip, headers)
            .await;

        if let Some(log) = &self.request_log
            && let Ok(mut file) = log.lock()
        {
            let timestamp = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
            let status = match &result.action {
                Action::Allow => '+',
                Action::Deny => '-',
            };
            if let Err(e) = writeln!(file, "{} {} {} {}", timestamp, status, method, url) {
                warn!("Failed to write to request log: {}", e);
            }
        }

        result
    }

    fn name(&self) -> &str {
        self.engine.name()
    }
}

#[derive(Clone)]
pub struct RuleEngine {
    inner: Arc<dyn RuleEngineTrait>,
}

impl RuleEngine {
    pub fn from_trait(
        engine: Box<dyn RuleEngineTrait>,
        request_log: Option<Arc<Mutex<File>>>,
    ) -> Self {
        let engine: Box<dyn RuleEngineTrait> = if request_log.is_some() {
            Box::new(LoggingRuleEngine::new(engine, request_log))
        } else {
            engine
        };
        RuleEngine {
            inner: Arc::from(engine),
        }
    }

    pub async fn evaluate(&self, method: Method, url: &str) -> Action {
        self.inner.evaluate(method, url, "127.0.0.1").await.action
    }

    pub async fn evaluate_with_context(&self, method: Method, url: &str) -> EvaluationResult {
        self.inner.evaluate(method, url, "127.0.0.1").await
    }

    pub async fn evaluate_with_ip(&self, method: Method, url: &str, requester_ip: &str) -> Action {
        self.inner.evaluate(method, url, requester_ip).await.action
    }

    pub async fn evaluate_with_context_and_ip(
        &self,
        method: Method,
        url: &str,
        requester_ip: &str,
    ) -> EvaluationResult {
        self.inner.evaluate(method, url, requester_ip).await
    }

    pub async fn evaluate_with_context_and_ip_and_headers(
        &self,
        method: Method,
        url: &str,
        requester_ip: &str,
        headers: &HeaderMap,
    ) -> EvaluationResult {
        self.inner
            .evaluate_with_headers(method, url, requester_ip, headers)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::v8_js::V8JsRuleEngine;
    use std::fs::OpenOptions;
    use std::sync::{Arc, Mutex};

    #[tokio::test]
    async fn test_request_logging() {
        let engine = V8JsRuleEngine::new("true".to_string()).unwrap();
        let log_file = tempfile::NamedTempFile::new().unwrap();
        let file = OpenOptions::new()
            .append(true)
            .open(log_file.path())
            .unwrap();
        let engine = RuleEngine::from_trait(Box::new(engine), Some(Arc::new(Mutex::new(file))));

        engine.evaluate(Method::GET, "https://example.com").await;

        let contents = std::fs::read_to_string(log_file.path()).unwrap();
        assert!(contents.contains("+ GET https://example.com"));
    }

    #[tokio::test]
    async fn test_request_logging_denied() {
        let engine = V8JsRuleEngine::new("false".to_string()).unwrap();
        let log_file = tempfile::NamedTempFile::new().unwrap();
        let file = OpenOptions::new()
            .append(true)
            .open(log_file.path())
            .unwrap();
        let engine = RuleEngine::from_trait(Box::new(engine), Some(Arc::new(Mutex::new(file))));

        engine.evaluate(Method::GET, "https://blocked.com").await;

        let contents = std::fs::read_to_string(log_file.path()).unwrap();
        assert!(contents.contains("- GET https://blocked.com"));
    }

    #[tokio::test]
    async fn test_headers_are_passed_to_rules() {
        let engine =
            V8JsRuleEngine::new("r.headers['x-httpjail-test'] === 'present'".to_string()).unwrap();
        let rule_engine = RuleEngine::from_trait(Box::new(engine), None);

        let mut headers = HeaderMap::new();
        headers.insert("x-httpjail-test", "present".parse().unwrap());

        let result = rule_engine
            .evaluate_with_context_and_ip_and_headers(
                Method::GET,
                "https://example.com",
                "127.0.0.1",
                &headers,
            )
            .await;
        assert!(matches!(result.action, Action::Allow));

        let empty_headers = HeaderMap::new();
        let result = rule_engine
            .evaluate_with_context_and_ip_and_headers(
                Method::GET,
                "https://example.com",
                "127.0.0.1",
                &empty_headers,
            )
            .await;
        assert!(matches!(result.action, Action::Deny));
    }
}
