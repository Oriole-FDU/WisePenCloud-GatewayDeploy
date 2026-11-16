-- =============================================================================
-- APISIX MCP Bearer 鉴权前置脚本（仅 /mcp 生效）
-- 作用：拦截第三方 MCP Host 的 Bearer token，注入身份头 + 能力头；失败返回 401 挑战
-- 注意：无 Bearer 时返回 401 挑战（/mcp 仅对公网 MCP Host）
-- =============================================================================

return function(conf, ctx)
    local core = require("apisix.core")
    local redis = require("resty.redis")

    local uri = ctx.var.uri
    if uri ~= "/mcp" and uri ~= "/mcp/" then
        return
    end

    -- 401 挑战（MCP 规范）
    local origin = ctx.var.scheme .. "://" .. ctx.var.http_host
    local resource_metadata = origin .. "/mcp/.well-known/oauth-protected-resource"
    local function reject_mcp()
        core.response.set_header("WWW-Authenticate", 'Bearer resource_metadata="' .. resource_metadata .. '"')
        return core.response.exit(401, {error = "invalid_token"})
    end

    -- 提取 Bearer token（/mcp 只对公网，无 Bearer 直接 401 挑战）
    local auth_header = core.request.header(ctx, "Authorization")
    local access_token = nil
    if auth_header then
        local m = ngx.re.match(auth_header, [[^Bearer\s+([a-zA-Z0-9-]+)\s*$]], "jo")
        if m then access_token = m[1] end
    end

    if not access_token then
        return reject_mcp()
    end

    -- 清洗 Header 抵御伪造
    core.request.set_header(ctx, "X-User-Id", nil)
    core.request.set_header(ctx, "X-Identity-Type", nil)
    core.request.set_header(ctx, "X-User-Status", nil)
    core.request.set_header(ctx, "X-Group-Role-Map", nil)
    core.request.set_header(ctx, "X-Mcp-Audience", nil)
    core.request.set_header(ctx, "X-Mcp-Capabilities", nil)

    -- ================= L1 缓存 (APISIX 极速内存字典) =================
    -- 注意：必须在 APISIX 的 config.yaml 中提前定义好这个共享内存块
    local local_cache = ngx.shared.session_cache
    local context_cache_json = local_cache and local_cache:get("mcp:ctx:" .. access_token)
    local fetched_from_redis = false

    if context_cache_json == "INVALID" then
        return reject_mcp()
    end

    -- 使用 APISIX 内置的 core.json 安全解析
    local context_cache_data = core.json.decode(context_cache_json)

    -- ================= L2 缓存 (Redis 兜底与同步) =================
    -- 未能命中缓存
    if not context_cache_data then
        local red = redis:new()
        -- 设置极短的超时时间(1秒)，防止 Redis 阻塞导致网关雪崩
        red:set_timeouts(1000, 1000, 1000)

        -- Redis 地址/密码
        --（由 setup.sh 在部署时注入 @@REDIS_URL@@  @@REDIS_PORT@@ 占位符）
        local ok, err = red:connect("@@REDIS_URL@@", "@@REDIS_PORT@@")
        if not ok then
            core.log.error(">>> [McpAuth] Redis Connect Failed: ", err)
            core.response.exit(500, {code = 500, msg = "网关内部错误：鉴权服务暂时不可用"})
            return
        end
        --（由 setup.sh 在部署时注入 @@REDIS_PASSWORD_B64@@ 占位符）
        local redis_password = ngx.decode_base64("@@REDIS_PASSWORD_B64@@")
        if not redis_password then
            core.log.error(">>> [McpAuth] Redis password decode failed")
            core.response.exit(500, {code = 500, msg = "网关内部错误：鉴权服务暂时不可用"})
            return
        end
        local ok, err = red:auth(redis_password)
        if not ok then
            core.log.error(">>> [McpAuth] Redis Auth Failed: ", err)
            core.response.exit(500, {code = 500, msg = "网关内部错误：鉴权服务暂时不可用"})
            return
        end

        -- 读 access token，拿 userId + capabilities
        local redis_key = "wisepen:mcp:oauth:token:" .. access_token
        local token_json = red:get(redis_key)

        if not token_json or token_json == ngx.null then
            -- 没查到，token 已撤销或过期
            if local_cache then
                local_cache:set("mcp:ctx:" .. access_token, "INVALID", 60)
            end
            red:set_keepalive(10000, 100)
            return reject_mcp()
        end

        fetched_from_redis = true

        local token = core.json.decode(token_json)
        if not token or not token.userId then
            core.log.error(">>> [McpAuth] Token JSON Decode Failed for: ", access_token)
            red:set_keepalive(10000, 100)
            return reject_mcp()
        end

        -- 查 context（身份真相）
        local context_json = red:get("wisepen:user:auth:context:" .. token.userId)

        -- 释放连接到连接池 (最大空闲时间 10 秒，池子大小 100)
        red:set_keepalive(10000, 100)

        if not context_json or context_json == ngx.null then
            return reject_mcp()
        end

        context_cache_data = core.json.decode(context_json)
        if not context_cache_data then
            core.log.error(">>> [McpAuth] Context JSON Decode Failed for User: ", token.userId)
            return reject_mcp()
        end
        context_cache_data.userId = token.userId
        context_cache_data.capabilities = token.capabilities
    end

    -- ================= 解析数据并注入 Header =================
    if fetched_from_redis and local_cache and tostring(context_cache_data.status) ~= "-1" then
        -- 将查到的结果写回 L1 内存缓存，存活 5 分钟 (300秒)
        -- 接下来的 5 分钟内，该 token 的请求都不会再引发 Redis 网络 I/O
        local_cache:set("mcp:ctx:" .. access_token, core.json.encode(context_cache_data), 300)
    end

    if context_cache_data.userId then
        core.request.set_header(ctx, "X-User-Id", tostring(context_cache_data.userId))
    end
    if context_cache_data.identityType then
        core.request.set_header(ctx, "X-Identity-Type", tostring(context_cache_data.identityType))
    end
    if context_cache_data.status then
        core.request.set_header(ctx, "X-User-Status", tostring(context_cache_data.status))
    end
    if context_cache_data.groupRoleMap then
        core.request.set_header(ctx, "X-Group-Role-Map", core.json.encode(context_cache_data.groupRoleMap))
    end

    -- 注入 MCP 能力头
    core.request.set_header(ctx, "X-Mcp-Audience", "external")
    if context_cache_data.capabilities then
        local caps = {}
        for _, cap in ipairs(context_cache_data.capabilities) do
            table.insert(caps, tostring(cap))
        end
        core.request.set_header(ctx, "X-Mcp-Capabilities", table.concat(caps, ","))
    end
end
