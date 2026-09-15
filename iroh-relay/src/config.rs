use anyhow::{Result, ensure};
use serde::Deserialize;
use std::{net::SocketAddr, path::PathBuf};

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub listen: SocketAddr,
    pub admin_listen: SocketAddr,
    pub tls_cert: PathBuf,
    pub tls_key: PathBuf,
    pub admission_url: String,
    pub relay_url: String,
    pub admission_secret: String,
    pub admin_secret: String,
    pub max_connections: usize,
    pub max_pending_admissions: usize,
    pub max_accounts: usize,
    pub max_account_connections: usize,
    pub max_endpoint_connections: usize,
    pub bytes_per_second: u32,
    pub burst_bytes: u32,
}
impl Config {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.listen.port() == 443,
            "client listener must use TLS port 443"
        );
        ensure!(
            self.admin_listen.ip().is_loopback(),
            "admin listener must be loopback; use private sidecar routing"
        );
        let url = reqwest::Url::parse(&self.admission_url)?;
        let relay = reqwest::Url::parse(&self.relay_url)?;
        ensure!(
            relay.scheme() == "https"
                && relay.username().is_empty()
                && relay.password().is_none()
                && relay.query().is_none()
                && relay.fragment().is_none()
                && relay.path() == "/",
            "invalid approved relay URL"
        );
        ensure!(
            matches!(url.scheme(), "http" | "https")
                && url.username().is_empty()
                && url.password().is_none()
                && url.query().is_none()
                && url.fragment().is_none()
                && url.path() == "/internal/peer-admission",
            "invalid admission URL"
        );
        ensure!(
            self.admission_secret.len() >= 32 && self.admin_secret.len() >= 32,
            "service secrets must be at least 32 bytes"
        );
        ensure!(
            (1..=100_000).contains(&self.max_connections)
                && (1..=1024).contains(&self.max_pending_admissions)
                && (1..=100_000).contains(&self.max_accounts)
                && self.max_account_connections > 0
                && self.max_account_connections <= self.max_connections
                && self.max_endpoint_connections > 0
                && self.max_endpoint_connections <= self.max_account_connections,
            "invalid resource bounds"
        );
        ensure!(
            self.bytes_per_second >= 1024 && self.burst_bytes >= 65536,
            "invalid traffic bounds"
        );
        Ok(())
    }
}
