-- Compile current source file to an object file, use objdump to display assembly of the object file,
-- attempt to navigate to same line of code in the assembly code.
local M = {}

local default_config = {
  keymap = { disassemble = "<leader>od", },
  compile_command_c = "gcc -g3 -c %s -o %s",
  compile_command_cpp = "g++ -g3 -c %s -o %s",
  objdump_command = "objdump -Sl --demangle -Mintel --source-comment --no-show-raw-insn -d %s",
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
  config = deep_extend(config, opts)
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
  local markers = {"compile_commands.json", "Makefile", ".git"}
  local path = vim.fn.expand("%:p:h")
  local root = path
  while root ~= '/' do
    for _, marker in ipairs(markers) do
      local marker_path = root .. '/' .. marker
      if vim.fn.filereadable(marker_path) == 1 or vim.fn.isdirectory(marker_path) == 1 then
        return root
      end
    end
    root = vim.fn.fnamemodify(root, ":h")
  end
  return path
end

local function is_absolute_path(path)
  if not path then return false end
  if path:sub(1, 1) == '/' then return true end
  return false
end

local function shell_quote_arg(arg)
  if string.match(arg, "[^a-zA-Z0-9_@%+=:,./-]") then
    return "'" .. string.gsub(arg, "'", "'\\''") .. "'"
  else return arg end
end

function M.get_compile_info_from_json(project_root, current_file_path)
  local compile_commands_path = project_root .. "/compile_commands.json"
  if vim.fn.filereadable(compile_commands_path) == 0 then
    return nil
  end

  local content = table.concat(vim.fn.readfile(compile_commands_path), "\n")
  local ok, commands_data = pcall(vim.fn.json_decode, content)
  if not ok or type(commands_data) ~= "table" then
    vim.notify("FAILED TO PARSE compile_commands.json: " .. (commands_data or "DECODE ERROR"), vim.log.levels.WARN)
    return nil
  end
  local current_abs_path = vim.fn.simplify(current_file_path)

  for _, entry in ipairs(commands_data) do
    if not entry.file or not entry.directory then
      goto continue_loop
    end

    local entry_file = entry.file
    if not is_absolute_path(entry_file) then
      entry_file = vim.fn.simplify(entry.directory .. '/' .. entry.file)
    else
      entry_file = vim.fn.simplify(entry_file)
    end

    if entry_file == current_abs_path then
      local command_str = nil
      local directory = entry.directory
      local output_file_path = nil

      if entry.command and type(entry.command) == "string" then
        command_str = entry.command
      elseif entry.arguments and type(entry.arguments) == "table" then
        local args_quoted = {}
        for _, arg in ipairs(entry.arguments) do
          table.insert(args_quoted, shell_quote_arg(arg))
        end
        command_str = table.concat(args_quoted, " ")
      else
        vim.notify("SKIPPING ENTRY FOR " .. entry_file .. ": MISSING OR INVALID 'command'/'arguments' FIELD.", vim.log.levels.WARN)
        return nil
      end

      if entry.output and type(entry.output) == "string" then
        if not is_absolute_path(entry.output) then
          output_file_path = vim.fn.simplify(directory .. '/' .. entry.output)
        else output_file_path = vim.fn.simplify(entry.output) end
      else return nil end

      return {
        command = command_str,
        directory = directory,
        output_file = output_file_path,
      }
    end
    ::continue_loop::
  end
  vim.notify("NO ENTRY FOUND FOR " .. current_file_path .. " IN compile_commands.json", vim.log.levels.INFO)
  return nil
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
  vim.api.nvim_buf_set_option(asm_buf_num, "filetype", "objdump")
  vim.api.nvim_buf_set_option(asm_buf_num, "modifiable", false)
  return asm_buf_num, asm_win
end

function M.search_target_line(current_file, current_line_nr, asm_buf)
  local target_line = 1
  --  Pattern for source line marker. e.g. /path/to/your/source.c:666
  local search_pattern = string.format("^%s:%d", vim.fn.escape(current_file, [[\]^$.*~]]), current_line_nr)
  local search_result = vim.fn.searchpos(search_pattern, "nW")
  if search_result[1] > 0 then
    local instruction_pattern = "^\\s*[0-9a-fA-F]+:"
    local start_line_for_instr_search = search_result[1]
    local next_instr_line = vim.fn.search(instruction_pattern, "nW", start_line_for_instr_search)
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
    vim.notify("NO FILE IS CURRENTLY OPEN")
    return
  end

  -- file name without extension
  local file_name = vim.fn.fnamemodify(current_file_path, ":t:r")
  local project_root = M.find_project_root()
  local original_win = vim.api.nvim_get_current_win()
  local original_cursor_pos = vim.api.nvim_win_get_cursor(original_win)
  local current_line_nr = original_cursor_pos[1]
  local ft = vim.bo[current_buf_num].filetype
  local compile_cmd

  if ft ~= 'c' and ft ~= "cpp" then
    vim.notify("UNSUPPORTED FILETYPE: " .. ft, vim.log.levels.ERROR)
    return
  end

  local obj_file_path
  local cd_dir
  local compile_info = M.get_compile_info_from_json(project_root, current_file_path)

  if compile_info then
    compile_cmd = compile_info.command
    obj_file_path = compile_info.output_file
    cd_dir = compile_info.directory
  else
    local makefile_path = project_root .. "/Makefile"
    if vim.fn.filereadable(makefile_path) == 1 then
      local target_obj = file_name .. ".o"
      target_obj = vim.fn.shellescape(target_obj)
      compile_cmd = string.format("make %s", target_obj)
      obj_file_path = project_root .. '/' .. file_name .. ".o"
      cd_dir = project_root
    else
      local compile_commands = {
        c = config.compile_command_c,
        cpp = config.compile_command_cpp,
      }
      obj_file_path = project_root .. '/' .. file_name .. ".o"
      compile_cmd = string.format(compile_commands[ft], current_file_path, obj_file_path)
      cd_dir = project_root
    end
  end

  local compile_result = vim.fn.system(compile_cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("ERROR: COMPILATION FAILED: " .. compile_result)
    return
  end
  if not obj_file_path or type(obj_file_path) ~= "string" or obj_file_path == "" then
    vim.notify("ERROR: INVALID OBJECT FILE PATH BEFORE objdump. PATH: " .. vim.inspect(obj_file_path), vim.log.levels.ERROR)
    return
  end
  if vim.fn.filereadable(obj_file_path) == 0 then
    vim.notify("ERROR: OBJECT FILE MISSING BEFORE objdump: " .. obj_file_path, vim.log.levels.ERROR)
    return
  end

  local objdump_cmd = string.format(config.objdump_command, obj_file_path)
  local objdump_result = vim.fn.system(string.format("cd %s && %s", vim.fn.shellescape(cd_dir), objdump_cmd))
  local asm_buf_num, asm_win = M.create_asm_buf(file_name, objdump_result)
  local target_line = M.search_target_line(current_file_path, current_line_nr, asm_buf_num)
  vim.api.nvim_set_current_win(original_win)
  vim.api.nvim_win_set_cursor(asm_win, {target_line, 1})
end

return M
