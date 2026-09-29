rockspec_format = "3.0"
package = "libtmux-luv"
version = "scm-1"
source = { url = "git+https://github.com/libtmux/libtmux-lua.git" }
description = {
    summary = "Standalone luv event-loop adapter for libtmux",
    homepage = "https://github.com/libtmux/libtmux-lua",
    issues_url = "https://github.com/libtmux/libtmux-lua/issues",
    license = "MIT",
}
dependencies = {
    "lua >= 5.1, < 5.6",
    "libtmux == scm-1",
    "luv >= 1.52.1, < 2.0",
}
build = {
    type = "builtin",
    modules = { ["libtmux.runtime.luv"] = "packages/luv/lua/libtmux/runtime/luv.lua" },
}
