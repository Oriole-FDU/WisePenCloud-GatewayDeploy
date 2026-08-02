-- =============================================================================
-- APISIX 环境隔离
-- 根据请求头 X-Developer 动态过滤 Nacos 节点，实现开发/生产环境隔离
-- =============================================================================

return function(conf, ctx)
    local core = require("apisix.core")

    -- 安全加载 Nacos 模块
    local has_nacos, nacos = pcall(require, "apisix.discovery.nacos")
    if not has_nacos or not nacos then
        core.log.error(">>> [Dev-Isolation] Nacos module NOT found! Check if APISIX discovery is enabled.")
        return
    end

    -- 普通 HTTP 使用 Header；浏览器 WebSocket 无法自定义 Header，改由查询参数透传
    local target_dev = core.request.header(ctx, "X-Developer")
    if not target_dev or target_dev == "" then
        local query_dev = ctx.var.arg_developer
        if query_dev and query_dev ~= "" then
            local matched = ngx.re.match(query_dev, [[^[A-Za-z0-9._-]{1,64}$]], "jo")
            if matched then
                target_dev = query_dev
                core.request.set_header(ctx, "X-Developer", target_dev)
            else
                core.log.warn(">>> [Dev-Isolation] Invalid developer query ignored")
            end
        end
    end

    -- 获取 Upstream 配置
    local route = ctx.matched_route
    local up_conf = route and route.value and route.value.upstream
    if not up_conf or up_conf.discovery_type ~= "nacos" or not up_conf.service_name then
        return
    end

    local service_name = up_conf.service_name

    -- 从 Nacos 获取全量节点
    local nodes = nacos.nodes(service_name)
    if not nodes then
        core.log.warn(">>> [Dev-Isolation] Nacos returned NO nodes for: ", service_name)
        return
    end

    local baseline_nodes = {} -- 基线节点（主干环境，给普通用户用）
    local dev_nodes = {}      -- 开发者专属节点

    for _, node in ipairs(nodes) do
        -- 判断该节点是否是某个开发者的专属节点
        local is_dev_node = node.metadata and node.metadata.developer and node.metadata.developer ~= ""

        if not is_dev_node then
            -- 干净的节点，加入主干（基线）
            table.insert(baseline_nodes, node)
        elseif target_dev and target_dev ~= "" and node.metadata.developer == target_dev then
            -- 恰好是当前请求头里指定的那个开发者的节点
            table.insert(dev_nodes, node)
        end
        -- 注意：如果 is_dev_node 为真，但名字不是当前请求的 target_dev，则直接丢弃，防止流量窜入别人的开发机
    end

    -- 流量决策
    local final_nodes = {}
    local gray_hit = false
    local gray_target = "baseline"
    if target_dev and target_dev ~= "" and #dev_nodes > 0 then
        -- 命中：存在专属节点，将流量全部分发给该开发者
        final_nodes = dev_nodes
        gray_hit = true
        gray_target = target_dev

        core.log.notice("[Dev-Isolation] Hit developer node for: ", target_dev)
    else
        -- 回退/普通流量：全部走到基线主干节点
        final_nodes = baseline_nodes
        gray_hit = false
        gray_target = "baseline"

        if target_dev and target_dev ~= "" then
            -- 开发者发了请求，但是他本地没起服务，帮他把流量降级到公共测试环境
            core.log.warn("[Dev-Isolation] Dev node not found, fallback to baseline: ", target_dev)
        end
    end
    
    -- 写入灰度观测响应头
    core.response.set_header("X-Development-Gray-Hit", tostring(gray_hit))
    core.response.set_header("X-Development-Gray-Target", gray_target)

    -- 重写上游配置
    if #final_nodes > 0 then
        local new_up_conf = core.table.clone(up_conf)
        new_up_conf.discovery_type = nil
        new_up_conf.service_name = nil

        local static_nodes = {}
        for _, n in ipairs(final_nodes) do
            table.insert(static_nodes, {
                host = n.host or n.ip,
                port = n.port,
                weight = n.weight or 1
            })
        end

        -- 将过滤后的节点列表交给负载均衡器
        new_up_conf.nodes = static_nodes
        ctx.upstream_conf = new_up_conf
    else
        -- 极其危险的边缘情况：连主干节点都掉线了
        core.log.error("[Dev-Isolation] ALERT: No available nodes (both dev and baseline empty) for ", service_name)

        return core.response.exit(403, {
            message = "No available upstream nodes",
            service = service_name,
        })
    end
end