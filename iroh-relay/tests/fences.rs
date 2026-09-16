use antgrid_iroh_relay::{
    auth::Admission,
    config::Config,
    io::GuardedIo,
    state::{Gate, State},
};
use std::{
    sync::{Arc, atomic::Ordering},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::Semaphore,
};

fn config() -> Config {
    serde_json::from_value(serde_json::json!({"listen":"127.0.0.1:443", "adminListen":"127.0.0.1:9000",
        "tlsCert":"unused", "tlsKey":"unused", "admissionUrl":"http://127.0.0.1/internal/peer-admission",
        "relayUrl":"https://relay.example/", "admissionSecret":"a".repeat(32), "adminSecret":"b".repeat(32),
        "maxConnections":8,"maxPendingAdmissions":2,"maxAccounts":2,"maxAccountConnections":2,
        "maxEndpointConnections":1,"bytesPerSecond":1_000_000,"burstBytes":1_000_000})).unwrap()
}
fn admission(endpoint: u8, user: &str, policy: &str) -> Admission {
    Admission {
        allowed: true,
        request_id: uuid::Uuid::new_v4().to_string(),
        endpoint_id: hex::encode([endpoint; 32]),
        user_id: user.to_owned(),
        device_id: uuid::Uuid::new_v4().to_string(),
        enrollment_id: "enrollment".to_owned(),
        registration_generation: "1".to_owned(),
        policy_generation: policy.to_owned(),
        lease_ms: 60_000,
    }
}
async fn gate(config: &Config) -> Arc<Gate> {
    Gate::new(
        Arc::new(Semaphore::new(1)).acquire_owned().await.unwrap(),
        config,
    )
}

#[tokio::test]
async fn invalidation_fences_raw_writes_and_all_account_destinations() {
    let config = config();
    let state = State::new(config.clone()).unwrap();
    let source = gate(&config).await;
    let destination = gate(&config).await;
    state
        .bind(
            &source,
            admission(1, "account", "1"),
            Instant::now() + Duration::from_secs(60),
            0,
        )
        .unwrap();
    state
        .bind(
            &destination,
            admission(2, "account", "1"),
            Instant::now() + Duration::from_secs(60),
            0,
        )
        .unwrap();
    let (writer, mut reader) = tokio::io::duplex(16);
    let mut writer = GuardedIo::new(writer, destination.clone());
    writer.write_all(b"before").await.unwrap();
    let mut first = [0; 6];
    reader.read_exact(&mut first).await.unwrap();
    assert_eq!(&first, b"before");
    state.invalidate("account", 2).unwrap();
    assert!(
        writer
            .write_all(b"queued-from-revoked-source")
            .await
            .is_err()
    );
    assert!(writer.flush().await.is_err());
    assert!(source.allowed(|| ()).is_err());
    assert!(destination.allowed(|| ()).is_err());
    assert_eq!(destination.tx.load(Ordering::Relaxed), 6);
}

#[tokio::test]
async fn pending_response_cannot_register_after_invalidation_and_limits_are_real() {
    let config = config();
    let state = State::new(config.clone()).unwrap();
    let stale = gate(&config).await;
    state.invalidate("account", 2).unwrap();
    assert!(
        state
            .bind(
                &stale,
                admission(1, "account", "1"),
                Instant::now() + Duration::from_secs(60),
                0
            )
            .is_err()
    );
    assert!(
        state
            .bind(
                &stale,
                admission(1, "account", "1"),
                Instant::now() + Duration::from_secs(60),
                1
            )
            .is_err()
    );
    let current = gate(&config).await;
    state
        .bind(
            &current,
            admission(1, "account", "2"),
            Instant::now() + Duration::from_secs(60),
            1,
        )
        .unwrap();
    assert!(
        state
            .bind(
                &current,
                admission(2, "account", "2"),
                Instant::now() + Duration::from_secs(60),
                1
            )
            .is_err()
    );
    let duplicate = gate(&config).await;
    assert!(
        state
            .bind(
                &duplicate,
                admission(1, "account", "2"),
                Instant::now() + Duration::from_secs(60),
                1
            )
            .is_err()
    );
    state.invalidate("second", 1).unwrap();
    assert!(state.invalidate("third", 1).is_err());
}

