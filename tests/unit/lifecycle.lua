local luaunit = require("luaunit")
local lifecycle = require("libtmux._internal.lifecycle")
local M = {}

local function row(token)
    return "LQ1\r$a;123;456;" .. (token or string.rep("a", 32)) .. ";\\$1;@2;\\%3;0;.\n"
end

function M.test_receipt_requires_one_complete_identity()
    local generation = {}
    local receipt = assert(lifecycle.parse({ stdout = row() }, "session", "$1", generation))
    luaunit.assertEquals(receipt.id, "$1")
    luaunit.assertIs(receipt.generation, generation)
    for _, output in ipairs({
        "",
        row() .. row(),
        row():sub(1, -2),
        row(""),
        row("bad"),
        row() .. "garbage\n",
    }) do
        local value, err = lifecycle.parse({ stdout = output }, "session", "$1", generation)
        luaunit.assertNil(value)
        luaunit.assertEquals(assert(err).code, "invalid_receipt")
    end
    luaunit.assertNil(lifecycle.parse({ stdout = row() }, "session", "$9", generation))
end

function M.test_randomness_failure_does_not_fall_back_to_time_or_pid()
    local value, err = lifecycle.nonce({
        random = function()
            return nil, "unavailable"
        end,
    })
    luaunit.assertNil(value)
    luaunit.assertEquals(assert(err).code, "unsupported")
end

return M
