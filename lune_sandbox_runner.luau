-- Lune sandbox host: loads the selected engine inside an isolated Luau environment.
-- User input runs through a minimal file proxy with no direct access to @lune, network, or process APIs.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local argv = table.clone(process.args)
if argv[1] == "--" then
    table.remove(argv, 1)
end

local enginePath = table.remove(argv, 1)
local inputPath = table.remove(argv, 1)
local outputPath = table.remove(argv, 1)
local scratchPath = "/tmp/lune-runner-home/loaded.lua"
local virtualFiles = {}

if type(enginePath) ~= "string" or type(inputPath) ~= "string" or type(outputPath) ~= "string" then
    error("usage: lune_sandbox_runner.luau -- ENGINE INPUT OUTPUT", 0)
end
local registryPath = enginePath:gsub("[^/]+$", "roblox_api_registry.luau")
if not fs.isFile(registryPath) then
    error("engine registry unavailable", 0)
end

local hostPrint = print
local hostClock = os.clock
local hostTime = os.time
local hostDate = os.date
local hostTraceback = debug.traceback
local hostSetfenv = setfenv

local function blocked(name)
    return function(...)
        error(name .. ": not available", 0)
    end
end

local function conciseFailure(message)
    local text = tostring(message or ""):gsub("\r", "")
    local syntax = text:match("[Ss]yntax error:%s*([^\n]+)")
    if syntax then
        syntax = syntax:gsub("^bypassed:%d+:%s*", "")
        syntax = syntax:gsub("^script[^:]*:%d+:%s*", "")
        return "Syntax error: " .. syntax
    end
    local attempt = text:match("(attempt to [^\n]+)")
    if attempt then return "Runtime error: " .. attempt end
    local loadError = text:match("load error:%s*([^\n]+)")
    if loadError then return "Load error: " .. loadError end
    local first = text:match("([^\n]+)") or "Execution failed"
    first = first:gsub("^engine:%d+:%s*", "")
    first = first:gsub("^%[internal%]%s*", "")
    return first
end

local function joinArgs(separator, ...)
    local values = table.pack(...)
    local parts = table.create(values.n)
    for index = 1, values.n do
        parts[index] = values[index] == nil and "nil" or tostring(values[index])
    end
    return table.concat(parts, separator)
end

local function makeReader(contents)
    local closed = false
    local pos = 1
    local len = #contents
    local function readLine(keepNewline)
        if pos > len then return nil end
        local nl = contents:find("\n", pos, true)
        if not nl then
            local tail = contents:sub(pos)
            pos = len + 1
            return tail
        end
        local finish = keepNewline and nl or (nl - 1)
        local line = contents:sub(pos, finish)
        if not keepNewline and line:sub(-1) == "\r" then
            line = line:sub(1, -2)
        end
        pos = nl + 1
        return line
    end
    return table.freeze({
        read = function(_, mode)
            if closed then return nil end
            if mode == nil or mode == "*l" or mode == "l" then
                return readLine(false)
            end
            if mode == "*L" or mode == "L" then
                return readLine(true)
            end
            if mode == "*a" or mode == "a" or mode == "*all" then
                if pos > len then return "" end
                local rest = contents:sub(pos)
                pos = len + 1
                return rest
            end
            if type(mode) == "number" then
                if mode <= 0 then return pos <= len and "" or nil end
                if pos > len then return nil end
                local stop = math.min(len, pos + math.floor(mode) - 1)
                local chunk = contents:sub(pos, stop)
                pos = stop + 1
                return chunk
            end
            return nil
        end,
        close = function()
            closed = true
            return true
        end,
        lines = function(_, ...)
            local mode = ...
            return function()
                if closed then return nil end
                if mode == "*L" or mode == "L" then return readLine(true) end
                return readLine(false)
            end
        end,
        seek = function(_, whence, offset)
            if closed then return nil, "closed file" end
            local base = pos - 1
            if whence == "set" then base = 0
            elseif whence == "end" then base = len end
            local target = math.max(0, math.min(len, base + (tonumber(offset) or 0)))
            pos = target + 1
            return target
        end,
    })
end

