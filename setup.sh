#!/bin/bash

# ================= 环境变量定义 =================
CONTAINER_NAME="apisix" # 容器名
APISIX_ADMIN="http://${CONTAINER_NAME}:9180"
ADMIN_KEY="edd1c9f034335f136f87ad84b625c8f1"

# 接收 Jenkins 传入的 CORS 正则数组
# 默认值保留为本地开发的正则表达式
CORS_REGEX_JSON=${CORS_REGEX_JSON:-'["^http://localhost:\\d+$", "^http://127\\.0\\.0\\.1:\\d+$"]'}

# 全局模版
TPL_ID_GLOBAL=1

# ================= 工具函数 =================

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo "错误: 未检测到 'jq' 命令。请先安装它 (apt install jq / yum install jq)"
    exit 1
fi

# 优雅地读取 Lua 并转义为 JSON 字符串
function load_lua_script() {
    local filepath=$1
    if [ ! -f "$filepath" ]; then
        echo "Error: $filepath 文件不存在！"
        exit 1
    fi
    # 使用 jq -Rs . 可以将任意文件内容转义为安全的 JSON 字符串
    cat "$filepath" | jq -Rs .
}

# ================= 核心函数定义 =================
function init_infrastructure() {
    echo ">>> [1/2] 加载 Lua 脚本..."
    # 获取转义后的 Lua 脚本字符串
    local LUA_ROUTE=$(load_lua_script "./scripts/route.lua")
    local LUA_AUTH=$(load_lua_script "./scripts/auth.lua")

    echo ">>> [2/2] 初始化全局模板 (ID: ${TPL_ID_GLOBAL})..."
    local body_global=$(jq -n \
        --argjson script_route "$LUA_ROUTE" \
        --argjson script_auth "$LUA_AUTH" \
        --argjson cors_regex_arr "$CORS_REGEX_JSON" \
        '{
            desc: "WisePen Global Template (Monitor + Routing + Auth + CORS)",
            plugins: {
                "prometheus": {},
                "opentelemetry": {},
                "cors": {
                    "allow_origins": "http://127.0.0.1",
                    "allow_origins_by_regex": $cors_regex_arr,
                    "allow_methods": "GET,POST,PUT,DELETE,PATCH,HEAD,OPTIONS",
                    "allow_headers": "Content-Type,Authorization,Accept,Origin,X-Requested-With,Cache-Control,Range,X-Developer,ETag,Last-Modified",
                    "expose_headers": "Accept-Ranges,Content-Range,Content-Length",
                    "allow_credential": true,
                    "max_age": 3600
                },
                "serverless-pre-function": {
                    "phase": "rewrite",
                    "functions": [$script_route, $script_auth]
                }
            }
        }')
    local RESPONSE=$(curl -s --noproxy "*" -w "\n%{http_code}" "${APISIX_ADMIN}/apisix/admin/plugin_configs/${TPL_ID_GLOBAL}" -X PUT \
          -H "X-API-KEY: ${ADMIN_KEY}" \
          -d "$body_global")
    local HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
    local HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)
    if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
        echo -e "\n✅ 基础设施初始化完成"
    else
        echo -e "\n❌ [Fatal] APISIX 拒绝了配置！状态码: ${HTTP_STATUS}"
        echo ">>> APISIX 报错详情: ${HTTP_BODY}"
        exit 1
    fi
}

# ================= 路由注册函数 =================

# 注册服务
# 参数：ID, Name, URI, NacosService, TemplateID
function register_route() {
    local ID=$1
    local NAME=$2
    local URI=$3
    local SERVICE=$4
    local EXTRA_CONFIG=${5:-"{}"}

    echo ">>> 注册路由 [$NAME] -> $SERVICE"

    local body=$(jq -n \
        --arg name "$NAME" \
        --arg uri "$URI" \
        --arg service "$SERVICE" \
        --argjson tpl "$TPL_ID_GLOBAL" \
        --argjson extra "$EXTRA_CONFIG" \
        '{
            name: $name,
            uri: $uri,
            plugin_config_id: $tpl,
            upstream: {
                type: "roundrobin",
                discovery_type: "nacos",
                service_name: $service
            }
        } * $extra')

    local RESPONSE=$(curl -s --noproxy "*" -w "\n%{http_code}" "${APISIX_ADMIN}/apisix/admin/routes/${ID}" -X PUT \
      -H "X-API-KEY: ${ADMIN_KEY}" \
      -d "$body")

    local HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
    local HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)

    if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
        echo "❌ [Error] 路由 [$NAME] 注册失败！状态码: ${HTTP_STATUS}"
        echo ">>> APISIX 报错详情: ${HTTP_BODY}" # 打印具体死因
        exit 1
    fi
}

echo "========================================="
echo "   WisePen 网关部署脚本"
echo "========================================="

init_infrastructure

echo -e "\n-----------------------------------------"

# 注册服务
# 格式: register_route  <ID>  <描述>  <路径>  <Nacos服务名>

# 注册服务
# user-service
register_route 101 "auth-service" "/auth/*" "wisepen-user-service"
register_route 102 "user-service" "/user/*" "wisepen-user-service"
register_route 103 "group-service" "/group/*" "wisepen-user-service"
register_route 201 "chat-service" "/chat/*" "wisepen-chat-service"
register_route 401 "resource-service" "/resource/*" "wisepen-resource-service"
register_route 501 "document-service" "/document/*" "wisepen-document-service"
register_route 601 "file-storage-service" "/storage/*" "wisepen-file-storage-service"
register_route 701 "note-service" "/note/*" "wisepen-note-service"

# note-collab-service 需要启用 WebSocket 支持，同时进行一致性哈希路由
WS_CONFIG='{
    "enable_websocket": true,
    "upstream": {
        "type": "chash",
        "hash_on": "vars",
        "key": "remote_addr"
    }
}'
register_route 702 "note-collab-service" "/note-collab/*" "wisepen-note-collab-service" "$WS_CONFIG"

echo -e "\n========================================="
echo "所有配置已推送到 APISIX !"
