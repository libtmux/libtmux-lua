local M = {}

function M.valid_utf8(value)
    if type(value) ~= "string" then
        return false
    end
    local index = 1
    while index <= #value do
        local byte = value:byte(index)
        local size = byte <= 127 and 1
            or byte >= 194 and byte <= 223 and 2
            or byte >= 224 and byte <= 239 and 3
            or byte >= 240 and byte <= 244 and 4
        if not size or index + size - 1 > #value then
            return false
        end
        for offset = 1, size - 1 do
            local next_byte = value:byte(index + offset)
            if next_byte < 128 or next_byte > 191 then
                return false
            end
        end
        local second = value:byte(index + 1)
        if
            size > 1
            and (
                byte == 224 and second < 160
                or byte == 237 and second > 159
                or byte == 240 and second < 144
                or byte == 244 and second > 143
            )
        then
            return false
        end
        index = index + size
    end
    return true
end

return M
