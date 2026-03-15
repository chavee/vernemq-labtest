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

function auth_on_register(reg)
    if reg.username ~= nil and reg.password ~= nil then
        -- Query the database for the user using our explicit pool
        local res = postgres.execute(
            "mypool",
            "SELECT password, publish_acl, subscribe_acl FROM vmq_auth_acl WHERE mountpoint = $1 AND username = $2",
            {reg.mountpoint, reg.username}
        )

        -- Check if user exists and password matches
        if #res == 1 and res[1].password == reg.password then
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

hooks = {
    auth_on_register = auth_on_register,
    auth_on_publish = auth_on_publish,
    auth_on_subscribe = auth_on_subscribe
}