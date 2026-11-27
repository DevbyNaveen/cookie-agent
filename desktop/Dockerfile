# Cookie team runner for a cloud box. Build from the cookie-harness root:
#   docker build -f desktop/Dockerfile -t cookie-team .
#   docker run -d -p 4519:4519 -v cookie-team:/data \
#     -e ANTHROPIC_API_KEY=... -e COOKIE_SECRETS_KEY=$(openssl rand -base64 32) \
#     cookie-team --public-url https://cookie.example.com
# Put it behind HTTPS (a load balancer, Caddy, a tunnel): tokens travel in requests.
#
# COOKIE_SECRETS_KEY seals the key file on /data (AES-256-GCM): keep it in the host's
# secret store, never on the same volume. Lose it and the saved keys must be entered again.
#
# Vaults (each agent's own Linux machine) need KVM: run on a host with /dev/kvm and pass
# it in (`--device /dev/kvm`), with the vault image under /data/parallax/images
# (see parallax/host/setup.sh). Without it, agents still have worlds, scripts and the web.
FROM rust:1.93-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# The harness, Parallax, and the desktop workspace (every member's manifest is needed to
# resolve it; only the team runner is built: no Tauri, no window).
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY parallax ./parallax
COPY desktop/Cargo.toml desktop/Cargo.lock ./desktop/
COPY desktop/team ./desktop/team
COPY desktop/net ./desktop/net
COPY desktop/hands ./desktop/hands
COPY desktop/relay ./desktop/relay
COPY desktop/src-tauri ./desktop/src-tauri
COPY desktop/ui ./desktop/ui
COPY desktop/skills-catalog ./desktop/skills-catalog
RUN cd desktop && cargo build --release -p cookie-team --bin cookie-team

FROM debian:bookworm-slim
# python3: code mode, watchers and the tools agents make. bubblewrap: the sandbox every
# command runs in on Linux. Firecracker is the host's (vaults), not the image's.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates python3 bubblewrap && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 10001 cookie && mkdir /data && chown cookie /data
COPY --from=build /src/desktop/target/release/cookie-team /usr/local/bin/cookie-team
USER cookie
VOLUME /data
EXPOSE 4519
ENTRYPOINT ["cookie-team", "serve", "--dir", "/data", "--bind", "0.0.0.0", "--port", "4519"]
