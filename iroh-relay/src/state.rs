use crate::{
    auth::{Admission, Backend, generation},
    config::Config,
};
use anyhow::{Result, ensure};
use futures_util::task::AtomicWaker;
use iroh_relay::server::{clients::Clients, streams::Bucket};
use std::{
    collections::HashMap,
    io,
    sync::{
        Arc, Mutex, Weak,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

pub struct Account {
    pub inner: Mutex<AccountState>,
    rx: AtomicU64,
    tx: AtomicU64,
}
pub struct AccountState {
    pub policy: u64,
    pub epoch: u64,
    pub clients: Clients,
    pub gates: Vec<(String, Weak<Gate>)>,
}
impl AccountState {
    pub fn retire(&mut self) {
        self.epoch = self.epoch.checked_add(1).expect("local epoch overflow");
        for gate in self.gates.drain(..).filter_map(|(_, gate)| gate.upgrade()) {
            gate.stop();
        }
        let old = std::mem::take(&mut self.clients);
        tokio::spawn(async move {
            old.shutdown().await;
        });
    }
}
#[derive(Clone)]
pub struct Binding {
    pub account: Arc<Account>,
    pub epoch: u64,
    pub admission: Admission,
    pub deadline: Instant,
}
pub struct Gate {
    pub active: AtomicBool,
    pub binding: Mutex<Option<Binding>>,
    pending_deadline: Instant,
    pub reader: AtomicWaker,
    pub writer: AtomicWaker,
    pub rx: AtomicU64,
    pub tx: AtomicU64,
    rx_budget: Mutex<Bucket>,
    tx_budget: Mutex<Bucket>,
    _permit: OwnedSemaphorePermit,
}
impl Gate {
    pub fn new(permit: OwnedSemaphorePermit, config: &Config) -> Arc<Self> {
        let bucket = || {
            Bucket::new(
                config.burst_bytes as i64,
                config.bytes_per_second as i64,
                Duration::from_millis(100),
            )
            .expect("validated traffic bounds")
        };
        Arc::new(Self {
            active: AtomicBool::new(true),
            binding: Mutex::new(None),
            pending_deadline: Instant::now() + Duration::from_secs(5),
            reader: AtomicWaker::new(),
            writer: AtomicWaker::new(),
            rx: AtomicU64::new(0),
            tx: AtomicU64::new(0),
            rx_budget: Mutex::new(bucket()),
            tx_budget: Mutex::new(bucket()),
            _permit: permit,
        })
    }
    pub fn stop(&self) {
        self.active.store(false, Ordering::SeqCst);
        self.reader.wake();
        self.writer.wake();
    }
    pub fn allowed<T>(&self, operation: impl FnOnce() -> T) -> io::Result<T> {
        let binding = self.binding.lock().expect("gate lock");
        if !self.active.load(Ordering::SeqCst) {
            return Err(denied());
        }
        if let Some(binding) = binding.as_ref() {
            let mut state = binding.account.inner.lock().expect("account lock");
            if state.epoch != binding.epoch || Instant::now() >= binding.deadline {
                if state.epoch == binding.epoch {
                    state.retire();
                }
                return Err(denied());
            }
            // The account lock linearizes raw writes with administration acknowledgement.
            Ok(operation())
        } else if Instant::now() < self.pending_deadline {
            Ok(operation())
        } else {
            Err(denied())
        }
    }
    pub fn reserve(&self, bytes: usize, write: bool) -> io::Result<()> {
        let budget = if write {
            &self.tx_budget
        } else {
            &self.rx_budget
        };
        if budget.lock().expect("budget lock").consume(bytes).is_err() {
            self.stop();
            return Err(io::Error::other("traffic budget exceeded"));
        }
        Ok(())
    }
    pub fn record_bytes(&self, count: usize, write: bool) {
        // Binding transfers pre-authentication totals under this same lock.
        let binding = self.binding.lock().expect("gate lock");
        let counter = if write { &self.tx } else { &self.rx };
        counter.fetch_add(count as u64, Ordering::Relaxed);
        if let Some(binding) = binding.as_ref() {
            let counter = if write {
                &binding.account.tx
            } else {
                &binding.account.rx
            };
            counter.fetch_add(count as u64, Ordering::Relaxed);
        }
    }
}
impl Drop for Gate {
    fn drop(&mut self) {
        if let Some(binding) = self.binding.get_mut().expect("gate lock").as_ref() {
            println!(
                "{}",
                serde_json::json!({"event":"endpoint-usage", "userId":binding.admission.user_id,
                "endpointId":binding.admission.endpoint_id, "rxTransportBytes":self.rx.load(Ordering::Relaxed),
                "txTransportBytes":self.tx.load(Ordering::Relaxed)})
            );
        }
    }
}
pub fn denied() -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, "authorization unavailable")
}
pub struct State {
    pub config: Config,
    pub backend: Backend,
    accounts: Mutex<HashMap<String, Arc<Account>>>,
    pub invalidations: AtomicU64,
    pub admitted: AtomicU64,
    pub rejected: AtomicU64,
    pub connections: Arc<Semaphore>,
}
impl State {
    pub fn new(config: Config) -> Result<Arc<Self>> {
        Ok(Arc::new(Self {
            backend: Backend::new(&config)?,
            connections: Arc::new(Semaphore::new(config.max_connections)),
            config,
            accounts: Mutex::new(HashMap::new()),
            invalidations: AtomicU64::new(0),
            admitted: AtomicU64::new(0),
            rejected: AtomicU64::new(0),
        }))
    }
    fn account(&self, user: &str) -> Result<Arc<Account>> {
        let mut accounts = self.accounts.lock().expect("accounts lock");
        if let Some(account) = accounts.get(user) {
            return Ok(account.clone());
        }
        ensure!(
            accounts.len() < self.config.max_accounts,
            "account capacity exceeded"
        );
        let account = Arc::new(Account {
            inner: Mutex::new(AccountState {
                policy: 0,
                epoch: 0,
                clients: Clients::default(),
                gates: Vec::new(),
            }),
            rx: AtomicU64::new(0),
            tx: AtomicU64::new(0),
        });
        accounts.insert(user.to_owned(), account.clone());
        Ok(account)
    }
    pub fn bind(
        &self,
        gate: &Arc<Gate>,
        admission: Admission,
        deadline: Instant,
        serial: u64,
    ) -> Result<Binding> {
        let account = self.account(&admission.user_id)?;
        let mut gate_binding = gate.binding.lock().expect("gate lock");
        ensure!(gate_binding.is_none(), "connection already bound");
        let mut state = account.inner.lock().expect("account lock");
        ensure!(
            self.invalidations.load(Ordering::SeqCst) == serial,
            "administration raced admission"
        );
        ensure!(
            gate.active.load(Ordering::SeqCst) && Instant::now() < deadline,
            "admission expired"
        );
        let policy = generation(&admission.policy_generation)?;
        ensure!(policy >= state.policy, "stale policy");
        if policy > state.policy {
            state.retire();
            state.policy = policy;
        }
        state.gates.retain(|(_, gate)| gate.strong_count() > 0);
        ensure!(
            state.gates.len() < self.config.max_account_connections,
            "account connection capacity"
        );
        ensure!(
            state
                .gates
                .iter()
                .filter(|(id, _)| *id == admission.endpoint_id)
                .count()
                < self.config.max_endpoint_connections,
            "endpoint connection capacity"
        );
        let endpoint_id = admission.endpoint_id.clone();
        let binding = Binding {
            account: account.clone(),
            epoch: state.epoch,
            admission,
            deadline,
        };
        account
            .rx
            .fetch_add(gate.rx.load(Ordering::Relaxed), Ordering::Relaxed);
        account
            .tx
            .fetch_add(gate.tx.load(Ordering::Relaxed), Ordering::Relaxed);
        *gate_binding = Some(binding.clone());
        state.gates.push((endpoint_id, Arc::downgrade(gate)));
        Ok(binding)
    }
    pub fn invalidate(&self, user: &str, policy: u64) -> Result<()> {
        // Fence all in-flight responses, including requests whose account was not known yet.
        self.invalidations.fetch_add(1, Ordering::SeqCst);
        let account = self.account(user)?;
        let mut state = account.inner.lock().expect("account lock");
        if policy > state.policy {
            state.policy = policy;
            state.retire();
        }
        Ok(())
    }
    pub fn expire(&self, gate: &Gate) {
        let binding = gate.binding.lock().expect("gate lock").clone();
        if let Some(binding) = binding {
            let mut state = binding.account.inner.lock().expect("account lock");
            if state.epoch == binding.epoch {
                state.retire();
            }
        } else {
            gate.stop();
        }
    }
    pub fn maintain(self: &Arc<Self>, gate: &Arc<Gate>) {
        let weak = Arc::downgrade(gate);
        let state = self.clone();
        tokio::spawn(async move {
            loop {
                let Some(gate) = weak.upgrade() else { return };
                if !gate.active.load(Ordering::SeqCst) {
                    return;
                }
                let deadline = gate
                    .binding
                    .lock()
                    .expect("gate lock")
                    .as_ref()
                    .expect("admitted")
                    .deadline;
                drop(gate);
                tokio::time::sleep(
                    Duration::from_secs(20).min(deadline.saturating_duration_since(Instant::now())),
                )
                .await;
                let Some(gate) = weak.upgrade() else { return };
                if gate.allowed(|| ()).is_err() {
                    state.expire(&gate);
                    return;
                }
                let current = gate
                    .binding
                    .lock()
                    .expect("gate lock")
                    .clone()
                    .expect("admitted");
                let refresh = tokio::time::timeout_at(
                    tokio::time::Instant::from_std(current.deadline),
                    state.backend.admit(&current.admission.endpoint_id),
                )
                .await;
                match refresh {
                    Ok(Ok((admission, deadline))) => {
                        let mut binding = gate.binding.lock().expect("gate lock");
                        let mut account = current.account.inner.lock().expect("account lock");
                        if !gate.active.load(Ordering::SeqCst) || account.epoch != current.epoch {
                            return;
                        }
                        if Instant::now() >= current.deadline || Instant::now() >= deadline {
                            account.retire();
                            return;
                        }
                        if admission.user_id != current.admission.user_id
                            || admission.device_id != current.admission.device_id
                            || admission.enrollment_id != current.admission.enrollment_id
                            || admission.registration_generation
                                != current.admission.registration_generation
                            || admission.policy_generation != current.admission.policy_generation
                        {
                            if let Ok(next) = generation(&admission.policy_generation) {
                                account.policy = account.policy.max(next);
                            }
                            account.retire();
                            return;
                        }
                        binding.as_mut().expect("admitted").deadline = deadline;
                    }
                    // Fail closed even on transient backend errors; no outage extends authority.
                    _ => {
                        state.expire(&gate);
                        return;
                    }
                }
            }
        });
    }
    pub fn metrics(&self) -> serde_json::Value {
        serde_json::json!({"accounts":self.accounts.lock().expect("accounts lock").len(),
            "admitted":self.admitted.load(Ordering::Relaxed), "rejected":self.rejected.load(Ordering::Relaxed),
            "invalidations":self.invalidations.load(Ordering::Relaxed)})
    }
    pub fn prometheus(&self) -> String {
        let mut output = format!(
            "antgrid_iroh_admissions_total {}\nantgrid_iroh_rejections_total {}\nantgrid_iroh_invalidations_total {}\nantgrid_iroh_connections {}\nantgrid_iroh_pending_admissions {}\nantgrid_iroh_backend_ready {}\n",
            self.admitted.load(Ordering::Relaxed),
            self.rejected.load(Ordering::Relaxed),
            self.invalidations.load(Ordering::Relaxed),
            self.config.max_connections - self.connections.available_permits(),
            self.backend.pending(),
            u8::from(self.backend.ready())
        );
        let accounts = self.accounts.lock().expect("accounts lock");
        output.push_str(&format!("antgrid_iroh_accounts {}\n", accounts.len()));
        for (user, account) in accounts.iter() {
            let clean: String = user
                .chars()
                .map(|c| if c.is_control() { '?' } else { c })
                .collect();
            let label = format!("\"{}\"", clean.replace('\\', "\\\\").replace('"', "\\\""));
            output.push_str(&format!("antgrid_iroh_account_rx_transport_bytes_total{{user_id={label}}} {}\nantgrid_iroh_account_tx_transport_bytes_total{{user_id={label}}} {}\n",
                account.rx.load(Ordering::Relaxed),account.tx.load(Ordering::Relaxed)));
            let current = account.inner.lock().expect("account lock");
            let mut endpoints: HashMap<&str, (u64, u64)> = HashMap::new();
            for (endpoint, gate) in &current.gates {
                if let Some(gate) = gate.upgrade() {
                    let entry = endpoints.entry(endpoint).or_default();
                    entry.0 += gate.rx.load(Ordering::Relaxed);
                    entry.1 += gate.tx.load(Ordering::Relaxed);
                }
            }
            for (endpoint, (rx, tx)) in endpoints {
                output.push_str(&format!("antgrid_iroh_endpoint_rx_transport_bytes_total{{user_id={label},endpoint_id=\"{endpoint}\"}} {rx}\nantgrid_iroh_endpoint_tx_transport_bytes_total{{user_id={label},endpoint_id=\"{endpoint}\"}} {tx}\n"));
            }
        }
        output
    }
}
