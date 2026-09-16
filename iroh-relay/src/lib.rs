pub mod auth;
pub mod config;
pub mod io;
pub mod state;

use crate::{
    io::{GuardedIo, PrefixedIo, WebSocketBytes},
    state::{Gate, State},
};
use anyhow::{Result, ensure};
use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited};
use hyper::{Request, Response, body::Incoming};
use iroh_relay::{
    KeyCache,
    http::{CLIENT_AUTH_HEADER, ProtocolVersion},
    protos::handshake,
    server::{
        Access, Metrics, OnDisconnectGuard, client::Config as ClientConfig, streams::RelayedStream,
    },
};
use std::{
    convert::Infallible,
    sync::{Arc, Mutex, atomic::Ordering},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::TcpListener,
    sync::Semaphore,
};
use tokio_rustls::TlsAcceptor;
use tokio_tungstenite::{
    accept_hdr_async_with_config,
    tungstenite::{
        handshake::server::{Request as WsRequest, Response as WsResponse},
        protocol::WebSocketConfig,
    },
};

/// `tls` is `None` only under `devInsecureHttp`, where the protocol below runs
/// over cleartext for a local stack that has no certificate. The whole
/// handshake-to-admission path is identical either way, so it lives in `serve`
/// and neither branch can drift from the other.
pub async fn relay_connection<T: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
    stream: T,
    state: Arc<State>,
    gate: Arc<Gate>,
    tls: Option<TlsAcceptor>,
) -> Result<()> {
    let guarded = GuardedIo::new(stream, gate.clone());
    match tls {
        Some(tls) => {
            // The accept is inside the budget `serve` would otherwise own alone,
            // so a peer that stalls mid-handshake cannot hold a permit forever.
            let stream = tokio::time::timeout(Duration::from_secs(5), tls.accept(guarded)).await??;
            serve(stream, state, gate).await
        }
        None => serve(guarded, state, gate).await,
    }
}

