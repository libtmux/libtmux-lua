local parser = require("libtmux._internal.control_parser")
local capture = io.read("*a")
local expected = "\000\001\n\r\\\255DONE"

for _, width in ipairs({ 1, 17, #capture }) do
    local decoder = assert(parser.new({ bootstrap = true }))
    local events = {}
    for start = 1, #capture, width do
        local batch, err = decoder:feed(capture:sub(start, start + width - 1))
        assert(not err, tostring(err))
        for _, event in ipairs(batch) do
            events[#events + 1] = event
        end
    end
    local eof, err = decoder:finish()
    assert(not err and eof[1].kind == "eof", tostring(err))
    assert(events[1].kind == "block" and events[1].phase == "bootstrap")
    local body_seen, mode_seen, wait_seen, exit_seen = false, false, false, false
    local ordinary, extended = "", ""
    for _, event in ipairs(events) do
        if event.kind == "block" and event.body:find("BODY_END", 1, true) then
            assert(
                event.body == "%output %0 body\n%begin 1 2 3\n%end 1 2 3\nBODY_END\n",
                string.format("unexpected body %q", event.body)
            )
            body_seen = true
        elseif event.kind == "block" and event.body == "WAIT_DONE\n" then
            wait_seen = true
        elseif event.name == "pane-mode-changed" then
            mode_seen = true
        elseif event.name == "output" then
            ordinary = ordinary .. event.data
        elseif event.name == "extended-output" then
            assert(event.age:match("^[0-9]+$") and event.metadata == "")
            extended = extended .. event.data
        elseif event.name == "exit" then
            exit_seen = true
        end
    end
    assert(body_seen and mode_seen and wait_seen and exit_seen)
    assert(ordinary:find("PLAIN" .. expected, 1, true), "ordinary output bytes differ")
    assert(extended:find("EXTENDED" .. expected, 1, true), "extended output bytes differ")
    assert(decoder:stats().retained_bytes == 0)
end

io.stdout:write("control parser capture passed\n")
