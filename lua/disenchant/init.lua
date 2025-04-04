local M = {}

function M.run_objdump_on_object_file()
    local current_file = vim.api.nvim_buf_get_name(0)
    if not current_file or current_file == "" then
        print("No file is currently open.")
        return
    end

    -- file name without extension
    local base_name = vim.fn.fnamemodify(current_file, ":t:r")
    local buffer_dir = vim.fn.fnamemodify(current_file, ":p:h")
    local object_file_path = buffer_dir .. "/" .. base_name .. ".o"

    if vim.fn.filereadable(object_file_path) == 0 then
        print("Object file not found: " .. object_file_path)
        return
    end

    local objdump_cmd = string.format("objdump -d -M -Sl --no-show-raw-insn %s", object_file_path)
    local handle = io.popen(objdump_cmd)
    local result = handle:read("*a")
    handle:close()

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.fn.bufname(buf) == "disenchant-" .. base_name then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end

    vim.cmd("vnew")
    local buf = vim.api.nvim_get_current_buf()

    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    vim.api.nvim_buf_set_name(buf, "disenchant-" .. base_name)

    local lines = {}
    for line in result:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

function M.read_file(file_path)
    local f = io.open(file_path, "r")
    if not f then return nil end

    local lines = {}
    for line in f:lines() do
        table.insert(lines, line)
    end

    f:close()
    return lines
end

vim.keymap.set('n', '<Leader>op', function() require('disenchant').disenchant() end, { desc = "Open custom pane" })
vim.keymap.set('n', '<Leader>of', function() require('disenchant').run_objdump_on_object_file() end, { desc = "Open custom pane" })

return M
