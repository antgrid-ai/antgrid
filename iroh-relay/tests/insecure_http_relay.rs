use antgrid_iroh_relay::{
    auth,
    config::Config,
    state::{Gate, State},
};
use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use http_body_util::{BodyExt, Full};
use hyper::{Request, Response, body::Incoming};
use iroh_base::SecretKey;
use iroh_dns::dns::DnsResolver;
use iroh_relay::{
    client::ClientBuilder,
    protos::relay::{ClientToRelayMsg, RelayToClientMsg},
    tls::{CaTlsConfig, default_provider},
};
use std::{
    collections::HashMap,
    convert::Infallible,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::net::TcpListener;

/// Real upstream relay clients over a cleartext listener: proves the dev path
/// actually carries the relay protocol rather than merely compiling, and that
/// dropping TLS drops nothing else — admission is still enforced per endpoint
/// and accounts are still isolated from one another.
///
/// The client needs no *trust* configuration to speak cleartext — an `http`
/// relay URL is dialled as `ws://` and the TLS config is never consulted — but
/// `ClientBuilder` still refuses to connect without one, so the stock
/// `CaTlsConfig` is handed over and goes unused.
#[tokio::test]
async fn cleartext_relay_carries_packets_and_still_enforces_admission() -> anyhow::Result<()> {
    // Admission is an outbound reqwest call whose rustls stack wants a provider
    // even when the URL it dials is cleartext.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let keys: Vec<SecretKey> = (1..=3).map(|byte| SecretKey::from_bytes(&[byte; 32])).collect();
    let secret = "insecure-http-admission-secret-32b";
    let accounts = Arc::new(HashMap::from([
        (keys[0].public().to_string(), "one"),
        (keys[1].public().to_string(), "one"),
        (keys[2].public().to_string(), "two"),
    ]));
    let backend = TcpListener::bind("127.0.0.1:0").await?;
    let backend_addr = backend.local_addr()?;
    let seen_relay_url = Arc::new(Mutex::new(Vec::<String>::new()));
    let observed = seen_relay_url.clone();
    let backend_task = tokio::spawn(async move {
        loop {
            let (stream, _) = backend.accept().await.unwrap();
            let accounts = accounts.clone();
            let observed = observed.clone();
            tokio::spawn(async move {
                let service = hyper::service::service_fn(move |request: Request<Incoming>| {
                    let accounts = accounts.clone();
                    let observed = observed.clone();
                    async move {
                        let signature = request.headers()["x-antgrid-signature"]
                            .to_str()
                            .unwrap()
                            .to_owned();
                        let body = request.into_body().collect().await.unwrap().to_bytes();
                        // Admission stays HMAC-authenticated without TLS.
                        assert!(auth::verify(secret, &body, &signature));
                        let request: serde_json::Value = serde_json::from_slice(&body).unwrap();
                        observed
                            .lock()
                            .unwrap()
                            .push(request["relayUrl"].as_str().unwrap().to_owned());
                        let endpoint = request["endpointId"].as_str().unwrap();
                        let response = match accounts.get(endpoint) {
                            Some(account) => serde_json::json!({"allowed":true,"requestId":request["requestId"],
                                "endpointId":endpoint,"userId":account,
                                "deviceId":"00000000-0000-4000-8000-000000000001","enrollmentId":endpoint,
                                "registrationGeneration":"1","policyGeneration":"1","leaseMs":60_000}),
                            None => serde_json::json!({"allowed":false,"requestId":request["requestId"]}),
                        };
                        Ok::<_, Infallible>(Response::new(Full::new(Bytes::from(
                            serde_json::to_vec(&response).unwrap(),
                        ))))
                    }
                });
                let _ = hyper::server::conn::http1::Builder::new()
                    .serve_connection(hyper_util::rt::TokioIo::new(stream), service)
                    .await;
            });
        }
    });

    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let relay_url = format!("http://127.0.0.1:{}/", addr.port());
    let config: Config = serde_json::from_value(serde_json::json!({
        "listen": format!("127.0.0.1:{}", addr.port()), "adminListen": "127.0.0.1:9000",
        "devInsecureHttp": true,
        "admissionUrl": format!("http://{backend_addr}/internal/peer-admission"),
        "relayUrl": relay_url.clone(), "admissionSecret": secret,
        "adminSecret": "admin-secret-private-32bytes-long",
        "maxConnections": 8, "maxPendingAdmissions": 2, "maxAccounts": 4,
        "maxAccountConnections": 4, "maxEndpointConnections": 1,
        "bytesPerSecond": 10_000_000, "burstBytes": 10_000_000,
    }))?;
    config.validate()?;
    let state = State::new(config)?;
    let permits = state.connections.clone();
    let serving = state.clone();
    let relay_task = tokio::spawn(async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let permit = permits.clone().try_acquire_owned().unwrap();
            let gate = Gate::new(permit, &serving.config);
            let state = serving.clone();
            tokio::spawn(async move {
                // `None`: no TLS acceptor, the cleartext branch under test.
                let _ = antgrid_iroh_relay::relay_connection(stream, state, gate, None).await;
            });
        }
    });

    let url: iroh_base::RelayUrl = relay_url.parse()?;
    let trust = CaTlsConfig::default().client_config(default_provider())?;
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
    let mut source = tokio::time::timeout(Duration::from_secs(5), connect(keys[0].clone())).await??;
    let mut destination =
        tokio::time::timeout(Duration::from_secs(5), connect(keys[1].clone())).await??;
    let mut other = tokio::time::timeout(Duration::from_secs(5), connect(keys[2].clone())).await??;

    source
        .send(ClientToRelayMsg::Datagrams {
            dst_endpoint_id: keys[1].public(),
            datagrams: b"cleartext-relayed-packet".as_slice().into(),
        })
        .await?;
    let packet = tokio::time::timeout(Duration::from_secs(2), destination.next())
        .await?
        .unwrap()?;
    match packet {
        RelayToClientMsg::Datagrams {
            remote_endpoint_id,
            datagrams,
        } => {
            assert_eq!(remote_endpoint_id, keys[0].public());
            assert_eq!(datagrams.contents, b"cleartext-relayed-packet".as_slice());
        }
        unexpected => panic!("unexpected relay frame {unexpected:?}"),
    }

    // Account isolation is a relay fence, not a TLS one.
    source
        .send(ClientToRelayMsg::Datagrams {
            dst_endpoint_id: keys[2].public(),
            datagrams: b"cross-account".as_slice().into(),
        })
        .await?;
    assert!(
        tokio::time::timeout(Duration::from_millis(100), other.next())
            .await
            .is_err()
    );

    // An endpoint the backend does not know is still refused.
    assert!(
        tokio::time::timeout(Duration::from_secs(5), connect(SecretKey::from_bytes(&[9; 32])))
            .await?
            .is_err()
    );

    // The relay reports the http origin it was configured with, which is what
    // the backend matches against its approved list.
    let seen = seen_relay_url.lock().unwrap().clone();
    assert!(!seen.is_empty());
    assert!(seen.iter().all(|value| *value == relay_url), "{seen:?}");

    relay_task.abort();
    backend_task.abort();
    Ok(())
}
