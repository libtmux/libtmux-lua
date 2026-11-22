-- Build the rock, install it into its own tree outside the checkout, and run what the package
-- promises: the import, the examples and the release candidate's source rock. Dependencies come
-- from the prepared tree and never from the network.
local api_examples = require("docs.api_examples")
local files = require("support.files")
local fs = require("support.fs")
local json = require("support.json")
local release = require("release.release")
local repo = require("support.repo")
local runtime = require("support.runtime")
local sandbox = require("tests.support.sandbox")
local shell = require("support.shell")

local M = {}

local ROOT = repo.root
M.DEPENDENCIES = { luv = "1.52.1-0" }
-- Where the changelog lands inside its installed rock: LuaRocks copies the core's root CHANGES.md
-- into doc/.
M.INSTALLED_CHANGELOGS = { libtmux = "doc/CHANGES.md" }
-- What a source rock carries from its tag. A change to one of these after the tag is drift.
M.SOURCE_PATHS = { ":(glob)lua/**/*.lua", "LICENSE" }

local function refuse(message)
    error(message, 0)
end

local function lines_of(text)
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    return lines
end

--- Runs argv and returns its output, or raises with the output when it fails.
---@param argv string[]
---@param opts? support.ShellOptions
---@return string
local function run(argv, opts)
    local code, output = shell.run(argv, opts)
    if code ~= 0 then
        refuse(("%s failed (%d):\n%s"):format(argv[1]:match("[^/]+$"), code, output))
    end
    return output
end

--- The tmux the examples run: LIBTMUX_TEST_TMUX, else TMUX_BIN, else tmux on PATH.
---@param getenv? fun(name: string): string?
---@return string
function M.tmux_binary(getenv)
    return runtime.executable_path(sandbox.tmux_binary(getenv))
end

