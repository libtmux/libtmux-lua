local test = require("luaunit")
local files = require("support.files")
local fs = require("support.fs")
local readme = require("docs.readme_examples")
local repo = require("support.repo")
local M = {}

local EXAMPLE = 'print("hello")\n'
local FENCE = "```"
local function be32(value)
    return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256
    )
end
local PNG = "\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(512) .. be32(512) .. ("\0"):rep(5)
local LOGO = '<!-- libtmux-logo -->\n<div align="center">\n  <picture>\n'
    .. '    <source srcset="assets/logo.svg" type="image/svg+xml">\n'
    .. '    <img src="assets/logo.png" width="128" height="128" alt="libtmux for Lua">\n'
    .. '  </picture>\n</div>\n<!-- /libtmux-logo -->\n\n<div align="center">\n\n'
local SECTIONS = "## What it leaves out\n\n- **A default server.** The caller names one.\n\n"
    .. "## Support and status\n\n- **Versions.** Pin an exact version.\n"

local function replace(text, old, new)
    local first, last = text:find(old, 1, true)
    assert(first, "missing " .. old)
    return text:sub(1, first - 1) .. new .. text:sub(last + 1)
end

local ROOT_README = LOGO
    .. "# Root\n\n</div>\n\n## Quick start\n\n<!-- example: examples/hello.lua -->\n\n"
    .. FENCE
    .. "lua\n"
    .. EXAMPLE
    .. FENCE
    .. "\n\n"
    .. FENCE
    .. "console\n$ lua examples/hello.lua\n"
    .. FENCE
    .. "\n\n"
    .. FENCE
    .. "console\n$ lua examples/api/connect.lua\nconnected\n"
    .. FENCE
    .. "\n\n"
    .. FENCE
    .. "console\n$ luarocks --local make \\\n    rockspecs/libtmux-scm-1.rockspec\n"
    .. FENCE
    .. "\n\n"
    .. FENCE
    .. "console\n$ lua -e 'print(require(\"libtmux\")._VERSION)'\n1\n"
    .. FENCE
    .. "\n\n[Core](https://github.com/libtmux/libtmux-lua/tree/master/lua/libtmux)\n\n"
    .. SECTIONS
local CORE_README = replace(ROOT_README, "# Root", "# Core")
local FILES = {
    ["README.md"] = ROOT_README,
    ["lua/libtmux/README.md"] = CORE_README,
    ["assets/logo.svg"] = "<svg>library</svg>",
    ["assets/logo.png"] = PNG,
    ["lua/libtmux/assets/logo.svg"] = "<svg>library</svg>",
    ["lua/libtmux/assets/logo.png"] = PNG,
    ["examples/hello.lua"] = EXAMPLE,
    ["examples/api/connect.lua"] = 'print("connected")\n',
    ["examples/api/manifest.json"] = '{"examples":[{"file":"examples/api/connect.lua",'
        .. '"stdout":"connected\\n"}]}',
    ["rockspecs/libtmux-scm-1.rockspec"] = "package = 'libtmux'\n",
    ["lua/libtmux/init.lua"] = 'return { _VERSION = "1" }\n',
}

local root
local function write(changes)
    for name, content in pairs(changes) do
        fs.mkdir_p(root .. "/" .. (name:match("^(.*)/[^/]+$") or "."))
        files.write(root .. "/" .. name, content)
    end
end

local function rejects(pattern, changes)
    write(changes or {})
    local ok, failure = pcall(readme.check_readmes, root)
    test.assertFalse(ok, "accepted: " .. pattern)
    test.assertStrContains(tostring(failure), pattern)
end

function M.setUp()
    root = fs.mkdtemp("libtmux-lua-readme-")
    write(FILES)
end

function M.tearDown()
    fs.remove_tree(root)
end

function M.test_repository_readmes_match_their_sources()
    readme.check_readmes(repo.root)
end

function M.test_clean_control_passes()
    readme.check_readmes(root)
end

