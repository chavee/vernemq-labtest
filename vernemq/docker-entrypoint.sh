#!/bin/bash
set -e

# Set Erlang cookie — always use VMQ_DISTRIBUTED_COOKIE if provided,
# otherwise fall back to existing file or default 'vmq'.
if [ -n "${VMQ_DISTRIBUTED_COOKIE:-}" ]; then
    COOKIE="$VMQ_DISTRIBUTED_COOKIE"
elif [ -f /vernemq/.erlang.cookie ] && [ -r /vernemq/.erlang.cookie ]; then
    COOKIE=$(cat /vernemq/.erlang.cookie)
else
    COOKIE="vmq"
fi
rm -f /vernemq/.erlang.cookie 2>/dev/null || true
echo "$COOKIE" > /vernemq/.erlang.cookie
chmod 400 /vernemq/.erlang.cookie

# Node name: VMQ_NODENAME is canonical; fall back to DOCKER_VERNEMQ_NODENAME (legacy) then 127.0.0.1
# Either form may include "VerneMQ@" prefix (k8s) or be just a hostname/IP (compose)
_RAW_NODENAME=${VMQ_NODENAME:-${DOCKER_VERNEMQ_NODENAME:-127.0.0.1}}
# Strip "VerneMQ@" prefix if present so NODE_HOST is always just the hostname/IP
NODE_HOST="${_RAW_NODENAME#VerneMQ@}"
# Full Erlang node name used in vernemq.conf and vm.args
NODENAME="VerneMQ@${NODE_HOST}"

# Update vm.args template with the correct node name.
# Note: VerneMQ actually boots from generated.configs/vm.*.args (produced by
# "vernemq config generate" below), but we patch the template too for consistency.
VMARGS_FILE=""
if [ -f /vernemq/etc/vm.args ]; then
    VMARGS_FILE=/vernemq/etc/vm.args
else
    VMARGS_FILE=$(find /vernemq/releases -name "vm.args" 2>/dev/null | head -1)
fi
if [ -n "$VMARGS_FILE" ]; then
    sed -r \
        -e "s/-name VerneMQ@[^ ]+/-name ${NODENAME}/" \
        -e "s/-setcookie [^ ]+/-setcookie ${COOKIE}/" \
        -e "/-eval.+/d" \
        "$VMARGS_FILE" > /tmp/vm.args.tmp

    # For non-seed nodes, inject cluster join into vm.args (same as official docker-vernemq).
    # -eval runs right after boot, before systree populates metadata, so is_empty() returns true.
    if [ -n "${VMQ_DISCOVERY_NODE:-}" ] && [ "${NODENAME}" != "${VMQ_DISCOVERY_NODE}" ]; then
        printf '\n%s\n' "-eval \"vmq_server_cmd:node_join('${VMQ_DISCOVERY_NODE}')\"" >> /tmp/vm.args.tmp
        echo "vm.args: added -eval node_join for ${VMQ_DISCOVERY_NODE}"
    fi

    cat /tmp/vm.args.tmp > "$VMARGS_FILE"
    rm -f /tmp/vm.args.tmp
fi

# Generate vernemq.conf from template (envsubst replaces ${VAR} tokens)
# NOTE: envsubst does NOT support bash ${VAR:-default} syntax.
#       Set defaults here explicitly before calling envsubst.
TEMPLATE_FILE="/vernemq/etc/vernemq.conf.template"
CONFIG_FILE="/vernemq/etc/vernemq.conf"

export VMQ_ALLOW_ANONYMOUS="${VMQ_ALLOW_ANONYMOUS:-off}"
export VMQ_LOG_CONSOLE_LEVEL="${VMQ_LOG_CONSOLE_LEVEL:-warning}"

if [ -f "$TEMPLATE_FILE" ]; then
    envsubst < "$TEMPLATE_FILE" > "$CONFIG_FILE"
    echo "Generated vernemq.conf from template"
else
    echo "WARNING: $TEMPLATE_FILE not found, using existing vernemq.conf"
fi


# Strip any previously generated config block (idempotent on restarts)
# The bind-mounted file persists across restarts so we must clean it first.
# Use a temp file because sed -i cannot rename bind-mounted files in Docker.
TMPCONF=$(mktemp)
sed '/^########## Docker Generated Config ##########/,/^########## End Docker Generated Config ##########/d' "$CONFIG_FILE" \
    | sed '/^[[:space:]]*$/{ /./!d }' > "$TMPCONF"
cat "$TMPCONF" > "$CONFIG_FILE"
rm -f "$TMPCONF"


# Append dynamic settings to vernemq.conf
# (base config is generated from vernemq.conf.template via envsubst above)
echo "" >> "$CONFIG_FILE"
echo "########## Docker Generated Config ##########" >> "$CONFIG_FILE"

