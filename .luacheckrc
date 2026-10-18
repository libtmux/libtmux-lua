std = "lua51"
max_line_length = 100
files["tests/run.lua"] = { globals = { "arg" } }
files["examples/nvim_snapshot.lua"] = { read_globals = { "vim" } }
