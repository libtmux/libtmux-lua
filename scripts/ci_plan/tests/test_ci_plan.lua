-- Proves the CI plan picks what each event should run, and that it can fail.
--
-- Every rule has a check, and every check has a deliberate break: the rule is replaced with its
-- absence and the check has to notice. A check that passes with its rule removed would prove
-- nothing about the rule.
local C = require("ci_plan.tests.plan_checks")

local M = {}
for name, check in pairs(C.checks) do
    M["test_" .. name] = check
end

return M
