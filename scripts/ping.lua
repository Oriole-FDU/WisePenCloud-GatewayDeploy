return function(conf, ctx)
    local core = require("apisix.core")

    core.response.exit(200, "pong")
end
