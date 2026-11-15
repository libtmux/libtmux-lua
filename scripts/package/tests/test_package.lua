local test = require("luaunit")
local files = require("support.files")
local fs = require("support.fs")
local package_checks = require("package.package")
local repo = require("support.repo")
local shell = require("support.shell")
local M = {}

local root

local function git(...)
    shell.check({ "git", ... }, { cwd = root })
end

function M.setUp()
    root = fs.mkdtemp("libtmux-lua-drift-")
    fs.mkdir_p(root .. "/lua/libtmux")
    files.write(root .. "/lua/libtmux/init.lua", "return {}\n")
    files.write(root .. "/LICENSE", "MIT\n")
    git("init", "-q")
    git("add", ".")
    git(
        "-c",
        "user.name=Drift fixture",
        "-c",
        "user.email=drift@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-qm",
        "Tagged source"
    )
    git("tag", "v0.1.1")
end

function M.tearDown()
    fs.remove_tree(root)
end

function M.test_an_unchanged_checkout_matches_its_tag()
    test.assertFalse(package_checks.drifted_from("v0.1.1", root))
end

function M.test_a_changed_lua_source_is_drift()
    files.write(root .. "/lua/libtmux/init.lua", "return { changed = true }\n")
    test.assertTrue(package_checks.drifted_from("v0.1.1", root))
end

function M.test_a_changed_license_is_drift()
    files.write(root .. "/LICENSE", "MIT, amended\n")
    test.assertTrue(package_checks.drifted_from("v0.1.1", root))
end

function M.test_other_files_are_not_drift()
    files.write(root .. "/lua/libtmux/README.md", "Notes.\n")
    files.write(root .. "/README.md", "Notes.\n")
    test.assertFalse(package_checks.drifted_from("v0.1.1", root))
end

local function installed(content)
    local prefix = fs.mkdtemp("libtmux-lua-installed-")
    fs.mkdir_p(prefix .. "/lib/luarocks/rocks-5.5/libtmux/0.1.1-2/doc")
    files.write(prefix .. "/lib/luarocks/rocks-5.5/libtmux/0.1.1-2/doc/CHANGES.md", content)
    return prefix
end

function M.test_a_packaging_revision_is_held_to_the_source_rocks_notes()
    local tagged = "# Changelog\n\n## 0.1.1-1\n"
    local prefix = installed(tagged)
    package_checks.inspect_installed_changelog("libtmux", prefix, "5.5", "0.1.1-2", tagged)
    test.assertErrorMsgContains(
        "installed doc/CHANGES.md differs",
        package_checks.inspect_installed_changelog,
        "libtmux",
        prefix,
        "5.5",
        "0.1.1-2",
        tagged .. "- Fix packaging.\n"
    )
    fs.remove_tree(prefix)
end

function M.test_without_an_expected_file_the_checkouts_is_the_standard()
    local prefix = installed(files.read(repo.root .. "/CHANGES.md"))
    package_checks.inspect_installed_changelog("libtmux", prefix, "5.5", "0.1.1-2")
    fs.remove_tree(prefix)
    prefix = installed("not the changelog\n")
    test.assertErrorMsgContains(
        "installed doc/CHANGES.md differs",
        package_checks.inspect_installed_changelog,
        "libtmux",
        prefix,
        "5.5",
        "0.1.1-2"
    )
    fs.remove_tree(prefix)
end

function M.test_the_closure_check_accepts_exactly_the_core_rock()
    test.assertTrue(package_checks.only({ libtmux = true }, "libtmux"))
    test.assertFalse(package_checks.only({ libtmux = true, luv = true }, "libtmux"))
    test.assertFalse(package_checks.only({}, "libtmux"))
    test.assertFalse(package_checks.only({ luv = true }, "libtmux"))
end

return M
