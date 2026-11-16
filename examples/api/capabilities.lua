local adapter = require("libtmux.runtime.luv")

local function must(value, err)
    if err ~= nil then
        error(tostring(err), 0)
    end
    return value
end

local binary = os.getenv("TMUX_BIN") or "/usr/bin/tmux"

must(adapter.run(function(runtime)
    local owned = must(runtime:start_server({ binary = binary }):await())
    local report = must(owned.server:capabilities():await())
    local deletion = assert(report.features["buffer-delete-named"])
    print("named deletion requires: " .. deletion.since)

    must(owned.server:set_buffer("demo", "kept until deletion is safe"):await())
    if deletion.supported then
        must(owned.server:delete_buffer("demo"):await())
    else
        local deleted, err = owned.server:delete_buffer("demo"):await()
        assert(deleted == nil and err.code == "unsupported" and err.effect == "not_sent")
    end
    print("daemon decision checked")

    must(owned:stop():await())
    return true
end))
