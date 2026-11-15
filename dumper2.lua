-- dumper2.lua


local INPUT_PATH  = arg and arg[1]
local OUTPUT_PATH = arg and arg[2]

if type(INPUT_PATH) ~= "string" or type(OUTPUT_PATH) ~= "string" then
    io.stderr:write("[dumper2] missing input/output path arguments\n")
    os.exit(2)
end

local hostIoOpen = io.open
local hostClock  = os.clock
local hostTime   = os.time
local hostDate   = os.date
local hostLoad   = loadstring or load
local hostType   = type
local hostTostring = tostring
local hostTonumber = tonumber
local hostPcall  = pcall
local hostXpcall = xpcall
local hostError  = error
local hostPairs  = pairs
local hostIpairs = ipairs
local hostNext   = next
local hostRawget = rawget
local hostRawset = rawset
local hostRawequal = rawequal
local hostRawlen = rawlen or function(t) return #t end
local hostPack = table.pack or function(...) return { n = select("#", ...), ... } end
local hostGetmetatable = getmetatable
local hostSetmetatable = setmetatable
local hostUnpack = table.unpack or unpack
local hostSetfenv = setfenv
local hostGetfenv = getfenv

-- Read input script
local inFile, inErr = hostIoOpen(INPUT_PATH, "rb")
if not inFile then
    io.stderr:write("[dumper2] failed to open input: " .. hostTostring(inErr) .. "\n")
    os.exit(1)
end
local SOURCE_CODE = inFile:read("*a") or ""
inFile:close()

-- Normalize BOM / line endings
if SOURCE_CODE:sub(1, 3) == "\239\187\191" then
    SOURCE_CODE = SOURCE_CODE:sub(4)
end
SOURCE_CODE = SOURCE_CODE:gsub("\r\n", "\n"):gsub("\r", "\n")

-- Capture log buffer
local _capturedLines = {}
local _capturedCount = 0
local _MAX_CAPTURED  = 4000
local _seenStageHash = {}
local _stageDepth    = 0
local _MAX_STAGE_DEPTH = 6
local _simTime       = 0
local _startClock    = hostClock()
local _rawMetaMap    = hostSetmetatable({}, { __mode = "k" })

