-- luacheck: globals vim
-- Run the Neovim example program and leave once it has reported.
local watchdog = (vim.uv or vim.loop).new_timer()
watchdog:start(700, 0, function()
    vim.schedule(function()
        io.stderr:write("Neovim example did not report\n")
        vim.cmd("cquit 1")
    end)
end)
vim.notify = function(message, level)
    io.stdout:write(message, "\n")
    vim.schedule(function()
        vim.cmd(level == vim.log.levels.ERROR and "cquit 1" or "qall!")
    end)
end
dofile("examples/nvim_snapshot.lua")
