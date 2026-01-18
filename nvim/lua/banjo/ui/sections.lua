local M = {}

-- Layout model: header/actions fixed at top, history scrolls; input is reserved (separate buffer for now).
local section_order = { "header", "actions", "history", "input" }
local section_defs = {
    header = { key = "header", scroll = "fixed" },
    history = { key = "history", scroll = "scroll" },
    input = { key = "input", scroll = "fixed" },
    actions = { key = "actions", scroll = "fixed" },
}

function M.new()
    return {
        order = section_order,
        defs = section_defs,
        counts = { header = 0, history = nil, input = 0, actions = 0 },
        ranges = {},
    }
end

function M.order()
    return section_order
end

function M.defs()
    return section_defs
end

function M.compute_ranges(total_lines, counts)
    local resolved = {
        header = counts.header or 0,
        input = counts.input or 0,
        actions = counts.actions or 0,
    }
    local fixed = resolved.header + resolved.input + resolved.actions
    local total = total_lines or fixed
    resolved.history = counts.history or math.max(total - fixed, 0)

    local ranges = {}
    local cursor = 0
    for _, key in ipairs(section_order) do
        local len = resolved[key] or 0
        ranges[key] = { start = cursor, stop = cursor + len }
        cursor = cursor + len
    end

    return ranges, resolved
end

function M.history_insert_line(ranges)
    local history = ranges.history or { start = 0, stop = 0 }
    return history.stop
end

return M