--- The `.rock` file `luarocks pack` wrote into `directory`, whose name starts with `prefix`.
---@param directory string
---@param prefix string
---@return string
local function packed_rock(directory, prefix)
    for _, name in ipairs(fs.list(directory)) do
        if name:sub(1, #prefix) == prefix and name:sub(-5) == ".rock" then
            return directory .. "/" .. name
        end
    end
    error(("no %s*.rock in %s"):format(prefix, directory), 0)
end

--- Runs a Lua program given as text through the interpreter, with its arguments.
local function run_source(lua, source, args, opts)
    local path = os.tmpname()
    files.write(path, source)
    opts.stdin = path
    local argv = { lua, "-" }
    for _, value in ipairs(args or {}) do
        argv[#argv + 1] = value
    end
    local ok, output = pcall(run, argv, opts)
    os.remove(path)
    if not ok then
        error(output, 0)
    end
    return output
end

--- The names installed in a rock tree.
---@param tree string
---@param rocks fun(arguments: string[], opts?: table): string
---@return table<string, boolean>
function M.installed(tree, rocks)
    local names = {}
    for _, line in ipairs(lines_of(rocks({ "--tree=" .. tree, "list", "--porcelain" }))) do
        local name = line:match("^([^\t]+)")
        if name then
            names[name] = true
        end
    end
    return names
end

--- Whether the set holds exactly `name`.
---@param set table<string, boolean>
---@param name string
---@return boolean
function M.only(set, name)
    return set[name] == true and next(set, name) == nil and next(set) == name
end

local INSPECT = [[
assert(loadfile(arg[1]))()
assert(description.license == "MIT", "package license must be MIT")
assert(version == arg[2], "rockspec version mismatch")
assert((source.tag or "") == arg[3], "rockspec tag mismatch")
assert(source.url == arg[4], "rockspec repository mismatch")
assert(dependencies[1] == "lua >= 5.1, < 5.6", "Lua version constraint mismatch")
for _, dep in ipairs(dependencies) do print("dependency\t" .. dep:match("^%S+")) end
for name, path in pairs(build.modules) do print("module\t" .. name .. "\t" .. path) end
]]

--- Checks the rockspec's license, version, tag, dependencies and module inventory.
function M.inspect_spec(spec, source_root, expected_dependencies, lua, opts, rock_version)
    rock_version = rock_version or "scm-1"
    local source_version = release.identity(release.candidate(ROOT))
    local tag = rock_version == "scm-1" and "" or "v" .. source_version
    local output =
        run_source(lua, INSPECT, { spec, rock_version, tag, "git+" .. release.REPOSITORY }, opts)
    local dependencies, modules = {}, {}
    for _, line in ipairs(lines_of(output)) do
        local kind, first, second = line:match("^(%a+)\t([^\t]*)\t?(.*)$")
        if kind == "dependency" then
            dependencies[first] = true
        elseif kind == "module" then
            modules[second] = true
        end
    end
    for name in pairs(dependencies) do
        if not expected_dependencies[name] then
            refuse(spec:match("[^/]+$") .. ": unexpected dependencies")
        end
    end
    for name in pairs(expected_dependencies) do
        if not dependencies[name] then
            refuse(spec:match("[^/]+$") .. ": unexpected dependencies")
        end
    end
    for _, relative in ipairs(fs.walk(ROOT .. "/" .. source_root)) do
        if relative:match("%.lua$") and not modules[source_root .. "/" .. relative] then
            refuse(
                spec:match("[^/]+$")
                    .. ": module inventory differs: "
                    .. source_root
                    .. "/"
                    .. relative
            )
        end
    end
    local discovered = {}
    for _, relative in ipairs(fs.walk(ROOT .. "/" .. source_root)) do
        if relative:match("%.lua$") then
            discovered[source_root .. "/" .. relative] = true
        end
    end
    for path in pairs(modules) do
        if not discovered[path] then
            refuse(spec:match("[^/]+$") .. ": module inventory differs: " .. path)
        end
    end
end

local function rock_directory(prefix, version, name, rock_version)
    return ("%s/lib/luarocks/rocks-%s/%s/%s"):format(prefix, version, name, rock_version)
end

function M.inspect_installed_license(name, prefix, version, rock_version)
    rock_version = rock_version or "scm-1"
    local rock = rock_directory(prefix, version, name, rock_version)
    local spec_name = ("%s-%s.rockspec"):format(name, rock_version)
    if files.read(rock .. "/" .. spec_name) ~= files.read(ROOT .. "/rockspecs/" .. spec_name) then
        refuse(name .. ": installed rockspec differs from its source metadata")
    end
    if files.read(rock .. "/doc/LICENSE") ~= files.read(ROOT .. "/LICENSE") then
        refuse(name .. ": installed license differs from the project MIT license")
    end
end

--- Requires the installed changelog to match `expected`, by default the checkout's.
function M.inspect_installed_changelog(name, prefix, version, rock_version, expected)
    rock_version = rock_version or "scm-1"
    local installed = rock_directory(prefix, version, name, rock_version)
        .. "/"
        .. M.INSTALLED_CHANGELOGS[name]
    expected = expected or files.read(ROOT .. "/" .. release.CHANGELOGS[name])
    if not fs.is_file(installed) or files.read(installed) ~= expected then
        refuse(
            ("%s: installed %s differs from %s"):format(
                name,
                M.INSTALLED_CHANGELOGS[name],
                release.CHANGELOGS[name]
            )
        )
    end
end

local function installed_paths(prefix, version)
    return {
        LUA_PATH = ("%s/share/lua/%s/?.lua;%s/share/lua/%s/?/init.lua"):format(
            prefix,
            version,
            prefix,
            version
        ),
        LUA_CPATH = ("%s/lib/lua/%s/?.so"):format(prefix, version),
    }
end

local function with_env(opts, extra)
    local env = {}
    for name, value in pairs(opts.env or {}) do
        env[name] = value
    end
    for name, value in pairs(extra) do
        env[name] = value
    end
    return { cwd = opts.cwd, env = env, unset = opts.unset }
end

--- Imports the installed rock from outside the checkout and, for the core, runs the pure query
--- example with every external I/O call refused.
function M.import_installed(name, prefix, version, lua, opts)
    local child = with_env(opts, installed_paths(prefix, version))
    local source = 'local tests = dofile("imports.lua")\n'
        .. "tests.test_core_and_query_import_without_effects()\n"
        .. 'local core = require("libtmux")\n'
    local source_version = release.identity(release.candidate(ROOT))
    source = source
        .. ('assert(core._VERSION == "%s", "installed source version mismatch")\n'):format(
            source_version
        )
    if name == "libtmux" then
        source = source
            .. 'for _, dep in ipairs({"luv", "lunajson"}) do\n'
            .. '    assert(not pcall(require, dep), "core-only install includes " .. dep)\nend\n'
    end
    run_source(lua, source, {}, child)
    if name == "libtmux" then
        local output = run_source(
            lua,
            'local function forbidden() error("pure example attempted external I/O") end\n'
                .. "io.open, io.popen, os.execute = forbidden, forbidden, forbidden\n"
                .. 'dofile("native_query.lua")\n',
            {},
            child
        )
        if output ~= "%1\tnvim\n%3\tvim\n" then
            refuse("installed native-query example returned unexpected output")
        end
    end
end

--- Runs the installed snapshot and quickstart examples, each on a private server of its own.
function M.live_example(prefix, version, lua, opts)
    local temporary = fs.mkdtemp("libtmux-lua-live-")
    local binary = M.tmux_binary()
    local child = with_env(opts, installed_paths(prefix, version))
    child.env.TMPDIR = temporary
    child.env.LIBTMUX_TEST_TMUX = binary
    child.env.TMUX_BIN = binary
    local ok, failure = pcall(function()
        local snapshot = run({ lua, "snapshot.lua" }, child)
        if snapshot ~= "%0\t@0\n" then
            refuse("installed snapshot example returned unexpected output")
        end
        local quickstart = run({ lua, "quickstart.lua" }, child)
        if not quickstart:match("^%$%d+\t@%d+\t%%%d+\n$") then
            refuse(("installed quickstart returned unexpected output: %q"):format(quickstart))
        end
        if #fs.list(temporary) > 0 then
            refuse("installed examples left a private server directory")
        end
    end)
    fs.remove_tree(temporary)
    if not ok then
        error(failure, 0)
    end
    print("PASS installed public snapshot/quickstart examples and private-server cleanup")
end

--- The (major, minor) release a tmux executable reports, such as 3, 7 for 3.7c.
function M.tmux_release(binary)
    local banner = run({ binary, "-V" })
    local major, minor = banner:match("(%d+)%.(%d+)")
    if not major then
        refuse(("cannot read the release from %q"):format(banner))
    end
    return tonumber(major), tonumber(minor)
end

--- Runs every complete API program against the installed rock, then a failing import and a
--- failing runtime to prove a failure propagates and leaves no server behind.
function M.complete_api_examples(prefix, version, lua, cwd, opts)
    local manifest = api_examples.load_examples(ROOT)
    local directory = cwd .. "/complete-api-examples"
    fs.mkdir_p(directory)
    -- Each program starts a private server under TMPDIR; its directory and socket alias must fit
    -- sun_path.
    local temporary = fs.mkdtemp("libtmux-lua-api-check-")
    local binary = M.tmux_binary()
    local child = with_env(opts, installed_paths(prefix, version))
    child.cwd = directory
    child.env.TMPDIR = temporary
    child.env.LIBTMUX_TEST_TMUX = binary
    child.env.TMUX_BIN = binary
    local major, minor = M.tmux_release(binary)
    local ran = 0
    local ok, failure = pcall(function()
        for _, example in ipairs(manifest.examples) do
            local needed = example.min_tmux
            local need_major, need_minor
            if needed then
                need_major, need_minor = needed:match("^(%d+)%.(%d+)$")
            end
            if
                needed
                and (
                    major < tonumber(need_major)
                    or (major == tonumber(need_major) and minor < tonumber(need_minor))
                )
            then
                print(
                    ("SKIP %s: needs tmux %s, found %d.%d"):format(example.id, needed, major, minor)
                )
            else
                ran = ran + 1
                local program = directory .. "/" .. example.file:match("[^/]+$")
                files.write(program, files.read(ROOT .. "/" .. example.file))
                local output = run({ lua, program }, child)
                if output ~= example.stdout then
                    refuse(
                        ("%s: complete example output differs: %q"):format(
                            example.file:match("[^/]+$"),
                            output
                        )
                    )
                end
                if #fs.list(temporary) > 0 then
                    refuse(
                        example.file:match("[^/]+$") .. ": complete example left a server directory"
                    )
                end
            end
        end
        -- The runtime failure comes after the server started, so it proves the cleanup.
        local connect = files.read(directory .. "/connect.lua")
        local failures = {
            {
                "import",
                'require("libtmux_example_missing_module")\n',
                "libtmux_example_missing_module",
            },
            {
                "runtime",
                (connect:gsub(
                    '    print%("connected"%)',
                    '    error("intentional example failure", 0)'
                )),
                "intentional example failure",
            },
        }
        for _, case in ipairs(failures) do
            local program = directory .. "/failure-" .. case[1] .. ".lua"
            files.write(program, case[2])
            local code, output = shell.run({ lua, program }, child)
            if code == 0 or not output:find(case[3], 1, true) then
                refuse(case[1] .. ": example failure did not propagate")
            end
            if #fs.list(temporary) > 0 then
                refuse(case[1] .. ": failing example left a server directory")
            end
        end
    end)
    fs.remove_tree(temporary)
    if not ok then
        error(failure, 0)
    end
    print(("PASS %d complete API programs and import/runtime failure cleanup"):format(ran))
end

--- Whether the checkout's Lua sources or license differ from `tag`.
---@param tag string
---@param root? string
---@return boolean
function M.drifted_from(tag, root)
    local argv = { "git", "diff", "--quiet", tag, "--" }
    for _, path in ipairs(M.SOURCE_PATHS) do
        argv[#argv + 1] = path
    end
    return shell.run(argv, { cwd = root or ROOT }) ~= 0
end

local function unzip_entry(artifact, name)
    return run({ "unzip", "-p", artifact, name })
end

--- Packs the committed spec, using an isolated source tree before the public tag exists.
function M.source_rock(spec, work, rocks, public_tag, opts)
    local packing = work .. "/source-rock"
    fs.mkdir_p(packing)
    local pack_env = {}
    if not public_tag then
        local repository = work .. "/source-repository"
        fs.mkdir_p(repository)
        local candidate = release.candidate(ROOT)
        local source_version, revision = release.identity(candidate)
        local source_tag = "v" .. source_version
        local tagged = shell.run(
            { "git", "rev-parse", "--verify", "refs/tags/" .. source_tag },
            { cwd = ROOT }
        ) == 0
        -- Once a Lua source file or the license changes after its release tag, the tag can no
        -- longer stand in for the checkout; the local fixture is packed instead. A release still
        -- needs the public tag, so the drift cannot be published.
        local drifted = tagged and M.drifted_from(source_tag)
        if tagged and not drifted then
            local archive = work .. "/source-tag.tar"
            run(
                { "git", "archive", "--format=tar", "--output=" .. archive, source_tag },
                { cwd = ROOT }
            )
            run({ "tar", "-x", "-C", repository, "-f", archive })
        elseif revision > 1 then
            local drift = "a packaging revision ships "
                .. source_tag
                .. "'s source, but lua/ or LICENSE differs"
            refuse(
                drifted and drift
                    or "fetch the original source tag before checking a packaging revision"
            )
        else
            local listing = run(
                { "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
                { cwd = ROOT }
            )
            for filename in listing:gmatch("([^%z]+)") do
                if fs.is_file(ROOT .. "/" .. filename) then
                    fs.mkdir_p((repository .. "/" .. filename):match("^(.*)/[^/]+$"))
                    run({ "cp", "-pP", ROOT .. "/" .. filename, repository .. "/" .. filename })
                end
            end
        end
        local git = { cwd = repository, unset = opts.unset }
        run({ "git", "init", "-q" }, git)
        run({ "git", "add", "." }, git)
        run({
            "git",
            "-c",
            "user.name=Release fixture",
            "-c",
            "user.email=release@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "Candidate source",
        }, git)
        run({ "git", "tag", "v" .. release.identity(candidate) }, git)
        pack_env = {
            GIT_CONFIG_NOSYSTEM = "1",
            GIT_CONFIG_GLOBAL = "/dev/null",
            GIT_CONFIG_COUNT = "1",
            GIT_ALLOW_PROTOCOL = "file",
            GIT_CONFIG_KEY_0 = "url.file://" .. repository .. ".insteadOf",
            GIT_CONFIG_VALUE_0 = release.REPOSITORY,
        }
    end
    rocks({ "--tree=" .. packing .. "/tree", "pack", spec }, { cwd = packing, env = pack_env })
    local artifact = packing .. "/" .. spec:match("[^/]+$"):gsub("%.rockspec$", ".src.rock")
    if unzip_entry(artifact, spec:match("[^/]+$")) ~= files.read(spec) then
        refuse("source rock embeds a different release rockspec")
    end
    local names, expected = {}, {}
    for line in run({ "unzip", "-Z1", artifact }):gmatch("[^\n]+") do
        names[line] = true
    end
    local actual = {}
    for name in pairs(names) do
        if name:sub(1, 16) == "libtmux-lua/lua/" and name:match("%.lua$") then
            actual[name] = true
        end
    end
    for _, relative in ipairs(fs.walk(ROOT .. "/lua")) do
        if relative:match("%.lua$") then
            expected["libtmux-lua/lua/" .. relative] = ROOT .. "/lua/" .. relative
        end
    end
    for name in pairs(actual) do
        if not expected[name] then
            refuse("source rock Lua module inventory differs from the tested checkout")
        end
    end
    for name in pairs(expected) do
        if not actual[name] then
            refuse("source rock Lua module inventory differs from the tested checkout")
        end
    end
    expected["libtmux-lua/LICENSE"] = ROOT .. "/LICENSE"
    -- A packaging revision packs the original source tag, whose notes are the ones that release
    -- was tagged with, so only the file's presence is held.
    if not names["libtmux-lua/CHANGES.md"] then
        refuse("source rock carries no CHANGES.md")
    end
    for name, path in pairs(expected) do
        if unzip_entry(artifact, name) ~= files.read(path) then
            refuse("source rock differs from the tested checkout: " .. name)
        end
    end
    return artifact
end

local function check_release(work, rocks, lua, rt, cache, output, public_tag, opts)
    local rock_version = release.candidate(ROOT)
    release.prepare(ROOT, rock_version, true)
    local spec = ROOT .. "/rockspecs/libtmux-" .. rock_version .. ".rockspec"
    M.inspect_spec(spec, "lua", { lua = true }, lua, with_env(opts, {}), rock_version)
    rocks({ "--tree=" .. work .. "/lint-tree", "lint", spec }, { cwd = work })
    local artifact = M.source_rock(spec, work, rocks, public_tag, opts)
    local prefix = work .. "/installed-release"
    rocks({ "--tree=" .. prefix, "install", "--deps-mode=one", artifact }, { cwd = work })
    if not M.only(M.installed(prefix, rocks), "libtmux") then
        refuse("core release includes unexpected dependencies")
    end
    M.inspect_installed_license("libtmux", prefix, rt.version, rock_version)
    -- The release is built from the source rock, which for a packaging revision is the original
    -- tag's, so the installed notes are held to that rock's copy of CHANGES.md.
    M.inspect_installed_changelog(
        "libtmux",
        prefix,
        rt.version,
        rock_version,
        unzip_entry(artifact, "libtmux-lua/CHANGES.md")
    )
    M.import_installed("libtmux", prefix, rt.version, lua, with_env(opts, {}))
    -- Add the explicit standalone adapter dependency only after proving the core boundary.
    rocks({ "--tree=" .. cache, "pack", "luv", M.DEPENDENCIES.luv }, { cwd = work })
    local luv = packed_rock(work, "luv-" .. M.DEPENDENCIES.luv .. ".")
    rocks({ "--tree=" .. prefix, "install", "--deps-mode=one", luv }, { cwd = work })
    M.live_example(prefix, rt.version, lua, opts)
    M.complete_api_examples(prefix, rt.version, lua, work, opts)
    if output then
        fs.mkdir_p(output)
        local spec_name = spec:match("[^/]+$")
        local artifact_name = artifact:match("[^/]+$")
        for _, name in ipairs({ spec_name, artifact_name, "SHA256SUMS", "candidate.json" }) do
            if fs.stat(output .. "/" .. name) then
                refuse("output already contains release artifacts; select an empty directory")
            end
        end
        run({ "cp", spec, output .. "/" .. spec_name })
        run({ "cp", artifact, output .. "/" .. artifact_name })
        local hashes = {
            [spec_name] = shell.sha256(output .. "/" .. spec_name),
            [artifact_name] = shell.sha256(output .. "/" .. artifact_name),
        }
        local order = { spec_name, artifact_name }
        local sums = {}
        for _, name in ipairs(order) do
            sums[#sums + 1] = hashes[name] .. "  " .. name .. "\n"
        end
        files.write(output .. "/SHA256SUMS", table.concat(sums))
        local head = run({ "git", "rev-parse", "HEAD" }, { cwd = ROOT }):match("%S+")
        local dirty = run({ "git", "status", "--porcelain" }, { cwd = ROOT }):find("%S") ~= nil
        local candidate = json.object(
            { "package", "version", "head", "dirty", "source", "artifacts" },
            {
                package = "libtmux",
                version = rock_version,
                head = head,
                dirty = dirty,
                source = public_tag and "public-tag" or "local-fixture",
                artifacts = json.object(order, hashes),
            }
        )
        files.write(output .. "/candidate.json", json.encode(candidate, 2) .. "\n")
    end
    print(
        ("PASS libtmux %s: source rock, isolated install, MIT, changelog, version, imports"):format(
            rock_version
        )
    )
end

--- Builds the development rock, installs it into its own tree and imports it from outside the
--- checkout.
function M.check_core(work, rocks, lua, version, opts)
    local spec = ROOT .. "/rockspecs/libtmux-scm-1.rockspec"
    M.inspect_spec(spec, "lua", { lua = true }, lua, with_env(opts, {}))
    local build = work .. "/build-libtmux"
    fs.mkdir_p(build)
    fs.copy_tree(ROOT .. "/lua", build .. "/lua")
    run({ "cp", spec, build .. "/" .. spec:match("[^/]+$") })
    run({ "cp", ROOT .. "/LICENSE", build .. "/LICENSE" })
    local changelog = release.CHANGELOGS.libtmux
    run({ "cp", ROOT .. "/" .. changelog, build .. "/" .. changelog })
    local build_prefix = work .. "/build-tree-libtmux"
    rocks(
        { "--tree=" .. build_prefix, "make", "--deps-mode=one", spec:match("[^/]+$") },
        { cwd = build }
    )
    rocks({ "--tree=" .. build_prefix, "pack", "libtmux", "scm-1" }, { cwd = build })
    local artifact = packed_rock(build, "libtmux-scm-1.")
    local prefix = work .. "/installed-libtmux"
    rocks({ "--tree=" .. prefix, "install", "--deps-mode=one", artifact }, { cwd = work })
    if not M.only(M.installed(prefix, rocks), "libtmux") then
        refuse("libtmux: installed closure differs from {'libtmux'}")
    end
    M.inspect_installed_license("libtmux", prefix, version)
    M.inspect_installed_changelog("libtmux", prefix, version)
    M.import_installed("libtmux", prefix, version, lua, with_env(opts, {}))
    print(
        "PASS libtmux: built artifact, isolated install, MIT license, changelog, imports, closure"
    )
end

---@class package.Options
---@field lua string
---@field luarocks string
---@field cache? string
---@field release boolean
---@field output? string
---@field public_tag boolean

---@param options package.Options
function M.main(options)
    local started = os.time()
    local rt = runtime.identify(options.lua)
    local lua = rt.executable
    local luarocks = runtime.executable_path(options.luarocks)
    local lua_dir = lua:match("^(.*)/bin/[^/]+$") or "."
    local version = rt.version
    local cache = options.cache or ROOT .. "/.cache/rocks/" .. rt.cache_label
    local work = fs.mkdtemp("libtmux-lua-packages-")
    local unset = { "LUA_INIT", "LUAROCKS_CONFIG" }
    for _, name in ipairs(runtime.LUA_VARIABLES) do
        unset[#unset + 1] = name
    end
    -- Empty servers make missing prerequisites fail locally instead of downloading.
    local config = work .. "/config.lua"
    files.write(config, "rocks_servers = {}\nrocks_trees = {}\n")
    local base_env = {
        LUAROCKS_CONFIG = config,
        ["LUAROCKS_CONFIG_" .. version:gsub("%.", "_")] = config,
    }
    local opts = { cwd = work, env = base_env, unset = unset }
    local function rocks(arguments, extra)
        local argv = { luarocks, "--lua-version=" .. version, "--lua-dir=" .. lua_dir }
        for _, value in ipairs(arguments) do
            argv[#argv + 1] = value
        end
        local env = {}
        for name, value in pairs(base_env) do
            env[name] = value
        end
        for name, value in pairs((extra or {}).env or {}) do
            env[name] = value
        end
        return run(argv, { cwd = (extra or {}).cwd, env = env, unset = unset })
    end
    local ok, failure = pcall(function()
        for _, row in ipairs({
            { "tests/unit/imports.lua", "imports.lua" },
            { "examples/native_query.lua", "native_query.lua" },
            { "examples/snapshot.lua", "snapshot.lua" },
            { "examples/quickstart.lua", "quickstart.lua" },
        }) do
            files.write(work .. "/" .. row[2], files.read(ROOT .. "/" .. row[1]))
        end
        if not options.release then
            M.check_core(work, rocks, lua, version, opts)
        end
        check_release(work, rocks, lua, rt, cache, options.output, options.public_tag, opts)
    end)
    fs.remove_tree(work)
    if not ok then
        error(failure, 0)
    end
    print(("PASS package checks: Lua %s, %ds"):format(version, os.time() - started))
end

return M
