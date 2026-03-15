package.path = package.path .. ";/vernemq/share/lua/?.lua"
require "auth/auth_commons"

-- The built-in postgres configuration creates a pool named "auth_postgres"
-- IF auth_postgres.enabled = on. But since we didn't enable it,
-- we will initialize our own pool using the injected 'postgres' global.
postgres.ensure_pool({
    pool_id = "mypool",
    host = "postgres",
    port = 5432,
    user = "vernemq",
    password = "vernemq_password",
    database = "vernemq_db"
})

redis.ensure_pool({
    pool_id = "my_redis",
    host = "redis",
    port = 6379,
    database = 0,
    password = ""
})

function auth_on_register(reg)
    if reg.username ~= nil and reg.password ~= nil then
        local pwd = obf.decrypt(reg.password)
        local res = postgres.execute(
            "mypool",
            "SELECT password FROM vmq_auth_acl WHERE mountpoint = $1 AND username = $2",
            reg.mountpoint, reg.username
        )

        if #res == 1 and res[1].password == pwd then
            return true
        end
    end

    return false
end

function auth_on_publish(pub)
    return true
end

function auth_on_subscribe(sub)
    return true
end

function on_publish(pub)
    -- นับจำนวน message ลงใน Redis key ชื่อ "mqtt_publish_count"
    redis.execute("my_redis", "INCR", "mqtt_publish_count")

    -- return true เพื่อบอกให้ VerneMQ ดำเนินการต่อ (อนุญาต publish)
    return true
end


hooks = {
    auth_on_register = auth_on_register,
    auth_on_publish = auth_on_publish,
    auth_on_subscribe = auth_on_subscribe,
    on_publish = on_publish
}
