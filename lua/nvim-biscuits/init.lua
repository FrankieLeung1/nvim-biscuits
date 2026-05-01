local utils = require("nvim-biscuits.utils")
local config = require("nvim-biscuits.config")
local languages = require("nvim-biscuits.languages")
local parse = require("vendor.parse")

local final_config = config.default_config()

local nvim_biscuits = { should_render_biscuits = true }
local attached_buffers = {}
local has_fallback_autocmds = false
local timers = {}

local function is_file_too_big()
    local file_size = vim.fn.wordcount().bytes

    local max_file_size = final_config.max_file_size
    if final_config.max_file_size == nil then
        max_file_size = 0
    end

    if type(max_file_size) == "string" then
        max_file_size = parse.file_size(max_file_size)
    else
        return nil
    end

    if max_file_size == nil then
        vim.notify(
            "nvim-biscuits: max_file_size is invalid. Valid case-insensitive values include: b, kb, kib, mb, mib, gb, gib, tb, tib, pb, pib"
        )
        max_file_size = 0
    end

    return max_file_size > 0 and file_size > max_file_size
end

local function normalize_language_name(lang)
    if lang == nil then
        return nil
    end

    return lang:gsub("-", "")
end

local function get_buffer_parser_lang(bufnr)
    local filetype = vim.bo[bufnr].filetype
    if filetype == nil or filetype == "" then
        return nil
    end

    if vim.treesitter and vim.treesitter.language and vim.treesitter.language.get_lang then
        local parser_lang = vim.treesitter.language.get_lang(filetype)
        if parser_lang ~= nil and parser_lang ~= "" then
            return parser_lang
        end
    end

    return filetype
end

local function get_named_children(node)
    local nodes = {}
    for i = 0, node:named_child_count() - 1, 1 do
        nodes[i + 1] = node:named_child(i)
    end

    return nodes
end

local make_biscuit_hl_group_name = function(lang)
    return "BiscuitColor" .. lang
end

local function cleanup_buffer_augroup(bufnr)
    local augroup_name = "Biscuits_" .. bufnr
    pcall(vim.api.nvim_del_augroup_by_name, augroup_name)
end

nvim_biscuits.decorate_nodes = function(bufnr, lang)
    if bufnr == nil then
        bufnr = vim.api.nvim_get_current_buf()
    end

    local parser_lang = lang or get_buffer_parser_lang(bufnr)
    if parser_lang == nil then
        return
    end

    local language_name = normalize_language_name(parser_lang)

    if config.get_language_config(final_config, language_name, "disabled") then
        return
    end

    local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, parser_lang)
    if not ok_parser or parser == nil then
        utils.console_log("no parser for " .. parser_lang)
        return
    end

    local parsed_trees = parser:parse()
    local root = parsed_trees and parsed_trees[1] and parsed_trees[1]:root()
    if root == nil then
        return
    end

    local biscuit_highlight_group_name = make_biscuit_hl_group_name(language_name)
    local biscuit_highlight_group = vim.api.nvim_create_namespace(
                                        biscuit_highlight_group_name)

    if not nvim_biscuits.should_render_biscuits then
        vim.api.nvim_buf_clear_namespace(bufnr, biscuit_highlight_group, 0, -1)
        return
    end

    local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local line_count = #all_lines

    local cursor_row = nil
    if final_config.cursor_line_only then
        cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    end
    local min_distance = final_config.min_distance
    local trim_by_words = config.get_language_config(final_config, language_name, "trim_by_words")
    local max_length = config.get_language_config(final_config, language_name, "max_length")
    local prefix_string = config.get_language_config(final_config, language_name, "prefix_string")

    -- Cache hot-loop references as locals
    local trim = utils.trim
    local set_extmark = vim.api.nvim_buf_set_extmark
    local should_decorate_lang = languages.should_decorate
    local transform_text_lang = languages.transform_text

    vim.api.nvim_buf_clear_namespace(bufnr, biscuit_highlight_group, 0, -1)

    local stack = { root }
    local stack_size = 1
    while stack_size > 0 do
        local node = stack[stack_size]
        stack[stack_size] = nil
        stack_size = stack_size - 1

        local start_line, _, end_line, _ = node:range()

        -- Prune subtrees that can't possibly contain the cursor line (children
        -- always lie within the parent's range, so this is safe).
        if end_line - start_line >= min_distance
            and (cursor_row == nil or (cursor_row >= start_line and cursor_row <= end_line))
        then
            local child_count = node:named_child_count()
            for i = 0, child_count - 1 do
                stack_size = stack_size + 1
                stack[stack_size] = node:named_child(i)
            end

            local raw_text = all_lines[start_line + 1]
            if raw_text then
                local text = trim(raw_text)

                if #text > 1
                    and (cursor_row == nil or end_line == cursor_row)
                    and should_decorate_lang(language_name, node, text, bufnr, all_lines) ~= false
                then
                    if trim_by_words == true then
                        local words = {}
                        local n = 0
                        for word in string.gmatch(text, "%w+") do
                            n = n + 1
                            words[n] = word
                            if n >= max_length then
                                break
                            end
                        end
                        text = table.concat(words, " ")
                    elseif #text >= max_length then
                        text = string.sub(text, 1, max_length) .. "..."
                    end

                    -- language specific text filter
                    text = transform_text_lang(language_name, node, text, bufnr, all_lines)

                    if text ~= nil and trim(text) ~= "" then
                        text = prefix_string .. text

                        -- Only set extmark if the line is within buffer bounds
                        if end_line < line_count then
                            set_extmark(bufnr, biscuit_highlight_group,
                                        end_line, 0, {
                                id = end_line + 1,
                                virt_text_pos = "eol",
                                virt_text = {
                                    { text, biscuit_highlight_group_name }
                                },
                                hl_mode = "combine"
                            })
                        end
                    end
                end
            end
        end
    end
