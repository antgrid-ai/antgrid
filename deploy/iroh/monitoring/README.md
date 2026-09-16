# Relay monitoring

Run Prometheus in the relay's network namespace or use an authenticated private
sidecar route. The example target is the relay's loopback administration listener;
do not publish that listener to the public network. Mount `prometheus.yml` and
`alerts.yml` together, then import `grafana-dashboard.json` into Grafana and select
the Prometheus data source. These files configure monitoring; no service has been
deployed by committing them.

Validate with `promtool check config prometheus.yml` and
`promtool check rules alerts.yml` in a qualified Prometheus installation. Tune
alert thresholds against staging load before promotion. Absence of metrics is a
failure, never zero traffic or zero latency.

The byte counters measure relay transport bytes, including framing and TLS
overhead. Live endpoint series are bounded and can reset when a connection is
replaced; use `rate`/`increase`, not subtraction of arbitrary samples. Structured
endpoint usage records preserve completed-connection totals for the operator's
accounting sink. Keep access to account and endpoint identifiers private.

This dashboard measures service health and relay usage. It does not establish
direct-path savings or interactive performance. Export matched workload results
and application lifecycle captures separately; missing path-byte classification
and connection-stage samples remain qualification gaps. Add host CPU/memory
metrics from the deployment's existing process/container exporter.
