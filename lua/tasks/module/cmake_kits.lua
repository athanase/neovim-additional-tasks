local Path = require('plenary.path')
local utils = require('tasks.utils')
local cmake_utils = require('tasks.cmake_kits_utils')

-- based on https://github.com/Shatur/neovim-tasks/blob/master/lua/tasks/module/cmake.lua
-- but implemented with support for cmake kits

local function getKeys(tbl)
    local keys = {}
    for k, _ in pairs(tbl) do
        table.insert(keys, k)
    end
    return keys
end

local function getTargetNames()
    local build_dir = cmake_utils.getBuildDir()
    if not build_dir:is_dir() then
        utils.notify(string.format('Build directory "%s" does not exist, you need to run "configure" task first',
            build_dir), vim.log.levels.ERROR)
        return nil
    end

    local reply_dir = cmake_utils.getReplyDir(build_dir)
    local codemodel_targets = cmake_utils.getCodemodelTargets(reply_dir)
    if not codemodel_targets then
        return nil
    end

    local targets = {}
    for _, target in ipairs(codemodel_targets) do
        local target_info = cmake_utils.getTargetInfo(target, reply_dir)
        local target_name = target_info['name']
        if target_name:find('_autogen') == nil then
            table.insert(targets, target_name)
        end
    end

    -- always add 'all' target
    table.insert(targets, 'all')

    return targets
end --

-- update query driver clangd flag and restart LSP
local function reconfigure_clangd()
    local clangdArgs = cmake_utils.currentClangdArgs()
    require('lspconfig')['clangd'].setup({
        cmd = clangdArgs,
    })
    vim.api.nvim_command('LspRestart clangd')
end

local function makeQueryFiles(build_dir)
    local query_dir = build_dir / '.cmake' / 'api' / 'v1' / 'query'
    if not query_dir:mkdir({ parents = true }) then
        utils.notify(string.format('Unable to create "%s"', query_dir.filename), vim.log.levels.ERROR)
        return false
    end

    local codemodel_file = query_dir / 'codemodel-v2'
    if not codemodel_file:is_file() then
        if not codemodel_file:touch() then
            utils.notify(string.format('Unable to create "%s"', codemodel_file.filename), vim.log.levels.ERROR)
            return false
        end
    end
    return true
end

-- inspired by https://github.com/Shatur/neovim-tasks/blob/master/lua/tasks/module/cmake.lua#L130
-- but modified to also support build kits
local function configure(module_config, _)
    local build_dir = cmake_utils.getBuildDir()
    build_dir:mkdir({ parents = true })

    if not makeQueryFiles(build_dir) then
        return nil
    end

    local buildTypes        = cmake_utils.getCMakeBuildTypesFromConfig(module_config)
    local cmakeKits         = cmake_utils.getCMakeKitsFromConfig(module_config)
    local build_type_config = buildTypes[module_config.build_type]
    local build_kit_config  = cmakeKits[module_config.build_kit]

    local cmakeBuildType = build_type_config.build_type

    local generator = build_kit_config.generator and build_kit_config.generator or "Ninja"
    local buildTypeAware = true
    if build_kit_config.build_type_aware ~= nil then
        buildTypeAware = build_kit_config.build_type_aware
    end

    local args = { '-G', generator, '-B', build_dir.filename, '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON' }
    if buildTypeAware then
        table.insert(args, '-DCMAKE_BUILD_TYPE=' .. cmakeBuildType)
    end
    if module_config.source_dir then
        table.insert(args, '-S')
        table.insert(args, module_config.source_dir)
    end

    if build_kit_config.toolchain_file then
        table.insert(args, '-DCMAKE_TOOLCHAIN_FILE=' .. build_kit_config.toolchain_file)
    end

    if build_kit_config.compilers then
        table.insert(args, '-DCMAKE_C_COMPILER=' .. build_kit_config.compilers.C)
        table.insert(args, '-DCMAKE_CXX_COMPILER=' .. build_kit_config.compilers.CXX)
    end

    if build_type_config.cmake_usr_args then
        for k, v in pairs(build_type_config.cmake_usr_args) do
            table.insert(args, '-D' .. k .. '=' .. v)
        end
    end

    if build_kit_config.cmake_usr_args then
        for k, v in pairs(build_kit_config.cmake_usr_args) do
            table.insert(args, '-D' .. k .. '=' .. v)
        end
    end

    return {
        cmd = module_config.cmd,
        args = args,
        env = build_type_config.environment_variables,
        after_success = reconfigure_clangd,
    }
end

local function build(module_config, _)
    local build_dir = cmake_utils.getBuildDirFromConfig(module_config)
    local cmakeKits = cmake_utils.getCMakeKitsFromConfig(module_config)

    local args = { '--build', build_dir.filename }
    if module_config.target and module_config.target ~= 'all' then
        vim.list_extend(args, { '--target', module_config.target })
    end

    return {
        cmd = module_config.cmd,
        args = args,
        env = cmakeKits[module_config.build_kit].environment_variables,
        after_success = reconfigure_clangd,
    }
