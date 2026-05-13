ARG RUST_VERSION=1.88
FROM rust:${RUST_VERSION}-bookworm as builder

WORKDIR /llmux
COPY . .
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
COPY --from=builder /llmux/target/release/llmux /usr/local/bin/llmux

ENTRYPOINT ["/usr/local/bin/llmux"]
CMD ["-c", "/config/config.yaml", "-p", "3000"]
