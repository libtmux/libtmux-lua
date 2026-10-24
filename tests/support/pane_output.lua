local M = {}

local function must(value, err)
    if value == nil or value == false then
        error(tostring(err), 0)
    end
    return value
end

-- Control observation needs tmux 3.7. Older daemons poll the pane's visible
-- text through the process lane, which every supported release offers.
function M.open(server, session, pane)
    local version = must(server:command({ "display-message", "-p", "#{version}" }):await()).stdout
    local minor = tonumber(version:match("^3%.(%d+)")) or 0
    local id = assert(pane:reference()).id
    local output = {}
    if minor >= 7 then
        local observation = must(server:observe(session):await())
        local watch = must(observation:watch_pane(pane):await())
        local seen = ""
        function output.until_text(marker)
            while not seen:find(marker, 1, true) do
                seen = seen .. must(watch:next({ timeout = 750 }):await()).data
            end
            return seen
        end
        function output.close()
            must(watch:close():await())
            must(observation:close():await())
        end
        return output
    end
    -- `visible` names the printable part of a marker that ends in escape bytes.
    function output.until_text(marker, visible)
        marker = visible or marker
        for _ = 1, 2000 do
            local text =
                must(server:command({ "capture-pane", "-p", "-J", "-t", id }):await()).stdout
            if text:find(marker, 1, true) then
                return text
            end
        end
        error("pane output never contained " .. marker, 0)
    end
    function output.close() end
    return output
end

return M
