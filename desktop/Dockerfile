# Cookie team runner for a cloud box. Build from the cookie-harness root:
#   docker build -f desktop/Dockerfile -t cookie-team .
#   docker run -d -p 4519:4519 -v cookie-team:/data \
#     -e ANTHROPIC_API_KEY=... cookie-team --public-url https://cookie.example.com
# Put it behind HTTPS (a load balancer, Caddy, a tunnel): tokens travel in requests.
FROM rust:1.93-slim AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY desktop/team ./desktop/team
COPY desktop/ui ./desktop/ui
# The runner builds alone: no Tauri, no window.
RUN cd desktop/team && cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 10001 cookie && mkdir /data && chown cookie /data
COPY --from=build /src/desktop/team/target/release/cookie-team /usr/local/bin/cookie-team
USER cookie
VOLUME /data
EXPOSE 4519
ENTRYPOINT ["cookie-team", "serve", "--dir", "/data", "--bind", "0.0.0.0", "--port", "4519"]
