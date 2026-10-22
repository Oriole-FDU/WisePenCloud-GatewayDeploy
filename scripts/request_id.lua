-- =============================================================================
-- 请求 ID 补齐
-- 当前 APISIX 构建未加载 request-id 插件，这里用 serverless 函数补齐。
-- 优先复用合法的上游请求头，否则使用 Nginx 的 $request_id，并写入响应头。
-- =============================================================================

return function(_, ctx)
    local core = require("apisix.core")

    local request_id = core.request.header(ctx, "X-Request-Id")
    local valid = request_id
        and request_id ~= ""
        and #request_id <= 128
        and ngx.re.match(request_id, [[^[A-Za-z0-9._-]+$]], "jo")

    if not valid then
        request_id = ngx.var.request_id
        if not request_id or request_id == "" then
            request_id = ngx.md5(
                tostring(ngx.now()) .. ":" .. tostring(ngx.worker.pid()) .. ":" .. tostring(math.random())
            )
        end
        core.request.set_header(ctx, "X-Request-Id", request_id)
    end

    core.response.set_header("X-Request-Id", request_id)
end
