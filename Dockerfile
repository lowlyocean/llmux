ARG RUST_VERSION=1.88
FROM rust:${RUST_VERSION}-bookworm as builder

WORKDIR /llmux
COPY . .
RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    curl \
    criu \
    && rm -rf /var/lib/apt/lists/*

COPY ./examples/portainer-vllm/warmup.sh /usr/local/bin/warmup.sh
COPY --from=builder /llmux/target/release/llmux /usr/local/bin/llmux
COPY ./examples/portainer-vllm/config.yaml /config/config.yaml

RUN chmod +x /usr/local/bin/warmup.sh

ENTRYPOINT ["/usr/local/bin/warmup.sh"]
CMD ["/usr/local/bin/llmux", "-c", "/config/config.yaml"]