local function makeWriter(path, append)
    local pieces = {}
    if append and fs.isFile(path) then
        pieces[1] = fs.readFile(path)
    end
    local function persist()
        fs.writeFile(path, table.concat(pieces))
    end
    if not append then
        persist()
    end
    local closed = false
    return table.freeze({
        write = function(_, ...)
            if closed then error("io.write: closed file", 0) end
            pieces[#pieces + 1] = joinArgs("", ...)
            return true
        end,
        close = function()
            if not closed then
                persist()
                closed = true
            end
            return true
        end,
        flush = function()
            if closed then return nil, "closed file" end
            persist()
            return true
        end,
        seek = function() return 0 end,
    })
end

local function makeVirtualWriter(path, append)
    local pieces = {}
    if append and virtualFiles[path] ~= nil then
        pieces[1] = virtualFiles[path]
    end
    local closed = false
    return table.freeze({
        write = function(_, ...)
            if closed then error("io.write: closed file", 0) end
            pieces[#pieces + 1] = joinArgs("", ...)
            return true
        end,
        close = function()
            if not closed then
                virtualFiles[path] = table.concat(pieces)
                closed = true
            end
            return true
        end,
        flush = function() return true end,
        seek = function() return 0 end,
    })
end

local function isVirtualWorkspacePath(path)
    return path:match("^workspace/[A-Za-z0-9_./%-]+$") ~= nil
        and not path:find("..", 1, true)
        and not path:find("//", 1, true)
end

local function safeOpen(path, mode)
    if type(path) ~= "string" then
        error("io.open: path must be a string", 0)
    end
    mode = mode or "r"
    if isVirtualWorkspacePath(path) then
        if mode:find("r", 1, true) then
            if virtualFiles[path] == nil then return nil, "file not found" end
            return makeReader(virtualFiles[path])
        end
        if mode:find("w", 1, true) or mode:find("a", 1, true) then
            return makeVirtualWriter(path, mode:find("a", 1, true) ~= nil)
        end
        return nil, "unsupported mode"
    end
    if path == inputPath and mode:find("r", 1, true) then
        return makeReader(fs.readFile(inputPath))
    end
    if path == outputPath and mode:find("r", 1, true) then
        if fs.isFile(outputPath) then
            return makeReader(fs.readFile(outputPath))
        end
        return nil, "file not found"
    end
    if path == outputPath and (mode:find("w", 1, true) or mode:find("a", 1, true)) then
        return makeWriter(outputPath, mode:find("a", 1, true) ~= nil)
    end
    if path == "/tmp/loaded.lua" and mode:find("w", 1, true) then
        return makeWriter(scratchPath, false)
    end
    return nil, "permission denied"
end

local safeIo = {
    open = safeOpen,
    lines = blocked("io.lines"),
    popen = blocked("io.popen"),
    tmpfile = blocked("io.tmpfile"),
    input = blocked("io.input"),
    output = blocked("io.output"),
    write = function(...) hostPrint(joinArgs("", ...)) end,
    stdout = table.freeze({ write = function(_, ...) hostPrint(joinArgs("", ...)) end }),
    stderr = table.freeze({ write = function(_, ...) hostPrint(joinArgs("", ...)) end }),
}

local safeOs = {
    clock = hostClock,
    time = hostTime,
    date = hostDate,
    difftime = os.difftime,
    getenv = function() return nil end,
    execute = blocked("os.execute"),
    remove = blocked("os.remove"),
    rename = blocked("os.rename"),
    tmpname = blocked("os.tmpname"),
    exit = function(code) error("__LUNE_EXIT__" .. tostring(code or 0), 0) end,
}

local safeDebug = {
    traceback = function(message)
        return conciseFailure(message)
    end,
    info = function() return nil end,
    getinfo = function() return { source = "[internal]", short_src = "[internal]" } end,
    getmetatable = getmetatable,
    setmetatable = setmetatable,
    getupvalue = debug.getupvalue,
    setupvalue = debug.setupvalue,
    getlocal = blocked("debug.getlocal"),
    setlocal = blocked("debug.setlocal"),
    getregistry = blocked("debug.getregistry"),
    upvalueid = blocked("debug.upvalueid"),
    upvaluejoin = blocked("debug.upvaluejoin"),
    sethook = blocked("debug.sethook"),
}

local safeString = table.clone(string)
safeString.dump = blocked("string.dump")
local safeTable = table.clone(table)
local safeMath = table.clone(math)
local safeCoroutine = table.clone(coroutine)
local safeUtf8 = table.clone(utf8)
local safeBuffer = type(buffer) == "table" and table.clone(buffer) or {}

local nativeRuntimeVersion = _VERSION
local environment = {}
local registryChunk = luau.load(fs.readFile(registryPath), {
    debugName = "@roblox_api_registry",
    environment = {},
})
local apiRegistry = registryChunk()
if type(apiRegistry) ~= "table" then
    error("engine registry invalid", 0)
end
environment._G = environment
environment.arg = { [0] = enginePath, [1] = inputPath, [2] = outputPath }
environment.io = safeIo
environment.os = safeOs
environment.debug = safeDebug
environment.string = safeString
environment.table = safeTable
environment.math = safeMath
environment.coroutine = safeCoroutine
environment.utf8 = safeUtf8
environment.buffer = safeBuffer
environment.Instance = {}
environment.Vector3 = {}
environment.task = {}
environment.require = blocked("require")
environment.dofile = blocked("dofile")
environment.loadfile = blocked("loadfile")
environment.package = nil
environment.socket = nil
environment.ffi = nil
environment.shared = {}
environment._VERSION = nativeRuntimeVersion
environment.__ROBLOX_API_REGISTRY = apiRegistry
environment.print = function(...) hostPrint(joinArgs("\t", ...)) end
environment.warn = environment.print
environment.getfenv = function() return environment end
environment.setfenv = function(target, _requestedEnvironment)
    if type(target) ~= "function" then
        error("setfenv: target must be a function", 0)
    end
    return hostSetfenv(target, environment)
end

local function hardenRequestedEnvironment(requestedEnvironment)
    if type(requestedEnvironment) ~= "table" then return environment end
    local hardened = {
        _G = nil,
        os = safeOs,
        debug = rawget(requestedEnvironment, "debug") or safeDebug,
        string = safeString,
        table = safeTable,
        math = safeMath,
        coroutine = safeCoroutine,
        utf8 = safeUtf8,
        buffer = safeBuffer,
        _VERSION = rawget(requestedEnvironment, "_VERSION") or nativeRuntimeVersion,
    }
    for key, value in pairs(requestedEnvironment) do
        if hardened[key] == nil then
            hardened[key] = value
        end
    end
    for _, key in ipairs({
        "game", "workspace", "script", "Instance", "Vector2", "Vector2int16", "Vector3", "Vector3int16",
        "CFrame", "Color3", "BrickColor", "ColorSequence", "ColorSequenceKeypoint",
        "NumberSequence", "NumberSequenceKeypoint", "NumberRange", "PhysicalProperties",
        "Faces", "Axes", "Region3", "Region3int16", "PathWaypoint", "Rect", "Ray",
        "RaycastParams", "OverlapParams", "RaycastResult", "TweenInfo", "Random",
        "DateTime", "Font", "Content", "Secret", "SharedTable", "Path2DControlPoint",
        "FloatCurveKey", "RotationCurveKey", "DockWidgetPluginGuiInfo", "CatalogSearchParams",
        "SecurityCapabilities", "Enum", "task", "typeof", "time", "elapsedTime",
        "print", "warn", "error", "assert", "pcall", "xpcall", "tostring", "tonumber",
        "type", "select", "ipairs", "pairs", "next", "rawget", "rawset", "rawequal",
        "rawlen", "setmetatable", "getmetatable", "unpack", "bit32", "utf8", "table",
        "string", "math", "coroutine", "buffer", "os", "debug", "shared", "tick",
        "wait", "spawn", "delay", "newproxy",
        "cloneref", "compareinstances", "identifyexecutor", "getexecutorname", "getexecutorversion",
        "getgenv", "getrenv", "getsenv", "getmenv", "getgc", "filtergc", "getreg",
        "getinstances", "getnilinstances", "getscripts", "getrunningscripts", "getloadedmodules",
        "getconnections", "firesignal", "fireclickdetector", "firetouchinterest", "fireproximityprompt",
        "replicatesignal", "hookfunction", "hookmetamethod", "restorefunction", "clonefunction",
        "newcclosure", "iscclosure", "islclosure", "isexecutorclosure", "isourclosure",
        "checkcaller", "getcallingscript", "getnamecallmethod", "setnamecallmethod",
        "getrawmetatable", "setrawmetatable", "setreadonly", "isreadonly", "make_writeable", "make_readonly",
        "gethiddenproperty", "sethiddenproperty", "isscriptable", "setscriptable",
        "getconstants", "getconstant", "setconstant", "getupvalues", "getupvalue", "setupvalue",
        "getprotos", "getproto", "getstack", "setstack", "getinfo",
        "getthreadidentity", "setthreadidentity", "getidentity", "setidentity", "gethwid",
        "getfpscap", "setfpscap", "getfflag", "setfflag", "isnetworkowner",
        "setsimulationradius", "getsimulationradius", "request", "http_request", "http",
        "crypt", "base64", "lz4compress", "lz4decompress", "bit", "Drawing", "WebSocket",
        "cache", "gethui", "setclipboard", "toclipboard", "getclipboard",
        "queue_on_teleport", "getcustomasset", "isrbxactive", "iswindowactive",
        "decompile", "getscriptbytecode", "getscripthash", "getfunctionhash", "getscriptclosure",
        "readfile", "writefile", "appendfile", "loadfile", "dofile", "isfile", "isfolder",
        "makefolder", "delfolder", "delfile", "listfiles",
        "rconsolecreate", "rconsoleprint", "rconsoleinfo", "rconsolewarn", "rconsoleerr",
        "rconsoleclear", "rconsoleinput", "rconsoledestroy", "rconsoletitle",
        "run_on_actor", "getactors", "create_comm_channel", "get_comm_channel",
    }) do
        if hardened[key] == nil then
            local ok, value = pcall(function() return requestedEnvironment[key] end)
            if ok and value ~= nil then hardened[key] = value end
        end
    end
    hardened.getfenv = function()
        return hardened
    end
    hardened._G = hardened
    local blockedLookup = {
        arg = true, io = true, require = true, dofile = true, loadfile = true,
        package = true, socket = true, ffi = true, collectgarbage = true,
        setfenv = true, dumperState = true, __ROBLOX_API_REGISTRY = true,
    }
    -- Luau resolves the built-in require even when a metatable lookup returns
    -- nil/false. Shadow it with a real blocked function and hide that guard
    -- from raw environment inspection and enumeration.
    local blockedRequire = blocked("require")
    hardened.require = blockedRequire
    local nativeRawget, nativeNext, nativePairs = rawget, next, pairs
    hardened.rawget = function(tableValue, key)
        if tableValue == hardened and blockedLookup[key] then return nil end
        return nativeRawget(tableValue, key)
    end
    local function hardenedNext(iterated, previous)
        if iterated ~= hardened then return nativeNext(iterated, previous) end
        local key, value = nativeNext(hardened, previous)
        while key ~= nil and blockedLookup[key] do
            key, value = nativeNext(hardened, key)
        end
        return key, value
    end
    hardened.next = hardenedNext
    hardened.pairs = function(iterated)
        if iterated ~= hardened then return nativePairs(iterated) end
        return hardenedNext, hardened, nil
    end
    setmetatable(hardened, {
        __index = function(_, key)
            if blockedLookup[key] then return false end
            return requestedEnvironment[key]
        end,
    })
    return hardened
end

-- Re-harden requested environments passed to setfenv so user closures cannot access host proxies.
environment.setfenv = function(target, requestedEnvironment)
    if type(target) ~= "function" then
        error("setfenv: target must be a function", 0)
    end
    return hostSetfenv(target, hardenRequestedEnvironment(requestedEnvironment))
end

environment.loadstring = function(source, chunkName, _mode, requestedEnvironment)
    local targetEnvironment = hardenRequestedEnvironment(requestedEnvironment)
    local ok, compiled = pcall(luau.load, source, {
        debugName = chunkName or "Obfuscated_Script",
        environment = targetEnvironment,
    })
    if not ok then
        return nil, tostring(compiled)
    end
    return compiled
end
environment.load = environment.loadstring

local engineSource = fs.readFile(enginePath)
local engine = luau.load(engineSource, {
    debugName = "@engine",
    environment = environment,
})

local ok, err = xpcall(engine, function(message)
    return conciseFailure(message)
end)
if not ok then
    local message = tostring(err)
    if not message:find("__LUNE_EXIT__0", 1, true) then
        hostPrint("Error: " .. conciseFailure(message))
        process.exit(1)
    end
end
