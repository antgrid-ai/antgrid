# Iroh staging container integration

This is an operator-applied template. No stack, DNS record, secret or certificate
has been created. The Docker daemon was unavailable during local verification;
container build/run and proxy configuration require staging validation.

Copy `iroh-relay/config.example.json` into a protected file outside the checkout.
Set its backend URL, exact approved public relay origin and independent admission
and administration secrets. Supply trusted TLS files named `fullchain.pem` and
`privkey.pem`; make the mounts readable by UID 65532. Keep `adminListen` at
`127.0.0.1:9000`. Point `IROH_CONFIG_PATH` and `IROH_CERT_DIRECTORY` at their
absolute paths, and `ANTGRID_PRIVATE_NETWORK` at the existing private network
used by the backend.

From this directory, operators can review with `docker compose config`, build
with `docker compose build`, then start staging with `docker compose up -d`.
Only TLS port 443 is published. The proxy shares the relay's network namespace
and exposes administration on container port 9001 to that private network;
port 9001 must never be published or routed from public ingress. Network access
to it belongs only to the backend and monitoring services.

Set this instance's `PEER_POLICY_TARGETS` URL to
`http://iroh:9001/internal/disconnect` with the configured administration secret.
The proxy preserves the exact body and signature; the relay verifies the HMAC.
Other private paths expose health/readiness and metrics. The relay continues to
verify TLS client traffic itself; this proxy does not terminate public TLS.

The example limits are initial bounds, not qualified capacity. Watch readiness,
admission failures, connection pressure, CPU and memory before changing them.
Adapt `monitoring/prometheus.yml` to scrape `iroh:9001` when Prometheus uses the
private Docker network. Service logs and the monitoring guide describe usage
accounting without payload capture.

Verify the container health check, rejection of unsigned administration, actual
backend revocation, endpoint rotation, forced relay, and network isolation before
enabling a client preference. Restarting the stack closes sessions: clients need
fresh E2E and hydration, with no command replay. Production promotion remains
subject to the saved qualification and rollout gates.
