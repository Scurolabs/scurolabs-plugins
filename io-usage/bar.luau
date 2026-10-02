--!nonstrict

local shared = require("./shared.luau")
local sample = shared.normalizeSample(noctalia.state.get(shared.stateKey))
local glyph = "activity"
local showGlyph = noctalia.getConfig("show_glyph") ~= false
local displayMode = noctalia.getConfig("display_mode")
local roundingMode = noctalia.getConfig("bar_rounding")
local stabilityMode = noctalia.getConfig("stability_mode")
local requestedWidth = stabilityMode == "fixed" and noctalia.getConfig("stability_width") or nil
local stabilityWidth = shared.stabilityWidth(requestedWidth)

if displayMode ~= "read"
    and displayMode ~= "write"
    and displayMode ~= "combined"
    and displayMode ~= "separate" then
    displayMode = "combined"
end

if roundingMode ~= "nearest" and roundingMode ~= "none" then
    roundingMode = "none"
end

local function translated(key, substitutions)
    return noctalia.tr("ui." .. key, substitutions)
end

local function valueText()
    return shared.formatDisplayValue(sample, displayMode, roundingMode)
        or translated("value_unavailable")
end

local function render()
    local valueColor = sample.ready and "on_surface" or "error"
    local valueLabel = ui.label({
        text = valueText(),
        color = valueColor,
        maxLines = 1,
        textAlign = "end",
    })
    local valueProps = { align = "center" }
    if stabilityWidth ~= nil then
        valueProps.width = stabilityWidth
        valueProps.justify = "end"
    end
    local children = {}
    if showGlyph then
        local glyphColor = sample.ready and "primary" or "error"
        children[#children + 1] = ui.glyph({ name = glyph, size = 16, color = glyphColor })
    end
    children[#children + 1] = ui.row(valueProps, { valueLabel })

    local container = barWidget.isVertical() and ui.column or ui.row
    barWidget.render(container({ gap = 4, align = "center", paddingH = 4, paddingV = 2 }, children))

    if sample.ready then
        barWidget.setTooltip(
            translated("tooltip.title")
                .. "\n" .. translated("tooltip.read", {
                    rate = shared.formatRate(sample.readBytesPerSec),
                })
                .. "\n" .. translated("tooltip.write", {
                    rate = shared.formatRate(sample.writeBytesPerSec),
                })
                .. "\n" .. translated("tooltip.aggregate", {
                    rate = shared.formatRate(sample.totalBytesPerSec),
                })
        )
    else
        barWidget.setTooltip(translated("tooltip.unavailable"))
    end
end

noctalia.state.watch(shared.stateKey, function(value)
    sample = shared.normalizeSample(value)
    render()
end)

render()