local function _escapeLuaString(s)
    local out = {}
    out[1] = '"'
    for i = 1, #s do
        local b = string.byte(s, i)
        if b == 92 then out[#out + 1] = "\\\\"
        elseif b == 34 then out[#out + 1] = '\\"'
        elseif b == 10 then out[#out + 1] = "\\n"
        elseif b == 13 then out[#out + 1] = "\\r"
        elseif b == 9 then out[#out + 1] = "\\t"
        elseif b < 32 or b > 126 then
            out[#out + 1] = string.format("\\%03d", b)
        else
            out[#out + 1] = string.char(b)
        end
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

local function _emitLine(line)
    if type(line) ~= "string" or line == "" then return end
    if _capturedCount >= _MAX_CAPTURED then return end
    _capturedCount = _capturedCount + 1
    _capturedLines[_capturedCount] = line
end

local function _formatArg(v, depth)
    depth = depth or 0
    local t = hostType(v)
    if v == nil then return "nil" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v then return "0/0" end
        if v == math.huge then return "math.huge" end
        if v == -math.huge then return "-math.huge" end
        return hostTostring(v)
    end
    if t == "string" then
        if #v > 2048 then
            return _escapeLuaString(v:sub(1, 2048)) .. " --[[truncated]]"
        end
        return _escapeLuaString(v)
    end
    if t == "function" then return "function() end" end
    if t == "table" then
        local mt = _rawMetaMap[v] or hostGetmetatable(v)
        if hostType(mt) == "table" then
            local tp = rawget(mt, "__type")
            if tp == "Vector3" then
                return string.format("Vector3.new(%s, %s, %s)", hostTostring(v.X or 0), hostTostring(v.Y or 0), hostTostring(v.Z or 0))
            elseif tp == "Vector2" then
                return string.format("Vector2.new(%s, %s)", hostTostring(v.X or 0), hostTostring(v.Y or 0))
            elseif tp == "Color3" then
                return string.format("Color3.new(%s, %s, %s)", hostTostring(v.R or 0), hostTostring(v.G or 0), hostTostring(v.B or 0))
            elseif tp == "CFrame" then
                return string.format("CFrame.new(%s, %s, %s)", hostTostring(v.X or 0), hostTostring(v.Y or 0), hostTostring(v.Z or 0))
            elseif tp == "EnumItem" or tp == "Enum" or tp == "Instance" then
                return hostTostring(v)
            end
        end
        if depth >= 2 then return "{...}" end
        local parts = {}
        local n = 0
        for k, val in hostPairs(v) do
            n = n + 1
            if n > 24 then
                parts[#parts + 1] = "--[[...]]"
                break
            end
            if hostType(k) == "number" then
                parts[#parts + 1] = _formatArg(val, depth + 1)
            elseif hostType(k) == "string" and k:match("^[%a_][%w_]*$") then
                parts[#parts + 1] = k .. " = " .. _formatArg(val, depth + 1)
            else
                parts[#parts + 1] = "[" .. _formatArg(k, depth + 1) .. "] = " .. _formatArg(val, depth + 1)
            end
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return hostTostring(v)
end

local function _formatArgs(...)
    local packed = hostPack(...)
    local out = {}
    for i = 1, packed.n do
        out[i] = _formatArg(packed[i], 0)
    end
    return table.concat(out, ", ")
end

-- API Registry from lune_sandbox_runner
local _apiRegistry = rawget(_G, "__ROBLOX_API_REGISTRY") or {}
local _apiEnums    = (hostType(_apiRegistry) == "table" and _apiRegistry.enums) or {}
local _apiClasses  = (hostType(_apiRegistry) == "table" and _apiRegistry.classes) or {}

-- Type / Proxy tracking
local _proxyTypes = hostSetmetatable({}, { __mode = "k" })
local _proxyPaths = hostSetmetatable({}, { __mode = "k" })
local _proxyProps = hostSetmetatable({}, { __mode = "k" })
local _proxyChildren = hostSetmetatable({}, { __mode = "k" })
local _proxyParent = hostSetmetatable({}, { __mode = "k" })
local _refBaseMap  = hostSetmetatable({}, { __mode = "k" })
local _readOnlyMap = hostSetmetatable({}, { __mode = "k" })
local _cclosureSet = hostSetmetatable({}, { __mode = "k" })
local _hookedMap   = hostSetmetatable({}, { __mode = "k" })
local _editableMeshes = hostSetmetatable({}, { __mode = "k" })
local _currentNamecallMethod = ""

-- Class inheritance helper
local _knownInherits = {
    Part = {"Part", "BasePart", "PVInstance", "Instance"},
    MeshPart = {"MeshPart", "BasePart", "PVInstance", "Instance"},
    WedgePart = {"WedgePart", "BasePart", "PVInstance", "Instance"},
    Humanoid = {"Humanoid", "Instance"},
    Animator = {"Animator", "Instance"},
    Animation = {"Animation", "Instance"},
    AnimationTrack = {"AnimationTrack", "Instance"},
    Player = {"Player", "Instance"},
    Model = {"Model", "PVInstance", "Instance"},
    Folder = {"Folder", "Instance"},
    LocalScript = {"LocalScript", "BaseScript", "LuaSourceContainer", "Instance"},
    Script = {"Script", "BaseScript", "LuaSourceContainer", "Instance"},
    ModuleScript = {"ModuleScript", "LuaSourceContainer", "Instance"},
    RemoteEvent = {"RemoteEvent", "BaseRemoteEvent", "Instance"},
    RemoteFunction = {"RemoteFunction", "Instance"},
    UnreliableRemoteEvent = {"UnreliableRemoteEvent", "BaseRemoteEvent", "Instance"},
    Sound = {"Sound", "Instance"},
    ScreenGui = {"ScreenGui", "LayerCollector", "GuiBase2d", "GuiBase", "Instance"},
    Frame = {"Frame", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    TextLabel = {"TextLabel", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    TextButton = {"TextButton", "GuiButton", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    TextBox = {"TextBox", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    ImageLabel = {"ImageLabel", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    ImageButton = {"ImageButton", "GuiButton", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    ScrollingFrame = {"ScrollingFrame", "GuiObject", "GuiBase2d", "GuiBase", "Instance"},
    EditableMesh = {"EditableMesh", "Object", "Instance"},
    Workspace = {"Workspace", "WorldRoot", "Model", "PVInstance", "Instance"},
    DataModel = {"DataModel", "ServiceProvider", "Instance"},
    Camera = {"Camera", "Instance"},
    Tool = {"Tool", "BackpackItem", "Instance"},
    Accessory = {"Accessory", "Accoutrement", "Instance"},
    Attachment = {"Attachment", "Instance"},
    Highlight = {"Highlight", "Instance"},
    ProximityPrompt = {"ProximityPrompt", "Instance"},
    ClickDetector = {"ClickDetector", "Instance"},
    Tween = {"Tween", "TweenBase", "Instance"},
}

local function _isClassA(className, targetName)
    if className == targetName then return true end
    if targetName == "Instance" or targetName == "Object" then return true end
    local list = _knownInherits[className]
    if list then
        for _, base in hostIpairs(list) do
            if base == targetName then return true end
        end
    end
    local clsDef = _apiClasses[className]
    local visited = {}
    while hostType(clsDef) == "table" and clsDef.superclass and not visited[clsDef.superclass] do
        if clsDef.superclass == targetName then return true end
        visited[clsDef.superclass] = true
        clsDef = _apiClasses[clsDef.superclass]
    end
    return false
end

-- Sandboxed Roblox Datatypes
local function _makeType(name, fields)
    local obj = fields or {}
    local mt = {
        __type = name,
        __tostring = function() return name end,
        __metatable = "The metatable is locked",
    }
    mt.__index = mt
    _rawMetaMap[obj] = mt
    return hostSetmetatable(obj, mt)
end

local _Vector2 = {}
do
    local v2mt = {
        __type = "Vector2",
        __tostring = function(s) return string.format("%g, %g", s.X, s.Y) end,
        __add = function(a, b) return _Vector2.new((a.X or 0) + (b.X or 0), (a.Y or 0) + (b.Y or 0)) end,
        __sub = function(a, b) return _Vector2.new((a.X or 0) - (b.X or 0), (a.Y or 0) - (b.Y or 0)) end,
        __mul = function(a, b)
            if hostType(b) == "number" then return _Vector2.new(a.X * b, a.Y * b) end
            return _Vector2.new((a.X or 0) * (b.X or 0), (a.Y or 0) * (b.Y or 0))
        end,
        __div = function(a, b)
            if hostType(b) == "number" then return _Vector2.new(a.X / b, a.Y / b) end
            return _Vector2.new((a.X or 0) / (b.X or 1), (a.Y or 0) / (b.Y or 1))
        end,
        __eq = function(a, b) return hostType(b) == "table" and a.X == b.X and a.Y == b.Y end,
    }
    v2mt.__index = function(s, k)
        if k == "x" then return s.X end
        if k == "y" then return s.Y end
        if k == "Magnitude" then return math.sqrt(s.X * s.X + s.Y * s.Y) end
        if k == "Unit" then
            local m = math.sqrt(s.X * s.X + s.Y * s.Y)
            return m > 0 and _Vector2.new(s.X / m, s.Y / m) or _Vector2.new(0, 0)
        end
        if k == "Lerp" then return function(self, g, a) return _Vector2.new(self.X + (g.X - self.X) * a, self.Y + (g.Y - self.Y) * a) end end
        if k == "Dot" then return function(self, o) return self.X * o.X + self.Y * o.Y end end
        return nil
    end
    _Vector2.new = function(x, y)
        return hostSetmetatable({ X = hostTonumber(x) or 0, Y = hostTonumber(y) or 0 }, v2mt)
    end
    _Vector2.zero = _Vector2.new(0, 0)
    _Vector2.one  = _Vector2.new(1, 1)
    _Vector2.xAxis = _Vector2.new(1, 0)
    _Vector2.yAxis = _Vector2.new(0, 1)
end

local _Vector3 = {}
do
    local v3mt
    v3mt = {
        __type = "Vector3",
        __tostring = function(s) return string.format("%g, %g, %g", s.X, s.Y, s.Z) end,
        __add = function(a, b) return _Vector3.new((a.X or 0) + (b.X or 0), (a.Y or 0) + (b.Y or 0), (a.Z or 0) + (b.Z or 0)) end,
        __sub = function(a, b) return _Vector3.new((a.X or 0) - (b.X or 0), (a.Y or 0) - (b.Y or 0), (a.Z or 0) - (b.Z or 0)) end,
        __unm = function(a) return _Vector3.new(-a.X, -a.Y, -a.Z) end,
        __mul = function(a, b)
            if hostType(b) == "number" then return _Vector3.new(a.X * b, a.Y * b, a.Z * b) end
            if hostType(a) == "number" then return _Vector3.new(a * b.X, a * b.Y, a * b.Z) end
            return _Vector3.new((a.X or 0) * (b.X or 0), (a.Y or 0) * (b.Y or 0), (a.Z or 0) * (b.Z or 0))
        end,
        __div = function(a, b)
            if hostType(b) == "number" then return _Vector3.new(a.X / b, a.Y / b, a.Z / b) end
            return _Vector3.new((a.X or 0) / (b.X or 1), (a.Y or 0) / (b.Y or 1), (a.Z or 0) / (b.Z or 1))
        end,
        __eq = function(a, b) return hostType(b) == "table" and a.X == b.X and a.Y == b.Y and a.Z == b.Z end,
    }
    v3mt.__index = function(s, k)
        if k == "x" then return s.X end
        if k == "y" then return s.Y end
        if k == "z" then return s.Z end
        if k == "Magnitude" or k == "magnitude" then
            return math.sqrt(s.X * s.X + s.Y * s.Y + s.Z * s.Z)
        end
        if k == "Unit" or k == "unit" then
            local m = math.sqrt(s.X * s.X + s.Y * s.Y + s.Z * s.Z)
            return m > 0 and _Vector3.new(s.X / m, s.Y / m, s.Z / m) or _Vector3.new(0, 0, 0)
        end
        if k == "Lerp" or k == "lerp" then
            return function(self, goal, alpha)
                return _Vector3.new(self.X + (goal.X - self.X) * alpha, self.Y + (goal.Y - self.Y) * alpha, self.Z + (goal.Z - self.Z) * alpha)
            end
        end
        if k == "Dot" or k == "dot" then
            return function(self, o) return self.X * o.X + self.Y * o.Y + self.Z * o.Z end
        end
        if k == "Cross" or k == "cross" then
            return function(self, o)
                return _Vector3.new(self.Y * o.Z - self.Z * o.Y, self.Z * o.X - self.X * o.Z, self.X * o.Y - self.Y * o.X)
            end
        end
        if k == "FuzzyEq" then
            return function(self, o, eps)
                eps = eps or 1e-5
                return math.abs(self.X - o.X) <= eps and math.abs(self.Y - o.Y) <= eps and math.abs(self.Z - o.Z) <= eps
            end
        end
        return nil
    end
    _Vector3.new = function(x, y, z)
        return hostSetmetatable({ X = hostTonumber(x) or 0, Y = hostTonumber(y) or 0, Z = hostTonumber(z) or 0 }, v3mt)
    end
    _Vector3.zero  = _Vector3.new(0, 0, 0)
    _Vector3.one   = _Vector3.new(1, 1, 1)
    _Vector3.xAxis = _Vector3.new(1, 0, 0)
    _Vector3.yAxis = _Vector3.new(0, 1, 0)
    _Vector3.zAxis = _Vector3.new(0, 0, 1)
end

local _CFrame = {}
do
    local cfMt
    local function _makeCF(x, y, z, r)
        return hostSetmetatable({
            X = hostTonumber(x) or 0,
            Y = hostTonumber(y) or 0,
            Z = hostTonumber(z) or 0,
            _r = r or {1, 0, 0, 0, 1, 0, 0, 0, 1},
        }, cfMt)
    end
    cfMt = {
        __type = "CFrame",
        __tostring = function(s) return string.format("%g, %g, %g", s.X, s.Y, s.Z) end,
        __mul = function(a, b)
            if hostType(b) == "table" and b._r then
                return _makeCF(a.X + b.X, a.Y + b.Y, a.Z + b.Z, a._r)
            elseif hostType(b) == "table" and b.X ~= nil then
                return _Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
            end
            return a
        end,
        __add = function(a, b) return _makeCF(a.X + (b.X or 0), a.Y + (b.Y or 0), a.Z + (b.Z or 0), a._r) end,
        __sub = function(a, b) return _makeCF(a.X - (b.X or 0), a.Y - (b.Y or 0), a.Z - (b.Z or 0), a._r) end,
        __eq = function(a, b) return hostType(b) == "table" and a.X == b.X and a.Y == b.Y and a.Z == b.Z end,
    }
    cfMt.__index = function(s, k)
        local r = s._r
        if k == "Position" or k == "p" then return _Vector3.new(s.X, s.Y, s.Z) end
        if k == "LookVector" then return _Vector3.new(-r[3], -r[6], -r[9]) end
        if k == "RightVector" then return _Vector3.new(r[1], r[4], r[7]) end
        if k == "UpVector" then return _Vector3.new(r[2], r[5], r[8]) end
        if k == "Inverse" or k == "inverse" then return function() return _makeCF(-s.X, -s.Y, -s.Z, r) end end
        if k == "Lerp" or k == "lerp" then return function(_, g, t) t = t or 0; return _makeCF(s.X + (g.X - s.X) * t, s.Y + (g.Y - s.Y) * t, s.Z + (g.Z - s.Z) * t, r) end end
        if k == "ToWorldSpace" then return function(_, o) return _makeCF(s.X + o.X, s.Y + o.Y, s.Z + o.Z, r) end end
        if k == "ToObjectSpace" then return function(_, o) return _makeCF(o.X - s.X, o.Y - s.Y, o.Z - s.Z, r) end end
        if k == "PointToWorldSpace" then return function(_, p) return _Vector3.new(s.X + p.X, s.Y + p.Y, s.Z + p.Z) end end
        if k == "PointToObjectSpace" then return function(_, p) return _Vector3.new(p.X - s.X, p.Y - s.Y, p.Z - s.Z) end end
        if k == "VectorToWorldSpace" or k == "VectorToObjectSpace" then return function(_, p) return p end end
        if k == "GetComponents" or k == "components" then return function() return s.X, s.Y, s.Z, r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9] end end
        if k == "ToEulerAnglesXYZ" or k == "toEulerAnglesXYZ" or k == "ToOrientation" then return function() return 0, 0, 0 end end
        return nil
    end
    _CFrame.new = function(x, y, z)
        if hostType(x) == "table" and y == nil then return _makeCF(x.X, x.Y, x.Z) end
        return _makeCF(x, y, z)
    end
    _CFrame.Angles = function() return _makeCF(0, 0, 0) end
    _CFrame.fromEulerAnglesXYZ = _CFrame.Angles
    _CFrame.fromEulerAnglesYXZ = _CFrame.Angles
    _CFrame.fromOrientation = _CFrame.Angles
    _CFrame.lookAt = function(pos) return _makeCF(pos and pos.X, pos and pos.Y, pos and pos.Z) end
    _CFrame.fromMatrix = function(pos) return _makeCF(pos and pos.X, pos and pos.Y, pos and pos.Z) end
    _CFrame.fromAxisAngle = function() return _makeCF(0, 0, 0) end
    _CFrame.identity = _makeCF(0, 0, 0)
end

local _Color3 = {}
do
    local c3mt = {
        __type = "Color3",
        __tostring = function(s) return string.format("%g, %g, %g", s.R, s.G, s.B) end,
        __eq = function(a, b) return hostType(b) == "table" and a.R == b.R and a.G == b.G and a.B == b.B end,
        __index = {
            Lerp = function(self, goal, alpha)
                alpha = alpha or 0
                return _Color3.new(self.R + (goal.R - self.R) * alpha, self.G + (goal.G - self.G) * alpha, self.B + (goal.B - self.B) * alpha)
            end,
            ToHSV = function(self)
                local maxC = math.max(self.R, self.G, self.B)
                local minC = math.min(self.R, self.G, self.B)
                local d = maxC - minC
                local h = 0
                if d > 0 then
                    if maxC == self.R then h = ((self.G - self.B) / d) % 6
                    elseif maxC == self.G then h = (self.B - self.R) / d + 2
                    else h = (self.R - self.G) / d + 4 end
                    h = h / 6
                end
                local s = maxC > 0 and (d / maxC) or 0
                return h, s, maxC
            end,
            ToHex = function(self)
                return string.format("%02x%02x%02x", math.floor(self.R * 255 + 0.5), math.floor(self.G * 255 + 0.5), math.floor(self.B * 255 + 0.5))
            end,
        },
    }
    _Color3.new = function(r, g, b) return hostSetmetatable({ R = r or 0, G = g or 0, B = b or 0 }, c3mt) end
    _Color3.fromRGB = function(r, g, b) return _Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end
    _Color3.fromHSV = function(h, s, v) return _Color3.new(v or 1, v or 1, v or 1) end
    _Color3.fromHex = function() return _Color3.new(1, 1, 1) end
end

local _BrickColor = {}
_BrickColor.new = function(val)
    return hostSetmetatable({ Name = hostTostring(val or "Medium stone grey"), Number = 194, Color = _Color3.new(0.6, 0.6, 0.6) }, { __type = "BrickColor", __tostring = function(s) return s.Name end })
end
_BrickColor.White  = function() return _BrickColor.new("White") end
_BrickColor.Black  = function() return _BrickColor.new("Black") end
_BrickColor.Red    = function() return _BrickColor.new("Bright red") end
_BrickColor.Blue   = function() return _BrickColor.new("Bright blue") end
_BrickColor.Green  = function() return _BrickColor.new("Bright green") end
_BrickColor.Random = function() return _BrickColor.new("Medium stone grey") end

local _UDim = {}
_UDim.new = function(s, o) return hostSetmetatable({ Scale = s or 0, Offset = o or 0 }, { __type = "UDim" }) end

local _UDim2 = {}
_UDim2.new = function(xs, xo, ys, yo)
    return hostSetmetatable({ X = _UDim.new(xs, xo), Y = _UDim.new(ys, yo) }, { __type = "UDim2" })
end
_UDim2.fromScale  = function(xs, ys) return _UDim2.new(xs, 0, ys, 0) end
_UDim2.fromOffset = function(xo, yo) return _UDim2.new(0, xo, 0, yo) end
local _TweenInfo = {
    new = function(t, style, dir, rep, rev, del)
        return hostSetmetatable({ Time = t or 1, EasingStyle = style, EasingDirection = dir, RepeatCount = rep or 0, Reverses = rev == true, DelayTime = del or 0 }, { __type = "TweenInfo" })
    end
}
local _Ray = {
    new = function(o, d)
        return hostSetmetatable({ Origin = o or _Vector3.zero, Direction = d or _Vector3.zero }, { __type = "Ray" })
    end
}
local _Rect = {
    new = function(a, b, c, d)
        return hostSetmetatable({ Min = _Vector2.new(a or 0, b or 0), Max = _Vector2.new(c or 0, d or 0) }, { __type = "Rect" })
    end
}
local _Region3 = {
    new = function(minV, maxV)
        return hostSetmetatable({ CFrame = _CFrame.new(), Size = _Vector3.new(4, 4, 4), Min = minV or _Vector3.zero, Max = maxV or _Vector3.zero }, { __type = "Region3" })
    end
}
local _NumberRange = { new = function(a, b) return hostSetmetatable({ Min = a or 0, Max = b or a or 0 }, { __type = "NumberRange" }) end }
local _NumberSequenceKeypoint = { new = function(t, v, e) return hostSetmetatable({ Time = t or 0, Value = v or 0, Envelope = e or 0 }, { __type = "NumberSequenceKeypoint" }) end }
local _NumberSequence = { new = function(v) return hostSetmetatable({ Keypoints = hostType(v) == "table" and v or { _NumberSequenceKeypoint.new(0, v or 0) } }, { __type = "NumberSequence" }) end }
local _ColorSequenceKeypoint = { new = function(t, v) return hostSetmetatable({ Time = t or 0, Value = v or _Color3.new(1, 1, 1) }, { __type = "ColorSequenceKeypoint" }) end }
local _ColorSequence = { new = function(v) return hostSetmetatable({ Keypoints = hostType(v) == "table" and v or { _ColorSequenceKeypoint.new(0, v or _Color3.new(1, 1, 1)) } }, { __type = "ColorSequence" }) end }
local _PhysicalProperties = { new = function(d, f, e) return hostSetmetatable({ Density = d or 0.7, Friction = f or 0.3, Elasticity = e or 0.5 }, { __type = "PhysicalProperties" }) end }
local _Faces = { new = function() return hostSetmetatable({}, { __type = "Faces" }) end }
local _Axes  = { new = function() return hostSetmetatable({}, { __type = "Axes" }) end }
local _OverlapParams = {
    new = function()
        return hostSetmetatable({ FilterDescendantsInstances = {}, IncludeInstances = {}, ExcludeInstances = {}, FilterType = nil, MaxParts = 0, RespectCanCollide = false, CollisionGroup = "Default" }, { __type = "OverlapParams" })
    end
}
local _RaycastParams = {
    new = function()
        return hostSetmetatable({ FilterDescendantsInstances = {}, FilterType = nil, IgnoreWater = false, RespectCanCollide = false, CollisionGroup = "Default" }, { __type = "RaycastParams" })
    end
}
local _PathWaypoint = { new = function(pos, act, lbl) return hostSetmetatable({ Position = pos or _Vector3.zero, Action = act, Label = lbl or "" }, { __type = "PathWaypoint" }) end }
local _Random = {
    new = function()
        return {
            NextNumber = function(_, a, b) if a and b then return a + math.random() * (b - a) end return math.random() end,
            NextInteger = function(_, a, b) return math.random(a or 1, b or 100) end,
            NextUnitVector = function() return _Vector3.new(0, 1, 0) end,
        }
    end
}
local _DateTime = {
    now = function()
        local ts = hostTime()
        return {
            UnixTimestamp = ts,
            UnixTimestampMillis = ts * 1000,
            ToIsoDate = function() return hostDate("!%Y-%m-%dT%H:%M:%SZ", ts) end,
            FormatUniversalTime = function() return hostDate("!%Y-%m-%d %H:%M:%S", ts) end,
            FormatLocalTime = function() return hostDate("%Y-%m-%d %H:%M:%S", ts) end,
        }
    end,
    fromUnixTimestamp = function(ts)
        return { UnixTimestamp = ts or 0, UnixTimestampMillis = (ts or 0) * 1000, ToIsoDate = function() return hostDate("!%Y-%m-%dT%H:%M:%SZ", ts or 0) end }
    end,
}
local _Font = {
    new = function(f, w, s) return hostSetmetatable({ Family = f or "", Weight = w, Style = s }, { __type = "Font" }) end,
    fromEnum = function(e) return hostSetmetatable({ Family = hostTostring(e) }, { __type = "Font" }) end,
}

-- Enum hierarchy backed by __ROBLOX_API_REGISTRY
local _enumCache = {}
local function _makeEnumItem(enumName, itemName, value, enumTypeObj)
    local key = enumName .. "." .. itemName
    if _enumCache[key] then return _enumCache[key] end
    local mt = {
        __type = "EnumItem",
        __tostring = function() return "Enum." .. key end,
        __metatable = "The metatable is locked",
    }
    local item = hostSetmetatable({
        Name = itemName,
        Value = value or 0,
        EnumType = enumTypeObj,
    }, mt)
    _rawMetaMap[item] = mt
    _enumCache[key] = item
    return item
end

local _enumTypeCache = {}
local _Enum = hostSetmetatable({}, {
    __type = "Enums",
    __tostring = function() return "Enum" end,
    __index = function(_, enumName)
        if _enumTypeCache[enumName] then return _enumTypeCache[enumName] end
        local enumObj
        local enumMt = {
            __type = "Enum",
            __tostring = function() return "Enum." .. enumName end,
            __index = function(_, itemName)
                if itemName == "GetEnumItems" then
                    return function()
                        local items = {}
                        local def = _apiEnums[enumName]
                        if hostType(def) == "table" and hostType(def.order) == "table" then
                            for _, n in hostIpairs(def.order) do
                                items[#items + 1] = _makeEnumItem(enumName, n, def.values and def.values[n] or 0, enumObj)
                            end
                        end
                        return items
                    end
                end
                local def = _apiEnums[enumName]
                local val = hostType(def) == "table" and hostType(def.values) == "table" and def.values[itemName] or 0
                return _makeEnumItem(enumName, itemName, val, enumObj)
            end,
        }
        enumObj = hostSetmetatable({}, enumMt)
        _rawMetaMap[enumObj] = enumMt
        _enumTypeCache[enumName] = enumObj
        return enumObj
    end,
})

-- Signal / Connection builder
local function _makeSignal(signalName)
    local listeners = {}
    local sig
    sig = hostSetmetatable({
        Connect = function(_, fn)
            local conn = { Connected = true }
            if hostType(fn) == "function" then
                listeners[#listeners + 1] = { conn = conn, fn = fn }
            end
            conn.Disconnect = function() conn.Connected = false end
            conn.disconnect = conn.Disconnect
            return hostSetmetatable(conn, { __type = "RBXScriptConnection" })
        end,
        Once = function(self, fn)
            local c
            c = self:Connect(function(...)
                if c then c:Disconnect() end
                if hostType(fn) == "function" then fn(...) end
            end)
            return c
        end,
        Wait = function() return 1 / 60 end,
        Fire = function(_, ...)
            for _, entry in hostIpairs(listeners) do
                if entry.conn.Connected then
                    hostPcall(entry.fn, ...)
                end
            end
        end,
    }, {
        __type = "RBXScriptSignal",
        __tostring = function() return "Signal " .. hostTostring(signalName or "Event") end,
    })
    sig.connect = sig.Connect
    sig.wait = sig.Wait
    return sig
end

-- Forward declaration for Instance factory
local _createInstance
local _sandboxEnv

-- Method & property caches per instance proxy
local function _makeInstanceProxy(className, name, parent, extraProps)
    local inst = {}
    _proxyTypes[inst]    = "Instance"
    _proxyPaths[inst]    = name or className
    _proxyChildren[inst] = {}
    _proxyParent[inst]   = parent
    local props = {
        ClassName = className,
        Name      = name or className,
    }
    if hostType(extraProps) == "table" then
        for k, v in hostPairs(extraProps) do
            props[k] = v
        end
    end
    _proxyProps[inst] = props
    if parent and _proxyChildren[parent] then
        _proxyChildren[parent][#_proxyChildren[parent] + 1] = inst
    end

    local methodCache = {}

    local function _baseMethod(key)
        if key == "IsA" then
            return function(self, target)
                local p = _proxyProps[_refBaseMap[self] or self] or props
                return _isClassA(p.ClassName or className, hostTostring(target or ""))
            end
        elseif key == "GetService" or key == "getService" then
            return function(self, svcName)
                svcName = hostTostring(svcName or "")
                return _sandboxEnv.game[svcName]
            end
        elseif key == "FindService" then
            return function(self, svcName)
                svcName = hostTostring(svcName or "")
                return _sandboxEnv.game[svcName]
            end
        elseif key == "FindFirstChild" or key == "findFirstChild" then
            return function(self, targetName, recursive)
                local base = _refBaseMap[self] or self
                for _, ch in hostIpairs(_proxyChildren[base] or {}) do
                    local cp = _proxyProps[ch]
                    if cp and cp.Name == targetName then return ch end
                end
                if recursive then
                    local queue = { base }
                    while #queue > 0 do
                        local cur = table.remove(queue, 1)
                        for _, ch in hostIpairs(_proxyChildren[cur] or {}) do
                            local cp = _proxyProps[ch]
                            if cp and cp.Name == targetName then return ch end
                            queue[#queue + 1] = ch
                        end
                    end
                end
                return nil
            end
        elseif key == "FindFirstChildOfClass" or key == "FindFirstChildWhichIsA" then
            return function(self, targetClass)
                local base = _refBaseMap[self] or self
                for _, ch in hostIpairs(_proxyChildren[base] or {}) do
                    local cp = _proxyProps[ch]
                    if cp and (cp.ClassName == targetClass or (key == "FindFirstChildWhichIsA" and _isClassA(cp.ClassName or "", targetClass))) then
                        return ch
                    end
                end
                return nil
            end
        elseif key == "WaitForChild" then
            return function(self, childName)
                local base = _refBaseMap[self] or self
                for _, ch in hostIpairs(_proxyChildren[base] or {}) do
                    local cp = _proxyProps[ch]
                    if cp and cp.Name == childName then return ch end
                end
                return _createInstance("Folder", childName, base)
            end
        elseif key == "GetChildren" or key == "getChildren" then
            return function(self)
                local base = _refBaseMap[self] or self
                local out = {}
                for _, ch in hostIpairs(_proxyChildren[base] or {}) do
                    out[#out + 1] = ch
                end
                return out
            end
        elseif key == "GetDescendants" or key == "getDescendants" then
            return function(self)
                local base = _refBaseMap[self] or self
                local out = {}
                local function walk(node)
                    for _, ch in hostIpairs(_proxyChildren[node] or {}) do
                        out[#out + 1] = ch
                        walk(ch)
                    end
                end
                walk(base)
                return out
            end
        elseif key == "IsDescendantOf" then
            return function(self, ancestor)
                local cur = _proxyParent[_refBaseMap[self] or self]
                local target = _refBaseMap[ancestor] or ancestor
                while cur do
                    if (_refBaseMap[cur] or cur) == target then return true end
                    cur = _proxyParent[cur]
                end
                return false
            end
        elseif key == "IsAncestorOf" then
            return function(self, desc)
                return desc and desc.IsDescendantOf and desc:IsDescendantOf(self) or false
            end
        elseif key == "Clone" or key == "clone" then
            return function(self)
                local p = _proxyProps[_refBaseMap[self] or self] or props
                return _createInstance(p.ClassName or className, p.Name, nil)
            end
        elseif key == "Destroy" or key == "Remove" or key == "destroy" then
            return function(self)
                local base = _refBaseMap[self] or self
                if _editableMeshes[base] then
                    _editableMeshes[base].verts = {}
                    _editableMeshes[base].nextId = 1
                end
                local par = _proxyParent[base]
                if par and _proxyChildren[par] then
                    for i, ch in hostIpairs(_proxyChildren[par]) do
                        if ch == base then table.remove(_proxyChildren[par], i) break end
                    end
                end
                _proxyParent[base] = nil
            end
        elseif key == "ClearAllChildren" then
            return function(self)
                local base = _refBaseMap[self] or self
                for _, ch in hostIpairs(_proxyChildren[base] or {}) do
                    _proxyParent[ch] = nil
                end
                _proxyChildren[base] = {}
            end
        elseif key == "GetAttribute" then
            return function(self, attr)
                local p = _proxyProps[_refBaseMap[self] or self]
                return p and p["__attr_" .. hostTostring(attr)]
            end
        elseif key == "SetAttribute" then
            return function(self, attr, val)
                local p = _proxyProps[_refBaseMap[self] or self]
                if p then p["__attr_" .. hostTostring(attr)] = val end
            end
        elseif key == "GetAttributes" then
            return function() return {} end
        elseif key == "GetFullName" then
            return function(self)
                return _proxyPaths[_refBaseMap[self] or self] or props.Name
            end
        elseif key == "FireServer" or key == "InvokeServer" or key == "Fire" or key == "Invoke" then
            return function(self, ...)
                local path = _proxyPaths[_refBaseMap[self] or self] or props.Name or "Remote"
                _emitLine(string.format("%s:%s(%s)", path, key, _formatArgs(...)))
                return nil
            end
        elseif key == "HttpGet" or key == "HttpGetAsync" then
            return function(self, url)
                _emitLine(string.format("game:%s(%s)", key, _formatArg(url)))
                return ""
            end
        elseif key == "HttpPost" or key == "HttpPostAsync" then
            return function(self, url, data)
                _emitLine(string.format("game:%s(%s, %s)", key, _formatArg(url), _formatArg(data)))
                return ""
            end
        end
        return nil
    end

    local mt = {
        __type = "Instance",
        __tostring = function() return props.Name or className end,
        __metatable = "The metatable is locked",
        __index = function(self, key)
            if key == "Parent" then return _proxyParent[self] end
            if props[key] ~= nil then return props[key] end
            if methodCache[key] then return methodCache[key] end
            local bm = _baseMethod(key)
            if bm then
                methodCache[key] = bm
                return bm
            end
            for _, ch in hostIpairs(_proxyChildren[inst] or {}) do
                local cp = _proxyProps[ch]
                if cp and cp.Name == key then return ch end
            end
            if key == "Heartbeat" or key == "RenderStepped" or key == "Stepped"
                or key == "PreRender" or key == "PostSimulation" or key == "PreSimulation"
                or key == "CharacterAdded" or key == "CharacterRemoving"
                or key == "PlayerAdded" or key == "PlayerRemoving"
                or key == "Changed" or key == "ChildAdded" or key == "ChildRemoved"
                or key == "AncestryChanged" or key == "OnClientEvent" then
                local sig = _makeSignal(key)
                props[key] = sig
                return sig
            end
            -- Fallback generic method for unknown Roblox service/instance calls
            local fn = function(_, ...)
                return nil
            end
            methodCache[key] = fn
            return fn
        end,
        __newindex = function(self, key, val)
            if key == "Parent" then
                local oldPar = _proxyParent[self]
                if oldPar and _proxyChildren[oldPar] then
                    for i, ch in hostIpairs(_proxyChildren[oldPar]) do
                        if ch == self then table.remove(_proxyChildren[oldPar], i) break end
                    end
                end
                _proxyParent[self] = val
                if val and _proxyChildren[val] then
                    _proxyChildren[val][#_proxyChildren[val] + 1] = self
                end
                return
            end
            if key == "Name" then
                props.Name = hostTostring(val or className)
                local par = _proxyParent[self]
                local parPath = par and _proxyPaths[par]
                _proxyPaths[self] = parPath and (parPath .. "." .. props.Name) or props.Name
                return
            end
            props[key] = val
        end,
        __namecall = function(self, ...)
            local method = _currentNamecallMethod
            local fn = self[method]
            if hostType(fn) == "function" then
                return fn(self, ...)
            end
            return nil
        end,
    }
    hostSetmetatable(inst, mt)
    _rawMetaMap[inst] = mt
    return inst
end

local _newEditableMesh
_createInstance = function(className, name, parent, extraProps)
    className = hostTostring(className or "Folder")
    if className == "EditableMesh" and _newEditableMesh then
        local m = _newEditableMesh()
        if parent and _proxyChildren[parent] then
            _proxyParent[m] = parent
            _proxyChildren[parent][#_proxyChildren[parent] + 1] = m
        end
        return m
    end
    local extras = extraProps or {}
    if className == "AnimationTrack" then
        extras.IsPlaying = false
        extras.TimePosition = 0
        extras.Length = 2
        extras.Speed = 1
        extras.Play = function(self) self.IsPlaying = true end
        extras.Stop = function(self) self.IsPlaying = false end
        extras.AdjustSpeed = function(self, s) self.Speed = hostTonumber(s) or 1 end
        extras.GetMarkerReachedSignal = function() return _makeSignal("MarkerReached") end
    elseif className == "Animator" then
        extras.LoadAnimation = function(_, anim)
            return _createInstance("AnimationTrack", "AnimationTrack", nil)
        end
        extras.GetPlayingAnimationTracks = function() return {} end
    elseif className == "Humanoid" then
        extras.Health = 100
        extras.MaxHealth = 100
        extras.WalkSpeed = 16
        extras.JumpPower = 50
        extras.JumpHeight = 7.2
        extras.LoadAnimation = function(_, anim)
            return _createInstance("AnimationTrack", "AnimationTrack", nil)
        end
    elseif className == "BasePart" or className == "Part" or className == "MeshPart" then
        extras.Position = _Vector3.new(0, 0, 0)
        extras.Size = _Vector3.new(4, 1, 2)
        extras.CFrame = _CFrame.new(0, 0, 0)
        extras.Anchored = false
        extras.CanCollide = true
    end
    local obj = _makeInstanceProxy(className, name or className, parent, extras)
    if className == "Humanoid" then
        _createInstance("Animator", "Animator", obj)
    end
    return obj
end

-- Build DataModel (`game`) and Services
local _game = _makeInstanceProxy("DataModel", "Game", nil, {
    PlaceId = 123456789,
    GameId = 987654321,
    JobId = "00000000-0000-0000-0000-000000000000",
    CreatorId = 1,
    IsLoaded = function() return true end,
})
_proxyPaths[_game] = "game"

local _services = {}
local function _registerService(className, extraProps)
    local svc = _makeInstanceProxy(className, className, _game, extraProps)
    _proxyPaths[svc] = (className == "Workspace") and "workspace" or ('game:GetService("' .. className .. '")')
    _services[className] = svc
    return svc
end

-- Workspace with spatial query support
local _workspace = _registerService("Workspace", {
    Gravity = 196.2,
    DistributedGameTime = 10,
    GetPartBoundsInBox = function(self, cf, size, params)
        local out = {}
        local inc = params and params.IncludeInstances
        local exc = params and params.ExcludeInstances
        local excSet = {}
        if hostType(exc) == "table" then
            for _, v in hostIpairs(exc) do excSet[v] = true end
        end
        if hostType(inc) == "table" and #inc > 0 then
            for _, v in hostIpairs(inc) do
                if not excSet[v] then out[#out + 1] = v end
            end
            return out
        end
        for _, ch in hostIpairs(_proxyChildren[self] or {}) do
            if not excSet[ch] then out[#out + 1] = ch end
        end
        return out
    end,
    GetPartBoundsInRadius = function(self, pos, radius, params)
        return self:GetPartBoundsInBox(_CFrame.new(pos), _Vector3.new(radius, radius, radius), params)
    end,
    GetPartsInPart = function(self, part, params)
        return self:GetPartBoundsInBox(_CFrame.new(), _Vector3.new(4, 4, 4), params)
    end,
    Raycast = function() return nil end,
    FindPartOnRay = function() return nil, _Vector3.zero, _Vector3.new(0, 1, 0), nil end,
})
_createInstance("Camera", "CurrentCamera", _workspace, {
    CFrame = _CFrame.new(0, 10, 0),
    ViewportSize = _Vector2.new(1920, 1080),
    FieldOfView = 70,
})
_workspace.CurrentCamera = _workspace:FindFirstChild("CurrentCamera")

-- Players + LocalPlayer + Character
local _localPlayer = _makeInstanceProxy("Player", "Player", nil, {
    UserId = 1234567,
    AccountAge = 1000,
    DisplayName = "Player",
    TeamColor = _BrickColor.White(),
    CameraMinZoomDistance = 0.5,
    CameraMaxZoomDistance = 128,
})
local _character = _createInstance("Model", "Player", _workspace)
local _hrp = _createInstance("Part", "HumanoidRootPart", _character, { Position = _Vector3.new(0, 5, 0), CFrame = _CFrame.new(0, 5, 0) })
_createInstance("Part", "Head", _character, { Position = _Vector3.new(0, 6.5, 0) })
_createInstance("Humanoid", "Humanoid", _character)
_character.PrimaryPart = _hrp
_localPlayer.Character = _character
_localPlayer.CharacterAdded = _makeSignal("CharacterAdded")

local _Players = _registerService("Players", {
    LocalPlayer = _localPlayer,
    MaxPlayers = 50,
    GetPlayers = function() return { _localPlayer } end,
    GetPlayerByUserId = function(_, id) return id == 1234567 and _localPlayer or nil end,
    GetNameFromUserIdAsync = function() return "Player" end,
    GetUserIdFromNameAsync = function() return 1234567 end,
})
_proxyParent[_localPlayer] = _Players
_proxyChildren[_Players][#_proxyChildren[_Players] + 1] = _localPlayer

-- RunService (Non-Studio client)
_registerService("RunService", {
    IsStudio = function() return false end,
    IsClient = function() return true end,
    IsServer = function() return false end,
    IsRunning = function() return true end,
    IsRunMode = function() return false end,
    Heartbeat = _makeSignal("Heartbeat"),
    RenderStepped = _makeSignal("RenderStepped"),
    Stepped = _makeSignal("Stepped"),
    PreRender = _makeSignal("PreRender"),
    PreSimulation = _makeSignal("PreSimulation"),
    PostSimulation = _makeSignal("PostSimulation"),
    BindToRenderStep = function() end,
    UnbindFromRenderStep = function() end,
})

-- CorePackages & CoreGui
_registerService("CorePackages", {})
_registerService("CoreGui", {})
_registerService("ReplicatedStorage", {})
_registerService("ReplicatedFirst", {})
_registerService("StarterGui", {
    SetCore = function() end,
    GetCore = function() return true end,
    SetCoreGuiEnabled = function() end,
    IsCoreGuiEnabled = function() return true end,
})
_registerService("StarterPack", {})
_registerService("StarterPlayer", {})
_registerService("Lighting", { ClockTime = 14, Brightness = 2 })
_registerService("GuiService", { GetGuiInset = function() return _Vector2.new(0, 36), _Vector2.new(0, 0) end })
_registerService("UserInputService", {
    GetMouseLocation = function() return _Vector2.new(960, 540) end,
    GetMouseDelta = function() return _Vector2.new(0, 0) end,
    IsKeyDown = function() return false end,
    IsMouseButtonPressed = function() return false end,
    GetFocusedTextBox = function() return nil end,
})
_registerService("HttpService", {
    JSONEncode = function(_, tbl)
        local function enc(v)
            local t = hostType(v)
            if v == nil then return "null" end
            if t == "boolean" then return v and "true" or "false" end
            if t == "number" then return hostTostring(v) end
            if t == "string" then return _escapeLuaString(v) end
            if t == "table" then
                local isArr = (#v > 0)
                local items = {}
                if isArr then
                    for i = 1, #v do items[i] = enc(v[i]) end
                    return "[" .. table.concat(items, ",") .. "]"
                else
                    for k, val in hostPairs(v) do
                        items[#items + 1] = _escapeLuaString(hostTostring(k)) .. ":" .. enc(val)
                    end
                    return "{" .. table.concat(items, ",") .. "}"
                end
            end
            return "null"
        end
        return enc(tbl)
    end,
    JSONDecode = function() return {} end,
    GenerateGUID = function() return "00000000-0000-4000-8000-000000000000" end,
    GetAsync = function(_, url) _emitLine(string.format('HttpService:GetAsync(%s)', _formatArg(url))); return "" end,
})
_registerService("TweenService", {
    Create = function(_, inst, info, props)
        return _createInstance("Tween", "Tween", nil, {
            Play = function() end,
            Cancel = function() end,
            Pause = function() end,
            Completed = _makeSignal("Completed"),
        })
    end,
})

-- VoiceChatService (real functions so type(...) == "function")
_registerService("VoiceChatService", {
    joinVoice = function() return true end,
    rejoinVoice = function() return true end,
    leaveVoice = function() return true end,
    IsVoiceEnabledForUserIdAsync = function() return false end,
    GetChatGroupsAsync = function() return {} end,
    GetSpeakerVolume = function() return 1.0 end,
    SetSpeakerVolume = function() end,
})

-- SoundService (real functions so type(...) == "function")
_registerService("SoundService", {
    RolloffScale = 1,
    DopplerScale = 1,
    DistanceFactor = 3.33,
    RespectFilteringEnabled = true,
    PlayLocalSound = function() end,
    GetAudioInstances = function() return {} end,
    GetInputDevices = function() return {} end,
    GetOutputDevices = function() return {} end,
})

-- AssetService with stateful EditableMesh
_newEditableMesh = function()
    local mesh = _makeInstanceProxy("EditableMesh", "EditableMesh", nil, nil)
    local store = { verts = {}, nextId = 1 }
    _editableMeshes[mesh] = store
    mesh.AddVertex = function(_, pos)
        local id = store.nextId
        store.verts[id] = pos
        store.nextId = id + 1
        return id
    end
    mesh.GetPosition = function(_, id)
        return store.verts[id] or _Vector3.new(0, 0, 0)
    end
    mesh.SetPosition = function(_, id, pos)
        store.verts[id] = pos
    end
    mesh.GetVertices = function()
        local out = {}
        for id in hostPairs(store.verts) do
            out[#out + 1] = id
        end
        return out
    end
    mesh.AddTriangle = function() return 1 end
    mesh.AddFace = function() return 1 end
    mesh.AddColor = function() return 1 end
    mesh.AddNormal = function() return 1 end
    mesh.AddUV = function() return 1 end
    mesh.Clear = function() store.verts = {}; store.nextId = 1 end
    return mesh
end

_registerService("AssetService", {
    CreateEditableMesh = function() return _newEditableMesh() end,
    CreateEditableMeshAsync = function() return _newEditableMesh() end,
    CreatePlaceAsync = function() return 0 end,
    GetBundleDetailsAsync = function() return {} end,
})

-- Dynamic GetService lookup backed by __ROBLOX_API_REGISTRY
local _gameMt = _rawMetaMap[_game] or hostGetmetatable(_game)
local _origGameIndex = _gameMt.__index
_gameMt.__index = function(self, key)
    if _services[key] then return _services[key] end
    if key == "GetService" or key == "getService" or key == "FindService" then
        return function(_, svcName)
            svcName = hostTostring(svcName or "")
            if _services[svcName] then return _services[svcName] end
            if _apiClasses[svcName] or svcName:match("Service$") or svcName:match("^Core") then
                return _registerService(svcName, {})
            end
            return _registerService(svcName, {})
        end
    end
    local res = _origGameIndex(self, key)
    if res ~= nil then return res end
    return _registerService(hostTostring(key), {})
end

-- Build isolated executor + Roblox sandbox environment
local _waitBudget = 0
local _MAX_WAIT_CALLS = 1500

local function _sandboxType(v)
    local t = hostType(v)
    if t == "table" then
        local mt = _rawMetaMap[v] or hostGetmetatable(v)
        if hostType(mt) == "table" then
            local tp = rawget(mt, "__type")
            if tp == "Instance" then return "userdata" end
            if tp == "Enum" or tp == "EnumItem" or tp == "Enums"
                or tp == "RBXScriptSignal" or tp == "RBXScriptConnection" then
                return "userdata"
            end
        end
    end
    return t
end

local function _sandboxTypeof(v)
    local t = hostType(v)
    if t == "table" or t == "userdata" then
        local mt = _rawMetaMap[v] or hostGetmetatable(v)
        if hostType(mt) == "table" and rawget(mt, "__type") then
            return rawget(mt, "__type")
        end
    end
    return t
end

local _safeDebug = {
    traceback = function(msg) return hostTostring(msg or "") end,
    info = function(target)
        if hostType(target) == "function" then
            return "[C]", 0, "", 0, false
        end
        return "[C]", 0, ""
    end,
    getinfo = function() return { source = "=[C]", short_src = "[C]", what = "C", currentline = -1 } end,
    getmetatable = hostGetmetatable,
    setmetatable = hostSetmetatable,
    getupvalue = debug and debug.getupvalue or function() return nil end,
    setupvalue = debug and debug.setupvalue or function() end,
    setmemorycategory = function() end,
    getmemorycategory = function() return "" end,
    resetmemorycategory = function() end,
    profilebegin = function() end,
    profileend = function() end,
}

local _safeOs = {
    clock = hostClock,
    time  = hostTime,
    date  = hostDate,
    difftime = os.difftime,
    getenv = function() return nil end,
}

local _safeTask = {
    wait = function(dt)
        _waitBudget = _waitBudget + 1
        if _waitBudget > _MAX_WAIT_CALLS or (hostClock() - _startClock) > 12 then
            hostError("__DUMPER2_BUDGET_LIMIT__", 0)
        end
        local step = hostTonumber(dt) or (1 / 60)
        if step < 0 then step = 0 end
        _simTime = _simTime + step
        for _, ch in hostIpairs(_proxyChildren[_workspace] or {}) do end
        -- Advance active AnimationTracks simulated time
        local hb = _services.RunService and _services.RunService.Heartbeat
        if hb and hb.Fire then hb:Fire(step) end
        return step
    end,
    spawn = function(fn, ...)
        if hostType(fn) == "function" then
            local args = hostPack(...)
            hostPcall(fn, hostUnpack(args, 1, args.n))
        end
    end,
    defer = function(fn, ...)
        if hostType(fn) == "function" then
            local args = hostPack(...)
            hostPcall(fn, hostUnpack(args, 1, args.n))
        end
    end,
    delay = function(_, fn, ...)
        if hostType(fn) == "function" then
            local args = hostPack(...)
            hostPcall(fn, hostUnpack(args, 1, args.n))
        end
    end,
    cancel = function() end,
    synchronize = function() end,
    desynchronize = function() end,
}

-- Wrap AnimationTrack TimePosition progression inside task.wait
do
    local _origWait = _safeTask.wait
    local _activeTracks = hostSetmetatable({}, { __mode = "k" })
    local _origCreate = _createInstance
    _createInstance = function(className, name, parent, extraProps)
        local obj = _origCreate(className, name, parent, extraProps)
        if className == "AnimationTrack" then
            _activeTracks[obj] = true
        end
        return obj
    end
    _safeTask.wait = function(dt)
        local step = _origWait(dt)
        for trk in hostPairs(_activeTracks) do
            if trk.IsPlaying then
                trk.TimePosition = (trk.TimePosition or 0) + step * (trk.Speed or 1)
            end
        end
        return step
    end
end

local _virtualFS = {}

local function _makeSandboxEnv()
    local env = {}
    env._G = env
    env._VERSION = "Luau"
    env.shared = {}
    env.game = _game
    env.workspace = _workspace
    env.Workspace = _workspace
    env.script = _createInstance("LocalScript", "LocalScript", _localPlayer)
    env.Enum = _Enum
    env.Instance = {
        new = function(className, parent)
            return _createInstance(className, className, parent)
        end,
        fromExisting = function(other)
            if not other then hostError("Instance.fromExisting requires an Instance", 2) end
            local p = _proxyProps[other]
            return _createInstance(p and p.ClassName or "Folder", p and p.Name or "Instance")
        end,
    }
    env.Vector2 = _Vector2
    env.Vector3 = _Vector3
    env.CFrame  = _CFrame
    env.Color3  = _Color3
    env.BrickColor = _BrickColor
    env.UDim    = _UDim
    env.UDim2   = _UDim2
    env.TweenInfo = _TweenInfo
    env.Ray     = _Ray
    env.Rect    = _Rect
    env.Region3 = _Region3
    env.NumberRange = _NumberRange
    env.NumberSequence = _NumberSequence
    env.NumberSequenceKeypoint = _NumberSequenceKeypoint
    env.ColorSequence = _ColorSequence
    env.ColorSequenceKeypoint = _ColorSequenceKeypoint
    env.PhysicalProperties = _PhysicalProperties
    env.Faces   = _Faces
    env.Axes    = _Axes
    env.OverlapParams = _OverlapParams
    env.RaycastParams = _RaycastParams
    env.PathWaypoint = _PathWaypoint
    env.Random  = _Random
    env.DateTime = _DateTime
    env.Font    = _Font
    env.Content = { none = {}, fromUri = function(u) return { Uri = u } end, fromObject = function(o) return { Object = o } end }
    env.Secret  = { new = function() return {} end }
    env.SharedTable = { new = function(t) return t or {} end, size = function(t) local n = 0 for _ in hostPairs(t or {}) do n = n + 1 end return n end }
    env.SecurityCapabilities = { fromCurrent = function() return {} end }

    env.math = math
    env.string = string
    env.table = table
    env.coroutine = coroutine
    env.utf8 = utf8
    env.bit32 = bit32
    env.buffer = buffer
    env.os = _safeOs
    env.debug = _safeDebug
    env.task = _safeTask
    env.wait = _safeTask.wait
    env.spawn = _safeTask.spawn
    env.delay = _safeTask.delay
    env.tick = function() return hostTime() + _simTime end
    env.time = function() return _simTime end
    env.elapsedTime = function() return hostClock() - _startClock end

    env.print = function(...)
        local parts = hostPack(...)
        local out = {}
        for i = 1, parts.n do
            out[i] = _formatArg(parts[i], 0)
        end
        _emitLine("print(" .. table.concat(out, ", ") .. ")")
    end
    env.warn = function(...)
        local parts = hostPack(...)
        local out = {}
        for i = 1, parts.n do
            out[i] = _formatArg(parts[i], 0)
        end
        _emitLine("warn(" .. table.concat(out, ", ") .. ")")
    end
    env.error = hostError
    env.assert = assert
    env.pcall = hostPcall
    env.xpcall = hostXpcall
    env.tostring = hostTostring
    env.tonumber = hostTonumber
    env.type = _sandboxType
    env.typeof = _sandboxTypeof
    env.select = select
    env.ipairs = hostIpairs
    env.pairs = hostPairs
    env.next = hostNext
    env.rawget = hostRawget
    env.rawset = hostRawset
    env.rawequal = hostRawequal
    env.rawlen = hostRawlen
    env.unpack = hostUnpack
    env.setmetatable = function(t, mt)
        _rawMetaMap[t] = mt
        return hostSetmetatable(t, mt)
    end
    env.getmetatable = function(t)
        if _proxyTypes[t] then return "The metatable is locked" end
        return hostGetmetatable(t)
    end
    env.newproxy = newproxy or function(withMt)
        local p = hostSetmetatable({}, withMt and {} or nil)
        return p
    end

    env.require = function(mod)
        if hostType(mod) == "string" then
            hostError("require: blocked module " .. mod, 2)
        end
        return {}
    end
    env.getfenv = function() return env end
    env.setfenv = function(fn, newEnv)
        if hostType(fn) == "function" and hostSetfenv then
            return hostSetfenv(fn, hostType(newEnv) == "table" and newEnv or env)
        end
        return fn
    end

    -- Executor APIs
    env.identifyexecutor = function() return "kenV1", "2.0" end
    env.getexecutorname = function() return "kenV1" end
    env.getexecutorversion = function() return "2.0" end
    env.getgenv = function() return env end
    env.getrenv = function() return env end
    env.getsenv = function() return env end
    env.getmenv = function() return {} end
    env.gethui  = function() return _services.CoreGui end
    env.checkcaller = function() return true end
    env.getcallingscript = function() return env.script end
    env.getnamecallmethod = function() return _currentNamecallMethod end
    env.setnamecallmethod = function(m) _currentNamecallMethod = hostTostring(m or "") end
    env.cloneref = function(inst)
        if not _proxyTypes[inst] then return inst end
        local base = _refBaseMap[inst] or inst
        local p = _proxyProps[base] or {}
        local clone = _makeInstanceProxy(p.ClassName or "Instance", p.Name or "Instance", _proxyParent[base], p)
        _refBaseMap[clone] = base
        _proxyPaths[clone] = _proxyPaths[base]
        return clone
    end
    env.compareinstances = function(a, b)
        return (_refBaseMap[a] or a) == (_refBaseMap[b] or b)
    end
    env.newcclosure = function(fn)
        if hostType(fn) ~= "function" then return fn end
        local w = function(...) return fn(...) end
        _cclosureSet[w] = true
        return w
    end
    env.iscclosure = function(fn)
        if hostType(fn) ~= "function" then return false end
        if _cclosureSet[fn] then return true end
        if debug and debug.info then
            local ok, src = hostPcall(debug.info, fn, "s")
            if ok and src == "[C]" then return true end
        end
        return false
    end
    env.islclosure = function(fn) return hostType(fn) == "function" and not env.iscclosure(fn) end
    env.isexecutorclosure = function(fn) return hostType(fn) == "function" and (_cclosureSet[fn] == true or env.islclosure(fn)) end
    env.isourclosure = env.isexecutorclosure
    env.checkclosure = env.isexecutorclosure
    env.clonefunction = function(fn)
        if hostType(fn) ~= "function" then return fn end
        return function(...) return fn(...) end
    end
    env.hookfunction = function(target, replacement)
        _hookedMap[target] = replacement
        return target
    end
    env.replaceclosure = env.hookfunction
    env.isfunctionhooked = function(fn) return _hookedMap[fn] ~= nil end
    env.restorefunction = function(fn) _hookedMap[fn] = nil end
    env.getrawmetatable = function(obj) return _rawMetaMap[obj] or hostGetmetatable(obj) end
    env.setrawmetatable = function(obj, mt) _rawMetaMap[obj] = mt; return hostSetmetatable(obj, mt) end
    env.setreadonly = function(t, flag) _readOnlyMap[t] = (flag == true) end
    env.isreadonly = function(t) return _readOnlyMap[t] == true end
    env.make_readonly = function(t) _readOnlyMap[t] = true end
    env.make_writeable = function(t) _readOnlyMap[t] = false end
    env.hookmetamethod = function(obj, method, fn)
        local mt = env.getrawmetatable(obj)
        if hostType(mt) ~= "table" then return nil end
        local old = rawget(mt, method)
        rawset(mt, method, fn)
        return old
    end
    env.getgc = function() return {} end
    env.filtergc = function() return {} end
    env.getreg = function() return {} end
    env.getinstances = function() return {} end
    env.getnilinstances = function() return {} end
    env.getscripts = function() return { env.script } end
    env.getrunningscripts = function() return { env.script } end
    env.getloadedmodules = function() return {} end
    env.getconnections = function() return {} end
    env.firesignal = function() end
    env.fireclickdetector = function() end
    env.firetouchinterest = function() end
    env.fireproximityprompt = function() end
    env.replicatesignal = function() end
    env.gethiddenproperty = function(obj, k)
        local ok, v = hostPcall(function() return obj[k] end)
        return ok and v or nil, false
    end
    env.sethiddenproperty = function(obj, k, v)
        hostPcall(function() obj[k] = v end)
        return true
    end
    env.isscriptable = function() return true end
    env.setscriptable = function() return true end
    env.gethwid = function() return "00000000-0000-0000-0000-000000000000" end
    env.getfpscap = function() return 60 end
    env.setfpscap = function() end
    env.getthreadidentity = function() return 8 end
    env.setthreadidentity = function() end
    env.getidentity = env.getthreadidentity
    env.setidentity = env.setthreadidentity
    env.setclipboard = function(s) _emitLine("-- clipboard: " .. hostTostring(s)) end
    env.toclipboard = env.setclipboard
    env.getclipboard = function() return "" end
    env.isrbxactive = function() return true end
    env.iswindowactive = function() return true end
    env.decompile = function() return "-- decompiled" end
    env.getscriptbytecode = function() return "" end
    env.getscripthash = function() return "00000000" end
    env.getfunctionhash = function() return "00000000" end
    env.readfile = function(p) return _virtualFS[p] or "" end
    env.writefile = function(p, c) _virtualFS[p] = hostTostring(c or "") end
    env.appendfile = function(p, c) _virtualFS[p] = (_virtualFS[p] or "") .. hostTostring(c or "") end
    env.isfile = function(p) return _virtualFS[p] ~= nil end
    env.isfolder = function() return false end
    env.makefolder = function() end
    env.delfile = function(p) _virtualFS[p] = nil end
    env.delfolder = function() end
    env.listfiles = function() return {} end
    env.request = function(opts)
        local url = hostType(opts) == "table" and (opts.Url or opts.url) or opts
        _emitLine(string.format("request({ Url = %s })", _formatArg(url)))
        return { StatusCode = 200, Success = true, Body = "", Headers = {} }
    end
    env.http_request = env.request
    env.http = { request = env.request }
    local _b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local function _b64Encode(data)
        data = hostTostring(data or "")
        return ((data:gsub(".", function(x)
            local r, b = "", x:byte()
            for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
            return r
        end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
            if #x < 6 then return "" end
            local c = 0
            for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
            return _b64chars:sub(c + 1, c + 1)
        end) .. ({ "", "==", "=" })[#data % 3 + 1])
    end
    local function _b64Decode(data)
        data = hostTostring(data or ""):gsub("[^" .. _b64chars .. "=]", "")
        return (data:gsub(".", function(x)
            if x == "=" then return "" end
            local r, f = "", (_b64chars:find(x, 1, true) - 1)
            for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0") end
            return r
        end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
            if #x ~= 8 then return "" end
            local c = 0
            for i = 1, 8 do c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0) end
            return string.char(c)
        end))
    end
    env.crypt = {
        base64encode = _b64Encode,
        base64decode = _b64Decode,
        base64 = { encode = _b64Encode, decode = _b64Decode },
        hash = function(s) return hostTostring(s or "") end,
    }
    env.base64 = { encode = _b64Encode, decode = _b64Decode }
    env.bit = bit32
    env.syn = {
        request = env.request,
        crypt = env.crypt,
        protect_gui = function() end,
        unprotect_gui = function() end,
        set_thread_identity = env.setthreadidentity,
        get_thread_identity = env.getthreadidentity,
    }
    env.fluxus = { request = env.request }
    env.lz4compress = function(s) return s end
    env.lz4decompress = function(s) return s end
    env.Drawing = { new = function() return { Visible = false, Remove = function() end, Destroy = function() end } end }
    env.WebSocket = { connect = function(url) _emitLine(string.format("WebSocket.connect(%s)", _formatArg(url))); return { Send = function() end, Close = function() end, OnMessage = _makeSignal("OnMessage"), OnClose = _makeSignal("OnClose") } end }

    -- Hooked loadstring/load that captures and runs nested stages inside this same sandbox
    env.loadstring = function(src, chunkName, _mode, customEnv)
        if hostType(src) ~= "string" then
            return nil, "loadstring expected string"
        end
        if #src >= 16 and not _seenStageHash[src] and _stageDepth < _MAX_STAGE_DEPTH then
            _seenStageHash[src] = true
            _emitLine(src)
        end
        local fn, loadErr = hostLoad(src, chunkName or "dumper2_stage", "t", hostType(customEnv) == "table" and customEnv or env)
        if not fn then
            return nil, loadErr
        end
        return function(...)
            _stageDepth = _stageDepth + 1
            local results = hostPack(hostPcall(fn, ...))
            _stageDepth = _stageDepth - 1
            if not results[1] then
                hostError(results[2], 0)
            end
            return hostUnpack(results, 2, results.n)
        end
    end
    env.load = env.loadstring

    return env
end

_sandboxEnv = _makeSandboxEnv()

-- Compile and execute the target input script inside _sandboxEnv
local mainFn, compileErr = hostLoad(SOURCE_CODE, "=dumper2_target", "t", _sandboxEnv)
if not mainFn then
    io.stderr:write("[dumper2] compile error: " .. hostTostring(compileErr) .. "\n")
    os.exit(1)
end

local ok, runErr = hostPcall(mainFn)
if not ok then
    local errStr = hostTostring(runErr or "")
    if not errStr:find("__DUMPER2_BUDGET_LIMIT__", 1, true) then
        io.stderr:write("[dumper2] runtime notice: " .. errStr .. "\n")
    end
end

-- Write captured output
local outputText = table.concat(_capturedLines, "\n")
local outFile, outErr = hostIoOpen(OUTPUT_PATH, "wb")
if not outFile then
    io.stderr:write("[dumper2] failed to open output: " .. hostTostring(outErr) .. "\n")
    os.exit(1)
end
outFile:write(outputText)
outFile:close()

io.stderr:write(string.format("[dumper2] done: lines=%d elapsed=%.2fs\n", _capturedCount, hostClock() - _startClock))
os.exit(0)
