-- Compile current source file to an object file, use objdump to display assembly of the object file,
-- attempt to navigate to same line of code in the assembly code.
local M = {}

local default_config = {
  keymap = { disassemble = "<leader>od", },
  compile_command_c = "gcc -g3 -c %s -o %s",
  compile_command_cpp = "g++ -g3 -c %s -o %s",
  compile_command_rust = "rustc -g --emit=obj %s -o %s",
  compile_command_rust_lib = "rustc -g --crate-type=lib --emit=obj %s -o %s",
  cargo_command = "cargo",
  cargo_args = {},
  objdump_command = "objdump -Sl --demangle -Mintel --source-comment --no-show-raw-insn -d %s",
}
local action_funcs = { disassemble = function() M.disenchant() end, }
local action_descs = { disassemble = "disenchant: DISASSEMBLE OBJECT FILE", }
local objdump_fallback_commands = {
  { "rust-objdump", "rust-objdump -Sl --demangle --no-show-raw-insn -d %s" },
  { "llvm-objdump", "llvm-objdump -Sl --demangle -Mintel --no-show-raw-insn -d %s" },
}
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
  local markers = {"compile_commands.json", "Cargo.toml", "Makefile", ".git"}
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

local function run_command(command, directory)
  if directory then
    command = string.format("cd %s && %s", shell_quote_arg(directory), command)
  end
  local result = vim.fn.system(command)
  return result, vim.v.shell_error
end

local function normalized_path(path)
  local realpath = (vim.uv or vim.loop).fs_realpath(path)
  return vim.fn.simplify(realpath or path)
end

local function find_file_upward(file_name, start_path)
  local directory = vim.fn.fnamemodify(start_path, ":p:h")
  while directory ~= "/" do
    local candidate = directory .. "/" .. file_name
    if vim.fn.filereadable(candidate) == 1 then
      return candidate
    end
    directory = vim.fn.fnamemodify(directory, ":h")
  end
  return nil
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

local function cargo_target_kind(target)
  local kind = target.kind and target.kind[1]
  if kind and (kind == "proc-macro" or kind:match("lib$")) then
    return "lib"
  end
  return kind
end

local function cargo_target_selector(target)
  local kind = cargo_target_kind(target)
  if kind == "lib" then
    return "--lib"
  end
  if kind == "bin" or kind == "example" or kind == "test" or kind == "bench" then
    return string.format("--%s %s", kind, shell_quote_arg(target.name))
  end
  return nil
end

