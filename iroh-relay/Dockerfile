# Official registry manifest index digests; update only with provenance review.
ARG RUST_IMAGE=rust:1.98.1-bookworm@sha256:9a73a5088750b4c95158ab26629c854c3d6fc4b173cb7bc8079ad252d8ed7bfa
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171
FROM ${RUST_IMAGE} AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY src ./src
RUN rustc --version | grep 'rustc 1.98.1 ' && cargo build --locked --release -j 2

FROM ${RUNTIME_IMAGE}
COPY --from=build /src/target/release/antgrid-iroh-relay /usr/local/bin/antgrid-iroh-relay
USER 65532:65532
EXPOSE 443
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 CMD ["/usr/local/bin/antgrid-iroh-relay", "--healthcheck", "/config/relay.json"]
ENTRYPOINT ["/usr/local/bin/antgrid-iroh-relay"]
CMD ["/config/relay.json"]
