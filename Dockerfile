FROM elixir:1.19.5-otp-28 AS build

ENV MIX_ENV=prod \
    LANG=C.UTF-8

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config

RUN mix deps.get --only ${MIX_ENV}
RUN mix deps.compile

COPY lib lib
COPY priv priv
COPY assets assets
COPY rel rel

RUN mix compile
RUN mix assets.deploy
RUN mix release

FROM debian:bookworm-slim AS app

ENV LANG=C.UTF-8 \
    PHX_SERVER=true \
    HOME=/app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      libncurses6 \
      libstdc++6 \
      locales \
      openssl && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen

WORKDIR /app

RUN useradd --system --create-home --home-dir /app appuser

COPY --from=build --chown=appuser:appuser /app/_build/prod/rel/store ./

USER appuser

EXPOSE 4000

CMD ["bin/store", "start"]