function M.test_rejects_a_block_that_drifted_from_its_source()
    rejects("differs from examples/hello.lua", { ["examples/hello.lua"] = 'print("changed")\n' })
end

function M.test_rejects_a_marker_without_a_source_file()
    os.remove(root .. "/examples/hello.lua")
    rejects("example source is missing")
end

function M.test_every_readme_needs_a_marker_on_every_lua_block()
    local unmarked = "\n" .. FENCE .. "lua\nprint(1)\n" .. FENCE .. "\n"
    rejects(
        "lacks an example or excerpt marker",
        { ["lua/libtmux/README.md"] = CORE_README .. unmarked }
    )
    write({ ["lua/libtmux/README.md"] = CORE_README })
    rejects("lacks an example or excerpt marker", { ["README.md"] = ROOT_README .. unmarked })
end

function M.test_accepts_an_excerpt_indented_in_its_source()
    local source = 'local a = 1\nif a then\n    print("a")\n\n    print("b")\nend\n'
    local excerpt = "\n<!-- excerpt: examples/long.lua -->\n\n"
        .. FENCE
        .. 'lua\nprint("a")\n\nprint("b")\n'
        .. FENCE
        .. "\n"
    write({ ["examples/long.lua"] = source, ["README.md"] = ROOT_README .. excerpt })
    readme.check_readmes(root)
end

function M.test_rejects_an_excerpt_that_drifted_or_skips_lines()
    write({ ["examples/long.lua"] = 'local a = 1\nprint("a")\nprint("b")\nprint("c")\n' })
    local marker = "<!-- excerpt: examples/long.lua -->"
    local clean = "\n"
        .. marker
        .. "\n\n"
        .. FENCE
        .. 'lua\nprint("a")\nprint("b")\n'
        .. FENCE
        .. "\n"
    write({ ["README.md"] = ROOT_README .. clean })
    readme.check_readmes(root)
    local changed = replace(clean, 'print("b")', 'print("changed")')
    local skipped = "\n"
        .. marker
        .. "\n\n"
        .. FENCE
        .. 'lua\nprint("a")\nprint("c")\n'
        .. FENCE
        .. "\n"
    for _, body in ipairs({ changed, skipped }) do
        rejects(
            "not a run of lines from examples/long.lua",
            { ["README.md"] = ROOT_README .. body }
        )
    end
    write({ ["README.md"] = ROOT_README .. clean })
    os.remove(root .. "/examples/long.lua")
    rejects("excerpt source is missing")
end

function M.test_rejects_a_readme_without_the_expected_sections()
    rejects("first section must be Quick start", {
        ["README.md"] = replace(ROOT_README, "## Quick start", "## Install"),
    })
    write({ ["README.md"] = ROOT_README })
    for _, title in ipairs({ "What it leaves out", "Support and status" }) do
        rejects("missing the " .. title .. " section", {
            ["lua/libtmux/README.md"] = replace(CORE_README, "## " .. title, "## Elsewhere"),
        })
        write({ ["lua/libtmux/README.md"] = CORE_README })
    end
end

function M.test_rejects_prose_that_reads_as_a_wall()
    local wall = ("word "):rep(60)
    rejects("reads as a wall", { ["README.md"] = ROOT_README .. "\n" .. wall .. "\n" })
    rejects("reads as a wall", { ["README.md"] = ROOT_README .. "\n- **Lead.** " .. wall .. "\n" })
    -- Link targets, code and tables do not count toward the length.
    local target = "https://example.test/" .. ("x"):rep(300)
    local cells = {}
    for index = 1, 3 do
        cells[index] = ("cell "):rep(20)
    end
    local grid = "| " .. table.concat(cells, " | ") .. " |\n| --- | --- | --- |"
    local quiet = ("\n[short](%s) and [`name`][ref]\n\n%s\n\n[ref]: %s\n"):format(
        target,
        grid,
        target
    )
    write({ ["README.md"] = ROOT_README .. quiet })
    readme.check_readmes(root)
