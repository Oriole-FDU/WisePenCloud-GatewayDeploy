return function(conf, ctx)
    local core = require("apisix.core")
    local origin = ctx.var.scheme .. "://" .. ctx.var.http_host
    core.response.exit(200, {
        resource = origin,
        authorization_servers = {origin},
        scopes_supported = {"mcp"}
    })
end
