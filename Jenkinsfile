pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timestamps()
    }

    // 定义构建参数
    parameters {
        string(name: 'BRANCH_NAME', defaultValue: 'main', description: '选择需要构建的 Git 分支')
        // 添加一个布尔型参数，默认不勾选 (false)
        booleanParam(name: 'APPLY_PATCH', defaultValue: false, description: '是否需要应用 APISIX Nacos Lua 补丁并重启网关？(仅当补丁有修改时才需要勾选)')
        text(name: 'CORS_REGEX_PARAM', defaultValue: '', description: '可选。留空则使用仓库 defaults/cors-allow-origins.json；填写时请给合法 JSON 数组（一行即可）。')
        string(name: 'APISIX_ADMIN_URL', defaultValue: 'http://apisix:9180', description: 'APISIX Admin API 完整地址')
        string(name: 'REDIS_URL', defaultValue: 'redis', description: '网关鉴权使用的 Redis 主机名或 IP')
        string(name: 'REDIS_PORT', defaultValue: '6379', description: '网关鉴权使用的 Redis 端口')
        booleanParam(name: 'DEPLOY_DOCS_ROUTE', defaultValue: false, description: '是否注册 Docs 服务路由')
        booleanParam(name: 'DEPLOY_AI_ASSET_ROUTE', defaultValue: true, description: '是否注册 AI Asset 微服务路由')
        booleanParam(name: 'DEPLOY_DOCUMENT_ROUTE', defaultValue: true, description: '是否注册文档微服务路由')
        booleanParam(name: 'DEPLOY_NOTE_ROUTE', defaultValue: true, description: '是否注册笔记及协作微服务路由')
        booleanParam(name: 'DEPLOY_FRONTEND_ROUTE', defaultValue: false, description: '是否注册前端容器路由（OSS 部署时关闭）')
        string(name: 'FRONTEND_HOST', defaultValue: '', description: '前端服务 IP/Host。DEPLOY_FRONTEND_ROUTE 勾选时必填，留空则跳过注册前端路由。')
        string(name: 'FRONTEND_PORT', defaultValue: '80', description: '前端服务端口。')
    }

    environment {
        CORS_REGEX_JSON = "${params.CORS_REGEX_PARAM}"
    }

    stages {
        stage('1. 拉取代码 (Checkout)') {
            steps {
                script {
                    def remoteUrl = scm.userRemoteConfigs[0].url
                    echo "开始从 ${remoteUrl} 拉取 ${params.BRANCH_NAME} 分支的部署脚本..."
                    deleteDir()
                    git branch: params.BRANCH_NAME, url: remoteUrl
                    env.GIT_COMMIT_FULL = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                    sh 'git status --short --branch'
                    echo "网关部署脚本已就绪，Commit: ${env.GIT_COMMIT_FULL}"
                }
            }
        }

        stage('2. 环境检查与准备') {
            steps {
                script {
                    sh '''
                    if ! command -v jq &> /dev/null; then
                        echo "系统缺失 jq，正在下载独立二进制版本..."
                        mkdir -p "$WORKSPACE/bin"
                        # 使用 GitHub 加速下载 jq 的 Linux amd64 版本
                        curl -L -# -o "$WORKSPACE/bin/jq" "https://github.com/jqlang/jq/releases/download/jq-1.8.1/jq-linux-amd64"
                        chmod +x "$WORKSPACE/bin/jq"
                        echo "jq 下载完毕，版本："
                        "$WORKSPACE/bin/jq" --version
                    else
                        echo "jq 工具已就绪"
                    fi
                    '''
                }
            }
        }

        stage('3. 应用 APISIX 补丁 (Patch)') {
            // 使用 when 指令：只有当构建参数 APPLY_PATCH 被勾选时，才会执行这个阶段
            when {
                expression { return params.APPLY_PATCH == true }
            }
            steps {
                dir('./') {
                    echo "检测到打补丁选项已开启，开始执行 patch.sh ..."
                    sh "chmod +x patch.sh"
                    sh "./patch.sh"
                    echo "补丁应用完成，网关容器已重启"
                }
            }
        }

        stage('4. 自动化注册路由 (Setup Routes)') {
            steps {
                dir('./') {
                    echo "开始推送到 APISIX Admin API 注册全局插件与路由..."
                    sh "chmod +x setup.sh"
                    script {
                        if (params.DEPLOY_FRONTEND_ROUTE && !params.FRONTEND_HOST?.trim()) {
                            error('DEPLOY_FRONTEND_ROUTE 已勾选，但 FRONTEND_HOST 为空。请填写前端服务 IP/Host。')
                        }
                    }
                    withCredentials([
                        string(credentialsId: 'apisix-admin-key', variable: 'APISIX_ADMIN_KEY'),
                        string(credentialsId: 'redis-password', variable: 'REDIS_AUTH_PASSWORD'),
                        string(credentialsId: 'from-source-secret', variable: 'FROM_SOURCE_SECRET'),
                    ]) {
                        withEnv([
                            "PATH=${env.WORKSPACE}/bin:${env.PATH}",
                            "APISIX_ADMIN_URL=${params.APISIX_ADMIN_URL.trim()}",
                            "REDIS_URL=${params.REDIS_URL.trim()}",
                            "REDIS_PORT=${params.REDIS_PORT.trim()}",
                            "DEPLOY_DOCS_ROUTE=${params.DEPLOY_DOCS_ROUTE}",
                            "DEPLOY_AI_ASSET_ROUTE=${params.DEPLOY_AI_ASSET_ROUTE}",
                            "DEPLOY_DOCUMENT_ROUTE=${params.DEPLOY_DOCUMENT_ROUTE}",
                            "DEPLOY_NOTE_ROUTE=${params.DEPLOY_NOTE_ROUTE}",
                            "FRONTEND_HOST=${params.DEPLOY_FRONTEND_ROUTE ? params.FRONTEND_HOST.trim() : ''}",
                            "FRONTEND_PORT=${params.FRONTEND_PORT}",
                        ]) {
                            sh "./setup.sh"
                        }
                    }
                    echo "路由配置同步完成"
                }
            }
        }
    }

    post {
        success {
            echo "网关自动化部署流水线执行成功！"
        }
        failure {
            echo "流水线执行失败，请检查脚本输出日志或确保 APISIX 服务存活！"
        }
    }
}