# ── Logging ───────────────────────────────────────────────────────────────────
echo "log.console.level = ${VMQ_LOG_CONSOLE_LEVEL}" >> "$CONFIG_FILE"
echo "" >> "$CONFIG_FILE"

# ── Erlang distribution cookie ────────────────────────────────────────────────
echo "distributed_cookie = ${COOKIE}" >> "$CONFIG_FILE"
echo "" >> "$CONFIG_FILE"

# ── Node identity (must match Erlang -name so generated vm.args is correct) ──
echo "nodename = ${NODENAME}" >> "$CONFIG_FILE"
echo "" >> "$CONFIG_FILE"

# ── Plain TCP listener (mqtt / 1883) ──────────────────────────────────────────
echo "listener.tcp.mqtt = 0.0.0.0:1883" >> "$CONFIG_FILE"
echo "" >> "$CONFIG_FILE"

# ── WebSocket listeners ───────────────────────────────────────────────────────
echo "listener.ws.ws = 0.0.0.0:8080" >> "$CONFIG_FILE"
echo "" >> "$CONFIG_FILE"

# ── Plugins ───────────────────────────────────────────────────────────────────
echo "plugins.vmq_passwd = off" >> "$CONFIG_FILE"
echo "plugins.vmq_acl = ${VMQ_PLUGINS__VMQ_ACL:-off}" >> "$CONFIG_FILE"
echo "" >> "$CONFIG_FILE"

# ── Redis / vmq_diversity ────────────────────────────────────────────────────
REDIS_HOST="${VMQ_DIVERSITY__REDIS__HOST:-}"
if [ -n "$REDIS_HOST" ]; then
    echo "vmq_diversity.redis.host = ${REDIS_HOST}" >> "$CONFIG_FILE"
    echo "vmq_diversity.redis.port = ${VMQ_DIVERSITY__REDIS__PORT:-6379}" >> "$CONFIG_FILE"
    echo "vmq_diversity.redis.database = ${VMQ_DIVERSITY__REDIS__DATABASE:-0}" >> "$CONFIG_FILE"
    # Only write password if provided (empty = no auth)
    if [ -n "${VMQ_DIVERSITY__REDIS__PASSWORD:-}" ]; then
        echo "vmq_diversity.redis.password = ${VMQ_DIVERSITY__REDIS__PASSWORD}" >> "$CONFIG_FILE"
    fi
    echo "vmq_diversity.redis.pool_size = ${VMQ_DIVERSITY__REDIS__POOL_SIZE:-5}" >> "$CONFIG_FILE"
    echo "" >> "$CONFIG_FILE"
fi

# ── PostgreSQL / vmq_diversity auth ──────────────────────────────────────────
if [ "${VMQ_PLUGINS__VMQ_DIVERSITY:-off}" = "on" ]; then
    echo "plugins.vmq_diversity = on" >> "$CONFIG_FILE"
    echo "vmq_diversity.auth_postgres.enabled = ${VMQ_DIVERSITY__AUTH_POSTGRES__ENABLED:-off}" >> "$CONFIG_FILE"
    echo "vmq_diversity.postgres.host = ${VMQ_DIVERSITY__POSTGRES__HOST:-localhost}" >> "$CONFIG_FILE"
    echo "vmq_diversity.postgres.port = ${VMQ_DIVERSITY__POSTGRES__PORT:-5432}" >> "$CONFIG_FILE"
    echo "vmq_diversity.postgres.user = ${VMQ_DIVERSITY__POSTGRES__USER:-postgres}" >> "$CONFIG_FILE"
    echo "vmq_diversity.postgres.password = ${VMQ_DIVERSITY__POSTGRES__PASSWORD:-password}" >> "$CONFIG_FILE"
    echo "vmq_diversity.postgres.database = ${VMQ_DIVERSITY__POSTGRES__DATABASE:-vernemq}" >> "$CONFIG_FILE"
    # echo "vmq_diversity.postgres.password_hash_method = ${VMQ_DIVERSITY__POSTGRES__PASSWORD_HASH_METHOD:-crypt}" >> "$CONFIG_FILE"
    echo "vmq_diversity.postgres.pool_size = ${VMQ_DIVERSITY__POSTGRES__POOL_SIZE:-5}" >> "$CONFIG_FILE"
    echo "" >> "$CONFIG_FILE"
fi

# ── TLS listeners (only if all three cert files are specified) ────────────────
SSL_CAFILE="${VMQ_SSL_CAFILE:-}"
SSL_CERTFILE="${VMQ_SSL_CERTFILE:-}"
SSL_KEYFILE="${VMQ_SSL_KEYFILE:-}"

