local M = {}

local default_config = {
  keymap = { disassemble = "<leader>od", }
}

local action_funcs = { disassemble = function() M.run_objdump_on_object_file() end, }
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

  for action_name, default_keybind in pairs(default_config.keymap) do
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
    vim.cmd("vnew")
    local asm_buf = vim.api.nvim_get_current_buf()
    local asm_win = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_option(asm_buf, "modifiable", true)
    vim.api.nvim_buf_set_option(asm_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_name(asm_buf, "disenchant-" .. file_name)
    vim.api.nvim_buf_set_lines(asm_buf, 0, -1, false, vim.split(objdump_result, '\n'))
    vim.api.nvim_buf_set_option(asm_buf, "modifiable", false)
    return asm_buf, asm_win
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
    asm_buf, asm_win = M.create_asm_buf(current_file, objdump_result)


        end
    end

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
