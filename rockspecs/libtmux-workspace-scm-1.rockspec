rockspec_format = "3.0"
package = "libtmux-workspace"
version = "scm-1"
source = { url = "git+https://github.com/libtmux/libtmux-lua.git" }
description = {
    summary = "Development package for planned libtmux workspace operations",
    homepage = "https://github.com/libtmux/libtmux-lua",
    license = "MIT",
}
dependencies = {
    "lua >= 5.1, < 5.6",
    "libtmux == scm-1",
    "luv >= 1.52.1, < 2.0",
    "lunajson >= 1.2.3, < 2.0",
    "lyaml >= 6.2.9, < 7.0",
}
build = {
    type = "builtin",
    modules = {
        libtmux_workspace = "packages/workspace/lua/libtmux_workspace/init.lua",
    },
}
