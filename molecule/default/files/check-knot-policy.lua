local rules = {}
local calls = {}

local function wire_name(text)
  local name = ''
  for label in text:gmatch('[^.]+') do
    name = name .. string.char(#label) .. label
  end
  return name .. '\0'
end

policy = {
  todnames = function(names)
    return {wire_name(names[1])}
  end,
  FLAGS = function(flags)
    assert(table.concat(flags, ',') == 'NO_CACHE,NO_EDNS,NO_0X20')
    return function()
      calls[#calls + 1] = 'flags'
    end
  end,
  STUB = function(addresses)
    assert(addresses[1] == '100.100.100.100')
    assert(addresses[2] == 'fd7a:115c:a1e0::53')
    assert(#addresses == 2)
    return function(state)
      calls[#calls + 1] = 'stub'
      return state
    end
  end,
  add = function(rule)
    rules[#rules + 1] = rule
  end,
}

dofile(arg[1])
assert(#rules == 1)

local cases = {
  {'machine.tailnet.ts.net', true},
  {'MACHINE.TAILNET.TS.NET', true},
  {'node.other-tailnet.ts.net', true},
  {'tailnet.ts.net', false},
  {'ts.net', false},
  {'sub.machine.tailnet.ts.net', false},
  {'machine.tailnet.ts.net.example', false},
  {'machine.tailnet.example', false},
}

for _, case in ipairs(cases) do
  local action = rules[1]({}, {name = function() return wire_name(case[1]) end})
  assert((action ~= nil) == case[2], case[1])
  if action then
    calls = {}
    assert(action(7, {}) == 7)
    assert(calls[1] == 'flags' and calls[2] == 'stub', case[1])
  end
end
