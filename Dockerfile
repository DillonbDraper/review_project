# Keep the OTP major aligned with .tool-versions; build and run on Debian bookworm.
ARG ELIXIR_VERSION=1.20.5
ARG OTP_VERSION=28.3.3
FROM node:24-bookworm-slim AS node
FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-bookworm-20261104-slim@sha256:73b445e0957bb0719ac8e89aec76eb712750f0f369c6de50bc61f0129e59d2cb AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git cmake pkg-config curl ca-certificates \
    libssl-dev libopus-dev libsrtp2-dev libavcodec-dev libavutil-dev libswresample-dev \
    && rm -rf /var/lib/apt/lists/*
# Debian bookworm's nodejs package is too old for Hologram; use Node 24.
COPY --from=node /usr/local/bin/ /usr/local/bin/
COPY --from=node /usr/local/lib/node_modules/ /usr/local/lib/node_modules/
RUN node --version && npm --version
ENV MIX_ENV=prod
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY vendor vendor
COPY config config
RUN mix deps.get --only prod && mix deps.compile
COPY assets assets
COPY priv priv
COPY lib lib
# compile includes Hologram's compiler (and its npm assets), BEFORE digest/release.
RUN mix compile && mix assets.setup && mix assets.deploy && mix release

FROM debian:bookworm-slim AS run
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 libncurses6 openssl ca-certificates locales \
    libopus0 libsrtp2-1 libavcodec59 libavutil57 libswresample4 \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
# Hologram detects a release as dev unless its runtime environment is explicit.
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 PHX_SERVER=true HOLOGRAM_ENV=prod
WORKDIR /app
COPY --from=build --chown=nobody:nogroup /app/_build/prod/rel/review_project ./
# Database-only trust anchor, deliberately outside the OS trust store and immutable
# to the runtime user. DATABASE_SSL remains opt-in.
COPY --chmod=0444 priv/certificates/supabase-root-ca.crt /app/certificates/supabase-root-ca.crt
RUN chmod 0555 /app/certificates
ENV DATABASE_CA_CERT_FILE=/app/certificates/supabase-root-ca.crt
USER nobody
EXPOSE 8080
CMD ["/app/bin/review_project", "start"]