#[tokio::test]
async fn blocked_write_is_woken_and_denied_on_account_revocation() {
    let config = config();
    let state = State::new(config.clone()).unwrap();
    let gate = gate(&config).await;
    state
        .bind(
            &gate,
            admission(1, "account", "1"),
            Instant::now() + Duration::from_secs(60),
            0,
        )
        .unwrap();
    let (writer, _reader) = tokio::io::duplex(1);
    let mut writer = GuardedIo::new(writer, gate);
    writer.write_all(b"x").await.unwrap();
    let pending = tokio::spawn(async move { writer.write_all(b"not-dispatched").await });
    tokio::task::yield_now().await;
    state.invalidate("account", 2).unwrap();
    assert!(
        tokio::time::timeout(Duration::from_secs(1), pending)
            .await
            .unwrap()
            .unwrap()
            .is_err()
    );
}

#[tokio::test]
async fn expiry_invalidates_destinations_and_permits_release() {
    let config = config();
    let state = State::new(config.clone()).unwrap();
    let permits = Arc::new(Semaphore::new(1));
    let gate = Gate::new(permits.clone().acquire_owned().await.unwrap(), &config);
    state
        .bind(
            &gate,
            admission(1, "account", "1"),
            Instant::now() + Duration::from_millis(10),
            0,
        )
        .unwrap();
    assert!(permits.clone().try_acquire_owned().is_err());
    tokio::time::sleep(Duration::from_millis(15)).await;
    assert!(gate.allowed(|| ()).is_err());
    drop(gate);
    assert_eq!(permits.available_permits(), 1);
}

#[tokio::test]
async fn transport_accounting_transfers_preauth_bytes_once_and_keeps_anonymous_bytes_unattributed()
{
    let config = config();
    let state = State::new(config.clone()).unwrap();
    let admitted = gate(&config).await;
    let (socket, mut peer) = tokio::io::duplex(128);
    let mut socket = GuardedIo::new(socket, admitted.clone());
    socket.write_all(b"tls-hello").await.unwrap();
    peer.write_all(b"auth").await.unwrap();
    let mut input = [0; 4];
    socket.read_exact(&mut input).await.unwrap();
    assert!(!state.prometheus().contains("user_id=\"account\""));

    state
        .bind(
            &admitted,
            admission(1, "account", "1"),
            Instant::now() + Duration::from_secs(60),
            0,
        )
        .unwrap();
    socket.write_all(b"payload").await.unwrap();
    peer.write_all(b"data").await.unwrap();
    socket.read_exact(&mut input).await.unwrap();
    assert_eq!(admitted.tx.load(Ordering::Relaxed), 16);
    assert_eq!(admitted.rx.load(Ordering::Relaxed), 8);

    let anonymous = gate(&config).await;
    anonymous.record_bytes(99, true);
    anonymous.record_bytes(88, false);
    anonymous.stop();
    assert!(
        state
            .bind(
                &anonymous,
                admission(2, "account", "1"),
                Instant::now() + Duration::from_secs(60),
                0
            )
            .is_err()
    );
    drop(anonymous);
    drop(socket);
    drop(admitted);
    let metrics = state.prometheus();
    assert!(
        metrics.contains("antgrid_iroh_account_tx_transport_bytes_total{user_id=\"account\"} 16\n")
    );
    assert!(
        metrics.contains("antgrid_iroh_account_rx_transport_bytes_total{user_id=\"account\"} 8\n")
    );
    assert!(!metrics.contains("antgrid_iroh_endpoint_tx_transport_bytes_total"));
}

#[tokio::test]
async fn binding_and_concurrent_byte_recording_have_exact_account_totals() {
    let config = config();
    let state = State::new(config.clone()).unwrap();
    let admitted = gate(&config).await;
    admitted.record_bytes(7, false);
    let barrier = Arc::new(std::sync::Barrier::new(2));
    let concurrent_gate = admitted.clone();
    let concurrent_barrier = barrier.clone();
    let recording = std::thread::spawn(move || {
        concurrent_barrier.wait();
        for _ in 0..10_000 {
            concurrent_gate.record_bytes(1, false);
            concurrent_gate.record_bytes(2, true);
        }
    });
    barrier.wait();
    state
        .bind(
            &admitted,
            admission(1, "account", "1"),
            Instant::now() + Duration::from_secs(60),
            0,
        )
        .unwrap();
    recording.join().unwrap();
    let metrics = state.prometheus();
    assert!(
        metrics
            .contains("antgrid_iroh_account_rx_transport_bytes_total{user_id=\"account\"} 10007\n")
    );
    assert!(
        metrics
            .contains("antgrid_iroh_account_tx_transport_bytes_total{user_id=\"account\"} 20000\n")
    );
}
