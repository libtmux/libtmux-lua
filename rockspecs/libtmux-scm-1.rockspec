rockspec_format = "3.0"
package = "libtmux"
version = "scm-1"
source = { url = "git+https://github.com/libtmux/libtmux-lua.git" }
description = {
    summary = "Development foundation for libtmux in Lua",
    homepage = "https://github.com/libtmux/libtmux-lua",
    license = "MIT",
}
dependencies = { "lua >= 5.1, < 5.6" }
build = {
    type = "builtin",
    modules = {
        libtmux = "lua/libtmux/init.lua",
        ["libtmux.query"] = "lua/libtmux/query.lua",
        ["libtmux._internal.query"] = "lua/libtmux/_internal/query.lua",
        ["libtmux._internal.query_wire"] = "lua/libtmux/_internal/query_wire.lua",
        ["libtmux._internal.runtime"] = "lua/libtmux/_internal/runtime.lua",
        ["libtmux._internal.error"] = "lua/libtmux/_internal/error.lua",
        ["libtmux._internal.process"] = "lua/libtmux/_internal/process.lua",
        ["libtmux._internal.codec"] = "lua/libtmux/_internal/codec.lua",
        ["libtmux._internal.identity"] = "lua/libtmux/_internal/identity.lua",
        ["libtmux._internal.command"] = "lua/libtmux/_internal/command.lua",
        ["libtmux._internal.fields"] = "lua/libtmux/_internal/fields.lua",
        ["libtmux._internal.graph"] = "lua/libtmux/_internal/graph.lua",
        ["libtmux._internal.metadata"] = "lua/libtmux/_internal/metadata.lua",
        ["libtmux._internal.control_parser"] = "lua/libtmux/_internal/control_parser.lua",
        ["libtmux._internal.control"] = "lua/libtmux/_internal/control.lua",
        ["libtmux._internal.observation"] = "lua/libtmux/_internal/observation.lua",
        ["libtmux._internal.control_io"] = "lua/libtmux/_internal/control_io.lua",
        ["libtmux._internal.endpoint"] = "lua/libtmux/_internal/endpoint.lua",
        ["libtmux._internal.server"] = "lua/libtmux/_internal/server.lua",
        ["libtmux._internal.batch"] = "lua/libtmux/_internal/batch.lua",
        ["libtmux._internal.execution"] = "lua/libtmux/_internal/execution.lua",
        ["libtmux._internal.entity"] = "lua/libtmux/_internal/entity.lua",
        ["libtmux._internal.domain"] = "lua/libtmux/_internal/domain.lua",
        ["libtmux._internal.pane"] = "lua/libtmux/_internal/pane.lua",
        ["libtmux._internal.planner"] = "lua/libtmux/_internal/planner.lua",
        ["libtmux._internal.live_query"] = "lua/libtmux/_internal/live_query.lua",
        ["libtmux.runtime.luv"] = "lua/libtmux/runtime/luv.lua",
        ["libtmux.runtime.nvim"] = "lua/libtmux/runtime/nvim.lua",
    },
}
