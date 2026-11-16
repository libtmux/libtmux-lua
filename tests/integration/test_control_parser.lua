-- Parse captured control bytes from one explicitly owned tmux server.
local test = require("luaunit")
local child = require("tests.support.child")
local fixture = require("tests.support.fixture")
local repo = require("support.repo")
local M = {}

local OUTPUT = repo.root .. "/tests/support/programs/output.lua"

local function contains(text, ...)
    for _, needle in ipairs({ ... }) do
        if not text:find(needle, 1, true) then
            return false
        end
    end
    return true
end

function M.test_live_guards_notifications_and_wait_continuation()
    fixture.with(function(f)
        local client = f:spawn({ "-C", "attach-session", "-t", "fixture" }, { stdin = "pipe" })
        local function command(value)
            client:write(value .. "\n")
        end
        local function until_seen(...)
            local needles = { ... }
            local seen = client:expect(function(fresh)
                return contains(fresh, unpack(needles))
            end, fixture.DEADLINE)
            test.assertTrue(seen, client:output())
        end
        local function boundary(marker)
            command('display-message -p "' .. marker .. '"')
            until_seen(marker .. "\n%end ")
        end
        boundary("PARSER_READY")
        command('display-message -p "%%output %%0 body\\n%%begin 1 2 3\\n%%end 1 2 3\\nBODY_END"')
        until_seen("BODY_END\n%end ")
        f:run("respawn-pane", "-k", "-t", "fixture:0.0", fixture.lua(), OUTPUT, "bytes", "PLAIN")
        until_seen("%output ", "DONE\n")
        command("refresh-client -f pause-after=5")
        until_seen("\n%end ")
        f:run("respawn-pane", "-k", "-t", "fixture:0.0", fixture.lua(), OUTPUT, "bytes", "EXTENDED")
        until_seen("%extended-output ", "DONE\n")
        -- An explicit pane target keeps job output routing stable across tmux versions.
        command('run-shell -t fixture:0.0 "printf PANE_ONLY"')
        boundary("WAIT_DONE")
        command("detach-client")
        test.assertTrue(client:wait(fixture.DEADLINE), client:output())
        test.assertEquals(client.code, 0)
        local result = child.run({ fixture.lua(), "tests/integration/control_parser.lua" }, {
            input = client:output(),
            cwd = repo.root,
            env = f.env,
            timeout = fixture.DEADLINE,
        })
        test.assertEquals(result.code, 0, result.stderr)
        test.assertStrContains(result.stdout, "control parser capture passed")
    end)
end

return M
