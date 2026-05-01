local utils = require("nvim-biscuits.utils")
local html = require("nvim-biscuits.languages.html")

local language = {}

language.should_decorate = function(ts_node, text, bufnr, all_lines)
    local should_decorate = html.should_decorate(ts_node, text, bufnr, all_lines)
    return should_decorate
end

language.transform_text = function(ts_node, text, bufnr, all_lines)
    text = html.transform_text(ts_node, text, bufnr, all_lines)
    return utils.trim(text)
end

return language