local function relative_path(path, directory)
  local prefix = directory .. "/"
  if path:sub(1, #prefix) ~= prefix then
    return nil
  end
  return path:sub(#prefix + 1)
end

local function cargo_target_priority(target, current_path, package_source_directory, relative_source_path)
  local source_path = normalized_path(target.src_path)
  if current_path == source_path then
    return 0
  end

  local source_directory = vim.fn.fnamemodify(source_path, ":h")
  local source_stem = vim.fn.fnamemodify(source_path, ":t:r")
  local target_directory = source_stem == "main" and source_directory or source_directory .. "/" .. source_stem
  if target_directory ~= package_source_directory
      and relative_path(current_path, target_directory) then
    return 1
  end

  local kind = cargo_target_kind(target)
  local target_prefix = kind == "test" and "tests/"
      or kind == "example" and "examples/"
      or kind == "bench" and "benches/"
  if target_prefix and relative_source_path:match("^" .. target_prefix) then
    return 2
  end
  if kind == "bin" and relative_source_path:match("^src/bin/") then
    return 2
  end
  if kind == "lib" and relative_source_path:match("^src/") then
    return 3
  end
  if kind == "bin" and relative_source_path:match("^src/") then
    return 4
  end
  return 5
end

local function get_cargo_package(manifest_path, current_file_path)
  local manifest_directory = vim.fn.fnamemodify(manifest_path, ":h")
  local command = string.format(
    "%s metadata --quiet --format-version 1 --no-deps --manifest-path %s",
    config.cargo_command,
    shell_quote_arg(manifest_path)
  )
  local result, exit_code = run_command(command, manifest_directory)
  if exit_code ~= 0 then
    return nil, "CARGO METADATA FAILED: " .. result
  end

  local ok, metadata = pcall(vim.fn.json_decode, result)
  if not ok or type(metadata) ~= "table" then
    return nil, "FAILED TO PARSE CARGO METADATA: " .. (metadata or "DECODE ERROR")
  end

  local manifest = normalized_path(manifest_path)
  local current_path = normalized_path(current_file_path)
  for _, package in ipairs(metadata.packages or {}) do
    if normalized_path(package.manifest_path) == manifest then
      return package, nil
    end
  end
  for _, package in ipairs(metadata.packages or {}) do
    for _, target in ipairs(package.targets or {}) do
      if normalized_path(target.src_path) == current_path then
        return package, nil
      end
    end
  end
  return nil, "NO CARGO PACKAGE FOUND FOR " .. current_file_path
end

local function get_cargo_targets(package, current_file_path)
  local package_directory = normalized_path(vim.fn.fnamemodify(package.manifest_path, ":h"))
  local current_path = normalized_path(current_file_path)
  local source_path = relative_path(current_path, package_directory) or ""
  local targets = {}
  for _, target in ipairs(package.targets or {}) do
    if cargo_target_selector(target) then
      target._disenchant_priority = cargo_target_priority(
        target,
        current_path,
        package_directory .. "/src",
        source_path
      )
      table.insert(targets, target)
    end
  end
  table.sort(targets, function(left, right)
    if left._disenchant_priority == right._disenchant_priority then
      return left.name < right.name
    end
    return left._disenchant_priority < right._disenchant_priority
  end)
  return targets
end

local function run_objdump(objdump_command, obj_file_path, directory)
  local objdump_cmd = string.format(objdump_command, shell_quote_arg(obj_file_path))
  local result, exit_code = run_command(objdump_cmd, directory)
  if exit_code ~= 0 then
    return nil, "OBJDUMP FAILED: " .. result
  end
  return result, nil
end

local function objdump_object(obj_file_path, directory)
  local result, objdump_error = run_objdump(config.objdump_command, obj_file_path, directory)
  if result then
    return result, nil
  end

  local errors = { objdump_error }
  for _, fallback in ipairs(objdump_fallback_commands) do
    if vim.fn.executable(fallback[1]) == 1 then
      result, objdump_error = run_objdump(fallback[2], obj_file_path, directory)
      if result then
        return result, nil
      end
      table.insert(errors, objdump_error)
    end
  end
  return nil, table.concat(errors, "\n")
end

local function compile_and_objdump(command, directory, obj_file_path, dependency_file_path)
  local compile_result, exit_code = run_command(command, directory)
  if exit_code ~= 0 then
    vim.fn.delete(obj_file_path)
    if dependency_file_path then vim.fn.delete(dependency_file_path) end
    return nil, "COMPILATION FAILED: " .. compile_result
  end
  if vim.fn.filereadable(obj_file_path) == 0 then
    vim.fn.delete(obj_file_path)
    if dependency_file_path then vim.fn.delete(dependency_file_path) end
    return nil, "OBJECT FILE MISSING BEFORE objdump: " .. obj_file_path
  end

  local dependency_info
  if dependency_file_path and vim.fn.filereadable(dependency_file_path) == 1 then
    dependency_info = table.concat(vim.fn.readfile(dependency_file_path), "\n")
  end
  local objdump_result, objdump_error = objdump_object(obj_file_path, directory)
  vim.fn.delete(obj_file_path)
  if dependency_file_path then vim.fn.delete(dependency_file_path) end
  return objdump_result, objdump_error, dependency_info
end

local function dependency_info_contains_source(dependency_info, current_file_path, package_directory)
  if not dependency_info then
    return false
  end
  dependency_info = dependency_info:gsub("\\ ", " ")
  local current_path = normalized_path(current_file_path)
  if dependency_info:find(current_path, 1, true) then
    return true
  end
  local source_path = relative_path(current_path, normalized_path(package_directory))
  return source_path and dependency_info:find(source_path, 1, true) ~= nil
end

local function cargo_compile_command(manifest_path, package, target, obj_file_path, dependency_file_path)
  local parts = {
    config.cargo_command,
    "rustc",
    "--manifest-path",
    shell_quote_arg(manifest_path),
    "--package",
    shell_quote_arg(package.name),
  }
  for _, arg in ipairs(config.cargo_args or {}) do
    table.insert(parts, shell_quote_arg(arg))
  end
  local required_features = target["required-features"] or {}
  if #required_features > 0 then
    table.insert(parts, "--features")
    table.insert(parts, shell_quote_arg(table.concat(required_features, ",")))
  end
  table.insert(parts, cargo_target_selector(target))
  table.insert(parts, "--")
  table.insert(parts, "-g")
  table.insert(parts, "-Ccodegen-units=1")
  table.insert(parts, shell_quote_arg(
    "--emit=obj=" .. obj_file_path .. ",dep-info=" .. dependency_file_path
  ))
  return table.concat(parts, " ")
end

local function disassemble_standalone_rust(current_file_path)
  local commands = { config.compile_command_rust, config.compile_command_rust_lib }
  if vim.fn.fnamemodify(current_file_path, ":t") == "lib.rs" then
    commands = { config.compile_command_rust_lib, config.compile_command_rust }
  end

  local errors = {}
  for _, command_template in ipairs(commands) do
    local obj_file_path = vim.fn.tempname() .. ".o"
    local compile_cmd = string.format(
      command_template,
      shell_quote_arg(current_file_path),
      shell_quote_arg(obj_file_path)
    )
    local objdump_result, compile_error = compile_and_objdump(
      compile_cmd,
      vim.fn.fnamemodify(current_file_path, ":h"),
      obj_file_path
    )
    if objdump_result then
      return objdump_result, nil
    end
    table.insert(errors, compile_error)
  end
  return nil, table.concat(errors, "\n")
end

local function cargo_profile()
  local profile = "dev"
  local args = config.cargo_args or {}
  for index, arg in ipairs(args) do
    if arg == "--release" then
      profile = "release"
    elseif arg == "--profile" and args[index + 1] then
      profile = args[index + 1]
    else
      local named_profile = arg:match("^%-%-profile=(.+)$")
      if named_profile then
        profile = named_profile
      end
    end
  end
  return profile
end

local function disassemble_cargo_build_script(manifest_path, package, current_file_path)
  local package_directory = vim.fn.fnamemodify(package.manifest_path, ":h")
  local parts = {
    config.cargo_command,
    "build",
    "--manifest-path",
    shell_quote_arg(manifest_path),
    "--package",
    shell_quote_arg(package.name),
    "--config",
    shell_quote_arg("profile." .. cargo_profile() .. ".build-override.debug=2"),
  }
  for _, arg in ipairs(config.cargo_args or {}) do
    table.insert(parts, shell_quote_arg(arg))
  end
  table.insert(parts, "--message-format=json")

  local build_result, exit_code = run_command(table.concat(parts, " "), package_directory)
  if exit_code ~= 0 then
    return nil, "COMPILATION FAILED: " .. build_result
  end

  local artifact_path
  for line in build_result:gmatch("[^\r\n]+") do
    local ok, message = pcall(vim.fn.json_decode, line)
    if ok and message.reason == "compiler-artifact" and message.target then
      if normalized_path(message.target.src_path) == normalized_path(current_file_path) then
        for _, filename in ipairs(message.filenames or {}) do
          if vim.fn.filereadable(filename) == 1 then
            artifact_path = filename
            break
          end
        end
      end
    end
  end
  if not artifact_path then
    return nil, "CARGO DID NOT REPORT A BUILD SCRIPT ARTIFACT FOR " .. current_file_path
  end
  return objdump_object(artifact_path, package_directory)
end

local function disassemble_rust(current_file_path)
  local manifest_path = find_file_upward("Cargo.toml", current_file_path)
  if not manifest_path then
    return disassemble_standalone_rust(current_file_path)
  end

  local package, metadata_error = get_cargo_package(manifest_path, current_file_path)
  if metadata_error then
    return nil, metadata_error
  end
  for _, target in ipairs(package.targets or {}) do
    if cargo_target_kind(target) == "custom-build"
        and normalized_path(target.src_path) == normalized_path(current_file_path) then
      return disassemble_cargo_build_script(manifest_path, package, current_file_path)
    end
  end
  local targets = get_cargo_targets(package, current_file_path)
  if #targets == 0 then
    return nil, "NO SUPPORTED CARGO TARGET FOUND FOR " .. current_file_path
  end

  local package_directory = vim.fn.fnamemodify(package.manifest_path, ":h")
  local errors = {}
  local cargo_compile_failed = false
  for _, target in ipairs(targets) do
    local obj_file_path = vim.fn.tempname() .. ".o"
    local dependency_file_path = vim.fn.tempname() .. ".d"
    local compile_cmd = cargo_compile_command(
      manifest_path,
      package,
      target,
      obj_file_path,
      dependency_file_path
    )
    local objdump_result, compile_error, dependency_info = compile_and_objdump(
      compile_cmd,
      package_directory,
      obj_file_path,
      dependency_file_path
    )
    if objdump_result then
      if dependency_info_contains_source(dependency_info, current_file_path, package_directory) then
        return objdump_result, nil
      end
    else
      cargo_compile_failed = true
      table.insert(errors, target.name .. ": " .. compile_error)
    end
  end

  if cargo_compile_failed then
    return nil, table.concat(errors, "\n")
  end
  local standalone_result, standalone_error = disassemble_standalone_rust(current_file_path)
  if standalone_result then
    return standalone_result, nil
  end
  table.insert(errors, "standalone rustc: " .. standalone_error)
  return nil, "NO CARGO TARGET CONTAINS " .. current_file_path .. "\n" .. table.concat(errors, "\n")
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

function M.search_target_line(current_file, current_line_nr, asm_buf, source_line_text)
  local target_line = 1
  local found_line = 0
  -- Pattern for source line markers from GNU and LLVM objdump.
  local search_pattern = string.format(
    "^\\s*[;#]*\\s*%s:%d",
    vim.fn.escape(current_file, [[\]^$.*~]]),
    current_line_nr
  )
  local search_result = vim.fn.searchpos(search_pattern, "nW")
  if search_result[1] > 0 then
    found_line = search_result[1]
  elseif source_line_text and source_line_text ~= "" then
    -- As fallback, search for the actual source line text.
    local trimmed = source_line_text:match("^%s*(.-)%s*$")
    if trimmed and trimmed ~= "" then
      local escaped = vim.fn.escape(trimmed, [[\]^$.*~]])
      local text_result = vim.fn.searchpos(escaped, "nW")
      if text_result[1] > 0 then
        found_line = text_result[1]
      end
    end
  end

  if found_line > 0 then
    local instruction_pattern = "^%s*[0-9a-fA-F]+:"
    local line_count = vim.api.nvim_buf_line_count(asm_buf)
    local scan_start = found_line
    while scan_start < line_count do
      local scan_end = math.min(scan_start + 64, line_count)
      local lines = vim.api.nvim_buf_get_lines(asm_buf, scan_start, scan_end, false)
      for offset, line in ipairs(lines) do
        if line:match(instruction_pattern) then
          return scan_start + offset
        end
      end
      scan_start = scan_end
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

  if ft ~= "c" and ft ~= "cpp" and ft ~= "rust" then
    vim.notify("UNSUPPORTED FILETYPE: " .. ft, vim.log.levels.ERROR)
    return
  end

  local objdump_result
  if ft == "rust" then
    local rust_error
    objdump_result, rust_error = disassemble_rust(current_file_path)
    if rust_error then
      vim.notify("ERROR: " .. rust_error, vim.log.levels.ERROR)
      return
    end
  else
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
        obj_file_path = project_root .. '/build/' .. file_name .. ".o"
        cd_dir = project_root
      else
        local compile_commands = {
          c = config.compile_command_c,
          cpp = config.compile_command_cpp,
        }
        obj_file_path = project_root .. '/' .. file_name .. ".o"
        compile_cmd = string.format(
          compile_commands[ft],
          shell_quote_arg(current_file_path),
          shell_quote_arg(obj_file_path)
        )
        cd_dir = project_root
      end
    end

    local compile_result, compile_exit_code = run_command(compile_cmd, cd_dir)
    if compile_exit_code ~= 0 then
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

    local objdump_error
    objdump_result, objdump_error = objdump_object(obj_file_path, cd_dir)
    if objdump_error then
      vim.notify("ERROR: " .. objdump_error, vim.log.levels.ERROR)
      return
    end
  end
  local asm_buf_num, asm_win = M.create_asm_buf(file_name, objdump_result)
  local source_line_text = vim.api.nvim_buf_get_lines(current_buf_num, current_line_nr - 1, current_line_nr, false)[1]
  local target_line = M.search_target_line(current_file_path, current_line_nr, asm_buf_num, source_line_text)
  vim.api.nvim_set_current_win(original_win)
  vim.api.nvim_win_set_cursor(asm_win, {target_line, 1})
end

return M
