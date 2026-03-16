# Stage 1: Build the release
FROM erlang:26 AS builder

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /vernemq

# Install build dependencies
# build-essential: for compiling C/C++ deps (e.g. eleveldb)
# git: for fetching dependencies
# libsnappy-dev: for eleveldb
# libssl-dev: for crypto
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libsnappy-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy project files (exclude docker-entrypoint.sh — copied separately in runtime stage)
COPY --exclude=docker-entrypoint.sh . .

# Prepare build vars
RUN cat vars.config pkg.vars.config > vars.generated \
    && chmod +x rebar3

# Fetch all deps and build release — both in one retry loop.
# rebar3 release fetches transitive deps not covered by get-deps alone,
# so both commands must be inside the retry loop.
RUN for i in 1 2 3 4 5; do \
    echo "==> Build attempt $i..." \
    && ./rebar3 get-deps \
    && ./rebar3 release \
    && break \
    || { echo "==> Attempt $i failed, retrying in 15s..."; sleep 15; }; \
    done



# Stage 2: Create the runtime image
FROM debian:bookworm-slim

WORKDIR /vernemq

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsnappy1v5 \
    openssl \
    ca-certificates \
    iproute2 \
    curl \
    procps \
    hostname \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Copy the release from the builder stage
COPY --from=builder /vernemq/_build/default/rel/vernemq ./

# Embed custom Lua auth scripts (override defaults baked into the release)
COPY patch/postgres.lua              /vernemq/share/lua/auth/postgres.lua
COPY patch/postgres_cockroach_commons.lua /vernemq/share/lua/auth/postgres_cockroach_commons.lua

# Embed vernemq.conf template (envsubst renders it at startup)
COPY patch/vernemq.conf.template     /vernemq/etc/vernemq.conf.template

ENV PATH="/vernemq/bin:$PATH"
ENV HOME="/vernemq"

EXPOSE 1883 8883 8084 8080 443 4369 8888 9100 9101 9102 9103 9104 9105 9106 9107 9108 9109

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN groupadd -r vernemq && useradd -r -g vernemq vernemq \
    && chown -R vernemq:vernemq /vernemq \
    && echo "vmq" > /vernemq/.erlang.cookie \
    && chown vernemq:vernemq /vernemq/.erlang.cookie \
    && chmod 400 /vernemq/.erlang.cookie \
    && chmod +x /usr/local/bin/docker-entrypoint.sh

USER vernemq

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
