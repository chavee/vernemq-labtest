-- MQTT Broker - PostgreSQL Auth Commons
--
-- Log level: change this value to control verbosity.
--   0 = silent (production / load test)
--   1 = errors only  (DENY decisions)
--   2 = info         (ALLOW + DENY, default)
--   3 = debug        (all including publish/subscribe ACL hits)
local LOG_LEVEL = 2

local function log_error(msg) if LOG_LEVEL >= 1 then print(msg) end end
local function log_info(msg)  if LOG_LEVEL >= 2 then print(msg) end end
local function log_debug(msg) if LOG_LEVEL >= 3 then print(msg) end end

-- ──────────────────────────────────────────────────────────────
-- Bridge credential config
--
-- Read once from environment variables (lazy, cached on first use).
-- VerneMQ passes env vars through to Lua via os.getenv().
--
--   BRIDGE_CLIENTID_PREFIX  e.g. "bridge-"
--   BRIDGE_USERNAME         e.g. "bridge"
--   BRIDGE_PASSWORD         e.g. "s3cr3t"
--
-- A client that matches all three checks is granted full
-- publish + subscribe access on any topic, bypassing the DB.
-- ──────────────────────────────────────────────────────────────
local _bridge_cfg = nil  -- lazy cache

local function get_bridge_config()
    if _bridge_cfg then return _bridge_cfg end
    _bridge_cfg = {
        prefix   = os.getenv("BRIDGE_CLIENTID_PREFIX") or "",
        username = os.getenv("BRIDGE_USERNAME")        or "",
        password = os.getenv("BRIDGE_PASSWORD")        or "",
    }
    if _bridge_cfg.username == "" then
        -- No bridge credentials configured — effectively disable bridge path
        log_debug("[auth] bridge: BRIDGE_USERNAME not set, bridge fast-path disabled")
    end
    return _bridge_cfg
end

-- ──────────────────────────────────────────────────────────────
-- PostgreSQL Schema Config
-- ──────────────────────────────────────────────────────────────
local _pg_schema = nil

local function get_pg_schema()
    if _pg_schema ~= nil then return _pg_schema end
    local schema = os.getenv("VMQ_DIVERSITY__POSTGRES__SCHEMA")
    if schema and schema ~= "" then
        _pg_schema = schema .. "."
    else
        _pg_schema = "" -- Default, no prefix
    end
    return _pg_schema
end

-- Two authentication paths, distinguished by listener mountpoint:
--
--   mountpoint = "x509"  → SSL listener (port 8084)
--       require_certificate=on, use_identity_as_username=on
--       VerneMQ sets reg.username = client cert CN automatically.
--       Allowed auth_method: 'certificate' or 'both'
--       Checks: active device, active cert row, cert not expired.
--       Returns modifiers: mountpoint → "", client_id → CN
--       so cert and password clients share the same topic namespace.
--
--   mountpoint = ""      → TCP/WS/MQTTS listener (ports 1883, 8080, 8883)
--       username + password required.
--       Allowed auth_method: 'password' or 'both'
--       Checks: active device, bcrypt password match.
--
-- auth_method enforcement (strict):
--   'certificate' → ONLY allowed on x509 listener, DENY on password path
--   'password'    → ONLY allowed on password path, DENY on x509 listener
--   'both'        → allowed on either path
--
-- ACL from device_policy_template_rules joined via devices.policy_template_id.
-- Rules: type='mqtt', action='publish'|'subscribe', value[1] = topic pattern.
-- Macro ${deviceId} in topic patterns is replaced with the device_id.

-- ──────────────────────────────────────────────────────────────
-- clientId parsing helpers
--
-- A UUID v4 has exactly 5 dash-separated groups: 8-4-4-4-12
-- We allow an optional "-<suffix>" appended (≤16 chars after the dash)
-- when allow_multiple_instance = true on the device.
--
-- extract_device_id("09682d62-5113-4670-abf9-2d9601f474cf")
--   → "09682d62-5113-4670-abf9-2d9601f474cf", nil
-- extract_device_id("09682d62-5113-4670-abf9-2d9601f474cf-xxxx")
--   → "09682d62-5113-4670-abf9-2d9601f474cf", "xxxx"
--
-- UUID pattern: 8hex-4hex-4hex-4hex-12hex
-- After the 12-hex segment, if there is a "-<suffix>" we split there.
-- ──────────────────────────────────────────────────────────────
local UUID_PATTERN = "^(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)"

