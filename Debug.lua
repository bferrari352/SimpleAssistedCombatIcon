local SACIProfiler = {
    data = {},
    wrapped = setmetatable({}, { __mode = "k" }), -- weak keys so GC safe
}

local function WrapFunction(self, func, name)
    self.data[name] = self.data[name] or {
        calls = 0,
        total = 0,
        max = 0,
    }

    local entry = self.data[name]

    return function(...)
        local t0 = debugprofilestop()
        local a,b,c,d,e,f = func(...)
        local dt = debugprofilestop() - t0

        entry.calls = entry.calls + 1
        entry.total = entry.total + dt
        if dt > entry.max then entry.max = dt end

        return a,b,c,d,e,f
    end
end

function SACIProfiler:HookMixin(mixin, mixinName)
    if self.wrapped[mixin] then return end
    self.wrapped[mixin] = true

    mixinName = mixinName or tostring(mixin)

    for key, value in pairs(mixin) do
        if type(value) == "function" then
            local fullName = mixinName .. "." .. key
            mixin[key] = WrapFunction(self, value, fullName)
        end
    end
end

function SACIProfiler:Report(limit)
    limit = limit or 40

    local list = {}
    for name, e in pairs(self.data) do
        table.insert(list, {
            name = name,
            calls = e.calls,
            total = e.total,
            avg = e.total / e.calls,
            max = e.max,
        })
    end

    table.sort(list, function(a, b)
        return a.total > b.total
    end)

    print("------ PROFILER REPORT ------")
    for i = 1, math.min(limit, #list) do
        local e = list[i]
        print(string.format(
            "%2d. %-40s total: %.3fms  avg: %.5fms  max: %.3fms  calls: %d",
            i, e.name, e.total, e.avg, e.max, e.calls
        ))
    end
    print("-----------------------------------")
end

_G.SACIProfiler = SACIProfiler
