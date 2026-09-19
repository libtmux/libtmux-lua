rockspec_format = "3.0"
package = "libtmux-mcp"
version = "scm-1"
source = { url = "git+https://github.com/libtmux/libtmux-lua.git" }
description = {
    summary = "Development package for the planned libtmux MCP server",
    homepage = "https://github.com/libtmux/libtmux-lua",
    license = "MIT",
}
dependencies = {
    "lua >= 5.1, < 5.6",
    "libtmux == scm-1",
    "luv >= 1.52.1, < 2.0",
    "lunajson >= 1.2.3, < 2.0",
}
build = {
    type = "builtin",
    modules = { libtmux_mcp = "packages/mcp/lua/libtmux_mcp/init.lua" },
}
