-- The documentation preview cleanup refuses a bad pull request number and runs the one command.
local test = require("luaunit")
local preview = require("docs.preview")

local M = {}

function M.test_the_command_removes_one_pull_requests_preview()
    test.assertEquals(
        preview.delete_command("site-bucket", "42"),
        { "aws", "s3", "rm", "s3://site-bucket/en/lua/pr-42/", "--recursive" }
    )
end

function M.test_a_number_that_is_not_digits_is_refused()
    for _, bad in ipairs({ "", "4a", "-1", "1/..", "1 2", "1\n" }) do
        test.assertErrorMsgContains(
            "pull request number must be numeric",
            preview.delete_command,
            "site-bucket",
            bad
        )
    end
    test.assertErrorMsgContains(
        "pull request number must be numeric",
        preview.delete_command,
        "site-bucket",
        nil
    )
end

function M.test_an_unset_bucket_is_refused()
    test.assertErrorMsgContains(
        "the documentation bucket is not set",
        preview.delete_command,
        "",
        "42"
    )
    test.assertErrorMsgContains(
        "the documentation bucket is not set",
        preview.delete_command,
        nil,
        "42"
    )
end

function M.test_delete_runs_the_command_and_reports_a_failure()
    local ran
    preview.delete("site-bucket", "7", function(argv)
        ran = argv
        return { code = 0 }
    end)
    test.assertEquals(ran[4], "s3://site-bucket/en/lua/pr-7/")
    test.assertErrorMsgContains("status 3", preview.delete, "site-bucket", "7", function()
        return { code = 3 }
    end)
end

function M.test_a_refused_number_runs_nothing()
    local ran = false
    pcall(preview.delete, "site-bucket", "x", function()
        ran = true
        return { code = 0 }
    end)
    test.assertFalse(ran)
end

return M
