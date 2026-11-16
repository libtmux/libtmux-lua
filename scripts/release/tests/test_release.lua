-- Critical release preparation and publication guards, without network access.
local test = require("luaunit")
local files = require("support.files")
local fs = require("support.fs")
local json = require("support.json")
local release = require("release.release")
local repo = require("support.repo")
local runtime = require("support.runtime")
local shell = require("support.shell")
local M = {}

local ROOT = repo.root
local PREPARED_SPEC = release.prepared_spec
local cache = {}

--- release.prepared_spec starts luarocks and stylua. Its result depends only on the template
--- rockspec, the stylua config and the version, so each fixture reuses the first run.
---@diagnostic disable-next-line: duplicate-set-field
release.prepared_spec = function(root, version)
    local inputs = { root .. "/rockspecs/libtmux-scm-1.rockspec", root .. "/stylua.toml" }
    local key = version
    for _, path in ipairs(inputs) do
        key = key .. "\0" .. (fs.is_file(path) and files.read(path) or "-")
    end
    cache[key] = cache[key] or PREPARED_SPEC(root, version)
    return cache[key]
end

local SPEC = [[rockspec_format = "3.0"
package = "libtmux"
version = "scm-1"
source = { url = "git+https://github.com/libtmux/libtmux-lua.git" }
description = { summary = "Lua tmux API", license = "MIT" }
dependencies = { "lua >= 5.1, < 5.6" }
build = { type = "builtin", modules = { libtmux = "lua/libtmux/init.lua" } }
]]
local CHANGES = "# Changelog\n\nNotable changes to `libtmux`.\n\n## Unreleased\n\n- Initial core.\n"

local function write(root, path, content)
    fs.mkdir_p(root .. "/" .. (path:match("^(.*)/[^/]+$") or "."))
    files.write(root .. "/" .. path, content)
end

local function git(root, ...)
    return shell.check({ "git", ... }, { cwd = root })
end

local function fixture(root)
    write(root, "lua/libtmux/init.lua", 'return { _VERSION = "scm" }\n')
    write(root, "rockspecs/libtmux-scm-1.rockspec", SPEC)
    write(root, "CHANGES.md", CHANGES)
    git(root, "init", "-q")
end

local function snapshot(root)
    local found = {}
    for _, relative in ipairs(fs.walk(root)) do
        if relative:sub(1, 5) ~= ".git/" then
            found[relative] = files.read(root .. "/" .. relative)
        end
    end
    return found
end

local function prepare(root, version, check)
    local ok, failure = pcall(release.prepare, root, version or release.candidate(root), check)
    return ok, failure
end

local function commit_all(root, tag)
    git(root, "add", ".")
    git(
        root,
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=test@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-qm",
        "Release"
    )
    git(root, "tag", tag)
    git(root, "update-ref", "refs/remotes/origin/master", "HEAD")
    return git(root, "rev-parse", "HEAD"):match("%S+")
end

local root, prepared

--- The GitHub tag-push event of a canonical release, with `changes` applied.
local function event_with(changes)
    local event = {
        ref = "refs/tags/v0.1.0alpha1",
        deleted = false,
        repository = { full_name = "libtmux/libtmux-lua" },
    }
    for key, value in pairs(changes) do
        event[key] = value
    end
    return event
end

function M.setUp()
    root = fs.mkdtemp("libtmux-lua-release-")
    fixture(root)
end

function M.tearDown()
    fs.remove_tree(root)
    if prepared then
        fs.remove_tree(prepared)
        prepared = nil
    end
end

--- The checkout after `prepare 0.1.0alpha1-1`, for tests that start from a prepared release.
local function start_prepared()
    assert(prepare(root, "0.1.0alpha1-1"))
    return root
end

function M.test_prepare_and_check_keep_one_alpha_identity()
    -- Once through the real command line.
    local lua = runtime.executable_path(arg and arg[-1] or "luajit")
    local code, output = shell.run(
        { lua, ROOT .. "/scripts/release/main.lua", "prepare", "0.1.0alpha1-1" },
        {
            cwd = root,
        }
    )
    test.assertEquals(code, 0, output)
    test.assertEquals(json.read(root .. "/release.json").version, "0.1.0alpha1-1")
    test.assertEquals(json.read(root .. "/release.json").package, "libtmux")
    test.assertEquals(
        files.read(root .. "/lua/libtmux/init.lua"),
        'return { _VERSION = "0.1.0alpha1" }\n'
    )
    test.assertFalse(
        fs.is_file(root .. "/libtmux-scm-1.rockspec"),
        "preparation leaked a temporary input"
    )
    test.assertStrContains(files.read(root .. "/CHANGES.md"), "## 0.1.0alpha1-1\n\n- Initial core.")
    local before = snapshot(root)
    test.assertTrue(prepare(root, "0.1.0alpha1-1", true))
    test.assertEquals(snapshot(root), before)
    test.assertTrue(prepare(root, "0.1.0alpha1-1"))
    test.assertEquals(snapshot(root), before)
