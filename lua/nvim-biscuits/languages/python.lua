local utils = require("nvim-biscuits.utils")

local language = {}

language.should_decorate = function(ts_node, text, bufnr, all_lines)
    local should_decorate = true
    return should_decorate
end

language.transform_text = function(ts_node, text, bufnr, all_lines)
    local start_line, start_col, end_line, end_col = ts_node:range()
    local parent_start_line, parent_start_col, parent_end_line, parent_end_col =
        ts_node:parent():range()
    if parent_start_line == start_line - 1 then
        start_line = parent_start_line
        start_col = parent_start_col
        end_line = parent_end_line
        end_col = parent_end_col
    end

    local text = ""
    if all_lines then
        text = all_lines[start_line + 1] or ""
    else
        local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, start_line + 1,
                                                 false)
        text = lines[1] or ""
    end

    -- text = html.transform_text(ts_node, text, bufnr)
    return utils.trim(text)
end

return language
