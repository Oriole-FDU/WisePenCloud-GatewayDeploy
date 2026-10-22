-- =============================================================================
-- 前端 OTel 入口重写
-- 当前 APISIX 构建未加载 proxy-rewrite / client-control，这里用 serverless 函数
-- 去掉 /otel 前缀，并限制上报请求体大小。
-- =============================================================================

local MAX_BODY_SIZE = 4 * 1024 * 1024

return function(_, ctx)
    local core = require("apisix.core")

    local content_length = tonumber(ngx.var.content_length or "")
    if content_length and content_length > MAX_BODY_SIZE then
        return core.response.exit(413, "request body too large")
    end

    local uri = ngx.var.uri
    if uri == "/otel/v1/traces" or uri == "/otel/v1/logs" then
        ngx.req.set_uri(uri:sub(6), false)
    end
end
