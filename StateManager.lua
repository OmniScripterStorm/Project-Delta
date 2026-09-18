-- ============================================================================
-- StateManager.luau (State & Configuration Layer)
-- ============================================================================

local HttpService = game:GetService("HttpService")

local StateManager = {}
StateManager.__index = StateManager

function StateManager.new(configFile)
    local self = setmetatable({
        _file = configFile or "NL_Settings.json",
        _listeners = {},
        _saveDebounce = false,
        _lastSaveTick = 0,
        
        Toggles = {
            Aimbot = false,
            SilentAim = false,
			RealisticAim = true,
            ESP = false,
            NoFog = false,
            Fullbright = false,
            NoGrass = false,
            FriendCheck = false,
            WallCheck = false,
            NPCs = false,
            FOVChanger = false,
            FOVCircle = false,
            BigHeads = false,
            FPSHud = true,
            Radar = false,
            FPSBoost = false,
        },
        
        Settings = {
            AimbotSmoothness = 0.4,
            AimbotFOV = 200,
            AimbotYOffset = 0,
            AimbotTarget = "Head",
            SilentAimFOV = 200,
            SilentAimTarget = "Head",
            CameraFOV = 70,
            ChamsTextSize = 13,
            VisibleColor = Color3.fromRGB(46, 204, 113),
            HiddenColor = Color3.fromRGB(231, 76, 60),
            ZoomFOV = 20,
            BigHeadsSize = 3.25,
            RadarSize = 200,
            RadarRange = 150,
            PredictionMultiplier = 1.0,
        },
        
        Keybinds = {
            OpenKey = Enum.KeyCode.RightShift,
            ZoomKey = Enum.KeyCode.LeftAlt,
            Aimbot = nil,
            SilentAim = nil,
            ESP = nil,
            FOVChanger = nil,
        },
        
        Indices = {
            CurrentTargetIdx = 1,
            CurrentSilentTargetIdx = 1,
            VisibleColorIdx = 1,
            HiddenColorIdx = 2,
            RingColorIdx = 1,
            ThemeIndex = 1,
        },
    }, StateManager)

    return self
end

function StateManager:SetToggle(key, value)
    local old = self.Toggles[key]
    if old ~= value then
        self.Toggles[key] = value
        self:_Dispatch("Toggle_" .. key, value, old)
        self:ScheduleSave()
    end
end

function StateManager:SetSetting(key, value)
    local old = self.Settings[key]
    if old ~= value then
        self.Settings[key] = value
        self:_Dispatch("Setting_" .. key, value, old)
        self:ScheduleSave()
    end
end

function StateManager:Subscribe(eventName, callback)
    self._listeners[eventName] = self._listeners[eventName] or {}
    table.insert(self._listeners[eventName], callback)
end

function StateManager:_Dispatch(eventName, ...)
    if self._listeners[eventName] then
        for _, cb in ipairs(self._listeners[eventName]) do
            task.spawn(cb, ...)
        end
    end
end

function StateManager:Save()
    local now = tick()
    if self._saveDebounce and (now - self._lastSaveTick < 0.5) then return false end
    self._saveDebounce = true
    self._lastSaveTick = now

    -- Deep copy and serialize Settings (prevents mutating runtime Color3 objects)
    local serializedSettings = {}
    for k, v in pairs(self.Settings) do
        if typeof(v) == "Color3" then
            serializedSettings[k] = { v.R, v.G, v.B }
        else
            serializedSettings[k] = v
        end
    end

    -- Deep copy and serialize Keybinds
    local serializedKeybinds = {}
    for k, v in pairs(self.Keybinds) do
        serializedKeybinds[k] = (typeof(v) == "EnumItem" and v.Name) or nil
    end

    -- Deep copy Toggles & Indices
    local serializedToggles = {}
    for k, v in pairs(self.Toggles) do
        serializedToggles[k] = v
    end

    local serializedIndices = {}
    for k, v in pairs(self.Indices) do
        serializedIndices[k] = v
    end

    local serialized = {
        Toggles = serializedToggles,
        Settings = serializedSettings,
        Indices = serializedIndices,
        Keybinds = serializedKeybinds,
    }

    local success, json = pcall(HttpService.JSONEncode, HttpService, serialized)
    if success and typeof(writefile) == "function" then
        pcall(writefile, self._file, json)
    end

    self._saveDebounce = false
    return true
end

function StateManager:Load()
    if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then return end
    if not isfile(self._file) then return end

    local success, json = pcall(readfile, self._file)
    if not success or not json or json == "" then return end

    local decodeOk, data = pcall(HttpService.JSONDecode, HttpService, json)
    if not decodeOk or type(data) ~= "table" then return end

    -- 1. Hydrate Toggles
    if type(data.Toggles) == "table" then
        for k, v in pairs(data.Toggles) do
            if self.Toggles[k] ~= nil and type(v) == "boolean" then
                self.Toggles[k] = v
            end
        end
    end

    -- 2. Hydrate Indices
    if type(data.Indices) == "table" then
        for k, v in pairs(data.Indices) do
            if self.Indices[k] ~= nil and type(v) == "number" then
                self.Indices[k] = v
            end
        end
    end

    -- 3. Hydrate Settings & Reconstruct Color3 objects
    if type(data.Settings) == "table" then
        for k, v in pairs(data.Settings) do
            if self.Settings[k] ~= nil then
                if (k == "VisibleColor" or k == "HiddenColor") and type(v) == "table" then
                    self.Settings[k] = Color3.new(v[1] or 1, v[2] or 1, v[3] or 1)
                else
                    self.Settings[k] = v
                end
            end
        end
    end

    -- 4. Hydrate Keybinds & Reconstruct Enum.KeyCode instances
    if type(data.Keybinds) == "table" then
        for k, v in pairs(data.Keybinds) do
            if self.Keybinds[k] ~= nil and type(v) == "string" then
                pcall(function()
                    if Enum.KeyCode[v] then
                        self.Keybinds[k] = Enum.KeyCode[v]
                    end
                end)
            end
        end
    end
end

function StateManager:ScheduleSave()
    task.spawn(function()
        self:Save()
    end)
end

return StateManager