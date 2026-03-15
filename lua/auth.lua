function auth_on_register(reg)
    -- return true ตลอด เพื่อให้ทุกคนสามารถ connect ได้ (Simple Auth)
    return true
end

function auth_on_publish(pub)
    -- return true ตลอด เพื่อให้ทุกคนสามารถ publish ได้ทุก topic
    return true
end

function auth_on_subscribe(sub)
    -- return true ตลอด เพื่อให้ทุกคนสามารถ subscribe ได้ทุก topic
    return true
end

-- Hook เข้ากับระบบของ VerneMQ
hooks = {
    auth_on_register = auth_on_register,
    auth_on_publish = auth_on_publish,
    auth_on_subscribe = auth_on_subscribe
}
