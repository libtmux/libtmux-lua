-- Delete the documentation preview of a closed pull request from the site bucket.
local M = {}

--- Where the Lua previews live under the bucket, one directory per pull request.
M.PREFIX = "en/lua/pr-"

---@param message string
local function refuse(message)
    error(message, 0)
end

--- The `aws s3 rm` command that removes one pull request's preview.
---@param bucket? string
---@param number? string
---@return string[]
function M.delete_command(bucket, number)
    if type(number) ~= "string" or not number:match("^%d+$") then
        refuse("pull request number must be numeric")
    end
    if bucket == nil or bucket == "" then
        refuse("the documentation bucket is not set")
    end
    return { "aws", "s3", "rm", ("s3://%s/%s%s/"):format(bucket, M.PREFIX, number), "--recursive" }
end

---@param argv string[]
---@return support.RunResult
local function run_attached(argv)
    return require("support.proc").run(argv, { inherit = true })
end

--- Deletes the preview, refusing a bad number before anything runs.
---@param bucket? string
---@param number? string
---@param runner? fun(argv: string[]): support.RunResult
function M.delete(bucket, number, runner)
    local command = M.delete_command(bucket, number)
    local result = (runner or run_attached)(command)
    if result.code ~= 0 then
        refuse("aws s3 rm failed with status " .. result.code)
    end
end

return M
