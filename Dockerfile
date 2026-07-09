# syntax=docker/dockerfile:1.7

FROM ocaml/opam:debian-12-ocaml-5.2 AS build

USER root
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
       build-essential ca-certificates curl libev-dev libpq-dev libssl-dev pkg-config unzip \
    && rm -rf /var/lib/apt/lists/*

USER opam
WORKDIR /home/opam/app

# Resolve dependencies before copying source so dependency layers remain cacheable.
COPY --chown=opam:opam dune-project freight_capacity_auction_clearing_engine.opam ./
RUN opam install . --deps-only --yes

COPY --chown=opam:opam . .
RUN opam exec -- dune build --profile=release \
      bin/server.exe \
      bin/worker.exe \
      bin/migrate.exe \
      bin/setup.exe

FROM debian:12-slim AS runtime

ARG DUCKDB_VERSION=1.2.2
ARG TARGETARCH

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
       ca-certificates curl dumb-init libev4 libpq5 libssl3 minizinc unzip \
    && case "${TARGETARCH:-amd64}" in \
         amd64) duckdb_arch=amd64 ;; \
         arm64) duckdb_arch=aarch64 ;; \
         *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && curl --fail --location --silent --show-error \
       "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${duckdb_arch}.zip" \
       --output /tmp/duckdb.zip \
    && unzip /tmp/duckdb.zip -d /usr/local/bin \
    && chmod 0755 /usr/local/bin/duckdb \
    && rm -f /tmp/duckdb.zip \
    && groupadd --gid 10001 freight \
    && useradd --uid 10001 --gid freight --create-home --home-dir /app --shell /usr/sbin/nologin freight \
    && mkdir -p /app/bin /app/data \
    && chown -R freight:freight /app \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build --chown=freight:freight /home/opam/app/_build/default/bin/server.exe /app/bin/server.exe
COPY --from=build --chown=freight:freight /home/opam/app/_build/default/bin/worker.exe /app/bin/worker.exe
COPY --from=build --chown=freight:freight /home/opam/app/_build/default/bin/migrate.exe /app/bin/migrate.exe
COPY --from=build --chown=freight:freight /home/opam/app/_build/default/bin/setup.exe /app/bin/setup.exe

ENV APP_ENV=production \
    APP_PORT=8080 \
    REPLAY_STORE_PATH=/app/data/replay.duckdb

USER freight
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:8080/health/ready >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/app/bin/server.exe"]