if [ -n "$SSL_CAFILE" ] && [ -n "$SSL_CERTFILE" ] && [ -n "$SSL_KEYFILE" ]; then

    # mqtts (8883): TLS, username+password — client cert optional
    echo "listener.ssl.mqtts = 0.0.0.0:8883" >> "$CONFIG_FILE"
    echo "listener.ssl.mqtts.cafile = ${SSL_CAFILE}" >> "$CONFIG_FILE"
    echo "listener.ssl.mqtts.certfile = ${SSL_CERTFILE}" >> "$CONFIG_FILE"
    echo "listener.ssl.mqtts.keyfile = ${SSL_KEYFILE}" >> "$CONFIG_FILE"
    echo "listener.ssl.mqtts.require_certificate = off" >> "$CONFIG_FILE"
    echo "" >> "$CONFIG_FILE"

    # x509 (8084): TLS, mTLS only — cert CN becomes username, mountpoint=x509
    echo "listener.ssl.x509 = 0.0.0.0:8084" >> "$CONFIG_FILE"
    echo "listener.ssl.x509.cafile = ${SSL_CAFILE}" >> "$CONFIG_FILE"
    echo "listener.ssl.x509.certfile = ${SSL_CERTFILE}" >> "$CONFIG_FILE"
    echo "listener.ssl.x509.keyfile = ${SSL_KEYFILE}" >> "$CONFIG_FILE"
    echo "listener.ssl.x509.require_certificate = on" >> "$CONFIG_FILE"
    echo "listener.ssl.x509.use_identity_as_username = on" >> "$CONFIG_FILE"
    echo "listener.ssl.x509.mountpoint = x509" >> "$CONFIG_FILE"
    echo "" >> "$CONFIG_FILE"

    # wss (443): WebSocket over TLS
    echo "listener.wss.wss = 0.0.0.0:443" >> "$CONFIG_FILE"
    echo "listener.wss.wss.cafile = ${SSL_CAFILE}" >> "$CONFIG_FILE"
    echo "listener.wss.wss.certfile = ${SSL_CERTFILE}" >> "$CONFIG_FILE"
    echo "listener.wss.wss.keyfile = ${SSL_KEYFILE}" >> "$CONFIG_FILE"
    echo "listener.wss.wss.require_certificate = off" >> "$CONFIG_FILE"
    echo "" >> "$CONFIG_FILE"

fi

echo "########## End Docker Generated Config ##########" >> "$CONFIG_FILE"

echo "Generated config appended to vernemq.conf"


# Check configuration file
echo "Checking configuration..."
/vernemq/bin/vernemq config generate 2>&1 | tee /tmp/config.out

if grep -q "error" /tmp/config.out; then
    echo "Configuration error detected!"
    cat /tmp/config.out
    exit 1
fi

echo "Configuration OK. Starting VerneMQ..."

# Cluster join verification (non-seed nodes).
# Primary join happens via -eval in vm.args (injected above).
# This background task verifies the join succeeded; if not, retries via vmq-admin.
if [ -n "${VMQ_DISCOVERY_NODE:-}" ] && [ "${NODENAME}" != "${VMQ_DISCOVERY_NODE}" ]; then
    (
        until /vernemq/bin/vmq-admin cluster show >/dev/null 2>&1; do
            sleep 1
        done
        sleep 5
        if /vernemq/bin/vmq-admin cluster show 2>/dev/null | grep -q "${VMQ_DISCOVERY_NODE}"; then
            echo "[cluster-join] Successfully joined cluster with ${VMQ_DISCOVERY_NODE}."
        else
            echo "[cluster-join] -eval node_join did not succeed, retrying via vmq-admin..."
            for attempt in 1 2 3; do
                /vernemq/bin/vmq-admin cluster join discovery-node="${VMQ_DISCOVERY_NODE}" 2>&1 && break
                sleep 5
            done
        fi
    ) &
fi

# Add API Key on startup — seed node only (avoids interfering with cluster join on non-seed nodes)
if [ -n "${VMQ_APIKEY:-}" ]; then
    _IS_SEED=false
    if [ -z "${VMQ_DISCOVERY_NODE:-}" ] || [ "${NODENAME}" = "${VMQ_DISCOVERY_NODE}" ]; then
        _IS_SEED=true
    fi
    if [ "$_IS_SEED" = "true" ]; then
        (
            until /vernemq/bin/vmq-admin cluster show >/dev/null 2>&1; do
                sleep 1
            done
            echo "VerneMQ is ready. Adding API Key: ${VMQ_APIKEY}"
            /vernemq/bin/vmq-admin api-key add key="${VMQ_APIKEY}" || true
        ) &
    fi
fi

# Start VerneMQ: use background mode if --background flag is passed, otherwise foreground
if [ "$1" = "--background" ]; then
    /vernemq/bin/vernemq start
    echo "VerneMQ started in background."
else
    exec /vernemq/bin/vernemq console -noshell -noinput
fi
