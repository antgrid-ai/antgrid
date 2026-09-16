use anyhow::{Result, ensure};
use serde::Deserialize;
use std::{
    net::{IpAddr, SocketAddr},
    path::PathBuf,
};

/// Cleartext is only defensible on a network the developer already controls, so
/// `dev_insecure_http` is confined to one. A LAN address counts — a phone or an
/// emulator has to reach the stack — but a public or unspecified bind does not.
/// Keeping that here makes "local development only" a property of this file,
/// rather than one that merely emerges from what every peer happens to refuse.
fn is_local_network(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(address) => {
            address.is_loopback() || address.is_private() || address.is_link_local()
        }
        // `is_unique_local` and `is_unicast_link_local` are still unstable.
        IpAddr::V6(address) => {
            address.is_loopback()
                || address.segments()[0] & 0xfe00 == 0xfc00
                || address.segments()[0] & 0xffc0 == 0xfe80
        }
    }
}

fn is_local_host(url: &reqwest::Url) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    if host == "localhost" {
        return true;
    }
    // `host_str` serializes an IPv6 literal with its brackets.
    let host = host
        .strip_prefix('[')
        .and_then(|rest| rest.strip_suffix(']'))
        .unwrap_or(host);
    host.parse::<IpAddr>().is_ok_and(is_local_network)
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub listen: SocketAddr,
    pub admin_listen: SocketAddr,
    /// Absent only with `dev_insecure_http`, which serves cleartext instead.
    #[serde(default)]
    pub tls_cert: Option<PathBuf>,
    #[serde(default)]
    pub tls_key: Option<PathBuf>,
    /// Dev-only: serve the relay protocol over cleartext HTTP instead of TLS,
    /// for a local stack that has no DNS name or publicly trusted certificate.
    /// Upstream's own relay binary exposes the same escape hatch as `--dev`.
    /// `validate` keeps this in lockstep with the approved origin's scheme and
    /// with whether a certificate is configured, so a deployment cannot end up
    /// serving cleartext while advertising `https`.
    #[serde(default)]
    pub dev_insecure_http: bool,
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
        if self.dev_insecure_http {
            ensure!(
                self.tls_cert.is_none() && self.tls_key.is_none(),
                "devInsecureHttp serves cleartext; remove tlsCert and tlsKey"
            );
            ensure!(
                is_local_network(self.listen.ip()),
                "devInsecureHttp must listen on a loopback or private address"
            );
        } else {
            ensure!(
                self.listen.port() == 443,
                "client listener must use TLS port 443"
            );
            ensure!(
                self.tls_cert.is_some() && self.tls_key.is_some(),
                "tlsCert and tlsKey are required unless devInsecureHttp is set"
            );
        }
        ensure!(
            self.admin_listen.ip().is_loopback(),
            "admin listener must be loopback; use private sidecar routing"
        );
        let url = reqwest::Url::parse(&self.admission_url)?;
        let relay = reqwest::Url::parse(&self.relay_url)?;
        // The advertised scheme is what clients dial, so it has to track how
        // this listener actually serves. Tying the two to one flag means no
        // configuration can advertise https while serving cleartext.
        let relay_scheme = if self.dev_insecure_http { "http" } else { "https" };
        ensure!(
            relay.scheme() == relay_scheme
                && relay.username().is_empty()
                && relay.password().is_none()
                && relay.query().is_none()
                && relay.fragment().is_none()
                && relay.path() == "/",
            "invalid approved relay URL"
        );
        // The origin peers dial names the same network the listener is bound
        // to, so a cleartext relay cannot advertise itself at a public name.
        ensure!(
            !self.dev_insecure_http || is_local_host(&relay),
            "devInsecureHttp requires a loopback or private relay URL host"
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