end

function M.test_check_rejects_runtime_drift_without_repairing_it()
    start_prepared()
    write(root, "lua/libtmux/init.lua", 'return { _VERSION = "wrong" }\n')
    local before = snapshot(root)
    local ok, failure = prepare(root, "0.1.0alpha1-1", true)
    test.assertFalse(ok)
    test.assertStrContains(tostring(failure), "lua/libtmux/init.lua")
    test.assertEquals(snapshot(root), before)
end

function M.test_dated_release_preserves_notes_and_pending_changes()
    start_prepared()
    for _, pending in ipairs({ "", "- Next release change.\n\n" }) do
        write(
            root,
            "CHANGES.md",
            "# Changelog\n\n## Unreleased\n\n"
                .. pending
                .. "## 0.1.0alpha1-1 (2026-09-20)\n\n- Initial core.\n"
        )
        local before = snapshot(root)
        test.assertTrue(prepare(root, nil, true))
        test.assertEquals(snapshot(root), before)
        test.assertTrue(prepare(root, "0.1.0alpha1-1"))
        test.assertEquals(snapshot(root), before)
    end
end

function M.test_invalid_identity_does_not_modify_files()
    local before = snapshot(root)
    for _, version in ipairs({
        "0.1.0-alpha.1",
        "0.1.0alpha1-0",
        "scm-1",
        "../0.1.0-1",
        "01.1.0-1",
        "0.1.0beta0-1",
    }) do
        local ok, failure = prepare(root, version)
        test.assertFalse(ok, version)
        test.assertStrContains(tostring(failure), "version")
        test.assertEquals(snapshot(root), before)
    end
end

function M.test_publication_requires_a_canonical_tag_push_and_exact_commit()
    start_prepared()
    local head = commit_all(root, "v0.1.0alpha1")
    local event = event_with({})
    release.verify_release(root, event, head)
    local changelog = files.read(root .. "/CHANGES.md")
    os.remove(root .. "/CHANGES.md")
    test.assertErrorMsgContains(
        "CHANGES.md: libtmux has no changelog",
        release.verify_release,
        root,
        event,
        head
    )
    files.write(root .. "/CHANGES.md", changelog)
    local cases = {
        { event_with({ ref = "refs/heads/master" }), head },
        { event_with({ repository = { full_name = "someone/fork" } }), head },
        { event_with({ ref = "refs/tags/v0.1.0" }), head },
        { event_with({ deleted = true }), head },
        { event_with({ deleted = json.null }), head },
        {
            {
                action = "published",
                repository = { full_name = "libtmux/libtmux-lua" },
                release = { tag_name = "v0.1.0alpha1" },
            },
            head,
        },
        { event, string.rep("0", 40) },
    }
    for index, case in ipairs(cases) do
        local ok = pcall(release.verify_release, root, case[1], case[2])
        test.assertFalse(ok, "case " .. index .. " was accepted")
    end
end

function M.test_upload_rejects_changed_bytes_and_unpublished_source_artifacts()
    start_prepared()
    local directory = root .. "/artifacts"
    fs.mkdir_p(directory)
    local spec, rock = "libtmux-0.1.0alpha1-1.rockspec", "libtmux-0.1.0alpha1-1.src.rock"
    files.write(directory .. "/" .. spec, files.read(root .. "/rockspecs/" .. spec))
    files.write(directory .. "/" .. rock, "validated artifact fixture")
    local hashes = json.object({ spec, rock }, {
        [spec] = shell.sha256(directory .. "/" .. spec),
        [rock] = shell.sha256(directory .. "/" .. rock),
    })
    local function manifest(overrides)
        local value = json.object(
            { "package", "version", "head", "dirty", "source", "artifacts" },
            {
                package = "libtmux",
                version = "0.1.0alpha1-1",
                head = "abc",
                dirty = false,
                source = "public-tag",
                artifacts = hashes,
            }
        )
        for key, item in pairs(overrides or {}) do
            value[key] = item
        end
        return value
    end
    local function save(value)
        files.write(directory .. "/candidate.json", json.encode(value))
    end
    files.write(
        directory .. "/SHA256SUMS",
        hashes[spec] .. "  " .. spec .. "\n" .. hashes[rock] .. "  " .. rock .. "\n"
    )
    save(manifest())
    release.verify_artifacts(root, directory, "abc")
    for _, overrides in ipairs({
        { source = "local-fixture" },
        { dirty = true },
        { head = "other" },
    }) do
        save(manifest(overrides))
        test.assertFalse(pcall(release.verify_artifacts, root, directory, "abc"))
    end
    save(manifest())
    files.write(directory .. "/" .. rock, "changed after validation")
    test.assertErrorMsgContains("checksum", release.verify_artifacts, root, directory, "abc")
