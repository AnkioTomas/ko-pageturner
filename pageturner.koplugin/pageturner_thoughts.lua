--[[--
当前屏可选的标记：他人段评、X-Ray 实体 + 自己带笔记的划线，统一成 { boxes, open }，按屏幕位置排序。

  - 段评 / X-Ray：月读阅读页公共标记层上一帧实际画出的标记 `ui._book_page_marks.painted`，
    每项 { mark = { tap }, pieces = 屏幕框 }，tap 开段评窗 / 实体详情。互斥后被让掉的不在里面，
    所见即所选。
  - 自己的划线：KOReader 原生 `ui.annotation.annotations` 里 note 非空的，开 TextViewer 看笔记。

@module pageturner.thoughts
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")

local Thoughts = {}

--- 从上到下、从左到右；必须是严格弱序，否则 table.sort 会抛 invalid order function。
local function byPosition(a, b)
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
end

--- 落在视口里的框（拷贝），按从上到下、从左到右排好；一个都没有返回 nil。
local function visible(boxes)
    local w, h = Device.screen:getWidth(), Device.screen:getHeight()
    local out = {}
    for _idx, b in ipairs(boxes or {}) do
        if b.x + b.w > 0 and b.x < w and b.y + b.h > 0 and b.y < h then out[#out + 1] = b end
    end
    table.sort(out, byPosition)
    return #out > 0 and out or nil
end

local function pageMarks(ui, out)
    local layer = ui._book_page_marks
    if not layer then return end
    for _idx, item in ipairs(layer.painted) do
        local boxes = visible(item.pieces)
        if boxes then out[#out + 1] = { boxes = boxes, open = item.mark.tap } end
    end
end

local function mine(ui, out)
    if not (ui.rolling and ui.annotation) then return end
    for _idx, a in ipairs(ui.annotation.annotations) do
        local boxes = a.note and a.note ~= "" and visible(ui.document:getScreenBoxesFromPositions(a.pos0, a.pos1, true))
        if boxes then
            out[#out + 1] = {
                boxes = boxes,
                open = function()
                    UIManager:show(require("ui/widget/textviewer"):new{ title = a.text, text = a.note })
                end,
            }
        end
    end
end

--- 当前屏的标记与想法；一条都没有返回 nil。
---@param ui table ReaderUI
---@return table[]|nil
function Thoughts.collect(ui)
    local out = {}
    pageMarks(ui, out)
    mine(ui, out)
    table.sort(out, function(a, b) return byPosition(a.boxes[1], b.boxes[1]) end)
    return #out > 0 and out or nil
end

return Thoughts
