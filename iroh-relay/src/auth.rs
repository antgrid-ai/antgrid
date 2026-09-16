use crate::config::Config;
use anyhow::{Result, bail, ensure};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::{
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::sync::Semaphore;

pub fn issued_at() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock")
        .as_millis() as u64
}
pub fn sign(secret: &str, body: &[u8]) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC key");
    mac.update(body);
    hex::encode(mac.finalize().into_bytes())
}
pub fn verify(secret: &str, body: &[u8], signature: &str) -> bool {
    let Ok(bytes) = hex::decode(signature) else {
        return false;
    };
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC key");
    mac.update(body);
    mac.verify_slice(&bytes).is_ok()
}
pub fn generation(value: &str) -> Result<u64> {
    ensure!(
        !value.is_empty()
            && value.len() <= 19
            && value.bytes().all(|c| c.is_ascii_digit())
            && (value == "0" || !value.starts_with('0')),
        "invalid generation"
    );
    let result: u64 = value.parse()?;
    ensure!(result <= i64::MAX as u64, "generation overflow");
    Ok(result)
}
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Admission {
    pub allowed: bool,
    pub request_id: String,
    pub endpoint_id: String,
    pub user_id: String,
    pub device_id: String,
    pub enrollment_id: String,
    pub registration_generation: String,
    pub policy_generation: String,
    pub lease_ms: u64,
}
impl Admission {
    pub fn validate(&self, endpoint: &str) -> Result<()> {
        ensure!(
            self.allowed
                && self.endpoint_id == endpoint
                && endpoint.len() == 64
                && endpoint
                    .bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)),
            "endpoint mismatch"
        );
        ensure!(
            !self.user_id.is_empty()
                && self.user_id.len() <= 256
                && !self.enrollment_id.is_empty()
                && self.enrollment_id.len() <= 256
                && uuid::Uuid::parse_str(&self.device_id).is_ok(),
            "identity invalid"
        );
        ensure!((1..=60_000).contains(&self.lease_ms), "lease invalid");
        generation(&self.registration_generation)?;
        generation(&self.policy_generation)?;
        Ok(())
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
#[serde(rename_all = "camelCase")]
struct Denial {
    allowed: bool,
    request_id: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AdmissionRequest<'a> {
    endpoint_id: &'a str,
    relay_url: &'a str,
    request_id: String,
    issued_at: u64,
}
pub struct Backend {
    client: reqwest::Client,
    url: String,
    relay_url: String,
    secret: String,
    pending: Semaphore,
    capacity: usize,
    last_response: AtomicU64,
}
impl Backend {
    pub fn new(config: &Config) -> Result<Self> {
        Ok(Self {
            client: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(2))
                .build()?,
            url: config.admission_url.clone(),
            relay_url: config.relay_url.clone(),
            secret: config.admission_secret.clone(),
            pending: Semaphore::new(config.max_pending_admissions),
            capacity: config.max_pending_admissions,
            last_response: AtomicU64::new(0),
        })
    }
    pub async fn admit(&self, endpoint: &str) -> Result<(Admission, Instant)> {
        let start = Instant::now();
        let _permit = self
            .pending
            .try_acquire()
            .map_err(|_| anyhow::anyhow!("admission overload"))?;
        let operation = async {
            let request_id = uuid::Uuid::new_v4().to_string();
            let body = serde_json::to_vec(&AdmissionRequest {
                endpoint_id: endpoint,
                relay_url: &self.relay_url,
                request_id: request_id.clone(),
                issued_at: issued_at(),
            })?;
            let mut response = self
                .client
                .post(&self.url)
                .header("content-type", "application/json")
                .header("x-antgrid-signature", sign(&self.secret, &body))
                .body(body)
                .send()
                .await?;
            ensure!(response.status().is_success(), "backend denied");
            let mut bytes = Vec::new();
            while let Some(chunk) = response.chunk().await? {
                ensure!(
                    bytes.len() + chunk.len() <= 4096,
                    "backend response too large"
                );
                bytes.extend_from_slice(&chunk);
            }
            if let Ok(denial) = serde_json::from_slice::<Denial>(&bytes) {
                ensure!(denial.request_id == request_id, "response request mismatch");
                ensure!(!denial.allowed, "malformed approval");
                self.last_response.store(issued_at(), Ordering::Relaxed);
                bail!("backend denied")
            }
            let admission: Admission = serde_json::from_slice(&bytes)?;
            ensure!(
                admission.request_id == request_id,
                "response request mismatch"
            );
            admission.validate(endpoint)?;
            self.last_response.store(issued_at(), Ordering::Relaxed);
            let deadline = start + Duration::from_millis(admission.lease_ms);
            ensure!(Instant::now() < deadline, "delayed authorization expired");
            Ok((admission, deadline))
        };
        tokio::time::timeout(Duration::from_secs(2), operation).await?
    }
    pub fn pending(&self) -> usize {
        self.capacity - self.pending.available_permits()
    }
    pub fn ready(&self) -> bool {
        issued_at().abs_diff(self.last_response.load(Ordering::Relaxed)) < 30_000
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Invalidation {
    pub user_id: String,
    pub generation: String,
    pub issued_at: u64,
}
impl Invalidation {
    pub fn validate(&self) -> Result<u64> {
        ensure!(
            !self.user_id.is_empty()
                && self.user_id.len() <= 256
                && issued_at().abs_diff(self.issued_at) <= 30_000,
            "invalid invalidation"
        );
        generation(&self.generation)
    }
}