end

local function build_all(module_config, _)
    local build_dir = cmake_utils.getBuildDirFromConfig(module_config)
    local cmakeKits = cmake_utils.getCMakeKitsFromConfig(module_config)

    return {
        cmd = module_config.cmd,
        args = { '--build', build_dir.filename },
        env = cmakeKits[module_config.build_kit].environment_variables,
        -- after_success = reconfigure_clangd,
    }
end

local function build_current_file(module_config, _)
    local build_dir = cmake_utils.getBuildDirFromConfig(module_config)
    local cmakeKits = cmake_utils.getCMakeKitsFromConfig(module_config)

    local sourceName = vim.fn.expand('%')
    local extension  = vim.fn.fnamemodify(sourceName, ':e')

    local headerExtensions = {
        ['h'] = true,
        ['hxx'] = true,
        ['hpp'] = true,
    }

    if #extension == 0 or headerExtensions[extension] then
        vim.notify('Given file is not a source file!', vim.log.levels.ERROR, { title = 'cmake_kits' })
        return nil
    end

    local build_kit_config = cmakeKits[module_config.build_kit]
    local generator        = build_kit_config.generator and build_kit_config.generator or "Ninja"

    if generator ~= "Ninja" then
        vim.notify('Build current file is supported only for Ninja generator at the moment!', vim.log.levels.ERROR,
            { title = 'cmake_kits' })
        return nil
    end

    local ninjaTarget = vim.fn.fnameescape(vim.fn.fnamemodify(sourceName, ':p') .. '^')
    return {
        cmd = module_config.cmd,
        args = { '--build', build_dir.filename, '--target', ninjaTarget },
        env = cmakeKits[module_config.build_kit].environment_variables,
        -- after_success = reconfigure_clangd,
    }
end

local function clean(module_config, _)
    local build_dir = cmake_utils.getBuildDirFromConfig(module_config)
    local cmakeKits = cmake_utils.getCMakeKitsFromConfig(module_config)

    return {
        cmd = module_config.cmd,
        args = { '--build', build_dir.filename, '--target', 'clean' },
        env = cmakeKits[module_config.build_kit].environment_variables,
        -- after_success = reconfigure_clangd,
    }
end

local function purgeBuildDir(module_config, _)
    local build_dir = cmake_utils.getBuildDirFromConfig(module_config)

    return {
        -- TODO: what about Windows?
        cmd = 'rm',
        args = { '-rf', tostring(build_dir) },
    }
end

local function runCTest(module_config, _)
    local build_dir = cmake_utils.getBuildDirFromConfig(module_config)
    local cmakeKits = cmake_utils.getCMakeKitsFromConfig(module_config)

    local numcpus = vim.fn.system('nproc')

    return {
        cmd = 'ctest',
        args = { '-C', module_config.build_type, '-j', numcpus, '--output-on-failure' },
        cwd = tostring(build_dir),
        env = cmakeKits[module_config.build_kit].environment_variables,
    }
end

local function run(module_config, _)
    if not module_config.target then
        utils.notify('No selected target, please set "target" parameter', vim.log.levels.ERROR)
        return nil
    end

    local build_dir = cmake_utils.getBuildDirFromConfig(module_config)
    if not build_dir:is_dir() then
        utils.notify(string.format('Build directory "%s" does not exist, you need to run "configure" task first',
            build_dir), vim.log.levels.ERROR)
        return nil
    end

    local target_path = cmake_utils.getExecutablePath(build_dir, module_config.target,
        cmake_utils.getReplyDir(build_dir))
    if not target_path then
        return
    end

    if not target_path:is_file() then
        utils.notify(string.format('Selected target "%s" is not built', target_path.filename), vim.log.levels.ERROR)
        return nil
    end

    return {
        cmd = target_path.filename,
        cwd = target_path:parent().filename,
    }
end

local function debug(module_config, _)
    local command = run(module_config, nil)
    if not command then
        return nil
    end

    command.dap_name = module_config.dap_name
    return command
end

return {
    params = {
        target     = getTargetNames,
        build_type = function() return getKeys(cmake_utils.getCMakeBuildTypes()) end,
        build_kit  = function() return getKeys(cmake_utils.getCMakeKits()) end,
    },
    condition = function() return Path:new('CMakeLists.txt'):exists() end,
    tasks = {
        configure = configure,
        build = build,
        build_all = build_all,
        build_current_file = build_current_file,
        run = { build, run },
        debug = { build, debug },
        clean = clean,
        ctest = runCTest,
        purge = purgeBuildDir,
        reconfigure = { purgeBuildDir, configure }
    }
}
