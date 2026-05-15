ARG RUST_VERSION=1.88
FROM rust:${RUST_VERSION}-bookworm AS builder

WORKDIR /llmux
COPY . .
RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    curl \
    criu \
    ca-certificates \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI via apt (https://docs.docker.com/engine/install/debian/)
RUN curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/debian \
        $(. /etc/os-release && grep VERSION_CODENAME /etc/os-release | cut -d'=' -f2) stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

COPY ./examples/portainer-vllm/warmup.sh /usr/local/bin/warmup.sh
COPY --from=builder /llmux/target/release/llmux /usr/local/bin/llmux
COPY ./examples/portainer-vllm/config.yaml /config/config.yaml

RUN chmod +x /usr/local/bin/warmup.sh

ENTRYPOINT ["/usr/local/bin/warmup.sh"]
CMD ["/usr/local/bin/llmux", "-c", "/config/config.yaml"]
