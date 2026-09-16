use antgrid_iroh_relay::{
    config::Config,
    state::{Gate, State},
};
use anyhow::{Result, ensure};
use futures_util::{SinkExt, StreamExt};
use iroh_base::SecretKey;
use iroh_dns::dns::DnsResolver;
use iroh_relay::{
    client::{Client, ClientBuilder},
    protos::relay::{ClientToRelayMsg, RelayToClientMsg},
    tls::{CaTlsConfig, default_provider},
};
use serde::Deserialize;
use std::{
    io::Write,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    net::TcpListener,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BackendConfig {
    backend_url: String,
    admission_secret: String,
}

fn emit(value: serde_json::Value) {
    println!("{value}");
    std::io::stdout().flush().expect("stdout flush");
}

async fn receive(client: &mut Client, sender: &SecretKey, expected: &[u8]) -> Result<()> {
    let packet = tokio::time::timeout(Duration::from_secs(5), client.next())
        .await?
        .ok_or_else(|| anyhow::anyhow!("relay client closed before packet"))??;
    match packet {
        RelayToClientMsg::Datagrams {
            remote_endpoint_id,
            datagrams,
        } => {
            ensure!(
                remote_endpoint_id == sender.public(),
                "wrong authenticated packet sender"
            );
            ensure!(
                datagrams.contents == expected,
                "packet bytes did not round trip"
            );
        }
        _ => anyhow::bail!("unexpected relay packet"),
    }
    Ok(())
}

async fn closed(client: &mut Client) -> Result<()> {
    tokio::time::timeout(Duration::from_secs(60), async {
        loop {
            match client.next().await {
                None | Some(Err(_)) => return,
                _ => {}
            }
        }
    })
    .await?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let url: iroh_base::RelayUrl =
        format!("https://localhost:{}/", listener.local_addr()?.port()).parse()?;
    emit(serde_json::json!({"stage":"listening", "relayUrl":url.to_string()}));
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let settings: BackendConfig = serde_json::from_str(
        &lines
            .next_line()
            .await?
            .ok_or_else(|| anyhow::anyhow!("missing backend configuration"))?,
    )?;
    let config: Config = serde_json::from_value(serde_json::json!({
        "listen":"127.0.0.1:443", "adminListen":"127.0.0.1:9000", "tlsCert":"test-only", "tlsKey":"test-only",
        "admissionUrl":format!("{}/internal/peer-admission", settings.backend_url), "relayUrl":url.to_string(),
        "admissionSecret":settings.admission_secret, "adminSecret":"test-only-unused-admin-secret-32bytes",
        "maxConnections":8, "maxPendingAdmissions":2, "maxAccounts":4, "maxAccountConnections":4, "maxEndpointConnections":1,
        "bytesPerSecond":10_000_000, "burstBytes":10_000_000
    }))?;
    config.validate()?;
    let state = State::new(config)?;
    let certificate = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()])?;
    let tls = tokio_rustls::TlsAcceptor::from(Arc::new(
        rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                vec![certificate.cert.der().clone()],
                rustls::pki_types::PrivatePkcs8KeyDer::from(
                    certificate.signing_key.serialize_der(),
                )
                .into(),
            )?,
    ));
    let trust = CaTlsConfig::custom_roots([certificate.cert.der().clone()])
        .client_config(default_provider())?;
    let serving = state.clone();
    let relay_task = tokio::spawn(async move {
        loop {
            let (stream, _) = listener.accept().await.expect("test socket accept");
            let permit = serving
                .connections
                .clone()
                .try_acquire_owned()
                .expect("test connection budget");
            let gate = Gate::new(permit, &serving.config);
            let state = serving.clone();
            let tls = tls.clone();
            tokio::spawn(async move {
                let _ = antgrid_iroh_relay::relay_connection(stream, state, gate, Some(tls)).await;
            });
        }
    });
    let connect = |key: SecretKey| {
        let url = url.clone();
        let trust = trust.clone();
        async move {
            ClientBuilder::new(url, key, DnsResolver::new())
                .tls_client_config(trust)
                .connect()
                .await
        }
    };
    let keys = [
        SecretKey::from_bytes(&[5; 32]),
        SecretKey::from_bytes(&[6; 32]),
    ];
    let mut machine =
        tokio::time::timeout(Duration::from_secs(5), connect(keys[0].clone())).await??;
    let mut app = tokio::time::timeout(Duration::from_secs(5), connect(keys[1].clone())).await??;
    ensure!(
        tokio::time::timeout(
            Duration::from_secs(5),
            connect(SecretKey::from_bytes(&[7; 32]))
        )
        .await?
        .is_err(),
        "unregistered endpoint was admitted"
    );
    machine
        .send(ClientToRelayMsg::Datagrams {
            dst_endpoint_id: keys[1].public(),
            datagrams: b"real-backend-gate".as_slice().into(),
        })
        .await?;
    receive(&mut app, &keys[0], b"real-backend-gate").await?;
    app.send(ClientToRelayMsg::Datagrams {
        dst_endpoint_id: keys[0].public(),
        datagrams: b"relay-echo".as_slice().into(),
    })
    .await?;
    receive(&mut machine, &keys[1], b"relay-echo").await?;
    emit(
        serde_json::json!({"stage":"ready", "trustedTls":true, "bidirectionalPackets":true, "unregisteredDenied":true}),
    );
    ensure!(
        lines.next_line().await?.as_deref() == Some("revoked"),
        "missing revocation signal"
    );
    let start = Instant::now();
    tokio::try_join!(closed(&mut machine), closed(&mut app))?;
    let elapsed = start.elapsed().as_millis();
    ensure!(elapsed <= 60_000, "revocation exceeded lease bound");
    ensure!(
        tokio::time::timeout(Duration::from_secs(5), connect(keys[0].clone()))
            .await?
            .is_err(),
        "revoked endpoint reconnected"
    );
    emit(
        serde_json::json!({"stage":"revoked", "elapsedMs":elapsed, "bothConnectionsClosed":true, "reconnectDenied":true}),
    );
    relay_task.abort();
    Ok(())
}
