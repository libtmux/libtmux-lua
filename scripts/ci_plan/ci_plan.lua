-- Plan the CI jobs from the tmux catalog (data/tmux-options.json), data/ci-matrix.json and the
-- workflow event. The workflow names no tmux version; this decides what a run covers.
--
--   luajit scripts/ci_plan/ci_plan.lua plan --event EVENT [--scope SCOPE] [--tmux-ref REFS]
--       [--lua RUNTIMES] [--nvim VERSIONS] [--os IMAGE] [--tmate MODE]
--       [--github-output FILE] [--summary FILE]
--   luajit scripts/ci_plan/ci_plan.lua verify
--   luajit scripts/ci_plan/ci_plan.lua identity --lua PATH [--tmux PATH] [--client PATH]
--       [--nvim PATH]
--
-- `plan` prints the plan as JSON and appends the workflow outputs and the job summary to the
-- given files. `verify` reads the NEEDS environment variable and exits 1 unless the plan and
-- validate jobs both succeeded. `identity` prints the version of each tool a job ran with. Exit
-- status 1 means a refused plan or a failed command, 2 a usage error.
-- See README.md for the scopes and the matrix fields.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path
require("support.repo").use_rocks()
os.exit(require("ci_plan.cli").main({ ... }))
