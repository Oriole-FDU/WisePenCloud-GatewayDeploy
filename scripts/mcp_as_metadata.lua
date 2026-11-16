return function(conf, ctx)
    local core = require("apisix.core")
    local origin = ctx.var.scheme .. "://" .. ctx.var.http_host
    core.response.exit(200, {
        issuer = origin,
        authorization_endpoint = origin .. "/oauth/authorize",
        token_endpoint = origin .. "/oauth/token",
        response_types_supported = {"code"},
        grant_types_supported = {"authorization_code", "refresh_token"},
        token_endpoint_auth_methods_supported = {"none"},
        code_challenge_methods_supported = {"S256"},
        scopes_supported = {"mcp"},
        revocation_endpoint = origin .. "/oauth/revoke",
        registration_endpoint = origin .. "/oauth/register"
    })
end
