# No upstream registry image for iroh-relay 1.2.0 has a verified digest, so the
# pinned crate is built from crates.io instead. Base images are pinned by
# official registry manifest index digest; update only with provenance review.
ARG RUST_IMAGE=rust:1.98.1-bookworm@sha256:9a73a5088750b4c95158ab26629c854c3d6fc4b173cb7bc8079ad252d8ed7bfa
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

FROM ${RUST_IMAGE} AS build
RUN cargo install iroh-relay --version 1.2.0 --locked --features server --root /out

FROM ${RUNTIME_IMAGE}
# access.http POSTs to web over rustls, which needs a trust store.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/bin/iroh-relay /usr/local/bin/iroh-relay
# The stock binary treats a missing config file as Config::default(), which is
# access = everyone on plain HTTP, and it ignores unknown keys, so a misspelt
# access table is equally open. Refuse to start rather than serve an open relay.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'set -e' \
      'if [ ! -f /config/relay.toml ]; then echo "iroh-relay: /config/relay.toml is not a file; refusing to start an open relay" >&2; exit 1; fi' \
      'if ! grep -q "^\[access\.http\]" /config/relay.toml; then echo "iroh-relay: /config/relay.toml has no [access.http] table; refusing to start an open relay" >&2; exit 1; fi' \
      'exec /usr/local/bin/iroh-relay --config-path /config/relay.toml "$@"' \
      > /usr/local/bin/relay-entrypoint \
    && chmod 0755 /usr/local/bin/relay-entrypoint
USER 65532:65532
EXPOSE 443 80
# Probes the plain captive-portal listener, which relay.example.toml binds on
# :80; it proves the process is serving, and /healthz over TLS is left to the
# external probe in monitoring/prometheus.yml.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
  CMD ["/bin/bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/80 && printf 'GET /generate_204 HTTP/1.0\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -q ' 204 '"]
ENTRYPOINT ["/usr/local/bin/relay-entrypoint"]