end

function M.test_rejects_a_reference_link_without_a_definition()
    rejects("link reference is not defined: [ref-missing]", {
        ["README.md"] = ROOT_README .. "\nSee [`Server`][ref-missing].\n",
    })
    write({
        ["README.md"] = ROOT_README
            .. "\nSee [`Server`][ref-server].\n\n[ref-server]: https://example.test/\n",
    })
    readme.check_readmes(root)
end

function M.test_rejects_a_command_naming_a_missing_file()
    os.remove(root .. "/rockspecs/libtmux-scm-1.rockspec")
    rejects("missing file: rockspecs/libtmux-scm-1.rockspec")
    rejects("missing file: examples/missing.lua", {
        ["README.md"] = replace(ROOT_README, "lua examples/hello.lua", "lua examples/missing.lua"),
        ["rockspecs/libtmux-scm-1.rockspec"] = "",
    })
end

function M.test_rejects_output_that_differs_from_the_manifest()
    rejects("manifest for examples/api/connect.lua", {
        ["README.md"] = replace(ROOT_README, "\nconnected\n", "\nconnected twice\n"),
    })
end

function M.test_rejects_a_printed_version_that_differs_from_the_source()
    rejects("printed version differs from libtmux", {
        ["lua/libtmux/init.lua"] = 'return { _VERSION = "1.0" }\n',
    })
end

function M.test_rejects_a_source_link_to_a_missing_path()
    rejects("missing path: packages/gone", {
        ["README.md"] = ROOT_README
            .. "[Gone](https://github.com/libtmux/libtmux-lua/tree/master/packages/gone)\n",
    })
end

function M.test_rejects_a_readme_that_does_not_open_with_the_logo_block()
    rejects("must open with the centered logo block", {
        ["lua/libtmux/README.md"] = CORE_README:sub(#LOGO + 1),
    })
    rejects("must open with the centered logo block", {
        ["lua/libtmux/README.md"] = "# Title\n\n" .. CORE_README,
    })
end

function M.test_rejects_a_paragraph_wrapper_and_a_changed_image_tag()
    local wrappers = {
        { "div align", "p align" },
        { "</div>\n<!-- /libtmux-logo", "</p>\n<!-- /libtmux-logo" },
        { 'width="128"', 'width="64"' },
        { "assets/logo.png", "https://example.test/logo.png" },
    }
    for _, pair in ipairs(wrappers) do
        rejects("must open with the centered logo block", {
            ["lua/libtmux/README.md"] = replace(CORE_README, pair[1], pair[2]),
        })
        write({ ["lua/libtmux/README.md"] = CORE_README })
    end
end

function M.test_rejects_the_wrong_alt_text_for_a_product()
    rejects('alt text must be "libtmux for Lua"', {
        ["lua/libtmux/README.md"] = replace(CORE_README, 'alt="libtmux for Lua"', 'alt="libtmux"'),
    })
end

function M.test_rejects_missing_or_malformed_logo_assets()
    rejects("assets/logo.svg is missing", { ["lua/libtmux/assets/logo.svg"] = "not vector art" })
    write(FILES)
    rejects("512 x 512", {
        ["lua/libtmux/assets/logo.png"] = replace(PNG, be32(512), be32(256)),
    })
    write(FILES)
    os.remove(root .. "/lua/libtmux/assets/logo.png")
    rejects("512 x 512")
end

function M.test_rejects_art_split_within_one_product()
    rejects('differs from the other "libtmux for Lua" README', {
        ["lua/libtmux/assets/logo.svg"] = "<svg>another</svg>",
    })
end

function M.test_console_steps_join_continuations_and_keep_output()
    local block = "$ luarocks make \\\n    rockspecs/a.rockspec\n$ lua -e 'x'\nscm\n"
    test.assertEquals(readme.console_steps(block), {
        { "luarocks make rockspecs/a.rockspec", {} },
        { "lua -e 'x'", { "scm" } },
    })
end

return M
