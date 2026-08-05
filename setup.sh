#!/bin/bash

# ================= 环境变量定义 =================
SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载 .env（如果存在），方便本地直接 bash setup.sh
for env_file in "${SETUP_DIR}/.env"; do
    if [ -f "$env_file" ]; then
        set -a; . "$env_file"; set +a
    fi
done

# APISIX Admin API 地址
APISIX_ADMIN_HOST=${APISIX_ADMIN_HOST:-apisix}
APISIX_ADMIN_PORT=${APISIX_ADMIN_PORT:-9180}
APISIX_ADMIN="http://${APISIX_ADMIN_HOST}:${APISIX_ADMIN_PORT}"

# APISIX Admin Key
# Jenkins 参数或环境变量 APISIX_ADMIN_KEY 传入
# 未设置时默认 edd1c9f034335f136f87ad84b625c8f1 （Dev Key）
ADMIN_KEY=${APISIX_ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}

# Redis 地址
REDIS_URL=${REDIS_URL:-redis}
REDIS_PORT=${REDIS_PORT:-6379}
# Redis AUTH 密码
# Jenkins 参数或环境变量 REDIS_AUTH_PASSWORD 传入
# 未设置时默认 root
REDIS_AUTH_PASSWORD=${REDIS_AUTH_PASSWORD:-root}
if command -v base64 >/dev/null 2>&1; then
    REDIS_PASSWORD_B64=$(printf '%s' "$REDIS_AUTH_PASSWORD" | base64 -w0 2>/dev/null || printf '%s' "$REDIS_AUTH_PASSWORD" | base64 | tr -d '\n')
else
    echo "错误: 需要 base64 命令以生成 Redis 密码占位符"
    exit 1
fi

# 安全切口，由 APISIX 注入到 X-From-Source 头，下游服务校验
# Jenkins 参数或环境变量 FROM_SOURCE_SECRET 传入
# 未设置时默认 APISIX-wX0iR6tY
FROM_SOURCE_SECRET=${FROM_SOURCE_SECRET:-APISIX-wX0iR6tY}

# 全局模版
TPL_ID_GLOBAL=1

# docs-service 路由开关。默认不注册，由 Jenkins/.env 显式开启。
DEPLOY_DOCS_ROUTE=${DEPLOY_DOCS_ROUTE:-false}

# 前端静态站点 upstream。FRONTEND_HOST 留空时不注册 frontend 兜底路由。
FRONTEND_HOST=${FRONTEND_HOST:-}
FRONTEND_PORT=${FRONTEND_PORT:-8085}
FRONTEND_SCHEME=${FRONTEND_SCHEME:-http}
if [ -n "$FRONTEND_HOST" ]; then
    if ! printf '%s' "$FRONTEND_PORT" | grep -Eq '^[0-9]+$'; then
        echo "错误: FRONTEND_PORT 必须是数字，当前值: ${FRONTEND_PORT}"
        exit 1
    fi
    if [ "$FRONTEND_SCHEME" != "http" ] && [ "$FRONTEND_SCHEME" != "https" ]; then
        echo "错误: FRONTEND_SCHEME 只支持 http 或 https，当前值: ${FRONTEND_SCHEME}"
        exit 1
    fi
fi

# ================= 工具函数 =================

# 检查 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo "错误: 未检测到 'jq' 命令。请先安装它 (apt install jq / yum install jq)"
    exit 1
fi

# CORS 正则：环境变量 CORS_REGEX_JSON 非空则直接用，否则读仓库内 JSON
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
    sed -e "s|@@REDIS_PASSWORD_B64@@|${REDIS_PASSWORD_B64}|g" \
        -e "s|@@REDIS_URL@@|${REDIS_URL}|g" \
        -e "s|@@REDIS_PORT@@|${REDIS_PORT}|g" \
        -e "s|@@FROM_SOURCE_SECRET@@|${FROM_SOURCE_SECRET}|g" \
        "./scripts/auth.lua" >"$AUTH_TMP"
    local LUA_AUTH
    LUA_AUTH=$(load_lua_script "$AUTH_TMP")
    rm -f "$AUTH_TMP"

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

# 注册服务
# 参数：ID, Name, URI/URIS, NacosService, ExtraConfig
# 第三个参数支持单路径字符串，或 JSON 字符串数组，例如 '["/a/*","/b/*"]'
function register_route() {
    local ID=$1
    local NAME=$2
    local URI=$3
    local SERVICE=$4
    local EXTRA_CONFIG=${5:-"{}"}
    local ROUTE_MATCH

    echo ">>> 注册路由 [$NAME] -> $SERVICE"

    if ROUTE_MATCH=$(printf '%s' "$URI" | jq -ec 'select(type == "array" and length > 0 and all(.[]; type == "string")) | {uris: .}' 2>/dev/null); then
        :
    else
        ROUTE_MATCH=$(jq -n --arg uri "$URI" '{uri: $uri}')
    fi

    local body=$(jq -n \
        --arg name "$NAME" \
        --arg service "$SERVICE" \
        --argjson tpl "$TPL_ID_GLOBAL" \
        --argjson route_match "$ROUTE_MATCH" \
        --argjson extra "$EXTRA_CONFIG" \
        '{
            name: $name,
            plugin_config_id: $tpl,
            upstream: {
                type: "roundrobin",
                discovery_type: "nacos",
                service_name: $service
            }

        } * $route_match * $extra')

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

# 注册网关本地 /ping 健康检查路由
# 不挂全局模板（避免走 auth/Redis），不依赖任何 Nacos 服务
function register_ping_route() {
    local ID=${1:-1}
    local URI=${2:-/ping}

    echo ">>> 注册本地路由 [ping] -> APISIX (${URI})"

    local LUA_PING
    LUA_PING=$(load_lua_script "./scripts/ping.lua")

    local body=$(jq -n \
        --arg uri "$URI" \
        --argjson script_ping "$LUA_PING" \
        --argjson cors_regex_arr "$CORS_REGEX_JSON" \
        '{
            name: "ping",
            uri: $uri,
            methods: ["GET", "HEAD", "OPTIONS"],
            plugins: {
                "cors": {
                    "allow_origins": "http://127.0.0.1",
                    "allow_origins_by_regex": $cors_regex_arr,
                    "allow_methods": "GET,HEAD,OPTIONS",
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
                    phase: "access",
                    functions: [$script_ping]
                }
            }
        }')

    local RESPONSE=$(curl -s --noproxy "*" -w "\n%{http_code}" "${APISIX_ADMIN}/apisix/admin/routes/${ID}" -X PUT \
        -H "X-API-KEY: ${ADMIN_KEY}" \
        -d "$body")

    local HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
    local HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)

    if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
        echo "❌ [Error] 路由 [ping] 注册失败！状态码: ${HTTP_STATUS}"
        echo ">>> APISIX 报错详情: ${HTTP_BODY}"
        exit 1
    fi
}

