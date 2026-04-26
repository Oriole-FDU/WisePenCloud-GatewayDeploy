#!/bin/bash

# ================= 环境变量定义 =================
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="apisix" # 容器名
APISIX_ADMIN="http://${CONTAINER_NAME}:9180"
ADMIN_KEY="edd1c9f034335f136f87ad84b625c8f1"

# Redis AUTH 密码：由 Jenkins 参数或环境变量 REDIS_AUTH_PASSWORD 传入；未设置时默认 root（与旧行为一致）
REDIS_AUTH_PASSWORD=${REDIS_AUTH_PASSWORD:-root}
if command -v base64 >/dev/null 2>&1; then
    REDIS_PASSWORD_B64=$(printf '%s' "$REDIS_AUTH_PASSWORD" | base64 -w0 2>/dev/null || printf '%s' "$REDIS_AUTH_PASSWORD" | base64 | tr -d '\n')
else
    echo "错误: 需要 base64 命令以生成 Redis 密码占位符"
    exit 1
fi

# 全局模版
TPL_ID_GLOBAL=1
ROUTE_ID_PING=1
LUA_PING=""

# ================= 工具函数 =================

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo "错误: 未检测到 'jq' 命令。请先安装它 (apt install jq / yum install jq)"
    exit 1
fi

# CORS 正则：环境变量 CORS_REGEX_JSON 非空则直接用；否则读仓库内 JSON（避免 Jenkins/Groovy 里写一堆反斜杠）
CORS_DEFAULT_FILE="$SETUP_DIR/defaults/cors-allow-origins.json"
if [ -z "${CORS_REGEX_JSON}" ]; then
    if [ ! -f "$CORS_DEFAULT_FILE" ]; then
        echo "错误: 默认 CORS 文件缺失: $CORS_DEFAULT_FILE"
        exit 1
    fi
    CORS_REGEX_JSON=$(jq -c . "$CORS_DEFAULT_FILE")
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
    local AUTH_TMP
    AUTH_TMP=$(mktemp)
    sed "s|@@REDIS_PASSWORD_B64@@|${REDIS_PASSWORD_B64}|g" "./scripts/auth.lua" >"$AUTH_TMP"
    local LUA_AUTH
    LUA_AUTH=$(load_lua_script "$AUTH_TMP")
    rm -f "$AUTH_TMP"
    LUA_PING=$(load_lua_script "./scripts/ping.lua")

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
                    "allow_headers": "Content-Type,Authorization,Accept,Origin,X-Requested-With,Cache-Control,Range,X-Developer,ETag,Last-Modified,Access-Control-Request-Private-Network",
                    "expose_headers": "Accept-Ranges,Content-Range,Content-Length",
                    "allow_credential": true,
                    "max_age": 3600
                },
                "response-rewrite": {
                    "headers": {
                        "set": {
                            "Access-Control-Allow-Private-Network": "true"
                        }
                    }
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

# 注册本地 /ping 健康检查路由
function register_ping_route() {
    echo ">>> 注册本地路由 [ping] -> APISIX"

    local body=$(jq -n \
        --argjson script_ping "$LUA_PING" \
        '{
            name: "ping",
            uri: "/ping",
            plugins: {
                "serverless-pre-function": {
                    phase: "rewrite",
                    functions: [$script_ping]
                }
            }
        }')

    local RESPONSE=$(curl -s --noproxy "*" -w "\n%{http_code}" "${APISIX_ADMIN}/apisix/admin/routes/${ROUTE_ID_PING}" -X PUT \
      -H "X-API-KEY: ${ADMIN_KEY}" \
      -d "$body")

    local HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
    local HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)

    if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
        echo "❌ [Error] 本地路由 [ping] 注册失败！状态码: ${HTTP_STATUS}"
        echo ">>> APISIX 报错详情: ${HTTP_BODY}"
        exit 1
    fi
}

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

# 注册网关本地健康检查
register_ping_route

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
