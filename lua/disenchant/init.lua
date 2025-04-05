local M = {}

function M.find_project_root()
  local markers = {'.git', 'Makefile', 'compile_commands.json'}
  local path = vim.fn.expand('%:p:h')
  local root = path
  while root ~= '/' do
    for _, marker in ipairs(markers) do
      local marker_path = root .. '/' .. marker
      if vim.fn.filereadable(marker_path) == 1 or vim.fn.isdirectory(marker_path) == 1 then
        return root
      end
    end
    root = vim.fn.fnamemodify(root, ':h')
  end
  return path
end

function M.run_objdump_on_object_file()
    local current_file = vim.api.nvim_buf_get_name(0)
    if not current_file or current_file == "" then
        print("NO FILE IS CURRENTLY OPEN")
        return
    end

    -- file name without extension
    local file_name = vim.fn.fnamemodify(current_file, ":t:r")
    local file_path = vim.fn.expand('%:p')
    local project_root = M.find_project_root()
    -- local has_makefile = vim.fn.filereadable(project_root .. '/Makefile') == 1
    local compile_cmd
    -- if has_makefile then
    --     compile_cmd = string.format('cd %s && make %s.o', project_root, file_name)
    -- else
    compile_cmd = string.format('cd %s && gcc -g3 -c %s -o %s.o', project_root, file_path, file_name)
    -- end

    local compile_result = vim.fn.system(compile_cmd)
    if vim.v.shell_error ~= 0 then
        print("COMPILATION FAILED: " .. compile_result)
        return
    end

    local objdump_cmd = string.format('cd %s && objdump -d -Sl --source-comment --no-show-raw-insn %s.o', project_root, file_name)
    local objdump_result = vim.fn.system(objdump_cmd)

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.fn.bufname(buf) == "disenchant-" .. file_name then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end

    vim.cmd("vnew")
    local buf = vim.api.nvim_get_current_buf()

    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    vim.api.nvim_buf_set_name(buf, "disenchant-" .. file_name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(objdump_result, '\n'))
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

vim.keymap.set('n', '<Leader>of', function() require('disenchant').run_objdump_on_object_file() end, { desc = "DISASSEMBLE" })

return M
