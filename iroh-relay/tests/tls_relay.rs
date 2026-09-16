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
    pin::Pin,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::{TcpListener, TcpStream},
};

struct PausedTransport {
    socket: TcpStream,
    paused: Arc<AtomicBool>,
    waker: Arc<futures_util::task::AtomicWaker>,
}
impl AsyncRead for PausedTransport {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().socket).poll_read(cx, buf)
    }
}
impl AsyncWrite for PausedTransport {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        let this = self.get_mut();
        this.waker.register(cx.waker());
        if this.paused.load(Ordering::SeqCst) {
            return Poll::Pending;
        }
        Pin::new(&mut this.socket).poll_write(cx, buf)
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().socket).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().socket).poll_shutdown(cx)
    }
}

#[tokio::test]
async fn trusted_tls_authentication_account_routing_and_signed_active_disconnect()
-> anyhow::Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let secret = "test-backend-service-secret-32bytes";
    let keys = [
        SecretKey::from_bytes(&[1; 32]),
        SecretKey::from_bytes(&[2; 32]),
        SecretKey::from_bytes(&[3; 32]),
    ];
    let accounts = Arc::new(HashMap::from([
        (keys[0].public().to_string(), "one"),
        (keys[1].public().to_string(), "one"),
        (keys[2].public().to_string(), "two"),
        (
            SecretKey::from_bytes(&[5; 32]).public().to_string(),
            "legacy",
        ),
        (
            SecretKey::from_bytes(&[6; 32]).public().to_string(),
            "legacy",
        ),
    ]));
    let backend = TcpListener::bind("127.0.0.1:0").await?;
    let backend_addr = backend.local_addr()?;
    let requests = Arc::new(Mutex::new(0));
    let request_count = requests.clone();
    let backend_task = tokio::spawn(async move {
        loop {
            let (stream, _) = backend.accept().await.unwrap();
            let accounts = accounts.clone();
            let requests = request_count.clone();
            tokio::spawn(async move {
                let service = hyper::service::service_fn(move |request: Request<Incoming>| {
                    let accounts = accounts.clone();
                    let requests = requests.clone();
                    async move {
                        assert_eq!(request.uri().path(), "/internal/peer-admission");
                        let signature = request.headers()["x-antgrid-signature"]
                            .to_str()
                            .unwrap()
                            .to_owned();
                        let body = request.into_body().collect().await.unwrap().to_bytes();
                        assert!(auth::verify(secret, &body, &signature));
                        let request: serde_json::Value = serde_json::from_slice(&body).unwrap();
                        assert_eq!(request["relayUrl"], "https://relay.example/");
                        *requests.lock().unwrap() += 1;
                        let endpoint = request["endpointId"].as_str().unwrap();
                        let response = match accounts.get(endpoint) {
                            Some(account) => {
                                serde_json::json!({"allowed":true,"requestId":request["requestId"],"endpointId":endpoint,
                                "userId":account,"deviceId":"00000000-0000-4000-8000-000000000001","enrollmentId":endpoint,
                                "registrationGeneration":"1","policyGeneration":"1","leaseMs":60_000})
                            }
                            None => {
                                serde_json::json!({"allowed":false,"requestId":request["requestId"]})
                            }
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
    let config: Config = serde_json::from_value(
        serde_json::json!({"listen":"127.0.0.1:443","adminListen":"127.0.0.1:9000",
        "tlsCert":"unused","tlsKey":"unused","admissionUrl":format!("http://{backend_addr}/internal/peer-admission"),
        "relayUrl":"https://relay.example/","admissionSecret":secret,"adminSecret":"admin-secret-private-32bytes-long",
        "maxConnections":8,"maxPendingAdmissions":2,"maxAccounts":4,"maxAccountConnections":4,"maxEndpointConnections":1,
        "bytesPerSecond":10_000_000,"burstBytes":10_000_000}),
    )?;
    let state = State::new(config.clone())?;
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
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let addr = listener.local_addr()?;
    let url: iroh_base::RelayUrl = format!("https://localhost:{}/", addr.port()).parse()?;
    let permits = state.connections.clone();
    let available = permits.clone();
    let serving = state.clone();
    let paused = Arc::new(AtomicBool::new(false));
    let pause_waker = Arc::new(futures_util::task::AtomicWaker::new());
    let destination_gate = Arc::new(Mutex::new(None::<std::sync::Weak<Gate>>));
    let pause = paused.clone();
    let wake = pause_waker.clone();
    let captured = destination_gate.clone();
    let relay_task = tokio::spawn(async move {
        let mut accepted = 0;
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let permit = permits.clone().try_acquire_owned().unwrap();
            let gate = Gate::new(permit, &serving.config);
            let stream = if accepted == 1 {
                *captured.lock().unwrap() = Some(Arc::downgrade(&gate));
                PausedTransport {
                    socket: stream,
                    paused: pause.clone(),
                    waker: wake.clone(),
                }
            } else {
                PausedTransport {
                    socket: stream,
                    paused: Arc::new(AtomicBool::new(false)),
                    waker: Arc::new(futures_util::task::AtomicWaker::new()),
                }
            };
            accepted += 1;
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
    let mut source =
        tokio::time::timeout(Duration::from_secs(5), connect(keys[0].clone())).await??;
    let mut destination =
        tokio::time::timeout(Duration::from_secs(5), connect(keys[1].clone())).await??;
    let mut other =
        tokio::time::timeout(Duration::from_secs(5), connect(keys[2].clone())).await??;
    assert!(state.prometheus().contains("antgrid_iroh_connections 3\n"));
    source
        .send(ClientToRelayMsg::Datagrams {
            dst_endpoint_id: keys[1].public(),
            datagrams: b"opaque-relayed-packet".as_slice().into(),
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
            assert_eq!(datagrams.contents, b"opaque-relayed-packet".as_slice());
        }
        other => panic!("unexpected relay frame {other:?}"),
    }
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
    assert!(
        tokio::time::timeout(
            Duration::from_secs(5),
            connect(SecretKey::from_bytes(&[4; 32]))
        )
        .await?
        .is_err()
    );
    if let Some(binary) = std::env::var_os("ANTGRID_LEGACY_RELAY_CLIENT") {
        let cert_file =
            std::env::temp_dir().join(format!("antgrid-relay-cert-{}.pem", uuid::Uuid::new_v4()));
        std::fs::write(&cert_file, certificate.cert.pem())?;
        let run = tokio::time::timeout(
            Duration::from_secs(10),
            tokio::process::Command::new(binary)
                .arg(url.to_string())
                .arg(&cert_file)
                .kill_on_drop(true)
                .output(),
        )
        .await;
        std::fs::remove_file(&cert_file)?;
        let result = run??;
        assert!(
            result.status.success(),
            "legacy client failed: {}",
            String::from_utf8_lossy(&result.stderr)
        );
        println!("{}", String::from_utf8_lossy(&result.stdout));
    }

    let administration = TcpListener::bind("127.0.0.1:0").await?;
    let admin_addr = administration.local_addr()?;
    let admin_state = state.clone();
    let admin_task = tokio::spawn(async move {
        loop {
            let (stream, _) = administration.accept().await.unwrap();
            let state = admin_state.clone();
            tokio::spawn(async move {
                let service = hyper::service::service_fn(move |req| {
                    antgrid_iroh_relay::admin(req, state.clone())
                });
                let _ = hyper::server::conn::http1::Builder::new()
                    .serve_connection(hyper_util::rt::TokioIo::new(stream), service)
                    .await;
            });
        }
    });
    let body = serde_json::to_vec(
        &serde_json::json!({"userId":"one","generation":"2","issuedAt":auth::issued_at()}),
    )?;
    paused.store(true, Ordering::SeqCst);
    let destination_bytes = destination_gate
        .lock()
        .unwrap()
        .as_ref()
        .unwrap()
        .upgrade()
        .unwrap();
    let before_revoke = destination_bytes.tx.load(Ordering::Relaxed);
    for _ in 0..32 {
        source
            .send(ClientToRelayMsg::Datagrams {
                dst_endpoint_id: keys[1].public(),
                datagrams: vec![7; 1024].into(),
            })
            .await?;
    }
    tokio::time::sleep(Duration::from_millis(30)).await;
    let http = reqwest::Client::new();
    let admin_url = format!("http://{admin_addr}/internal/disconnect");
    assert_eq!(
        http.post(&admin_url)
            .body(body.clone())
            .send()
            .await?
            .status(),
        401
    );
    assert_eq!(
        http.post(&admin_url)
            .header(
                "x-antgrid-signature",
                auth::sign(&config.admin_secret, &body)
            )
            .body(body)
            .send()
            .await?
            .status(),
        200
    );
    paused.store(false, Ordering::SeqCst);
    pause_waker.wake();
    async fn closed(client: &mut iroh_relay::client::Client) {
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                match client.next().await {
                    None | Some(Err(_)) => break,
                    _ => {}
                }
            }
        })
        .await
        .unwrap();
    }
    closed(&mut source).await;
    closed(&mut destination).await;
    assert_eq!(
        destination_bytes.tx.load(Ordering::Relaxed),
        before_revoke,
        "buffered relay packets reached the socket after revocation"
    );
    drop(destination_bytes);
    other.send(ClientToRelayMsg::Ping([9; 8])).await?;
    assert!(matches!(
        tokio::time::timeout(Duration::from_secs(2), other.next())
            .await?
            .unwrap()?,
        RelayToClientMsg::Pong([9, 9, 9, 9, 9, 9, 9, 9])
    ));
    assert!(*requests.lock().unwrap() >= 4);
    drop(source);
    drop(destination);
    drop(other);
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(available.available_permits(), config.max_connections);
    relay_task.abort();
    backend_task.abort();
    admin_task.abort();
    Ok(())
}