end

function M.test_packaging_revision_keeps_the_source_version()
    start_prepared()
    local notes = files.read(root .. "/CHANGES.md")
    write(
        root,
        "CHANGES.md",
        (notes:gsub("## Unreleased\n", "## Unreleased\n\n- Fix packaging.\n", 1))
    )
    test.assertTrue(prepare(root, "0.1.0alpha1-2"))
    test.assertEquals(
        files.read(root .. "/lua/libtmux/init.lua"),
        'return { _VERSION = "0.1.0alpha1" }\n'
    )
    test.assertEquals(release.release_tag("0.1.0alpha1-2"), "rocks/0.1.0alpha1-2")
    test.assertTrue(fs.is_file(root .. "/rockspecs/libtmux-0.1.0alpha1-1.rockspec"))
end

function M.test_a_tagged_release_rockspec_that_would_change_is_refused()
    start_prepared()
    commit_all(root, "v0.1.0alpha1")
    write(root, "rockspecs/libtmux-0.1.0alpha1-1.rockspec", "-- hand edited\n")
    local ok, failure = prepare(root, "0.1.0alpha1-1")
    test.assertFalse(ok)
    test.assertStrContains(tostring(failure), "tagged release rockspec would change")
end

local function changelog_root()
    local directory = fs.mkdtemp("libtmux-lua-changelogs-")
    files.write(directory .. "/CHANGES.md", files.read(ROOT .. "/CHANGES.md"))
    return directory
end

local function refused(directory, fragment)
    local reported = release.changelog_failures(directory)
    for _, line in ipairs(reported) do
        if line:find(fragment, 1, true) then
            return
        end
    end
    test.fail("not reported: " .. fragment .. " in " .. table.concat(reported, "; "))
end

function M.test_the_changelog_checkout_passes_and_names_one_rock()
    local directory = changelog_root()
    test.assertEquals(release.changelog_failures(directory), {})
    test.assertEquals(release.CHANGELOGS, { libtmux = "CHANGES.md" })
    local lua = runtime.executable_path(arg and arg[-1] or "luajit")
    local code, output = shell.run(
        { lua, ROOT .. "/scripts/release/main.lua", "changelogs" },
        { cwd = directory }
    )
    test.assertEquals(code, 0, output)
    os.remove(directory .. "/CHANGES.md")
    code, output = shell.run(
        { lua, ROOT .. "/scripts/release/main.lua", "changelogs" },
        { cwd = directory }
    )
    test.assertNotEquals(code, 0)
    test.assertStrContains(output, "CHANGES.md: libtmux has no changelog")
    fs.remove_tree(directory)
end

function M.test_a_missing_unreleased_section_is_refused_even_inside_a_fence()
    local directory = changelog_root()
    local path = directory .. "/CHANGES.md"
    local text = files.read(path)
    files.write(path, (text:gsub("## Unreleased\n", "")))
    refused(directory, 'CHANGES.md: has no "## Unreleased" section')
    -- A fence closes only on its own character, at least as long, with no info string, so a
    -- shorter or different line inside it does not end it.
    for _, fence in ipairs({
        { "```", "~~~" },
        { "~~~", "" },
        { "````", "```" },
        { "```", "```js" },
    }) do
        files.write(
            path,
            (
                text:gsub(
                    "## Unreleased\n",
                    fence[1] .. "markdown\n" .. fence[2] .. "\n## Unreleased\n" .. fence[1] .. "\n",
                    1
                )
            )
        )
        refused(directory, 'CHANGES.md: has no "## Unreleased" section')
    end
    fs.remove_tree(directory)
end

function M.test_a_changelog_that_is_not_the_rocks_own_is_refused()
    local directory = changelog_root()
    local path = directory .. "/CHANGES.md"
    local text = files.read(path)
    files.write(
        path,
        (text:gsub("Notable changes to `libtmux`%.", "Notable changes to `another`.", 1))
    )
    refused(directory, "CHANGES.md: is the changelog of another, not libtmux")
    files.write(path, (text:gsub("# Changelog\n\n", "# Changelog\n\nSomething else first.\n\n", 1)))
    refused(directory, 'CHANGES.md: does not open with "Notable changes to `libtmux`."')
    files.write(path, (text:gsub("Notable changes to `[^`]+`%.\n\n", "", 1)))
    refused(directory, 'CHANGES.md: does not open with "Notable changes to `libtmux`."')
    fs.remove_tree(directory)
