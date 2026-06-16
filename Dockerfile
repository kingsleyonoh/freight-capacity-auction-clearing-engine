# Freight Capacity Auction Clearing Engine
FROM ocaml/opam:debian-12-ocaml-5.2 AS build
WORKDIR /workspace
COPY --chown=opam:opam . .
RUN opam switch create . 5.2.0 --deps-only --with-test || opam install . --deps-only --with-test -y
RUN opam exec -- dune build @all

FROM debian:12-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libpq5 redis-tools duckdb && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /workspace/_build/default/bin/server.exe /app/server.exe
COPY --from=build /workspace/_build/default/bin/worker.exe /app/worker.exe
COPY --from=build /workspace/_build/default/bin/migrate.exe /app/migrate.exe
COPY --from=build /workspace/_build/default/bin/setup.exe /app/setup.exe
EXPOSE 8080
CMD ["/app/server.exe"]
