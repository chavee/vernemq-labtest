-- MQTT Broker - PostgreSQL Auth Entry Point
--
-- Authenticates MQTT clients against the 'devices' table.
-- Two auth methods supported (per device, field auth_method):
--   'certificate' — x.509 mTLS, VerneMQ puts cert CN in reg.username
--   'password'    — MQTT username + bcrypt password
--   'both'        — either method accepted
--
-- Disconnect events are debounced via Redis (SETEX) so rapid
-- connect/disconnect cycles do not hammer PostgreSQL.
-- The API worker polls Redis and flushes to DB in batch.
--
-- Logic is in postgres_cockroach_commons.lua (loaded from same dir).

require "auth/auth_commons"
require "auth/postgres_cockroach_commons"

function auth_on_register(reg)
    return auth_on_register_common(postgres, reg)
end

-- PostgreSQL pool
pool = "auth_postgres"
postgres.ensure_pool({ pool_id = pool, ssl = false })

-- Redis pool (for disconnect debounce)
-- Host/port/database come from vmq_diversity.redis.* in vernemq.conf
-- (set by docker-entrypoint.sh from VMQ_DIVERSITY__REDIS__* env vars)
redis_pool = "auth_redis"
redis.ensure_pool({
    pool_id = redis_pool,
    size = 100,
    max_overflow = 0
})


-- Disconnect hooks defined here (not in required file) so luerl
-- resolves them in this script's own global scope for hook dispatch.
local DISCONNECT_TTL = 30

local function do_disconnect(...)
    -- luerl may pass the proplist [{mountpoint,MP},{client_id,CID}] as:
    --   a) a single table arg with string keys: reg.client_id
    --   b) a single table arg with integer keys: reg[1]={"mountpoint",""}, reg[2]={"client_id","..."}
    --   c) two separate args (unlikely but handled)
    local args = {...}
    local reg = args[1]
    local cid = nil
    if type(reg) == "table" then
        -- try string key first
        cid = reg.client_id
        -- fallback: integer-indexed list of {key,val} pairs
        if cid == nil then
            for i = 1, #reg do
                local pair = reg[i]
                if type(pair) == "table" and pair[1] == "client_id" then
                    cid = pair[2]
                    break
                end
            end
        end
    end
    if not cid or cid == "" then return end
    local key = "device:pending_disconnect:" .. cid
    local ts  = tostring(os.time())  -- unix epoch, no spaces
    redis.cmd(redis_pool, "set " .. key .. " " .. ts .. " EX " .. tostring(DISCONNECT_TTL))
    print("[disconnect] scheduled: " .. cid .. " at " .. ts)
end

function on_client_gone(...)     do_disconnect(...) end
function on_client_offline(...)  do_disconnect(...) end
function on_session_expired(...) do_disconnect(...) end

hooks = {
    auth_on_register    = auth_on_register,
    auth_on_publish     = auth_on_publish,
    auth_on_subscribe   = auth_on_subscribe,
    on_unsubscribe      = on_unsubscribe,
    on_client_gone      = on_client_gone,
    on_client_offline   = on_client_offline,
    on_session_expired  = on_session_expired,

    -- auth_on_register_m5  = auth_on_register_m5,
    -- auth_on_publish_m5   = auth_on_publish_m5,
    -- auth_on_subscribe_m5 = auth_on_subscribe_m5,
}