end

nvim_biscuits.debounced_decorate = function(bufnr, lang)
    if bufnr == nil then
        bufnr = vim.api.nvim_get_current_buf()
    end

    local timer = timers[bufnr]
    if not timer then
        timer = vim.loop.new_timer()
        timers[bufnr] = timer
    end

    timer:stop()
    timer:start(final_config.debounce_ms, 0, vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            nvim_biscuits.decorate_nodes(bufnr, lang)
        end
    end))
end

nvim_biscuits.BufferAttach = function(bufnr, lang)
    if bufnr == nil then
        bufnr = vim.api.nvim_get_current_buf()
    end

    local parser_lang = lang or get_buffer_parser_lang(bufnr)
    if parser_lang == nil then
        return
    end

    local language_name = normalize_language_name(parser_lang)

    local has_parser = pcall(vim.treesitter.get_parser, bufnr, parser_lang)
    if not has_parser then
        return
    end

    if attached_buffers[bufnr] then
        return
    end

    attached_buffers[bufnr] = true

    local toggle_keybind = config.get_language_config(final_config, language_name,
                                                      "toggle_keybind")
    if toggle_keybind ~= nil then
        vim.api.nvim_set_keymap("n", toggle_keybind,
                                "<Cmd>lua require('nvim-biscuits').toggle_biscuits()<CR>",
                                { noremap = false, desc = "toggle biscuits" })
    end

    if is_file_too_big() then
        vim.notify_once(
            "nvim-biscuits: File is larger than configured max_file_size")
        return
    end

    vim.cmd("highlight default link " ..
                make_biscuit_hl_group_name(language_name) .. " BiscuitColor")

    -- we need to fire once at the very start if config allows
    if (not toggle_keybind) or
        config.get_language_config(final_config, language_name, "show_on_start") then
        nvim_biscuits.decorate_nodes(bufnr, parser_lang)
    else
        nvim_biscuits.should_render_biscuits = false
    end

    local on_events = table.concat(final_config.on_events, ",")
    local augroup_name = "Biscuits_" .. bufnr
    if on_events ~= "" then
        vim.api.nvim_create_autocmd(final_config.on_events, {
            group = vim.api.nvim_create_augroup(augroup_name, { clear = true }),
            buffer = bufnr,
            callback = function()
                nvim_biscuits.debounced_decorate(bufnr, parser_lang)
            end,
            desc = "Biscuits event-based update"
        })
    elseif final_config.cursor_line_only == true then
        vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
            group = vim.api.nvim_create_augroup(augroup_name, { clear = true }),
            buffer = bufnr,
            callback = function()
                nvim_biscuits.debounced_decorate(bufnr, parser_lang)
            end,
            desc = "Biscuits cursor-line update"
        })
    else
        vim.api.nvim_buf_attach(bufnr, false, {
            on_lines = function()
                nvim_biscuits.debounced_decorate(bufnr, parser_lang)
            end,

            on_detach = function()
                attached_buffers[bufnr] = nil
                cleanup_buffer_augroup(bufnr)
                if timers[bufnr] then
                    timers[bufnr]:stop()
                    timers[bufnr]:close()
                    timers[bufnr] = nil
                end
            end
        })
    end
end

local function register_fallback_attach()
    if has_fallback_autocmds then
        return
    end

    has_fallback_autocmds = true

    local group = vim.api.nvim_create_augroup("NvimBiscuitsAutoAttach",
                                               { clear = true })

    vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
        group = group,
        callback = function(args)
            if vim.bo[args.buf].buftype ~= "" then
                return
            end

            nvim_biscuits.BufferAttach(args.buf)
        end,
        desc = "Auto attach nvim-biscuits"
    })

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
            nvim_biscuits.BufferAttach(bufnr)
        end
    end
end

nvim_biscuits.setup = function(user_config)
    if user_config == nil then
        user_config = {}
    end

    final_config = utils.merge_tables(final_config, user_config)

    if user_config.default_config then
        final_config = utils.merge_tables(final_config,
                                          user_config.default_config)
    end

    -- Use legacy nvim-treesitter module registration when available.
    local has_ts, nvim_treesitter = pcall(require, "nvim-treesitter")
    if has_ts and type(nvim_treesitter.define_modules) == "function" then
        nvim_treesitter.define_modules {
            nvim_biscuits = {
                enable = true,
                attach = function(bufnr, lang)
                    nvim_biscuits.BufferAttach(bufnr, lang)
                end,
                detach = function(bufnr)
                    attached_buffers[bufnr] = nil
                    cleanup_buffer_augroup(bufnr)
                    if timers[bufnr] then
                        timers[bufnr]:stop()
                        timers[bufnr]:close()
                        timers[bufnr] = nil
                    end
                end,
                is_supported = function(lang)
                    local language_name = normalize_language_name(lang)
                    if language_name == nil then
                        return true
                    end
                    return not config.get_language_config(final_config,
                                                          language_name,
                                                          "disabled")
                end
            }
        }
    else
        register_fallback_attach()
    end

    utils.clear_log()
end

nvim_biscuits.toggle_biscuits = function()
    if is_file_too_big() then
        vim.notify("nvim-biscuits: File is larger than configured max_file_size")
        return
    end

    nvim_biscuits.should_render_biscuits = not nvim_biscuits.should_render_biscuits
    local bufnr = vim.api.nvim_get_current_buf()
    local parser_lang = get_buffer_parser_lang(bufnr)
    if parser_lang == nil then
        return
    end

    nvim_biscuits.decorate_nodes(bufnr, parser_lang)
end

return nvim_biscuits
