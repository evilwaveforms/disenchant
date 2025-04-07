-- Compile current source file to an object file, use objdump to display assembly of the object file,
-- attempt to navigate to same line of code in the assembly code.
local M = {}

local default_config = {
  keymap = { disassemble = "<leader>od", }
}

local action_funcs = { disassemble = function() M.disenchant() end, }
local action_descs = { disassemble = "disenchant: DISASSEMBLE OBJECT FILE", }
local config = vim.deepcopy(default_config)

local function deep_extend(target, source)
  for k, v in pairs(source) do
    if type(v) == "table" and type(target[k]) == "table" then
      deep_extend(target[k], v)
    else
      target[k] = v
    end
  end
  return target
end

function M.setup(opts)
  opts = opts or {}
  if vim.tbl_deep_extend then
     config = vim.tbl_deep_extend('force', config, opts)
  else
     config = deep_extend(config, opts)
  end

  for action_name, _ in pairs(default_config.keymap) do
    local keybind_to_set = config.keymap and config.keymap[action_name]
    if type(keybind_to_set) == "string" and keybind_to_set ~= "" then
      local func = action_funcs[action_name]
      local desc = action_descs[action_name] or ("disenchant: " .. action_name)
      if func then
        vim.keymap.set('n', keybind_to_set, func, { desc = desc, silent = true })
      end
    end
  end
end

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

function M.create_asm_buf(file_name, objdump_result)
    -- Delete if already exists.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.fn.bufname(buf) == "disenchant-" .. file_name then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end
    vim.cmd("rightbelow vnew")
    local asm_buf_num = vim.api.nvim_get_current_buf()
    local asm_win = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_option(asm_buf_num, "modifiable", true)
    vim.api.nvim_buf_set_option(asm_buf_num,  "buftype", "nofile")
    vim.api.nvim_buf_set_name(asm_buf_num, "disenchant-" .. file_name)
    vim.api.nvim_buf_set_lines(asm_buf_num, 0, -1, false, vim.split(objdump_result, '\n'))
    vim.api.nvim_buf_set_option(asm_buf_num, "modifiable", false)
    return asm_buf_num, asm_win
end

function M.search_target_line(current_file, current_line_nr, asm_buf)
    local target_line = 1
    --  Pattern for source line marker. e.g. /path/to/your/source.c:666
    local search_pattern = string.format('^%s:%d', vim.fn.escape(current_file, [[\]^$.*~]]), current_line_nr)
    local search_result = vim.fn.searchpos(search_pattern, 'nW')
    if search_result[1] > 0 then
        local instruction_pattern = '^\\s*[0-9a-fA-F]+:'
        local start_line_for_instr_search = search_result[1]
        local next_instr_line = vim.fn.search(instruction_pattern, 'nW', start_line_for_instr_search)
        if next_instr_line > 0 then
            target_line = next_instr_line
        else
            target_line = search_result[1] + 1
            local line_count = vim.api.nvim_buf_line_count(asm_buf)
            target_line = math.min(target_line, line_count)
        end
    end
    return target_line
end

function M.disenchant()
    local current_buf_num = vim.api.nvim_get_current_buf()
    local current_file_path = vim.api.nvim_buf_get_name(current_buf_num)
    if not current_file_path or current_file_path == "" then
        print("NO FILE IS CURRENTLY OPEN")
        return
    end

    -- file name without extension
    local file_name = vim.fn.fnamemodify(current_file_path, ":t:r")
    local file_path = vim.fn.expand('%:p')
    local project_root = M.find_project_root()
    local original_win = vim.api.nvim_get_current_win()
    local original_cursor_pos = vim.api.nvim_win_get_cursor(original_win)
    local current_line_nr = original_cursor_pos[1]
    local ft = vim.bo[current_buf_num].filetype

    local has_makefile = vim.fn.filereadable(project_root .. '/Makefile') == 1
    local compile_cmd
    if ft == 'c' or ft == 'cpp' then
        if has_makefile then
            compile_cmd = string.format('cd %s && make %s.o', project_root, file_name)
        else
            compile_cmd = string.format('cd %s && gcc -g3 -c %s -o %s.o', project_root, file_path, file_name)
        end
    else
        vim.notify("UNSUPPORTED FILETYPE: " .. ft, vim.log.levels.ERROR)
        return
    end

    local compile_result = vim.fn.system(compile_cmd)
    if vim.v.shell_error ~= 0 then
        print("COMPILATION FAILED: " .. compile_result)
        return
    end

    local objdump_cmd = string.format('cd %s && objdump -Sl --demangle -Mintel --source-comment --no-show-raw-insn -d %s.o', project_root, file_name)
    local objdump_result = vim.fn.system(objdump_cmd)
    local asm_buf_num, asm_win = M.create_asm_buf(file_name, objdump_result)
    local target_line = M.search_target_line(current_file_path, current_line_nr, asm_buf_num)

    vim.api.nvim_win_set_cursor(asm_win, {target_line, 1})
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

return M
