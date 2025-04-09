# disenchant

Inspired by emacs plugin [disaster](https://github.com/jart/disaster), disenchant lets you see
asm of the current c/c++ file.

It first attempts to compile the current code to an object file using Makefile in the root path of
the project. If no Makefile exists, gcc/g++ will be used instead. Afterwards, the object file is
passed to `objdump` to generate assembly code. The assembly code is then displayed in a new split
buffer.

## installation & configuration

### lazy.nvim

Values inside `opts` are defaults. If you don't want to change them, opts can be {}.

```lua
    {
        "evilwaveforms/disenchant",
        opts = {
            keymap = {
                disassemble = "<leader>om",
            },
            compile_command_c = 'cd %s && gcc -g3 -c %s -o %s.o',
            compile_command_cpp = 'cd %s && g++ -g3 -c %s -o %s.o',
            objdump_command = 'cd %s && objdump -Sl --demangle -Mintel --source-comment --no-show-raw-insn -d %s.o',
        },
    },
```
