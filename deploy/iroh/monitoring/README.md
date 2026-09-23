# Relay monitoring

Run Prometheus in the relay's network namespace (`network_mode: 'service:iroh'`
on the Prometheus container, or an equivalent private sidecar route) so it can
reach the metrics listener on `127.0.0.1:9000`, which is never published. The
relay's metrics port is moved off upstream's default 9090 because Prometheus
listens there itself inside that shared namespace. Mount `prometheus.yml` and
`alerts.yml` together, then import `grafana-dashboard.json` into Grafana and
select the Prometheus data source. These files configure monitoring; no service
has been deployed by committing them.

The `relayserver-healthz` job needs a `blackbox_exporter` (not part of this
compose stack) reachable from Prometheus at `blackbox-exporter:9115` with the
standard `http_2xx` module. It probes `/healthz` at the relay's public origin:
the stock relay serves `/healthz` only on its HTTPS listener, and the exporter
runs in its own network namespace, where `127.0.0.1` is not the relay. Replace
the example hostname with the deployed origin. The stock relay has no
administration API, so nothing else needs a private route.

Validate with `promtool check config prometheus.yml` and
`promtool check rules alerts.yml` in a qualified Prometheus installation. Tune
alert thresholds against staging load before promotion. Absence of metrics is a
failure, never zero traffic or zero latency.

All counters are process-wide, not per-account or per-endpoint: the stock
relay's `relayserver_*` group has no per-account transport bytes, no backend
readiness and no admission-rejection counter. Access decisions happen on web,
so alerting on denials and access-check timeouts belongs to web's monitoring.
Counters reset on process restart; use `rate`/`increase`, not subtraction of
arbitrary samples.

This dashboard measures service health and relay usage. It does not establish
direct-path savings or interactive performance. Export matched workload results
and application lifecycle captures separately; missing path-byte classification
and connection-stage samples remain qualification gaps. Add host CPU/memory
metrics from the deployment's existing process/container exporter.
