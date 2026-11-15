-- Public creation preserves literal data and uses actual returned identities.
local test = require("luaunit")
local files = require("support.files")
local fixture = require("tests.support.fixture")
local fs = require("support.fs")
local repo = require("support.repo")
local M = {}

fixture.each_host(M, "create_window_and_split_with_literal_data", function(host)
    fixture.with(function(f)
        local directory = f.path .. "/literal#{pid}"
        fs.mkdir_p(directory)
        local report = f.path .. "/created.bin"
        local result = f:program(host, "domain", {
            LIBTMUX_CREATE_CWD = directory,
            LIBTMUX_CREATE_REPORT = report,
            LIBTMUX_CREATE_SCRIPT = repo.root .. "/tests/support/programs/created.lua",
        })
        test.assertStrContains(result.stdout, "public domain creation PASS")
        -- The working directory, the environment value and the one argument, as bytes.
        test.assertEquals(
            files.read(report),
            directory .. "\0#{pid};$(not-a-shell)\0literal;$(not-a-shell)\n#{pid}"
        )
        test.assertEquals(f:pins(), {})
        test.assertEquals(f:try("has-session", "-t", "$0").code, 0)
    end)
end)

return M