end

function M.test_only_alpha_beta_and_rc_versions_are_prereleases()
    test.assertTrue(release.is_prerelease("0.1.0alpha1-1"))
    test.assertTrue(release.is_prerelease("0.1.0beta12-2"))
    test.assertTrue(release.is_prerelease("1.0.0rc3-1"))
    test.assertFalse(release.is_prerelease("0.1.0-1"))
    test.assertFalse(release.is_prerelease("1.2.3-4"))
end

function M.test_the_upload_command_names_the_two_artifacts_and_carries_the_key()
    test.assertEquals(release.upload_command("0.1.0-1", "dist", "secret"), {
        "luarocks",
        "upload",
        "dist/libtmux-0.1.0-1.rockspec",
        "dist/libtmux-0.1.0-1.src.rock",
        "--temp-key",
        "secret",
    })
    test.assertErrorMsgContains(
        "LUAROCKS_API_KEY is not set",
        release.upload_command,
        "0.1.0-1",
        "dist",
        ""
    )
    test.assertErrorMsgContains(
        "LUAROCKS_API_KEY is not set",
        release.upload_command,
        "0.1.0-1",
        "dist",
        nil
    )
end

function M.test_the_github_release_marks_a_prerelease_and_lists_its_assets()
    local stable = release.github_release_command("0.1.0-1", "v0.1.0", "dist")
    test.assertEquals({ unpack(stable, 1, 8) }, {
        "gh",
        "release",
        "create",
        "v0.1.0",
        "--verify-tag",
        "--title",
        "libtmux 0.1.0-1",
        "--generate-notes",
    })
    test.assertEquals({ unpack(stable, 9) }, {
        "dist/libtmux-0.1.0-1.rockspec",
        "dist/libtmux-0.1.0-1.src.rock",
        "dist/SHA256SUMS",
        "dist/candidate.json",
        "dist/provenance.sigstore.json",
    })
    local pre = release.github_release_command("0.1.0alpha1-1", "v0.1.0alpha1", "dist")
    test.assertEquals(pre[9], "--prerelease")
    test.assertEquals(#pre, #stable + 1)
end

--- A checkout whose release.json names `version`, and a directory of artifacts.
local function publication(version)
    local checkout = fs.mkdtemp("libtmux-lua-publish-")
    json.write(checkout .. "/release.json", { package = "libtmux", version = version })
    local dist = checkout .. "/dist"
    fs.mkdir_p(dist)
    for _, name in ipairs({
        "libtmux-" .. version .. ".rockspec",
        "libtmux-" .. version .. ".src.rock",
        "SHA256SUMS",
        "candidate.json",
    }) do
        files.write(dist .. "/" .. name, name)
    end
    files.write(checkout .. "/bundle.json", "bundle bytes")
    return checkout, dist
end

function M.test_upload_runs_luarocks_for_the_candidate_and_reports_a_failure()
    local checkout, dist = publication("0.1.0alpha1-1")
    local ran
    release.upload(checkout, dist, "secret", function(argv)
        ran = argv
        return { code = 0 }
    end)
    test.assertEquals(ran[3], dist .. "/libtmux-0.1.0alpha1-1.rockspec")
    test.assertEquals(ran[#ran], "secret")
    test.assertErrorMsgContains("status 7", release.upload, checkout, dist, "secret", function()
        return { code = 7 }
    end)
    local started = false
    pcall(release.upload, checkout, dist, "", function()
        started = true
        return { code = 0 }
    end)
    test.assertFalse(started, "a missing key must stop before luarocks runs")
    fs.remove_tree(checkout)
end

function M.test_github_release_copies_the_bundle_and_refuses_a_missing_asset()
    local checkout, dist = publication("0.1.0-1")
    local ran
    release.github_release(checkout, "v0.1.0", dist, checkout .. "/bundle.json", function(argv)
        ran = argv
        return { code = 0 }
    end)
    test.assertEquals(files.read(dist .. "/provenance.sigstore.json"), "bundle bytes")
    test.assertEquals(ran[4], "v0.1.0")
    test.assertEquals(ran[#ran], dist .. "/provenance.sigstore.json")
    test.assertEquals(ran[9], dist .. "/libtmux-0.1.0-1.rockspec")
    os.remove(dist .. "/candidate.json")
    local started = false
    test.assertErrorMsgContains(
        "release asset is missing",
        release.github_release,
        checkout,
        "v0.1.0",
        dist,
        checkout .. "/bundle.json",
        function()
            started = true
            return { code = 0 }
        end
    )
    test.assertFalse(started)
    fs.remove_tree(checkout)
end

return M
