# Iroh staging container integration

This is an operator-applied template. No stack, DNS record, secret or
certificate has been created. The image and stack have not been built or run;
`docker compose config` and a parse of `relay.example.toml` by the stock
binary are the only local checks, and container build/run require staging
validation.

Copy `relay.example.toml` into a protected file outside the checkout. Fill in
the real hostnames, the approved public relay origin baked into the
`access.http.url` query, and TLS material under `[tls]`. Supply trusted TLS
files named `fullchain.pem` and `privkey.pem`; make the mounts readable by UID
65532. Point `IROH_CONFIG_PATH` and `IROH_CERT_DIRECTORY` at their absolute
paths, `IROH_RELAY_HTTP_BEARER_TOKEN` at the same value web holds as
`PEER_RELAY_ACCESS_TOKEN`, and `ANTGRID_PRIVATE_NETWORK` at the existing
private network used by the backend. The token is env-only by design; never
put it in the mounted file. The image refuses to start when the config file is
missing or has no `[access.http]` table, because the stock binary would
otherwise run as an open relay. Leave `RUST_LOG` unset or at `info`: at `debug` the
stock binary prints its whole parsed config at startup, bearer token included.

From this directory, operators can review with `docker compose config`, build
with `docker compose build`, then start staging with `docker compose up -d`.
Only ports 443 and 80 are published — 80 serves the plain captive-portal probe
(`/generate_204`) that TLS-mode clients use for connectivity checks, nothing
administrative. Metrics stay on `127.0.0.1` inside the container and are never
published; see `monitoring/README.md` for how to reach them. The container
health check probes the captive-portal listener on port 80, so keep
`http_bind_addr` on that port.

The example limits under `[limits]` are initial bounds, not qualified
capacity. Watch `monitoring/grafana-dashboard.json`, connection pressure, CPU
and memory before changing them.

Verify the container health check, the `/healthz` probe, the access check
denying an unregistered endpoint, denial of every new connection once the
origin leaves `IROH_RELAY_URLS`,
endpoint rotation, and network isolation before enabling a client preference.
Restarting the stack closes sessions: clients need fresh E2E and hydration,
with no command replay. Production promotion remains subject to the saved
qualification and rollout gates.

## Cutover from the retired custom relay

The stock relay has no admin HTTP API and no `/internal/disconnect`. Web
decides admission once per relay connection through `access.http`; an
already-admitted connection is not dropped on revocation, and the bridge's
authorization lease retires the revoked peer instead. Follow this order, not a
straight swap:

1. Deploy web with the `/internal/iroh-access` route live and
   `PEER_RELAY_ACCESS_TOKEN` set. The stock relay admits no one until it is.
2. Remove the `http://iroh:9001/internal/disconnect` target from the live
   `PEER_POLICY_TARGETS` secret. A stale target wedges the policy outbox — a
   row only counts as delivered once every target succeeds — and that target
   stops existing the moment the custom relay's admin sidecar is gone.
3. Swap the relay container for this one, keeping the exact same public
   origin in `IROH_RELAY_URLS` and in `relay.example.toml`'s `access.http.url`
   query. Endpoints reconnect against an unchanged relay URL; only what is
   listening behind it changes.
4. Retire the custom relay's deployment once the swap is verified.
