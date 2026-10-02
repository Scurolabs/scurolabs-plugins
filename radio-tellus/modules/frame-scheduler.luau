--!nonstrict
-- Coalesces panel state changes into one render on a future frame.

local scheduler = {}

function scheduler.new(targetPanel, renderCallback)
    local self = {
        panel = targetPanel,
        renderCallback = renderCallback,
        dirty = {},
        armed = false,
        open = false,
        notBefore = 0,
    }

    function self:arm()
        if self.open and not self.armed then
            self.armed = true
            self.panel.setNeedsFrameTick(true)
        end
    end

    function self:request(reason, debounceMs)
        self.dirty[reason or "state"] = true
        local now = math.floor(noctalia.nowMs())
        if debounceMs == nil then
            self.notBefore = now
        else
            local due = now + math.max(0, tonumber(debounceMs) or 0)
            if due > self.notBefore then self.notBefore = due end
        end
        self:arm()
    end

    function self:openPanel()
        self.open = true
        self:request("open")
    end

    function self:closePanel()
        self.open = false
        self.dirty = {}
        self.notBefore = 0
        self.armed = false
        self.panel.setNeedsFrameTick(false)
    end

    function self:flush()
        if not self.open then
            self.armed = false
            self.panel.setNeedsFrameTick(false)
            return
        end
        if math.floor(noctalia.nowMs()) < self.notBefore then
            self.panel.setNeedsFrameTick(true)
            return
        end
        self.armed = false
        self.panel.setNeedsFrameTick(false)
        if next(self.dirty) == nil then return end
        self.dirty = {}
        self.notBefore = 0
        self.renderCallback()
        if self.open and next(self.dirty) ~= nil then self:arm() end
    end

    return self
end

return scheduler
