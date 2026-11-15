-- Directory work the scripts share, on luv: listing, walking, creating and removing trees.
local uv = require("support.uv")

local M = {}

---@param path string
---@return table? stat
function M.stat(path)
    return uv.fs_stat(path)
end

---@param path string
---@return boolean
function M.is_file(path)
    local stat = uv.fs_stat(path)
    return stat ~= nil and stat.type == "file"
end

---@param path string
---@return boolean
function M.is_directory(path)
    local stat = uv.fs_stat(path)
    return stat ~= nil and stat.type == "directory"
end

---@param path string
---@return boolean
function M.is_symlink(path)
    local stat = uv.fs_lstat(path)
    return stat ~= nil and stat.type == "link"
end

--- The names in a directory, sorted.
---@param path string
---@return string[]
function M.list(path)
    local names = {}
    local scan = uv.fs_scandir(path)
    while scan do
        local name = uv.fs_scandir_next(scan)
        if not name then
            break
        end
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

--- Every file under a directory, as paths relative to it, sorted. Symlinks are not followed.
---@param root string
---@return string[]
function M.walk(root)
    local found = {}
    local function visit(relative)
        for _, name in ipairs(M.list(relative == "" and root or root .. "/" .. relative)) do
            local child = relative == "" and name or relative .. "/" .. name
            local stat = uv.fs_lstat(root .. "/" .. child)
            if stat and stat.type == "directory" then
                visit(child)
            elseif stat then
                found[#found + 1] = child
            end
        end
    end
    visit("")
    table.sort(found)
    return found
end

--- Creates a directory and its parents.
---@param path string
function M.mkdir_p(path)
    local built = path:sub(1, 1) == "/" and "" or "."
    for part in path:gmatch("[^/]+") do
        built = built .. "/" .. part
        local made, failure = uv.fs_mkdir(built, 448)
        if not made and not M.is_directory(built) then
            error("cannot create " .. built .. ": " .. tostring(failure), 0)
        end
    end
end

---@param path string
function M.remove_tree(path)
    if M.stat(path) == nil and not M.is_symlink(path) then
        return
    end
    if M.is_directory(path) and not M.is_symlink(path) then
        for _, name in ipairs(M.list(path)) do
            M.remove_tree(path .. "/" .. name)
        end
        assert(uv.fs_rmdir(path))
    else
        assert(uv.fs_unlink(path))
    end
end

--- Copies a directory tree: files are copied byte for byte, modes are kept.
---@param source string
---@param destination string
function M.copy_tree(source, destination)
    M.mkdir_p(destination)
    for _, name in ipairs(M.list(source)) do
        local from, to = source .. "/" .. name, destination .. "/" .. name
        if M.is_directory(from) then
            M.copy_tree(from, to)
        else
            assert(uv.fs_copyfile(from, to))
        end
    end
end

--- A new private directory under `parent`, named from `prefix`.
---@param prefix string
---@param parent? string
---@return string
function M.mkdtemp(prefix, parent)
    return assert(uv.fs_mkdtemp((parent or "/tmp") .. "/" .. prefix .. "XXXXXX"))
end

return M