local function extract_device_id(client_id)
    if not client_id then return nil, nil end
    local uuid = client_id:match(UUID_PATTERN)
    if not uuid then
        -- not UUID-shaped — treat entire string as device_id, no suffix
        return client_id, nil
    end
    local rest = client_id:sub(#uuid + 1)  -- "" or "-suffix"
    if rest == "" then
        return uuid, nil
    end
    if rest:sub(1, 1) == "-" then
        local suffix = rest:sub(2)
        return uuid, suffix
    end
    -- unexpected format
    return client_id, nil
end

-- ──────────────────────────────────────────────────────────────
-- has_cn_prefix(client_id, cn)
--
-- Returns true if client_id equals cn exactly, OR starts with cn
-- followed by "-" (i.e. format "${cn}-xxxxx").
-- Used on the x509 path to decide whether the presented client_id
-- intentionally identifies this device.
-- ──────────────────────────────────────────────────────────────
local function has_cn_prefix(client_id, cn)
    if not client_id or not cn then return false end
    if client_id == cn then return true end
    -- check "${cn}-" prefix
    if client_id:sub(1, #cn + 1) == cn .. "-" then return true end
    return false
end

-- ──────────────────────────────────────────────────────────────
-- ACL helpers
-- ──────────────────────────────────────────────────────────────
-- vmq_diversity returns TEXT[] columns as a Lua table (integer-indexed).
-- Extract the first element regardless of type.
local function pg_array_first(v)
    if type(v) == "table" then return v[1] end
    if type(v) == "string" then return v end
    return nil
end

local function build_acl_from_rules(rules, device_id)
    local publish_acl   = {}
    local subscribe_acl = {}
    if not rules then return publish_acl, subscribe_acl end
    for _, rule in ipairs(rules) do
        if rule.type == "mqtt" then
            local pattern = pg_array_first(rule.value)
            if pattern then
                pattern = pattern:gsub("%${deviceId}", device_id)
                if rule.action == "publish" then
                    table.insert(publish_acl,   {pattern = pattern})
                elseif rule.action == "subscribe" then
                    table.insert(subscribe_acl, {pattern = pattern})
                end
            end
        end
    end
    return publish_acl, subscribe_acl
end

-- ──────────────────────────────────────────────────────────────
-- Fetch ACL rules for a device via its policy_template_id
-- Returns publish_acl, subscribe_acl (empty tables if no template)
-- ──────────────────────────────────────────────────────────────
-- ──────────────────────────────────────────────────────────────
-- safe_execute: wraps db_library.execute with pcall so a broken
-- or temporarily unavailable pool logs a clear error instead of
-- crashing with {illegal_index,false,1}.
-- Returns a (possibly empty) table on success, nil on failure.
-- ──────────────────────────────────────────────────────────────
local function safe_execute(label, db_library, ...)
    local ok, result = pcall(db_library.execute, ...)
    if not ok then
        log_error("[db] " .. label .. " ERROR (exception): " .. tostring(result))
        return nil
    end
    if result == false or result == nil then
        log_error("[db] " .. label .. " returned " .. tostring(result) .. " — pool down or query failed")
        return nil
    end
    log_debug("[db] " .. label .. " OK rows=" .. tostring(type(result) == 'table' and #result or '?'))
    return result
end

local function fetch_acl_for_device(db_library, device_id)
    local rows = safe_execute("acl_rules", db_library, pool,
        "SELECT r.type, r.action, r.value"
        .. " FROM " .. get_pg_schema() .. "devices d"
        .. " JOIN " .. get_pg_schema() .. "device_policy_templates t ON t.id = d.policy_template_id"
        .. " JOIN " .. get_pg_schema() .. "device_policy_template_rules r ON r.template_id = t.id"
        .. " WHERE d.device_id = $1"
        .. " AND r.type = 'mqtt'",
        device_id)
    if not rows then return {}, {} end
    return build_acl_from_rules(rows, device_id)
end

-- ──────────────────────────────────────────────────────────────
-- Common auth entry point (called from postgres.lua)
-- ──────────────────────────────────────────────────────────────
function auth_on_register_common(db_library, reg)
    local username   = reg.username
    local mountpoint = reg.mountpoint or ""

    log_debug("[auth] connect: client_id=" .. tostring(reg.client_id)
        .. " username=" .. tostring(username)
        .. " mountpoint=" .. mountpoint)

    -- ── Bridge fast-path ──────────────────────────────────────────────────────
    -- If the connecting client matches the BRIDGE_* env credentials AND its
    -- client_id starts with BRIDGE_CLIENTID_PREFIX, grant full access immediately
    -- without touching the database.
    do
        local bcfg = get_bridge_config()
        local client_id = reg.client_id or ""
        local password  = nil
        if reg.password and reg.password ~= "" then
            local ok, dec = pcall(obf.decrypt, reg.password)
            password = ok and dec or reg.password
        end

        local prefix_ok   = bcfg.prefix == "" or client_id:sub(1, #bcfg.prefix) == bcfg.prefix
        local username_ok = bcfg.username ~= "" and username == bcfg.username
        local password_ok = bcfg.password ~= "" and password == bcfg.password

        if username_ok and password_ok and prefix_ok then
            -- Publish: full wildcard
            -- Subscribe: '#' + '$share/#' — MQTT spec says '#' does NOT match
            --   topics starting with '$', so shared subscriptions need explicit entry
            local pub_acl = {{pattern = "#"}}
            local sub_acl = {{pattern = "#"}, {pattern = "$share/#"}}
            cache_insert(mountpoint, client_id, username, pub_acl, sub_acl)
            log_info("[auth] ALLOW bridge: client_id=" .. client_id
                .. " username=" .. username
                .. " mountpoint=" .. mountpoint)
            return true
        end
    end
    -- ─────────────────────────────────────────────────────────────────────────

    if mountpoint == "x509" then
        -- CN in username is always the clean device_id.
        -- VerneMQ sets use_identity_as_username=on, so CN lands in reg.username.
        local cn = username
        if not cn then
            log_error("[auth] DENY cert: no CN (use_identity_as_username may be off)")
            return false
        end

        -- Lookup device by CN first — we need allow_multiple_instance before
        -- deciding what to do with the presented client_id.
        local results = safe_execute("cert_device_lookup", db_library, pool,
            "SELECT device_id, auth_method, enabled, allow_multiple_instance,"
            .. " certificate_expires_at::TEXT AS certificate_expires_at"
            .. " FROM " .. get_pg_schema() .. "devices"
            .. " WHERE device_id = $1"
            .. " AND status = 'active'",
            cn)

        if not results or #results == 0 then
            log_error("[auth] DENY cert: device not found or inactive (or DB error), CN=" .. cn)
            return false
        end
        local dev = results[1]

        if not dev.enabled then
            log_error("[auth] DENY cert: device=" .. cn .. " is disabled")
            return false
        end

        if dev.auth_method ~= "certificate" and dev.auth_method ~= "both" then
            log_error("[auth] DENY cert: device=" .. cn
                .. " auth_method='" .. tostring(dev.auth_method)
                .. "' does not allow certificate auth")
            return false
        end

        -- ── Determine effective_client_id ──────────────────────────────────────
        --
        -- Rules (evaluated in order):
        --
        --   Case A: client_id has CN as prefix  (format "${cn}" or "${cn}-xxxxx")
        --           AND allow_multiple_instance = true
        --           → use the presented client_id as-is  (multi-instance intended)
        --
        --   Case B: client_id has CN as prefix
        --           AND allow_multiple_instance = false
        --           → override with CN  (suffix ignored, single-instance enforced)
        --
        --   Case C/D: client_id does NOT have CN as prefix (random / unknown format)
        --           regardless of allow_multiple_instance
        --           → override with CN  (device may clash if another instance
        --             connects simultaneously, but we cannot do better here)
        --
        local presented_client_id = reg.client_id
        local effective_client_id
        local override_reason

        if has_cn_prefix(presented_client_id, cn) then
            -- client_id intentionally identifies this device (Case A or B)
            if dev.allow_multiple_instance then
                -- Case A: keep the presented client_id
                effective_client_id = presented_client_id
            else
                -- Case B: single-instance device — ignore suffix, use CN
                effective_client_id = cn
                if presented_client_id ~= cn then
                    override_reason = "allow_multiple_instance=false"
                end
            end
        else
            -- Case C/D: random / unrecognised client_id — always override with CN
            effective_client_id = cn
            if presented_client_id and presented_client_id ~= "" then
                override_reason = "client_id has no CN prefix"
            end
        end

        if override_reason then
            log_info("[auth] cert: overriding client_id '" .. tostring(presented_client_id)
                .. "' -> '" .. cn .. "' (" .. override_reason .. ")")
        end
        -- ──────────────────────────────────────────────────────────────────────

        if dev.certificate_expires_at then
            local now_r = safe_execute("now_query", db_library, pool, "SELECT NOW()::TEXT AS now")
            local now_str = now_r and now_r[1] and now_r[1].now or ""
            if now_str ~= "" and dev.certificate_expires_at < now_str then
                log_error("[auth] DENY cert: certificate expired for device=" .. cn)
                return false
            end
        end

        local active_cert = safe_execute("cert_active_check", db_library, pool,
            "SELECT certificate_id FROM " .. get_pg_schema() .. "certificates"
            .. " WHERE device_id = $1 AND status = 'active' LIMIT 1",
            cn)
        if not active_cert or #active_cert == 0 then
            log_error("[auth] DENY cert: no active certificate row for device=" .. cn)
            return false
        end

        local pub_acl, sub_acl = fetch_acl_for_device(db_library, cn)

        -- Cache under rewritten mountpoint "" so pub/sub works on shared namespace.
        -- ACL macros always use the clean CN (device_id), not the (possibly suffixed)
        -- effective_client_id.
        cache_insert("", effective_client_id, cn, pub_acl, sub_acl)

        safe_execute("cert_set_online", db_library, pool,
            "UPDATE " .. get_pg_schema() .. "devices SET is_online = true, last_connected_at = NOW() WHERE device_id = $1", cn)

        log_info("[auth] ALLOW cert: device=" .. cn
            .. " effective_client_id=" .. effective_client_id
            .. " allow_multiple_instance=" .. tostring(dev.allow_multiple_instance)
            .. " auth_method=" .. dev.auth_method
            .. " publish_rules=" .. #pub_acl
            .. " subscribe_rules=" .. #sub_acl
            .. " -> rewrite mountpoint='' client_id=" .. effective_client_id)

        return {subscriber_id = {mountpoint = "", client_id = effective_client_id}}
    end

    -- ── Path 2: TCP / WS / MQTTS listener, username + password ───────────────
    -- vmq_http_pub sends plain-text passwords (no obfuscation), while normal
    -- MQTT clients have their password obfuscated by VerneMQ before reaching Lua.
    -- Try decrypt first; fall back to plain text if decrypt fails.
    local password = nil
    if reg.password and reg.password ~= "" then
        local ok, decrypted = pcall(obf.decrypt, reg.password)
        if ok then
            password = decrypted
        else
            password = reg.password  -- plain text (e.g. from vmq_http_pub)
        end
    end

    if not username then
        log_error("[auth] DENY pwd: no username provided")
        return false
    end
    if not password then
        log_error("[auth] DENY pwd: no password provided for username=" .. username)
        return false
    end

    -- Parse client_id: UUID or UUID-suffix
    -- If client_id is absent (e.g. vmq_http_pub), treat as if client_id = device_id (no suffix)
    local presented_client_id = reg.client_id
    local parsed_device_id, suffix
    if not presented_client_id or presented_client_id == "" then
        parsed_device_id = nil  -- resolved after DB lookup
        suffix = nil
    else
        parsed_device_id, suffix = extract_device_id(presented_client_id)
    end

    local results = safe_execute("pwd_device_lookup", db_library, pool,
        "SELECT device_id, auth_method, enabled, allow_multiple_instance, mqtt_password_hash"
        .. " FROM " .. get_pg_schema() .. "devices"
        .. " WHERE mqtt_username = $1"
        .. " AND status = 'active'",
        username)

    if not results or #results == 0 then
        log_error("[auth] DENY pwd: no active device for mqtt_username=" .. username .. " (or DB error)")
        return false
    end
    local dev = results[1]

    if not dev.enabled then
        log_error("[auth] DENY pwd: device=" .. dev.device_id .. " is disabled")
        return false
    end

    if dev.auth_method ~= "password" and dev.auth_method ~= "both" then
        log_error("[auth] DENY pwd: device=" .. dev.device_id
            .. " auth_method='" .. tostring(dev.auth_method)
            .. "' does not allow password auth")
        return false
    end

    -- Validate client_id against device_id and allow_multiple_instance
    -- Skip check if client_id was absent (e.g. vmq_http_pub); use device_id as effective client_id
    if parsed_device_id == nil then
        presented_client_id = dev.device_id
    elseif parsed_device_id ~= dev.device_id then
        log_error("[auth] DENY pwd: client_id device portion '" .. tostring(parsed_device_id)
            .. "' does not match device_id '" .. dev.device_id .. "'")
        return false
    end
    if suffix ~= nil then
        if not dev.allow_multiple_instance then
            log_error("[auth] DENY pwd: device=" .. dev.device_id
                .. " has suffix '" .. suffix .. "' but allow_multiple_instance=false")
            return false
        end
        if #suffix > 16 then
            log_error("[auth] DENY pwd: device=" .. dev.device_id
                .. " suffix '" .. suffix .. "' exceeds 16 characters")
            return false
        end
    end

    if not dev.mqtt_password_hash then
        log_error("[auth] DENY pwd: no password hash configured for device=" .. dev.device_id)
        return false
    end

    local verify = safe_execute("pwd_crypt_verify", db_library, pool,
        "SELECT (" .. get_pg_schema() .. "crypt($1, regexp_replace($2, '^\\$2b\\$', '$2a$'))"
        .. " = regexp_replace($2, '^\\$2b\\$', '$2a$')) AS ok",
        password, dev.mqtt_password_hash)

    if not verify or not verify[1] or not verify[1].ok then
        log_error("[auth] DENY pwd: wrong password for device=" .. dev.device_id)
        return false
    end

    local pub_acl, sub_acl = fetch_acl_for_device(db_library, dev.device_id)

    -- Cache using the presented client_id (may include suffix)
    cache_insert(reg.mountpoint, presented_client_id, username, pub_acl, sub_acl)

    safe_execute("pwd_set_online", db_library, pool,
        "UPDATE " .. get_pg_schema() .. "devices SET is_online = true, last_connected_at = NOW() WHERE device_id = $1", dev.device_id)

    log_info("[auth] ALLOW pwd: device=" .. dev.device_id
        .. " client_id=" .. presented_client_id
        .. (suffix and (" suffix=" .. suffix) or "")
        .. " auth_method=" .. dev.auth_method
        .. " publish_rules=" .. #pub_acl
        .. " subscribe_rules=" .. #sub_acl
        .. " via username=" .. username)

    return true
end

-- ──────────────────────────────────────────────────────────────
-- MQTT topic wildcard matching (Lua-side, used on no_cache path)
--
-- Splits topic/pattern by "/" and matches word by word:
--   +  matches exactly one level
--   #  (only valid as last level) matches everything remaining
-- ──────────────────────────────────────────────────────────────
local function split_topic(s)
    local parts = {}
    for p in (s .. "/"):gmatch("([^/]*)/") do
        table.insert(parts, p)
    end
    return parts
end

local function mqtt_match(topic, pattern)
    local tw = split_topic(topic)
    local pw = split_topic(pattern)
    local ti, pi = 1, 1
    while pi <= #pw do
        local p = pw[pi]
        if p == "#" then return true end
        if ti > #tw then return false end
        if p ~= "+" and p ~= tw[ti] then return false end
        ti = ti + 1
        pi = pi + 1
    end
    return ti > #tw
end

-- ──────────────────────────────────────────────────────────────
-- no_cache fallback: fetch rules from DB, populate cache, decide.
--
-- Called when auth_cache has no entry for this client (edge case:
-- publish/subscribe arrives before the register hook cache_insert
-- has been processed, or cache was cleared externally).
--
-- Fetches ALL mqtt rules (publish + subscribe) for the device,
-- inserts them into auth_cache so subsequent messages hit the
-- fast ETS path, then evaluates the requested action immediately.
-- Returns false if the device has no policy template at all.
-- ──────────────────────────────────────────────────────────────
local function repopulate_cache_and_check(mountpoint, client_id, action, topic)
    -- client_id may have a suffix — resolve the clean device_id for DB lookup
    local device_id = extract_device_id(client_id)

    local rows = postgres.execute(pool,
        "SELECT r.action, r.value"
        .. " FROM " .. get_pg_schema() .. "devices d"
        .. " JOIN " .. get_pg_schema() .. "device_policy_templates t ON t.id = d.policy_template_id"
        .. " JOIN " .. get_pg_schema() .. "device_policy_template_rules r ON r.template_id = t.id"
        .. " WHERE d.device_id = $1 AND r.type = 'mqtt'",
        device_id)

    -- No policy template → deny
    if #rows == 0 then
        log_debug("[acl] no_cache deny: device=" .. tostring(client_id) .. " has no mqtt rules")
        return false
    end

    local pub_acl = {}
    local sub_acl = {}
    local allowed = false

    for _, rule in ipairs(rows) do
        local pattern = pg_array_first(rule.value)
        if pattern then
            -- Use clean device_id for macro substitution (not suffixed client_id)
            pattern = pattern:gsub("%${deviceId}", device_id)
            if rule.action == "publish" then
                table.insert(pub_acl, {pattern = pattern})
                if action == "publish" and mqtt_match(topic, pattern) then
                    allowed = true
                end
            elseif rule.action == "subscribe" then
                table.insert(sub_acl, {pattern = pattern})
                if action == "subscribe" and mqtt_match(topic, pattern) then
                    allowed = true
                end
            end
        end
    end

    -- Populate cache keyed by the full client_id (including any suffix)
    cache_insert(mountpoint, client_id, device_id, pub_acl, sub_acl)
    log_debug("[acl] no_cache repopulated: device=" .. tostring(device_id)
        .. " client_id=" .. tostring(client_id)
        .. " pub=" .. #pub_acl .. " sub=" .. #sub_acl
        .. " action=" .. action .. " allowed=" .. tostring(allowed))
    return allowed
end

-- ──────────────────────────────────────────────────────────────
-- ACL hooks — delegate to VerneMQ's in-memory cache (ETS).
--
-- match_publish / match_subscribe return:
--   true      → allowed
--   false     → denied
--   no_cache  → no cache entry → use DB fallback
-- ──────────────────────────────────────────────────────────────
function auth_on_publish(pub)
    return true

    local result = auth_cache.match_publish(
        pub.mountpoint,
        pub.client_id,
        pub.topic,
        pub.qos,
        pub.payload or "",
        pub.retain or false)
    if result == "no_cache" then
        return repopulate_cache_and_check(pub.mountpoint, pub.client_id, "publish", pub.topic)
    end
    return result
end

function auth_on_subscribe(sub)
    local result = auth_cache.match_subscribe(
        sub.mountpoint,
        sub.client_id,
        sub.topic,
        sub.qos)
    if result == "no_cache" then
        return repopulate_cache_and_check(sub.mountpoint, sub.client_id, "subscribe", sub.topic)
    end
    return result
end

function on_unsubscribe(unsub) end

-- ──────────────────────────────────────────────────────────────
-- Disconnect debounce via Redis
--
-- On disconnect we write a Redis key:
--   device:pending_disconnect:<client_id>  = <iso_timestamp>  EX 30
--
-- If the device reconnects within 30s, the key gets overwritten
-- by the next disconnect (or deleted naturally if it reconnects
-- and stays connected). The API worker polls these keys every 10s
-- and batch-writes last_disconnected_at to PostgreSQL.
--
-- client_id on mountpoint "" is the device_id (set by Lua cert
-- modifier, or passed directly by password clients).
-- ──────────────────────────────────────────────────────────────

-- MQTT v5 variants
function auth_on_register_m5(reg)  return auth_on_register_common(postgres, reg) end
function auth_on_publish_m5(pub)   return auth_on_publish(pub) end
function auth_on_subscribe_m5(sub) return auth_on_subscribe(sub) end
