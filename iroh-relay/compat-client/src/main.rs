use futures_util::{SinkExt, StreamExt};
use iroh_base::SecretKey;
use iroh_dns::dns::DnsResolver;
use iroh_relay::{
    client::ClientBuilder,
    protos::relay::{ClientToRelayMsg, RelayToClientMsg},
    tls::{CaTlsConfig, default_provider},
};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let args: Vec<_> = std::env::args().collect();
    anyhow::ensure!(
        args.len() == 3,
        "usage: compat-client <relay-url> <trusted-cert.pem>"
    );
    let relay_url: iroh_base::RelayUrl = args[1].parse()?;
    let pem = std::fs::read(&args[2])?;
    let certs = rustls_pemfile::certs(&mut &pem[..]).collect::<Result<Vec<_>, _>>()?;
    let trust = CaTlsConfig::custom_roots(certs).client_config(default_provider())?;
    let key1 = SecretKey::from_bytes(&[5; 32]);
    let key2 = SecretKey::from_bytes(&[6; 32]);
    let mut source = ClientBuilder::new(relay_url.clone(), key1.clone(), DnsResolver::new())
        .tls_client_config(trust.clone())
        .connect()
        .await?;
    let mut destination = ClientBuilder::new(relay_url, key2.clone(), DnsResolver::new())
        .tls_client_config(trust)
        .connect()
        .await?;
    source
        .send(ClientToRelayMsg::Datagrams {
            dst_endpoint_id: key2.public(),
            datagrams: b"legacy-relay-protocol".as_slice().into(),
        })
        .await?;
    let message = tokio::time::timeout(std::time::Duration::from_secs(2), destination.next())
        .await?
        .ok_or_else(|| anyhow::anyhow!("closed"))??;
    match message {
        RelayToClientMsg::Datagrams {
            remote_endpoint_id,
            datagrams,
        } => {
            anyhow::ensure!(
                remote_endpoint_id == key1.public()
                    && datagrams.contents == b"legacy-relay-protocol".as_slice(),
                "invalid relay message"
            );
        }
        _ => anyhow::bail!("unexpected message"),
    }
    println!("iroh-relay 1.0.0 trusted-TLS compatibility passed");
    Ok(())
}
