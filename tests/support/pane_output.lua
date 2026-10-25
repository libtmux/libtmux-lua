local M = {}

local function must(value, err)
    if value == nil or value == false then
        error(tostring(err), 0)
    end
    return value
end

-- Waits poll the pane's visible text, which every supported release offers.
function M.open(pane)
    local output = {}
    -- `visible` names the printable part of a marker that ends in escape bytes.
    function output.until_text(marker, visible)
        return must(pane:wait_for_text(visible or marker, { timeout = 5000 }):await()).text
    end
    function output.close() end
    return output
end

return M