async fn serve<T: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
    stream: T,
    state: Arc<State>,
    gate: Arc<Gate>,
) -> Result<()> {
    tokio::time::timeout(Duration::from_secs(5), async {
        let mut stream = stream;
        let mut prefix = Vec::new();
        while !prefix.ends_with(b"\r\n\r\n") {
            ensure!(prefix.len() < 8192, "HTTP headers too large"); prefix.push(stream.read_u8().await?);
        }
        let first_line = prefix.split(|byte| *byte == b'\n').next().unwrap_or_default();
        if first_line == b"GET /ping HTTP/1.1\r" || first_line == b"GET /generate_204 HTTP/1.1\r" {
            stream.write_all(b"HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await?;
            stream.flush().await?; return Ok(());
        }
        let stream = PrefixedIo { prefix: prefix.into(), inner: stream };
        let captured = Arc::new(Mutex::new(None)); let headers = captured.clone();
        let socket = accept_hdr_async_with_config(stream, move |request: &WsRequest, mut response: WsResponse| {
            if request.uri().path() != "/relay" { return Err(http::Response::builder().status(404).body(None).expect("404")); }
            let protocol = request.headers().get("sec-websocket-protocol").and_then(|h| h.to_str().ok())
                .and_then(|value| value.split(',').filter_map(|p| ProtocolVersion::match_from_str(p.trim())).max());
            let Some(protocol) = protocol else { return Err(http::Response::builder().status(400).body(None).expect("400")); };
            response.headers_mut().insert("sec-websocket-protocol", protocol.to_header_value());
            *headers.lock().expect("header lock") = Some((request.clone().into_parts().0, protocol)); Ok(response)
        }, Some(WebSocketConfig::default().max_message_size(Some(1024 * 1024)).max_frame_size(Some(1024 * 1024))
            .write_buffer_size(0).max_write_buffer_size(2 * 1024 * 1024))).await?;
        let (parts, protocol) = captured.lock().expect("header lock").take().expect("negotiated protocol");
        let auth_header = parts.headers.get(CLIENT_AUTH_HEADER).cloned();
        let mut socket = WebSocketBytes { inner: socket, gate: gate.clone() };
        let authenticated = handshake::serverside(&mut socket, auth_header).await?;
        let endpoint = authenticated.client_key;
        let serial = state.invalidations.load(Ordering::SeqCst);
        let (admission, deadline) = match state.backend.admit(&endpoint.to_string()).await {
            Ok(value) => value,
            Err(error) => {
                let _ = authenticated.authorize_if(Access::Deny { reason: Some("not authorized".to_owned()) }, &mut socket).await;
                return Err(error)
            }
        };
        let binding = state.bind(&gate, admission, deadline, serial)?;
        authenticated.authorize_if(Access::Allow, &mut socket).await?;
        let relayed = RelayedStream::new(socket, KeyCache::new(1024));
        let mut config = ClientConfig::new(OnDisconnectGuard::empty(endpoint), relayed, protocol);
        config.channel_capacity = 64; config.write_timeout = Duration::from_secs(2);
        {
            let account = binding.account.inner.lock().expect("account lock");
            ensure!(account.epoch == binding.epoch && gate.active.load(Ordering::SeqCst) && Instant::now() < deadline, "registration invalidated");
            account.clients.register(config, Arc::new(Metrics::default()));
        }
        state.admitted.fetch_add(1, Ordering::Relaxed); state.maintain(&gate); Ok(())
    }).await?
}

fn response(status: u16, body: impl Into<Bytes>) -> Response<Full<Bytes>> {
    Response::builder()
        .status(status)
        .header("cache-control", "no-store")
        .body(Full::new(body.into()))
        .expect("response")
}
pub async fn admin(
    request: Request<Incoming>,
    state: Arc<State>,
) -> Result<Response<Full<Bytes>>, Infallible> {
    if request.method() == http::Method::GET {
        return Ok(match request.uri().path() {
            "/healthz" => response(200, "ok"),
            "/readyz" => response(if state.backend.ready() { 200 } else { 503 }, ""),
            "/metrics" => {
                let mut result = response(200, state.prometheus());
                result.headers_mut().insert(
                    "content-type",
                    http::HeaderValue::from_static("text/plain; version=0.0.4"),
                );
                result
            }
            _ => response(404, ""),
        });
    }
    if request.method() != http::Method::POST || request.uri().path() != "/internal/disconnect" {
        return Ok(response(404, ""));
    }
    let signature = request
        .headers()
        .get("x-antgrid-signature")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_owned();
    let bytes = match tokio::time::timeout(
        Duration::from_secs(2),
        Limited::new(request.into_body(), 4096).collect(),
    )
    .await
    {
        Ok(Ok(bytes)) => bytes.to_bytes(),
        _ => return Ok(response(413, "")),
    };
    if !auth::verify(&state.config.admin_secret, &bytes, &signature) {
        return Ok(response(401, ""));
    }
    let invalidation = match serde_json::from_slice::<auth::Invalidation>(&bytes) {
        Ok(value) => value,
        Err(_) => return Ok(response(400, "")),
    };
    let generation = match invalidation.validate() {
        Ok(value) => value,
        Err(_) => return Ok(response(400, "")),
    };
    Ok(match state.invalidate(&invalidation.user_id, generation) {
        Ok(()) => response(200, "ok"),
        Err(_) => response(503, ""),
    })
}

pub async fn run(config: config::Config) -> Result<()> {
    config.validate()?;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let tls = match (&config.tls_cert, &config.tls_key) {
        (Some(cert_path), Some(key_path)) => {
            let cert = std::fs::read(cert_path)?;
            let key = std::fs::read(key_path)?;
            let certificates =
                rustls_pemfile::certs(&mut &cert[..]).collect::<std::result::Result<Vec<_>, _>>()?;
            let key = rustls_pemfile::private_key(&mut &key[..])?
                .ok_or_else(|| anyhow::anyhow!("TLS key missing"))?;
            Some(TlsAcceptor::from(Arc::new(
                rustls::ServerConfig::builder()
                    .with_no_client_auth()
                    .with_single_cert(certificates, key)?,
            )))
        }
        // `validate` has already refused this pairing without dev_insecure_http.
        _ => {
            println!(
                "{}",
                serde_json::json!({
                    "event": "relay_insecure_http",
                    "listen": config.listen.to_string(),
                    "relayUrl": config.relay_url,
                    "warning": "serving the relay protocol over cleartext; local development only",
                })
            );
            None
        }
    };
    let listener = TcpListener::bind(config.listen).await?;
    let administration = TcpListener::bind(config.admin_listen).await?;
    let admin_permits = Arc::new(Semaphore::new(16));
    let state = State::new(config)?;
    let readiness = Arc::downgrade(&state);
    tokio::spawn(async move {
        loop {
            let Some(state) = readiness.upgrade() else {
                return;
            };
            let _ = state.backend.admit(&"0".repeat(64)).await;
            drop(state);
            tokio::time::sleep(Duration::from_secs(10)).await;
        }
    });
    loop {
        tokio::select! {
            signal = tokio::signal::ctrl_c() => { signal?; return Ok(()) },
            incoming = listener.accept() => {
                let (socket, _) = incoming?;
                socket.set_nodelay(true)?;
                let Ok(permit) = state.connections.clone().try_acquire_owned() else { drop(socket); continue };
                let gate = Gate::new(permit, &state.config); let state = state.clone(); let tls = tls.clone();
                tokio::spawn(async move {
                    if relay_connection(socket, state.clone(), gate, tls).await.is_err() { state.rejected.fetch_add(1, Ordering::Relaxed); }
                });
            },
            incoming = administration.accept() => {
                let (socket, _) = incoming?;
                let Ok(permit) = admin_permits.clone().try_acquire_owned() else { drop(socket); continue };
                let state = state.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    let handler = hyper::service::service_fn(move |request| admin(request, state.clone()));
                    let _ = tokio::time::timeout(Duration::from_secs(5), hyper::server::conn::http1::Builder::new()
                        .max_buf_size(8192).keep_alive(false).serve_connection(hyper_util::rt::TokioIo::new(socket), handler)).await;
                });
            },
        }
    }
}