# 注册前端静态站点兜底路由
# 不挂全局模板（避免静态资源走 auth/Redis），通过固定 upstream 转发到前端服务
function register_frontend_route() {
    local ID=${1:-901}
    local URI=${2:-'["/assets/*","/*"]'}
    local ROUTE_MATCH

    if [ -z "$FRONTEND_HOST" ]; then
        echo ">>> 跳过前端路由 [frontend]：FRONTEND_HOST 未设置"
        return
    fi

    echo ">>> 注册前端路由 [frontend] -> ${FRONTEND_SCHEME}://${FRONTEND_HOST}:${FRONTEND_PORT}"

    if ROUTE_MATCH=$(printf '%s' "$URI" | jq -ec 'select(type == "array" and length > 0 and all(.[]; type == "string")) | {uris: .}' 2>/dev/null); then
        :
    else
        ROUTE_MATCH=$(jq -n --arg uri "$URI" '{uri: $uri}')
    fi

    local body=$(jq -n \
        --arg host "$FRONTEND_HOST" \
        --argjson port "$FRONTEND_PORT" \
        --arg scheme "$FRONTEND_SCHEME" \
        --argjson route_match "$ROUTE_MATCH" \
        '{
            name: "frontend",
            methods: ["GET", "HEAD", "OPTIONS"],
            priority: -100,
            upstream: {
                type: "roundrobin",
                scheme: $scheme,
                pass_host: "pass",
                nodes: [
                    {
                        host: $host,
                        port: $port,
                        weight: 1
                    }
                ]
            }
        } * $route_match')

    local RESPONSE=$(curl -s --noproxy "*" -w "\n%{http_code}" "${APISIX_ADMIN}/apisix/admin/routes/${ID}" -X PUT \
        -H "X-API-KEY: ${ADMIN_KEY}" \
        -d "$body")

    local HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
    local HTTP_STATUS=$(echo "$RESPONSE" | tail -n 1)

    if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
        echo "❌ [Error] 路由 [frontend] 注册失败！状态码: ${HTTP_STATUS}"
        echo ">>> APISIX 报错详情: ${HTTP_BODY}"
        exit 1
    fi
}

echo "========================================="
echo "   WisePen 网关部署脚本"
echo "========================================="

init_infrastructure

echo -e "\n-----------------------------------------"

# 注册网关本地路由
register_ping_route 1 "/ping"

# 注册 API 文档服务
if [ "$DEPLOY_DOCS_ROUTE" = "true" ]; then
    register_route 2 "docs-service" '["/docs","/docs/*"]' "wisepen-docs-service"
else
    echo ">>> 跳过路由 [docs-service]：DEPLOY_DOCS_ROUTE 未开启"
fi

# 注册服务

# 格式: register_route  <ID>  <描述>  <路径或JSON路径数组>  <Nacos服务名>
# user-service
register_route 101 "auth-service" "/auth/*" "wisepen-user-service"
register_route 102 "user-service" "/user/*" "wisepen-user-service"
register_route 103 "group-service" "/group/*" "wisepen-user-service"
register_route 201 "chat-service" "/chat/*" "wisepen-chat-service"
register_route 301 "skill-service" "/skill/*" "wisepen-ai-asset-service"
register_route 302 "agent-service" "/agent/*" "wisepen-ai-asset-service"
register_route 401 "resource-service" "/resource/*" "wisepen-resource-service"
register_route 501 "document-service" '["/document/*","/external/document/*"]' "wisepen-document-service"
register_route 601 "file-storage-service" '["/storage/*","/external/storage/*"]' "wisepen-file-storage-service"
register_route 701 "note-service" "/note/*" "wisepen-note-service"

# note-collab-service 仅透传业务 WebSocket 入口；.websocket 是 express-ws 内部路径，网关不做改写
WS_CONFIG='{
    "enable_websocket": true,
    "upstream": {
        "type": "chash",
        "hash_on": "vars",
        "key": "arg_resourceId"
    }
}'
register_route 702 "note-collab-service" "/note-collab/ws" "wisepen-note-collab-service" "$WS_CONFIG"

# 注册前端服务
register_frontend_route 3 '["/assets/*","/*"]'

echo -e "\n========================================="
echo "所有配置已推送到 APISIX !"
