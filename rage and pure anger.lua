-- Napoleon Hub / Tribes 3v3

local Config = {
    ESP = true,
    Aim = false,
    JumpPrediction = true,
    StrafePrediction = true, -- smooth velocity + collapse lead on direction changes
    StrafeTau = 0.09,        -- velocity smoothing / lead-recovery time constant (s)
    CircleStrafe = true,     -- hold [C]: orbit / park behind target (auto-fly)
    CircleStrafeMode = "Orbit", -- "Orbit" or "BehindBack"; tap [B] to switch
    ShowHud = true,          -- on-screen keybind + active-feature panel
    Fly = false,             -- menu toggle: free-fly (WASD + space/shift)
    Speed = false,           -- menu toggle: walk-speed boost
    SuperJump = false,       -- menu toggle: high jump
    Trajectory = true,
    Names = true,
    MeleeRange = true,       -- visually indicates when enemies are within striking reach
    MeleeReach = 9.0,        -- studs threshold for melee striking range
    MeleeLockRange = 16.0,   -- studs threshold to begin auto-locking camera onto target
    MeleeAutoFace = true,    -- automatically align horizontal view toward enemy on melee attack
    FOVRadius = 180,
    AimSmooth = 0.35,        -- 0 = instant snap, 0.05..0.95 = smooth lerp
    MaxDistance = 650,
    IncludeTrainingDummies = true,
    PreferHighArc = false,
    TargetPart = "UpperTorso",
    TargetRefresh = 0.25,
    SelectInterval = 0.05,
    TrajectoryInterval = 1 / 144,
    IdleTrajectoryInterval = 1 / 144,
    CastStep = 1 / 45,
    MaxLifetime = 5,
    MaxTravel = 1200,
    MaxCandidates = 3,
    ExtraLeadSeconds = 0,
    RunMathTests = false,
}

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer
assert(player and RunService:IsClient(), "[Napoleon Hub] Run this in the game client.")

-- Settings persistence -------------------------------------------------------
-- Auto-saves the menu's toggles to the executor's data folder and reloads them
-- on the next run, so the script returns exactly how you left it. Silently a
-- no-op on executors without a filesystem (readfile/writefile/isfile).
local CONFIG_FILE = "napoleon_hub_config.json"
local PERSIST = {
    "ESP", "Aim", "MeleeRange", "MeleeLockRange", "MeleeAutoFace", "JumpPrediction",
    "StrafePrediction", "Trajectory", "Names", "FOVRadius", "AimSmooth", "PreferHighArc", "TargetPart",
    "CircleStrafe", "CircleStrafeMode", "ShowHud",
    "Fly", "Speed", "SuperJump",
}
local fsRead   = type(readfile)  == "function" and readfile  or nil
local fsWrite  = type(writefile) == "function" and writefile or nil
local fsIsFile = type(isfile)    == "function" and isfile    or nil

local function serializeConfig()
    local out = {}
    for _, key in ipairs(PERSIST) do out[key] = Config[key] end
    local ok, encoded = pcall(function() return HttpService:JSONEncode(out) end)
    return ok and encoded or nil
end

local function loadConfig()
    if not (fsRead and fsIsFile) then return end
    local ok, raw = pcall(function()
        if fsIsFile(CONFIG_FILE) then return fsRead(CONFIG_FILE) end
        return nil
    end)
    if not ok or type(raw) ~= "string" then return end
    local decoded
    ok, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(decoded) ~= "table" then return end
    for _, key in ipairs(PERSIST) do
        local saved = decoded[key]
        if saved ~= nil and type(saved) == type(Config[key]) then Config[key] = saved end
    end
end

local lastSavedSnapshot
local function saveConfig()
    if not fsWrite then return end
    local encoded = serializeConfig()
    if encoded and encoded ~= lastSavedSnapshot then
        if pcall(fsWrite, CONFIG_FILE, encoded) then lastSavedSnapshot = encoded end
    end
end

loadConfig()
lastSavedSnapshot = serializeConfig()

local playerGui = game.CoreGui
assert(playerGui, "[Napoleon Hub] PlayerGui did not load.")
local ROOT_NAME = "__NapoleonHub_v1"
local old = playerGui:FindFirstChild(ROOT_NAME)
if old then
    local stop = old:FindFirstChild("Shutdown")
    if stop and stop:IsA("BindableEvent") then stop:Fire(); task.wait() end
    if old.Parent then old:Destroy() end
end

local connections, destructors = {}, {}
local active = true
local renderFailed = false
local binding = ROOT_NAME .. "_" .. tostring(math.floor(os.clock() * 1000000))
local menuBinding = binding .. "_Menu"
local windowFocused = true
local function connect(signal, fn)
    local connection = signal:Connect(fn)
    table.insert(connections, connection)
    return connection
end

local gui = Instance.new("ScreenGui")
gui.Name = ROOT_NAME
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = true
gui.DisplayOrder = 1000
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui
local shutdown = Instance.new("BindableEvent")
shutdown.Name = "Shutdown"
shutdown.Parent = gui
local visuals = Instance.new("Folder")
visuals.Name = ROOT_NAME
visuals.Parent = Workspace

local function unload()
    if not active then return end
    active = false
    RunService:UnbindFromRenderStep(binding)
    RunService:UnbindFromRenderStep(menuBinding)
    for _, connection in ipairs(connections) do connection:Disconnect() end
    for _, destructor in ipairs(destructors) do pcall(destructor) end
    visuals:Destroy()
    gui:Destroy()
    print("[Napoleon Hub] Unloaded.")
end
connect(shutdown.Event, unload)
connect(gui.Destroying, unload)

local function make(class, properties, parent)
    local object = Instance.new(class)
    for key, value in pairs(properties) do object[key] = value end
    object.Parent = parent
    return object
end
local function rounded(object, radius)
    make("UICorner", {CornerRadius = UDim.new(0, radius)}, object)
end
local PANEL_WIDTH, PANEL_HEIGHT = 342, 444
local panel = make("Frame", {
    Name = "Menu", Visible = true,
    Position = UDim2.fromOffset(20, 90), Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT),
    BackgroundColor3 = Color3.fromRGB(15, 23, 30), BackgroundTransparency = 0.04,
    BorderSizePixel = 0,
}, gui)
rounded(panel, 9)
make("UIStroke", {Color = Color3.fromRGB(47, 83, 90), Thickness = 1}, panel)
local function textLabel(parent, text, y, height)
    return make("TextLabel", {
        Position = UDim2.fromOffset(12, y), Size = UDim2.new(1, -24, 0, height),
        BackgroundTransparency = 1, Text = text, TextSize = 13,
        Font = Enum.Font.Code, TextColor3 = Color3.fromRGB(221, 231, 237),
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        TextYAlignment = Enum.TextYAlignment.Center,
    }, parent)
end
local title = textLabel(panel, "NAPOLEON HUB", 8, 24)
title.Size = UDim2.new(1, -96, 0, 24)
title.TextColor3 = Color3.fromRGB(87, 221, 211)
local content = make("Frame", {
    Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 1, -42), BackgroundTransparency = 1,
}, panel)
local function button(parent, caption, x, y, width, height)
    local result = make("TextButton", {
        Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(width, height),
        BackgroundColor3 = Color3.fromRGB(32, 47, 58), BorderSizePixel = 0,
        TextSize = 13, Font = Enum.Font.Code, TextColor3 = Color3.new(1, 1, 1), Text = caption,
    }, parent)
    rounded(result, 5)
    return result
end
local minimize = button(panel, "-", PANEL_WIDTH - 76, 8, 28, 26)
local mouseIconBeforeMenu = UIS.MouseIconEnabled
minimize.Modal = true -- Free the cursor only while the menu is visible.
table.insert(destructors, function()
    minimize.Modal = false
    if panel.Visible then UIS.MouseIconEnabled = mouseIconBeforeMenu end
end)
local close = button(panel, "X", PANEL_WIDTH - 40, 8, 28, 26)
close.BackgroundColor3 = Color3.fromRGB(91, 44, 49)
connect(close.Activated, unload)
connect(minimize.Activated, function()
    content.Visible = not content.Visible
    panel.Size = UDim2.fromOffset(PANEL_WIDTH, content.Visible and PANEL_HEIGHT or 42)
    minimize.Text = content.Visible and "-" or "+"
end)

local buttons = {}
for i, entry in ipairs({{"ESP", "ESP"}, {"Aim", "AIM"}, {"Trajectory", "ARC"}}) do
    local key, caption = entry[1], entry[2]
    local control = button(content, caption, 12 + (i - 1) * 108, 0, 102, 32)
    buttons[key] = {button = control, caption = caption}
    connect(control.Activated, function()
        Config[key] = not Config[key]
    end)
end
local namesButton = button(content, "NAMES ON", 12, 42, 102, 30)
local partButton = button(content, "TARGET: TORSO", 120, 42, 210, 30)
connect(namesButton.Activated, function() Config.Names = not Config.Names end)
connect(partButton.Activated, function()
    Config.TargetPart = Config.TargetPart == "Head" and "UpperTorso" or "Head"
end)
local fovLabel = textLabel(content, "AIM FOV: 180 px", 85, 26)
fovLabel.Size = UDim2.fromOffset(225, 26)
local less = button(content, "-", 254, 84, 32, 28)
local more = button(content, "+", 298, 84, 32, 28)
connect(less.Activated, function() Config.FOVRadius = math.max(40, Config.FOVRadius - 20) end)
connect(more.Activated, function() Config.FOVRadius = math.min(400, Config.FOVRadius + 20) end)
local arcButton = button(content, "ARC: LOW / FAST", 12, 124, 318, 30)
connect(arcButton.Activated, function() Config.PreferHighArc = not Config.PreferHighArc end)

local smoothLabel = textLabel(content, "SMOOTH: 0.35", 164, 26)
smoothLabel.Size = UDim2.fromOffset(225, 26)
local smoothLess = button(content, "-", 254, 163, 32, 28)
local smoothMore = button(content, "+", 298, 163, 32, 28)
connect(smoothLess.Activated, function()
    Config.AimSmooth = math.clamp(math.floor((Config.AimSmooth - 0.05) * 100 + 0.5) / 100, 0, 0.95)
end)
connect(smoothMore.Activated, function()
    Config.AimSmooth = math.clamp(math.floor((Config.AimSmooth + 0.05) * 100 + 0.5) / 100, 0, 0.95)
end)

local meleeButton = button(content, "MELEE RANGE ON", 12, 200, 154, 30)
connect(meleeButton.Activated, function() Config.MeleeRange = not Config.MeleeRange end)

local autoFaceButton = button(content, "AUTO-FACE ON", 176, 200, 154, 30)
connect(autoFaceButton.Activated, function() Config.MeleeAutoFace = not Config.MeleeAutoFace end)

local jumpButton = button(content, "JUMP LEAD ON", 12, 238, 318, 30)
connect(jumpButton.Activated, function() Config.JumpPrediction = not Config.JumpPrediction end)
local flyButton = button(content, "FLY OFF", 12, 276, 102, 30)
connect(flyButton.Activated, function() Config.Fly = not Config.Fly end)
local speedButton = button(content, "SPEED OFF", 120, 276, 102, 30)
connect(speedButton.Activated, function() Config.Speed = not Config.Speed end)
local jumpBoostButton = button(content, "JUMP OFF", 228, 276, 102, 30)
connect(jumpBoostButton.Activated, function() Config.SuperJump = not Config.SuperJump end)
local status = textLabel(content, "Standby...", 314, 20)
local targetLabel = textLabel(content, "Enable AIM, then draw your bow", 336, 20)
textLabel(content, "Insert: hide/show menu. [X]: unload.", 360, 16).TextSize = 11

local dragging, dragStart, panelStart, dragInput
local dragHandle = make("TextButton", {
    Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, -84, 0, 40),
    BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
}, panel)
connect(dragHandle.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging, dragStart, panelStart, dragInput = true, input.Position, panel.Position, input
    end
end)
connect(UIS.InputChanged, function(input)
    if not dragging then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement and input ~= dragInput then return end
    local delta = input.Position - dragStart
    local camera = Workspace.CurrentCamera
    if not camera then return end
    panel.Position = UDim2.fromOffset(
        math.clamp(panelStart.X.Offset + delta.X, 0, math.max(0, camera.ViewportSize.X - PANEL_WIDTH)),
        math.clamp(panelStart.Y.Offset + delta.Y, 0, math.max(0, camera.ViewportSize.Y - panel.AbsoluteSize.Y))
    )
end)
connect(UIS.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input == dragInput then dragging = false end
end)

local ring = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(Config.FOVRadius * 2, Config.FOVRadius * 2),
    BackgroundTransparency = 1, BorderSizePixel = 0,
}, gui)
make("UICorner", {CornerRadius = UDim.new(1, 0)}, ring)
make("UIStroke", {Color = Color3.fromRGB(79, 200, 211), Transparency = 0.55, Thickness = 1}, ring)
local aimDot = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(7, 7),
    BackgroundColor3 = Color3.fromRGB(255, 219, 103), BorderSizePixel = 0, Visible = false,
}, gui)
rounded(aimDot, 4)

local isDrawing = false
local drawStart, drawDuration = 0, 1
local lastTool
local panelHovered = false
local selected, selectionTime = nil, -math.huge
local applyAim

connect(panel.MouseEnter, function() panelHovered = true end)
connect(panel.MouseLeave, function() panelHovered = false end)

local MELEE_RING_SEGMENTS = 28
local meleeRingParts = {}
for _ = 1, MELEE_RING_SEGMENTS do
    meleeRingParts[#meleeRingParts + 1] = make("Part", {
        Name = "MeleeRangeRing", Anchored = true, CanCollide = false, CanTouch = false,
        CanQuery = false, CastShadow = false, Material = Enum.Material.Neon,
        Size = Vector3.new(0.12, 0.12, 1), Transparency = 1,
    }, visuals)
end
local function hideMeleeRing()
    for _, p in ipairs(meleeRingParts) do p.Transparency = 1 end
end
local function drawMeleeRing(center, radius, enemyInRange)
    local col = enemyInRange and Color3.fromRGB(80, 255, 130) or Color3.fromRGB(255, 219, 103)
    local trans = enemyInRange and 0.15 or 0.55
    for i, p in ipairs(meleeRingParts) do
        local a0, a1 = (i - 1) / MELEE_RING_SEGMENTS * math.pi * 2, i / MELEE_RING_SEGMENTS * math.pi * 2
        local p0 = center + Vector3.new(math.cos(a0), 0, math.sin(a0)) * radius
        local p1 = center + Vector3.new(math.cos(a1), 0, math.sin(a1)) * radius
        p.Size = Vector3.new(0.12, 0.12, (p1 - p0).Magnitude)
        p.CFrame = CFrame.lookAt((p0 + p1) * 0.5, p1)
        p.Color, p.Transparency = col, trans
    end
end

local function setMenuVisible(visible)
    if not active then return end
    local wasVisible = gui.Enabled and panel.Visible
    if visible and not wasVisible then mouseIconBeforeMenu = UIS.MouseIconEnabled end
    if visible then
        gui.Enabled = true
        content.Visible = true
        panel.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
        minimize.Text = "-"
        local camera = Workspace.CurrentCamera
        if camera then
            panel.Position = UDim2.fromOffset(
                math.clamp(panel.Position.X.Offset, 0, math.max(0, camera.ViewportSize.X - PANEL_WIDTH)),
                math.clamp(panel.Position.Y.Offset, 0, math.max(0, camera.ViewportSize.Y - PANEL_HEIGHT))
            )
        end
    end
    panel.Visible = visible
    minimize.Modal = visible
    dragging, dragInput, panelHovered = false, nil, false
    if visible then
        UIS.MouseIconEnabled = true
    else
        UIS.MouseIconEnabled = mouseIconBeforeMenu
    end
end

connect(UIS.InputBegan, function(input)
    if input.KeyCode ~= Enum.KeyCode.Insert then return end
    if UIS:GetFocusedTextBox() or GuiService.MenuIsOpen then return end
    setMenuVisible(not (gui.Enabled and panel.Visible))
end)
RunService:BindToRenderStep(menuBinding, Enum.RenderPriority.Camera.Value + 4, function()
    if active and gui.Enabled and panel.Visible then UIS.MouseIconEnabled = true end
end)
setMenuVisible(true)
print("[Napoleon Hub] Menu ready. Insert hides/shows it.")

-- Fallback ballistics for all weapons (bows, crossbows, guns, throwables).
-- Read-only query against ReplicatedStorage.Shared.Weapons will dynamically
-- override these if available in game memory.
local fallbackWeapons = {
    short_bow       = {kind = "Bow",         drawTime = 0.5,  speedMin = 120, speedMax = 250, gravity = 55, radius = 0.3,  range = 400},
    longbow         = {kind = "Bow",         drawTime = 1.1,  speedMin = 160, speedMax = 380, gravity = 32, radius = 0.28, range = 600},
    crossbow        = {kind = "Crossbow",    speed = 320, gravity = 28, radius = 0.28, range = 500},
    musket          = {kind = "Musket",      speed = 900, gravity = 12, radius = 0.22, range = 600},
    rifle           = {kind = "Musket",      speed = 900, gravity = 12, radius = 0.22, range = 600},
    flintlock       = {kind = "Pistol",      speed = 700, gravity = 20, radius = 0.25, range = 400},
    pistol          = {kind = "Pistol",      speed = 700, gravity = 20, radius = 0.25, range = 400},
    blunderbuss     = {kind = "Blunderbuss", speed = 420, gravity = 20, radius = 0.3,  range = 90},
    shotgun         = {kind = "Blunderbuss", speed = 420, gravity = 20, radius = 0.3,  range = 90},
    throwing_knives = {kind = "Knives",      speed = 240, gravity = 30, radius = 0.3,  range = 300},
    knives          = {kind = "Knives",      speed = 240, gravity = 30, radius = 0.3,  range = 300},
    knife           = {kind = "Knives",      speed = 240, gravity = 30, radius = 0.3,  range = 300},
    dagger_throw    = {kind = "Knives",      speed = 240, gravity = 30, radius = 0.3,  range = 300},
    javelins        = {kind = "Javelin",     drawTime = 0.45, speedMin = 95,  speedMax = 175, gravity = 62, radius = 0.45, range = 400},
    javelin         = {kind = "Javelin",     drawTime = 0.45, speedMin = 95,  speedMax = 175, gravity = 62, radius = 0.45, range = 400},
    harpoon         = {kind = "Javelin",     drawTime = 0.6,  speedMin = 110, speedMax = 160, gravity = 55, radius = 0.5,  range = 220},
    sling           = {kind = "Sling",       speed = 150, gravity = 85, radius = 0.35, range = 350},
    slingshot       = {kind = "Sling",       speed = 150, gravity = 85, radius = 0.35, range = 350},
    bolas           = {kind = "Knives",      speed = 150, gravity = 45, radius = 0.7,  range = 160},
    chakram         = {kind = "Knives",      speed = 110, gravity = 0,  radius = 0.9,  range = 45},
}

local AIMABLE_KINDS = {
    Bow = true, Crossbow = true, Musket = true, Pistol = true, Blunderbuss = true,
    Knives = true, Javelin = true, Sling = true,
}
local CHARGE_KINDS = {Bow = true, Javelin = true}
local HITSCAN_KINDS = {Musket = true, Pistol = true, Blunderbuss = true}
local aimHitscan = false
local isHoldingAim = false

local MELEE_KINDS = {
    Melee = true, Sword = true, Axe = true, Dagger = true, Spear = true,
    Mace = true, Hammer = true, Club = true, Halberd = true, Greatsword = true,
}

local function weaponModel(kind)
    return CHARGE_KINDS[kind] and "charge" or "instant"
end

local cachedWeaponDefs = {}
local function getWeaponDefinition(id)
    if not id then return nil end
    if not cachedWeaponDefs[id] then
        pcall(function()
            local shared = ReplicatedStorage:FindFirstChild("Shared")
            local weaponsMod = shared and shared:FindFirstChild("Weapons")
            if weaponsMod and weaponsMod:IsA("ModuleScript") then
                local weapons = require(weaponsMod)
                if type(weapons) == "table" and type(weapons.Get) == "function" then
                    local def = weapons.Get(id)
                    if type(def) == "table" then
                        cachedWeaponDefs[id] = def
                    end
                end
            end
        end)
    end
    return cachedWeaponDefs[id]
end

-- Checks if the equipped tool is a melee weapon (or unarmed)
local function isMeleeEquipped()
    local character = player.Character
    local tool = character and character:FindFirstChildOfClass("Tool")
    if not tool then
        -- Unarmed fists/kick: counts as melee
        return true, nil, nil
    end
    local id = tool:GetAttribute("WeaponId")
    local def = getWeaponDefinition(id)
    local kind = def and def.kind
    if kind then
        if MELEE_KINDS[kind] then return true, tool, def end
        if AIMABLE_KINDS[kind] then return false, tool, def end
    end
    -- Fallback checks on tool name and fallbackWeapons
    if id and fallbackWeapons[id] and AIMABLE_KINDS[fallbackWeapons[id].kind] then
        return false, tool, nil
    end
    return true, tool, def
end

-- Helper to match fallback tuning by WeaponId or Tool Name
local function resolveWeaponTuning(tool)
    if not tool then return nil end
    local id = tool:GetAttribute("WeaponId")
    local tuning, kind, weaponId = nil, nil, id
    
    if id then
        local def = getWeaponDefinition(id)
        if def and AIMABLE_KINDS[def.kind] then
            tuning = def.tuning or fallbackWeapons[id]
            kind = def.kind
        elseif fallbackWeapons[id] then
            tuning = fallbackWeapons[id]
            kind = tuning.kind
        end
    end

    -- If no match yet, infer from Tool Name
    if not tuning then
        local nameLower = string.lower(tool.Name):gsub("[%s_%-]+", "")
        for key, fb in pairs(fallbackWeapons) do
            local cleanKey = string.lower(key):gsub("[%s_%-]+", "")
            if nameLower:find(cleanKey, 1, true) or cleanKey:find(nameLower, 1, true) then
                tuning = fb
                kind = fb.kind
                weaponId = key
                break
            end
        end
    end

    -- General category matching from Tool Name
    if not tuning then
        local nameLower = string.lower(tool.Name)
        if nameLower:find("bow") and not nameLower:find("cross") then
            tuning, kind, weaponId = fallbackWeapons.short_bow, "Bow", "short_bow"
        elseif nameLower:find("cross") then
            tuning, kind, weaponId = fallbackWeapons.crossbow, "Crossbow", "crossbow"
        elseif nameLower:find("musket") or nameLower:find("rifle") then
            tuning, kind, weaponId = fallbackWeapons.musket, "Musket", "musket"
        elseif nameLower:find("flint") or nameLower:find("pistol") or nameLower:find("gun") then
            tuning, kind, weaponId = fallbackWeapons.flintlock, "Pistol", "flintlock"
        elseif nameLower:find("blunder") or nameLower:find("shotgun") then
            tuning, kind, weaponId = fallbackWeapons.blunderbuss, "Blunderbuss", "blunderbuss"
        elseif nameLower:find("knife") or nameLower:find("knives") or nameLower:find("dagger") then
            tuning, kind, weaponId = fallbackWeapons.throwing_knives, "Knives", "throwing_knives"
        elseif nameLower:find("javelin") or nameLower:find("spear") then
            tuning, kind, weaponId = fallbackWeapons.javelins, "Javelin", "javelins"
        elseif nameLower:find("sling") then
            tuning, kind, weaponId = fallbackWeapons.sling, "Sling", "sling"
        end
    end

    return tuning, kind, weaponId
end

-- Returns tool, tuning, id, kind, model for any aimable weapon, or nil.
local function bowInfo()
    local character = player.Character
    local tool = character and character:FindFirstChildOfClass("Tool")
    if tool ~= lastTool then
        isDrawing = false
        selected, selectionTime = nil, -math.huge
        lastTool = tool
    end
    if not tool then return nil end

    local tuning, kind, id = resolveWeaponTuning(tool)
    if not tuning or not kind or not AIMABLE_KINDS[kind] then return nil end

    local model = weaponModel(kind)
    aimHitscan = HITSCAN_KINDS[kind] == true
    return tool, tuning, id, kind, model
end

local function chargeFor(tuning, kind)
    if kind and not CHARGE_KINDS[kind] then
        return 1, isHoldingAim -- Instant weapons are always 100% full velocity
    end
    if isDrawing then
        local duration = tuning and tuning.drawTime or 1
        return math.clamp((os.clock() - drawStart) / math.max(0.001, duration), 0, 1), true
    end
    return 1, false -- Idle preview is full charge
end

local function attribute(model, owner, key)
    local value = model and model:GetAttribute(key)
    if value == nil and owner then value = owner:GetAttribute(key) end
    return value
end

local function isEnemy(model, owner)
    if model == player.Character or owner == player or not model:IsDescendantOf(Workspace) then return false end
    if attribute(model, owner, "Alive") == false then return false end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return false end
    local myMatch = attribute(player.Character, player, "MatchId")
    local theirMatch = attribute(model, owner, "MatchId")
    local myTeam = attribute(player.Character, player, "Team")
    local theirTeam = attribute(model, owner, "Team")
    if type(myMatch) == "string" and myMatch ~= "" then
        return theirMatch == myMatch and theirTeam ~= nil and myTeam ~= nil and theirTeam ~= myTeam
    end
    return Config.IncludeTrainingDummies and CollectionService:HasTag(model, "TrainingDummy")
end

local records = {}
local function refreshTargets()
    local visited, valid = {}, {}
    local function visit(model, owner)
        if not model or not model:IsA("Model") or visited[model] then return end
        visited[model] = true
        if not isEnemy(model, owner) then return end
        local root = model:FindFirstChild("HumanoidRootPart")
        local part = model:FindFirstChild(Config.TargetPart) or model:FindFirstChild("Torso")
            or model:FindFirstChild("Head") or root
        if not root or not root:IsA("BasePart") or not part or not part:IsA("BasePart") then return end
        valid[model] = true
        local head = model:FindFirstChild("Head")
        local adornee = head and head:IsA("BasePart") and head or root
        local record = records[model]
        if not record then
            local highlight = make("Highlight", {
                Adornee = model, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
                FillColor = Color3.fromRGB(243, 87, 89), FillTransparency = 0.8,
                OutlineColor = Color3.fromRGB(255, 146, 127), OutlineTransparency = 0.1,
            }, visuals)
            local billboard = make("BillboardGui", {
                Adornee = adornee, AlwaysOnTop = true,
                Size = UDim2.fromOffset(220, 42), StudsOffsetWorldSpace = Vector3.new(0, 2.4, 0),
                MaxDistance = Config.MaxDistance,
            }, gui)
            local label = make("TextLabel", {
                Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, TextSize = 12,
                Font = Enum.Font.Code, TextColor3 = Color3.new(1, 1, 1),
                TextStrokeTransparency = 0.25, Text = "",
            }, billboard)
            record = {highlight = highlight, billboard = billboard, label = label, model = model}
            records[model] = record
        end
        record.owner, record.root, record.part = owner, root, part
        record.humanoid = model:FindFirstChildOfClass("Humanoid")
        record.billboard.Adornee = adornee
    end
    for _, other in ipairs(Players:GetPlayers()) do visit(other.Character, other) end
    for _, tag in ipairs({"Combatant", "Bot", "TrainingDummy"}) do
        for _, model in ipairs(CollectionService:GetTagged(tag)) do
            if model:IsA("Model") then visit(model, Players:GetPlayerFromCharacter(model)) end
        end
    end
    for model, record in pairs(records) do
        if not valid[model] then
            if selected and selected.record == record then selected, selectionTime = nil, -math.huge end
            record.highlight:Destroy()
            record.billboard:Destroy()
            records[model] = nil
        end
    end
end

local function exclusionContext()
    local list, seen = {}, {}
    local function add(object)
        if object and not seen[object] then
            seen[object] = true
            table.insert(list, object)
        end
    end
    add(visuals)
    add(player.Character)
    for _, name in ipairs({"FX", "Projectiles"}) do
        local folder = Workspace:FindFirstChild(name)
        add(folder)
    end
    local myMatch = attribute(player.Character, player, "MatchId")
    local myTeam = attribute(player.Character, player, "Team")
    local function teammate(model, owner)
        if model and model:IsA("Model") and myMatch ~= nil and myMatch ~= "" and myTeam ~= nil
            and attribute(model, owner, "MatchId") == myMatch
            and attribute(model, owner, "Team") == myTeam then
            add(model)
        end
    end
    for _, other in ipairs(Players:GetPlayers()) do teammate(other.Character, other) end
    for _, tag in ipairs({"Combatant", "Bot"}) do
        for _, model in ipairs(CollectionService:GetTagged(tag)) do teammate(model, nil) end
    end
    return {list = list, seen = seen, params = {}}
end

local function exclusions(extra, context)
    context = context or exclusionContext()
    local key = extra or false
    if context.params[key] then return context.params[key] end
    local list = table.clone(context.list)
    if extra and not context.seen[extra] then table.insert(list, extra) end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = list
    params.IgnoreWater = true
    context.params[key] = params
    return params
end

local function shotOrigin(tool, params)
    local character = player.Character
    local head = character and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart"))
    if not head or not head:IsA("BasePart") then return nil end
    local fallback = head.Position
    if head.Name == "HumanoidRootPart" then fallback = fallback + Vector3.new(0, 1.5, 0) end
    local muzzle = tool:FindFirstChild("Muzzle", true)
    local handle = tool:FindFirstChild("Handle")
    local point = muzzle and muzzle:IsA("Attachment") and muzzle.WorldPosition
        or (handle and handle:IsA("BasePart") and handle.Position) or fallback
    if (point - fallback).Magnitude > 7 then return fallback end
    local delta = point - fallback
    if delta.Magnitude > 0.001 and Workspace:Raycast(fallback, delta, params) then return fallback end
    return point
end

local function shotDirection(origin, params)
    local camera = Workspace.CurrentCamera
    if not camera then return nil end
    local hit = Workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * 1000, params)
    local point = hit and hit.Position or camera.CFrame.Position + camera.CFrame.LookVector * 1000
    local delta = point - origin
    return delta.Magnitude > 0.001 and delta.Unit or camera.CFrame.LookVector
end

-- Original numeric solver. Coefficients are in ascending powers.
local function finite(x)
    return type(x) == "number" and x == x and math.abs(x) < math.huge
end

local function polynomialValue(c, x)
    local y = c[#c]
    for i = #c - 1, 1, -1 do y = y * x + c[i] end
    return y
end

local function polynomialScale(c, x)
    local y = math.abs(c[#c])
    for i = #c - 1, 1, -1 do y = y * math.abs(x) + math.abs(c[i]) end
    return y
end

local function polynomialRoots(c, lo, hi)
    while #c > 1 and c[#c] == 0 do table.remove(c) end
    local magnitude = 0
    for _, value in ipairs(c) do magnitude = math.max(magnitude, math.abs(value)) end
    if magnitude == 0 or #c == 1 then return {} end
    for i = 1, #c do c[i] = c[i] / magnitude end
    if #c == 2 then
        local root = -c[1] / c[2]
        return root >= lo and root <= hi and {root} or {}
    end
    local derivative = {}
    for i = 2, #c do derivative[i - 1] = (i - 1) * c[i] end
    local boundaries = {lo}
    for _, value in ipairs(polynomialRoots(derivative, lo, hi)) do
        if value > lo and value < hi then table.insert(boundaries, value) end
    end
    table.insert(boundaries, hi)
    table.sort(boundaries)
    local roots = {}
    local function add(root)
        for _, existing in ipairs(roots) do
            if math.abs(existing - root) < 1e-8 then return end
        end
        table.insert(roots, root)
    end
    for _, x in ipairs(boundaries) do
        if math.abs(polynomialValue(c, x)) <= 1e-12 * math.max(1e-30, polynomialScale(c, x)) then
            add(x)
        end
    end
    for i = 1, #boundaries - 1 do
        local a, b = boundaries[i], boundaries[i + 1]
        local fa, fb = polynomialValue(c, a), polynomialValue(c, b)
        if (fa < 0 and fb > 0) or (fa > 0 and fb < 0) then
            for _ = 1, 44 do
                local middle = (a + b) * 0.5
                local fm = polynomialValue(c, middle)
                if (fa < 0 and fm < 0) or (fa > 0 and fm > 0) then
                    a, fa = middle, fm
                else
                    b = middle
                end
            end
            add((a + b) * 0.5)
        end
    end
    table.sort(roots)
    return roots
end

local function intercepts(origin, target, velocity, speed, gravity, lifetime, targetAcceleration)
    if not finite(speed) or speed <= 0 or not finite(lifetime) or lifetime <= 0 then return {} end
    targetAcceleration = targetAcceleration or Vector3.zero
    local relativeGravity = gravity - targetAcceleration
    local offset = target - origin
    if offset.Magnitude < 0.001 then return {} end
    local c = {
        offset:Dot(offset),
        2 * offset:Dot(velocity),
        velocity:Dot(velocity) - offset:Dot(relativeGravity) - speed * speed,
        -velocity:Dot(relativeGravity),
        0.25 * relativeGravity:Dot(relativeGravity),
    }
    for i = 1, #c do
        c[i] = c[i] * lifetime ^ (i - 1)
        if not finite(c[i]) then return {} end
    end
    local solutions = {}
    for _, x in ipairs(polynomialRoots(c, 0.000001 / lifetime, 1)) do
        local time = x * lifetime
        local launch = offset / time + velocity - 0.5 * relativeGravity * time
        if finite(launch.Magnitude) and launch.Magnitude > 0
            and math.abs(launch.Magnitude - speed) <= math.max(0.0001, speed * 0.00001) then
            table.insert(solutions, {
                time = time,
                direction = launch.Unit,
                impact = target + velocity * time + 0.5 * targetAcceleration * time * time,
            })
        end
    end
    return solutions
end


local function parameters(tuning, charge)
    local minimum = tonumber(tuning.speedMin or tuning.speed) or 120
    local maximum = tonumber(tuning.speedMax or tuning.speed) or minimum
    local speed = minimum + (maximum - minimum) * charge
    local gravity = Vector3.new(0, -(tonumber(tuning.gravity) or 55), 0)
    return speed, gravity, tonumber(tuning.radius) or 0.3
end

local function trace(origin, direction, speed, gravity, duration, params, radius, collect)
    local position, velocity = origin, direction * speed
    local points = collect and {origin} or nil
    local age, traveled = 0, 0
    while age < duration - 1e-7 do
        local dt = math.min(Config.CastStep, duration - age)
        local delta = velocity * dt + 0.5 * gravity * dt * dt
        if traveled + delta.Magnitude > Config.MaxTravel then return points, nil, true end
        local hit
        if delta.Magnitude > 0.0001 then
            if radius > 0 then
                hit = Workspace:Spherecast(position, radius, delta, params)
            else
                hit = Workspace:Raycast(position, delta, params)
            end
        end
        if hit then
            if points then table.insert(points, position + delta.Unit * hit.Distance) end
            return points, hit, false
        end
        position = position + delta
        velocity = velocity + gravity * dt
        traveled = traveled + delta.Magnitude
        age = age + dt
        if points then table.insert(points, position) end
    end
    return points, nil, false
end

-- Landing is a bounded estimate on nearby, nearly level static ground. A ledge,
-- moving platform or slope keeps the airborne model instead of inventing a floor.
local function estimateLanding(record, velocity, targetGravity)
    local root, humanoid = record.root, record.humanoid
    local standingHeight = root.Size.Y * 0.5 + math.max(0, humanoid.HipHeight)
    if humanoid.RigType == Enum.HumanoidRigType.R6 then
        local leg = record.model:FindFirstChild("Left Leg") or record.model:FindFirstChild("Right Leg")
        if not leg or not leg:IsA("BasePart") then return nil end
        standingHeight = standingHeight + leg.Size.Y
    end
    local excluded, seen = {visuals}, {[visuals] = true}
    local function exclude(model)
        if model and not seen[model] then seen[model] = true; table.insert(excluded, model) end
    end
    exclude(record.model)
    exclude(player.Character)
    for _, other in ipairs(Players:GetPlayers()) do exclude(other.Character) end
    for model in pairs(records) do exclude(model) end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = excluded
    params.IgnoreWater, params.RespectCanCollide = true, true
    params.CollisionGroup = root.CollisionGroup
    local rootPosition = root.Position
    local function groundAt(x, z)
        local hit = Workspace:Raycast(Vector3.new(x, rootPosition.Y + 1, z), Vector3.new(0, -192, 0), params)
        if not hit or hit.Normal.Y < 0.98 then return nil end
        if hit.Instance:IsA("BasePart") and not hit.Instance.Anchored then return nil end
        return hit.Position.Y
    end
    local firstGround = groundAt(rootPosition.X, rootPosition.Z)
    if firstGround == nil then return nil end
    local clearance = rootPosition.Y - firstGround - standingHeight
    if clearance < -0.5 then return nil end
    local landingTime = (velocity.Y + math.sqrt(velocity.Y * velocity.Y + 2 * targetGravity * math.max(0, clearance))) / targetGravity
    if not finite(landingTime) or landingTime < 0 or landingTime > Config.MaxLifetime + 1 then return nil end
    local lastGround = groundAt(rootPosition.X + velocity.X * landingTime, rootPosition.Z + velocity.Z * landingTime)
    if lastGround == nil or math.abs(lastGround - firstGround) > 0.5 then return nil end
    -- Recompute for the checked landing surface; the small allowed height change
    -- limits extrapolation error without tracing a whole character trajectory.
    clearance = rootPosition.Y - lastGround - standingHeight
    if clearance < -0.5 then return nil end
    landingTime = (velocity.Y + math.sqrt(velocity.Y * velocity.Y + 2 * targetGravity * math.max(0, clearance))) / targetGravity
    return landingTime, lastGround + standingHeight + record.part.Position.Y - rootPosition.Y
end

local function targetMotion(record, velocity)
    local position, rootPosition = record.part.Position, record.root.Position
    local humanoid = record.humanoid
    local state = humanoid and humanoid:GetState()
    local targetGravity = Workspace.Gravity
    local now = os.clock()
    local cached = record.jumpMotion
    if cached and now - cached.sampledAt < 0.05 and cached.root == record.root and cached.part == record.part
        and cached.position == position and cached.rootPosition == rootPosition and cached.velocity == velocity
        and cached.state == state and cached.gravity == targetGravity and cached.enabled == Config.JumpPrediction then
        return cached
    end
    local motion = {
        position = position, rootPosition = rootPosition, velocity = velocity, acceleration = Vector3.zero,
        root = record.root, part = record.part, sampledAt = now, state = state,
        gravity = targetGravity, enabled = Config.JumpPrediction,
    }
    if Config.JumpPrediction and humanoid and finite(targetGravity) and targetGravity > 0
        and (state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall) then
        motion.acceleration = Vector3.new(0, -targetGravity, 0)
        motion.landingTime, motion.landingY = estimateLanding(record, velocity, targetGravity)
    end
    record.jumpMotion = motion
    return motion
end

local function motionIntercepts(origin, motion, speed, gravity, lifetime, lead)
    lead = finite(lead) and math.max(0, lead) or 0
    local solutions = {}
    local remainingAirTime = motion.landingTime and math.max(0, motion.landingTime - lead) or lifetime
    if remainingAirTime > 0 then
        local position = motion.position + motion.velocity * lead + 0.5 * motion.acceleration * lead * lead
        local velocity = motion.velocity + motion.acceleration * lead
        solutions = intercepts(origin, position, velocity, speed, gravity, math.min(lifetime, remainingAirTime), motion.acceleration)
    end
    if motion.landingTime then
        local velocity = Vector3.new(motion.velocity.X, 0, motion.velocity.Z)
        local position = Vector3.new(motion.position.X, motion.landingY, motion.position.Z) + velocity * lead
        for _, solution in ipairs(intercepts(origin, position, velocity, speed, gravity, lifetime)) do
            if solution.time + lead >= motion.landingTime - 0.00001 then
                local duplicate = false
                for _, existing in ipairs(solutions) do
                    if math.abs(solution.time - existing.time) < 0.00001 then duplicate = true; break end
                end
                if not duplicate then table.insert(solutions, solution) end
            end
        end
    end
    table.sort(solutions, function(a, b) return a.time < b.time end)
    return solutions
end

-- Strafe-aware target velocity. Smooths the raw physics velocity (kills the
-- single-frame jitter behind small misses on straight runs) and tracks heading
-- consistency: hold a direction and confidence -> 1 so we lead fully; reverse and
-- confidence collapses so the lead folds back toward the target's current
-- position (right after a juke their next step is a coin flip), then ramps back
-- up as they commit. Horizontal only -- vertical stays raw for the jump model.
local function leadVelocity(record, raw)
    if not Config.StrafePrediction then record.strafe = nil; return raw end
    local horizontal = Vector3.new(raw.X, 0, raw.Z)
    local now = os.clock()
    local s = record.strafe
    if not s then
        record.strafe = {smooth = horizontal, t = now, conf = 1, lead = horizontal}
        return Vector3.new(horizontal.X, raw.Y, horizontal.Z)
    end
    local dt = now - s.t
    if dt < 0.006 then return Vector3.new(s.lead.X, raw.Y, s.lead.Z) end
    local tau = tonumber(Config.StrafeTau) or 0.09
    local alpha = math.clamp(dt / (dt + tau), 0, 1)
    local align = 1
    if horizontal.Magnitude > 1 and s.smooth.Magnitude > 1 then
        align = horizontal.Unit:Dot(s.smooth.Unit)
    end
    local target = math.clamp((align + 0.25) / 1.25, 0, 1)
    local conf = target < s.conf and target or (s.conf + alpha * (target - s.conf))
    local smooth = s.smooth:Lerp(horizontal, alpha)
    local lead = smooth * conf
    s.smooth, s.t, s.conf, s.lead = smooth, now, conf, lead
    return Vector3.new(lead.X, raw.Y, lead.Z)
end

local function solveRecord(record, origin, speed, gravity)
    if not record.model.Parent or not record.part.Parent or not record.root.Parent
        or not isEnemy(record.model, record.owner) then return {} end
    local rawVelocity = record.root.AssemblyLinearVelocity
    if not finite(rawVelocity.Magnitude) or rawVelocity.Magnitude > 1000 then return {} end
    if aimHitscan then
        -- Hitscan firearms: instant raycast hit server-side. Zero lead, zero drop.
        local delta = record.part.Position - origin
        local dist = delta.Magnitude
        local dir = dist > 0.001 and delta.Unit or Vector3.new(0, 0, -1)
        return {{
            time = 0.001,
            direction = dir,
            impact = record.part.Position,
        }}
    end
    local velocity = leadVelocity(record, rawVelocity)
    local motion = targetMotion(record, velocity)
    local solutions = motionIntercepts(origin, motion, speed, gravity, Config.MaxLifetime, Config.ExtraLeadSeconds)
    if Config.PreferHighArc then
        local reverse = {}
        for i = #solutions, 1, -1 do table.insert(reverse, solutions[i]) end
        return reverse
    end
    return solutions
end

local function selectTarget(origin, tuning, speed, gravity, radius, force, context)
    local camera = Workspace.CurrentCamera
    if not camera then selected = nil; return nil end
    local now = os.clock()
    if not force and now - selectionTime < Config.SelectInterval then return selected end
    selectionTime = now
    local range = math.min(Config.MaxDistance, tonumber(tuning.range) or Config.MaxDistance)
    local function check(record)
        if not record.part.Parent or not isEnemy(record.model, record.owner)
            or (record.part.Position - origin).Magnitude > range then return nil end
        local params = exclusions(record.model, context)
        for _, solution in ipairs(solveRecord(record, origin, speed, gravity)) do
            local pitch = math.asin(math.clamp(solution.direction.Y, -1, 1))
            if pitch >= math.rad(-80) and pitch <= math.rad(78) then
                if aimHitscan then
                    -- Hitscan direct raycast check
                    local hit = Workspace:Raycast(origin, solution.direction * math.min(range, (record.part.Position - origin).Magnitude + 1), params)
                    if not hit or hit.Instance:IsDescendantOf(record.model) then
                        return {record = record, solution = solution}
                    end
                else
                    local _, hit, exhausted = trace(origin, solution.direction, speed, gravity, solution.time, params, radius, false)
                    if not hit and not exhausted then return {record = record, solution = solution} end
                end
            end
        end
        return nil
    end
    -- FOV is an acquisition rule. Ballistic camera elevation must not break a draw lock.
    if selected then
        local retained = check(selected.record)
        if retained then selected = retained; return selected end
    end
    local center = camera.ViewportSize * 0.5
    local candidates = {}
    for _, record in pairs(records) do
        if record.part.Parent and isEnemy(record.model, record.owner) then
            local projected, onScreen = camera:WorldToViewportPoint(record.part.Position)
            local screenDistance = (Vector2.new(projected.X, projected.Y) - center).Magnitude
            local distance = (record.part.Position - origin).Magnitude
            if onScreen and projected.Z > 0 and screenDistance <= Config.FOVRadius and distance <= range then
                table.insert(candidates, {record = record, score = screenDistance})
            end
        end
    end
    table.sort(candidates, function(a, b) return a.score < b.score end)
    selected = nil
    for i = 1, math.min(#candidates, Config.MaxCandidates) do
        local choice = check(candidates[i].record)
        if choice then selected = choice; return choice end
    end
    return nil
end

local function allowedToAim()
    if renderFailed or not windowFocused or not Config.Aim
        or UIS:GetFocusedTextBox() or GuiService.MenuIsOpen or (panel.Visible and panelHovered) then return false end
    -- Ranged weapons (bows, crossbows, guns, throwables) aim only on user action:
    -- Bows/javelins while drawing (isDrawing), or instant weapons while holding RMB / firing (isHoldingAim).
    if not isDrawing and not isHoldingAim then return false end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0 and attribute(character, player, "Alive") ~= false
end

-- Make the camera's 1000-stud endpoint lie on the desired muzzle ray.
local function cameraDirection(origin, direction, cameraPosition)
    local offset = cameraPosition - origin
    local along = offset:Dot(direction)
    local perpendicularSquared = math.max(0, offset:Dot(offset) - along * along)
    local distance = along + math.sqrt(math.max(1, 1000 * 1000 - perpendicularSquared))
    return (origin + direction * distance - cameraPosition).Unit
end

local function setView(direction, smoothFactor, dt)
    local camera = Workspace.CurrentCamera
    if not camera or not finite(direction.Magnitude) or direction.Magnitude < 0.001 then return end
    local targetCF = CFrame.lookAt(camera.CFrame.Position, camera.CFrame.Position + direction.Unit)
    smoothFactor = tonumber(smoothFactor) or 0
    if smoothFactor <= 0.001 then
        camera.CFrame = targetCF
    else
        dt = tonumber(dt) or (1 / 60)
        -- Exponential decay lerp: frame-rate independent smooth tracking
        local speed = (1 - smoothFactor) * 45
        local alpha = math.clamp(1 - math.exp(-speed * dt), 0.01, 1)
        camera.CFrame = camera.CFrame:Lerp(targetCF, alpha)
    end
end

applyAim = function(forcedCharge, forceCheck, context, dt)
    local tool, tuning, id, kind, model = bowInfo()
    if not active or not tool or not allowedToAim() then return nil end
    context = context or exclusionContext()
    local charge = forcedCharge
    if charge == nil then charge = chargeFor(tuning) end
    local speed, gravity, radius = parameters(tuning, charge)
    local params = exclusions(nil, context)
    local origin = shotOrigin(tool, params)
    if not origin then return nil end
    local choice = selectTarget(origin, tuning, speed, gravity, radius, forceCheck, context)
    if not choice then return nil end
    local camera = Workspace.CurrentCamera
    local originalView = camera.CFrame
    local function reject()
        setView(originalView.LookVector, 0)
        camera.CFrame = originalView
        selected = nil
        return nil
    end
    local solution
    -- On instant release shots (forceCheck=true), snap directly without smoothing delay.
    local smooth = forceCheck and 0 or (Config.AimSmooth or 0)
    -- Re-evaluate because the game's third-person ShotOrigin depends on camera direction.
    for _ = 1, 3 do
        origin = shotOrigin(tool, params)
        if not origin then return reject() end
        local roots = solveRecord(choice.record, origin, speed, gravity)
        solution = roots[1]
        if not solution then return reject() end
        -- Preserve the collision-approved arc if several roots exist.
        for _, candidate in ipairs(roots) do
            if math.abs(candidate.time - choice.solution.time) < math.abs(solution.time - choice.solution.time) then
                solution = candidate
            end
        end
        local launchPitch = math.asin(math.clamp(solution.direction.Y, -1, 1))
        if launchPitch < math.rad(-80) or launchPitch > math.rad(78) then return reject() end
        setView(cameraDirection(origin, solution.direction, camera.CFrame.Position), smooth, dt)
        local actual = shotDirection(origin, params)
        if actual and actual:Dot(solution.direction) < 0.999999 then
            local corrected = camera.CFrame.LookVector + solution.direction - actual
            if corrected.Magnitude > 0.001 then setView(corrected.Unit, smooth, dt) end
        end
    end
    local finalOrigin = shotOrigin(tool, params)
    if not finalOrigin then return reject() end
    local actualDirection = shotDirection(finalOrigin, params)
    if not actualDirection then return reject() end
    local size = choice.record.part.Size
    if not aimHitscan then
        local endpoint = finalOrigin + actualDirection * speed * solution.time
            + gravity * (0.5 * solution.time * solution.time)
        local tolerance = radius + math.max(0.25, math.min(size.X, size.Y, size.Z) * 0.35)
        if (endpoint - solution.impact).Magnitude > tolerance then return reject() end
    end
    if forceCheck or not choice.finalCheck or os.clock() - choice.finalCheck >= Config.SelectInterval then
        if aimHitscan then
            local dist = (choice.record.part.Position - finalOrigin).Magnitude
            local hit = Workspace:Raycast(finalOrigin, actualDirection * (dist + 1), exclusions(choice.record.model, context))
            if hit and not hit.Instance:IsDescendantOf(choice.record.model) then return reject() end
        else
            local _, hit, exhausted = trace(finalOrigin, actualDirection, speed, gravity,
                solution.time, exclusions(choice.record.model, context), radius, false)
            if hit or exhausted then return reject() end
        end
        choice.finalCheck = os.clock()
    end
    choice.solution = solution
    return choice
end

local function clearRecordShot(record, origin, tuning, charge, context)
    if not record or not record.part.Parent or not isEnemy(record.model, record.owner) then return nil end
    if (record.part.Position - origin).Magnitude > math.min(Config.MaxDistance, tonumber(tuning.range) or Config.MaxDistance) then return nil end
    local speed, gravity, radius = parameters(tuning, charge)
    for _, solution in ipairs(solveRecord(record, origin, speed, gravity)) do
        local pitch = math.asin(math.clamp(solution.direction.Y, -1, 1))
        if pitch >= math.rad(-80) and pitch <= math.rad(78) then
            local _, hit, exhausted = trace(origin, solution.direction, speed, gravity,
                solution.time, exclusions(record.model, context), radius, false)
            if not hit and not exhausted then return {record = record, solution = solution} end
        end
    end
    return nil
end

local trajectoryParts = {}
local function trajectoryPart()
    return make("Part", {
        Name = "Arc", Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
        CastShadow = false, Material = Enum.Material.Neon, Transparency = 1,
        Size = Vector3.new(0.065, 0.065, 1),
    }, visuals)
end
for _ = 1, 72 do table.insert(trajectoryParts, trajectoryPart()) end
local impactMarker = make("Part", {
    Name = "PredictedImpact", Shape = Enum.PartType.Ball, Size = Vector3.new(0.45, 0.45, 0.45),
    Anchored = true, CanCollide = false, CanTouch = false, CanQuery = false,
    CastShadow = false, Material = Enum.Material.Neon, Transparency = 1,
}, visuals)
local function hideTrajectory()
    for _, part in ipairs(trajectoryParts) do part.Transparency = 1 end
    impactMarker.Transparency = 1
end

local function displayTrajectory(points, blocked)
    if not points or #points < 2 then hideTrajectory(); return end
    local count = math.min(#trajectoryParts, #points - 1)
    local color = blocked and Color3.fromRGB(255, 125, 83) or Color3.fromRGB(67, 220, 208)
    for i, part in ipairs(trajectoryParts) do
        if i <= count then
            local a = points[math.floor((i - 1) * (#points - 1) / count) + 1]
            local b = points[math.floor(i * (#points - 1) / count) + 1]
            local distance = (b - a).Magnitude
            if distance > 0.001 then
                part.Size = Vector3.new(0.065, 0.065, distance)
                part.CFrame = CFrame.lookAt((a + b) * 0.5, b)
                part.Color, part.Transparency = color, 0.12
            else part.Transparency = 1 end
        else part.Transparency = 1 end
    end
    impactMarker.Position = points[#points]
    impactMarker.Color, impactMarker.Transparency = color, 0.15
end

local lastMeleeTargetModel = nil
local lastMeleeAcquireTime = 0

local function performMeleeAutoFace(dt, snap)
    if not (active and Config.MeleeAutoFace) then
        lastMeleeTargetModel = nil
        return false
    end
    if UIS:GetFocusedTextBox() or GuiService.MenuIsOpen or (panel.Visible and panelHovered) then return false end

    -- 1. Must have a melee weapon equipped (or unarmed)
    local isMelee, tool, def = isMeleeEquipped()
    if not isMelee then
        lastMeleeTargetModel = nil
        return false
    end

    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    if not (root and humanoid and humanoid.Health > 0 and attribute(char, player, "Alive") ~= false) then
        lastMeleeTargetModel = nil
        return false
    end

    -- 2. Hysteresis target selection to prevent target-flicker jitter
    local myPos = root.Position
    local lockRange = tonumber(Config.MeleeLockRange) or (tonumber(Config.MeleeReach) and Config.MeleeReach * 1.75) or 16.0
    local bestRecord, bestDist = nil, math.huge
    local now = os.clock()

    -- Check if locked target is still valid within lockRange + buffer
    if lastMeleeTargetModel and records[lastMeleeTargetModel] then
        local rec = records[lastMeleeTargetModel]
        local eRoot = rec.root
        if eRoot and eRoot.Parent and isEnemy(rec.model, rec.owner)
            and rec.humanoid and rec.humanoid.Health > 0 then
            local d = (eRoot.Position - myPos).Magnitude
            if d <= lockRange + 3.0 then
                bestRecord = rec
                bestDist = d
            end
        end
    end

    -- If no retained target or lost, acquire closest within lockRange
    if not bestRecord then
        for _, record in pairs(records) do
            local enemyRoot = record.root
            if enemyRoot and enemyRoot.Parent and isEnemy(record.model, record.owner)
                and record.humanoid and record.humanoid.Health > 0 then
                local d = (enemyRoot.Position - myPos).Magnitude
                if d <= lockRange and d < bestDist then
                    bestRecord = record
                    bestDist = d
                end
            end
        end
    end

    if not bestRecord then
        lastMeleeTargetModel = nil
        return false
    end
    lastMeleeTargetModel = bestRecord.model

    -- 3. Target positioning with velocity smoothing
    local targetPos = bestRecord.part and bestRecord.part.Position or bestRecord.root.Position
    local enemyVel = bestRecord.root and bestRecord.root.AssemblyLinearVelocity or Vector3.zero
    if finite(enemyVel.Magnitude) and enemyVel.Magnitude > 1 and enemyVel.Magnitude < 100 then
        -- Add slight lead dampener (0.02s) to track motion cleanly
        targetPos = targetPos + Vector3.new(enemyVel.X, 0, enemyVel.Z) * 0.02
    end

    local flatDiff = Vector3.new(targetPos.X - myPos.X, 0, targetPos.Z - myPos.Z)
    if flatDiff.Magnitude > 0.05 then
        local targetLook = flatDiff.Unit
        dt = tonumber(dt) or (1 / 60)

        -- Firmly align character horizontal heading
        if snap then
            root.CFrame = CFrame.lookAt(root.Position, root.Position + targetLook)
        else
            local desiredRootCF = CFrame.lookAt(root.Position, root.Position + targetLook)
            local rootAlpha = math.clamp(1 - math.exp(-38 * dt), 0.2, 1)
            root.CFrame = root.CFrame:Lerp(desiredRootCF, rootAlpha)
        end

        -- Firm, decisive camera melee lock with responsive pull
        local cam = Workspace.CurrentCamera
        if cam then
            local desiredLook = (targetPos - cam.CFrame.Position).Unit
            local targetCF = CFrame.lookAt(cam.CFrame.Position, cam.CFrame.Position + desiredLook)
            local smoothFactor = snap and 0 or (Config.AimSmooth or 0)

            if smoothFactor <= 0.001 or snap then
                cam.CFrame = targetCF
            else
                -- Robust responsive tracking rate (45 - 85 responsiveness)
                local trackSpeed = (1 - smoothFactor) * 55 + 20
                local camAlpha = math.clamp(1 - math.exp(-trackSpeed * dt), 0.35, 1)
                cam.CFrame = cam.CFrame:Lerp(targetCF, camAlpha)
            end
        end
        return true, bestRecord
    end
    return false
end

connect(UIS.InputBegan, function(input, processed)
    if renderFailed or processed or UIS:GetFocusedTextBox() then return end
    if panel.Visible and panelHovered then return end

    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        local tool, tuning, id, kind, model = bowInfo()
        if tool then
            if model == "charge" then
                isDrawing = true
                drawStart, drawDuration = os.clock(), tuning.drawTime or 1
                selected, selectionTime = nil, -math.huge
            else
                -- Instant weapon: hold LMB tracks target, releasing fires snap shot
                isHoldingAim = true
                selected, selectionTime = nil, -math.huge
                pcall(applyAim, nil, true)
            end
        else
            -- No ranged weapon equipped: check if melee weapon and in melee range (instant snap on swing)
            performMeleeAutoFace(nil, true)
        end
    elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
        -- RMB aim-assist tracking for instant weapons (crossbow, gun, knives, sling)
        local tool, tuning, id, kind, model = bowInfo()
        if tool and model == "instant" then
            isHoldingAim = true
            selected, selectionTime = nil, -math.huge
        end
    end
end)
connect(UIS.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        if isDrawing or isHoldingAim then
            pcall(applyAim, nil, true)
        end
        isDrawing = false
        isHoldingAim = false
        selected = nil
    elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
        isHoldingAim = false
        selected = nil
    end
end)
connect(UIS.WindowFocusReleased, function()
    windowFocused = false
    isDrawing = false
    isHoldingAim = false
    selected = nil
    dragging = false
end)
connect(UIS.WindowFocused, function() windowFocused = true end)
connect(player.CharacterAdded, function()
    isDrawing = false
    isHoldingAim = false
    selected, lastTool = nil, nil
    selectionTime = -math.huge
end)

local function mathTests()
    local zero = Vector3.zero
    local function test(name, target, velocity, speed, gravity, lifetime, expected)
        local roots = intercepts(zero, target, velocity, speed, gravity, lifetime)
        assert(#roots == #expected, name .. ": wrong root count " .. tostring(#roots))
        for i, solution in ipairs(roots) do
            assert(math.abs(solution.time - expected[i]) < 0.001, name .. ": wrong time")
            local endpoint = solution.direction * speed * solution.time + gravity * (0.5 * solution.time ^ 2)
            assert((endpoint - target - velocity * solution.time).Magnitude < 0.01, name .. ": endpoint miss")
        end
    end
    test("linear", Vector3.new(100, 0, 0), Vector3.new(10, 0, 0), 50, zero, 10, {2.5})
    test("outrunning", Vector3.new(100, 0, 0), Vector3.new(60, 0, 0), 50, zero, 10, {})
    test("two arcs", Vector3.new(100, 0, 0), zero, 50, Vector3.new(0, -10, 0), 12, {2.0430964, 9.7890631})
    test("tangent", Vector3.new(250, 0, 0), zero, 50, Vector3.new(0, -10, 0), 12, {7.0710678})
    test("unreachable", Vector3.new(251, 0, 0), zero, 50, Vector3.new(0, -10, 0), 12, {})
    test("lifetime", Vector3.new(100, 0, 0), zero, 50, Vector3.new(0, -10, 0), 5, {2.0430964})
    test("coincident", zero, zero, 50, zero, 5, {})
    test("zero speed", Vector3.new(100, 0, 0), zero, 0, zero, 5, {})
    print("[Napoleon Hub] 8 ballistic tests passed.")
    return true
end

local lastRenderTime = os.clock()
local nextRefresh, nextTrajectory, nextUI = 0, 0, 0
local function render()
    if not active or renderFailed then return end
    local now = os.clock()
    local dt = math.clamp(now - lastRenderTime, 0.001, 0.1)
    lastRenderTime = now
    local camera = Workspace.CurrentCamera
    if not camera then return end
    if now >= nextRefresh then refreshTargets(); nextRefresh = now + Config.TargetRefresh end
    local tool, tuning, id, weaponKind, model = bowInfo()
    local charge, drawingNow = 1, false
    if tool then charge, drawingNow = chargeFor(tuning, weaponKind) end
    local choice, castContext
    if tool then
        charge, drawingNow = chargeFor(tuning, weaponKind)
        if allowedToAim() then
            castContext = exclusionContext()
            choice = applyAim(nil, false, castContext, dt)
        end
    else
        selected = nil
        -- Continuous Melee Auto-Face: runs whenever melee weapon is equipped and enemy is in reach
        if Config.MeleeAutoFace then
            performMeleeAutoFace(dt, false)
        end
    end
    if not allowedToAim() then selected = nil end
    ring.Visible = Config.Aim and tool ~= nil and not GuiService.MenuIsOpen
    ring.Position = UDim2.fromOffset(camera.ViewportSize.X * 0.5, camera.ViewportSize.Y * 0.5)
    ring.Size = UDim2.fromOffset(Config.FOVRadius * 2, Config.FOVRadius * 2)
    aimDot.Visible = false
    if choice then
        local point, visible = camera:WorldToViewportPoint(choice.solution.impact)
        if visible then aimDot.Position = UDim2.fromOffset(point.X, point.Y); aimDot.Visible = true end
    end
    if now >= nextTrajectory then
        nextTrajectory = now + (drawingNow and Config.TrajectoryInterval or Config.IdleTrajectoryInterval)
        if tool and Config.Trajectory then
            castContext = castContext or exclusionContext()
            local params = exclusions(nil, castContext)
            local origin = shotOrigin(tool, params)
            local direction = origin and shotDirection(origin, params)
            if direction then
                local speed, gravity, radius = parameters(tuning, charge)
                local duration = choice and choice.solution.time or Config.MaxLifetime
                local points, hit, exhausted = trace(origin, direction, speed, gravity, duration, params, radius, true)
                displayTrajectory(points, hit ~= nil or exhausted)
            else hideTrajectory() end
        else hideTrajectory() end
    end
    if now >= nextUI then
        nextUI = now + 0.1
        saveConfig() -- debounced: writes only when a setting actually changed
        for key, item in pairs(buttons) do
            item.button.Text = item.caption .. (Config[key] and " ON" or " OFF")
            item.button.BackgroundColor3 = Config[key] and Color3.fromRGB(25, 69, 77) or Color3.fromRGB(60, 50, 54)
        end
        namesButton.Text = Config.Names and "NAMES ON" or "NAMES OFF"
        partButton.Text = Config.TargetPart == "Head" and "TARGET: HEAD" or "TARGET: TORSO"
        fovLabel.Text = string.format("AIM FOV: %d px", Config.FOVRadius)
        smoothLabel.Text = Config.AimSmooth <= 0.001 and "SMOOTH: SNAP (0.00)" or string.format("SMOOTH: %.2f", Config.AimSmooth)
        arcButton.Text = Config.PreferHighArc and "ARC: HIGH / LOB" or "ARC: LOW / FAST"
        meleeButton.Text = Config.MeleeRange and "MELEE RNG ON" or "MELEE RNG OFF"
        meleeButton.BackgroundColor3 = Config.MeleeRange and Color3.fromRGB(25, 69, 77) or Color3.fromRGB(32, 47, 58)
        autoFaceButton.Text = Config.MeleeAutoFace and "AUTO-FACE ON" or "AUTO-FACE OFF"
        autoFaceButton.BackgroundColor3 = Config.MeleeAutoFace and Color3.fromRGB(25, 69, 77) or Color3.fromRGB(32, 47, 58)
        jumpButton.Text = Config.JumpPrediction and "JUMP LEAD ON" or "JUMP LEAD OFF"
        jumpButton.BackgroundColor3 = Config.JumpPrediction and Color3.fromRGB(25, 69, 77) or Color3.fromRGB(32, 47, 58)
        flyButton.Text = Config.Fly and "FLY ON" or "FLY OFF"
        flyButton.BackgroundColor3 = Config.Fly and Color3.fromRGB(25, 69, 77) or Color3.fromRGB(32, 47, 58)
        speedButton.Text = Config.Speed and "SPEED ON" or "SPEED OFF"
        speedButton.BackgroundColor3 = Config.Speed and Color3.fromRGB(25, 69, 77) or Color3.fromRGB(32, 47, 58)
        jumpBoostButton.Text = Config.SuperJump and "JUMP ON" or "JUMP OFF"
        jumpBoostButton.BackgroundColor3 = Config.SuperJump and Color3.fromRGB(25, 69, 77) or Color3.fromRGB(32, 47, 58)
        local myChar = player.Character
        local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
        local myPos = myRoot and myRoot.Position
        local enemyInMelee = false

        for _, record in pairs(records) do
            local alive = record.root.Parent and isEnemy(record.model, record.owner)
            local camDist = alive and (record.root.Position - camera.CFrame.Position).Magnitude or math.huge
            local playerDist = (alive and myPos) and (record.root.Position - myPos).Magnitude or math.huge
            local enabled = Config.ESP and alive and camDist <= Config.MaxDistance
            local inMeleeRange = Config.MeleeRange and alive and playerDist <= Config.MeleeReach
            if inMeleeRange then enemyInMelee = true end

            record.highlight.Enabled = enabled
            record.billboard.Enabled = enabled and Config.Names

            if inMeleeRange then
                record.highlight.OutlineColor = Color3.fromRGB(80, 255, 130) -- Green: In Striking Reach!
                record.highlight.FillColor = Color3.fromRGB(50, 220, 100)
                record.highlight.FillTransparency = 0.65
            elseif choice and choice.record == record then
                record.highlight.OutlineColor = Color3.fromRGB(255, 219, 103) -- Gold: Aim locked
                record.highlight.FillColor = Color3.fromRGB(243, 87, 89)
                record.highlight.FillTransparency = 0.8
            else
                record.highlight.OutlineColor = Color3.fromRGB(255, 146, 127) -- Default enemy
                record.highlight.FillColor = Color3.fromRGB(243, 87, 89)
                record.highlight.FillTransparency = 0.8
            end

            if enabled then
                local tag = inMeleeRange and " [STRIKE]" or ""
                record.label.Text = string.format("%s | %d HP | %d st%s",
                    record.owner and record.owner.DisplayName or record.model.Name,
                    math.max(0, math.floor(record.humanoid.Health)), math.floor(camDist), tag)
                record.label.TextColor3 = inMeleeRange and Color3.fromRGB(80, 255, 130) or Color3.new(1, 1, 1)
            end
        end

        if Config.MeleeRange and myRoot and myRoot.Parent then
            drawMeleeRing(Vector3.new(myPos.X, myPos.Y - 2.8, myPos.Z), Config.MeleeReach, enemyInMelee)
        else
            hideMeleeRing()
        end
        local actionDesc = model == "instant" and (isHoldingAim and "aim" or "ready") or (drawingNow and "draw" or "preview")
        status.Text = tool and string.format("%s (%s) | %d%% %s", id or "?", weaponKind or "?", math.floor(charge * 100), actionDesc)
            or "Equip a ranged weapon"
        targetLabel.Text = choice and string.format("%s | %.2fs flight", choice.record.model.Name, choice.solution.time)
            or (allowedToAim() and "No clear, reachable target in FOV" or (model == "instant" and "Hold RMB or Click LMB to aim" or "Enable AIM and hold LMB to aim"))
    end
end

if Config.RunMathTests then
    local ok, err = pcall(mathTests)
    if not ok then unload(); error(err) end
end
RunService:BindToRenderStep(binding, Enum.RenderPriority.Camera.Value + 3, function()
    local ok, err = pcall(render)
    if not ok then
        -- Keep the menu and its key binding alive so a failed feature cannot erase the UI.
        renderFailed = true
        RunService:UnbindFromRenderStep(binding)
        isDrawing, isHoldingAim, selected = false, false, nil
        ring.Visible, aimDot.Visible = false, false
        hideTrajectory()
        hideMeleeRing()
        for _, record in pairs(records) do
            record.highlight.Enabled = false
            record.billboard.Enabled = false
        end
        status.Visible, targetLabel.Visible = false, false
        make("TextLabel", {
            Name = "RuntimeError", Position = UDim2.fromOffset(12, 241),
            Size = UDim2.fromOffset(318, 85), BackgroundTransparency = 1,
            Font = Enum.Font.Code, TextSize = 11, TextColor3 = Color3.fromRGB(255, 146, 127),
            TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true, Text = "Features stopped; rerun script.\n" .. tostring(err):sub(1, 160),
        }, content)
        setMenuVisible(true)
        warn("[Napoleon Hub] Features stopped after runtime error (menu stays available): " .. tostring(err))
    end
end)
-- ============================================================================
-- Circle Strafe (+ auto-Fly) + on-screen HUD.
-- Toggle-to-activate, isolated from the aim core. All character movement is
-- client-side CFrame work: it replicates in Roblox, but it is also the most
-- anticheat-visible thing here and Tribes' server movement checks are unknown
-- (no server code in the dump). Edit KEYS below to rebind; tune Config.Circle*.
-- ============================================================================
Config.CircleRadius = Config.CircleRadius or 6    -- studs from target (tight orbit)
Config.CircleHeight = Config.CircleHeight or 2    -- hover height above target root
Config.CircleSpeed  = Config.CircleSpeed  or 12.0  -- orbit rate (rad/s)
Config.StrafeSmooth = Config.StrafeSmooth or 0.30 -- 0..1 move-toward (lower = smoother)
Config.CircleRange = Config.CircleRange or 120  -- target acquisition range (studs)

local KEYS = {
    Strafe   = Enum.KeyCode.End,      -- toggle: orbit / park behind target (auto-fly)
    Mode     = Enum.KeyCode.B,        -- tap: switch Orbit <-> Behind-Back
}
local toggles, orbitAngle, flying, platformStash = {}, 0, false, nil

local function nearestEnemy(fromPos, maxRange)
    local best, bestDist
    for _, record in pairs(records) do
        local root = record.root
        if root and root.Parent and isEnemy(record.model, record.owner)
            and record.humanoid and record.humanoid.Health > 0 then
            local d = (root.Position - fromPos).Magnitude
            if d <= maxRange and (not bestDist or d < bestDist) then best, bestDist = record, d end
        end
    end
    return best
end

-- Ring visualizers (segmented neon circle on the ground) ----------------------
local RING_SEGMENTS = 28
local ringParts = {}
for _ = 1, RING_SEGMENTS do
    ringParts[#ringParts + 1] = make("Part", {
        Name = "StrafeRing", Anchored = true, CanCollide = false, CanTouch = false,
        CanQuery = false, CastShadow = false, Material = Enum.Material.Neon,
        Size = Vector3.new(0.14, 0.14, 1), Transparency = 1,
    }, visuals)
end
local function hideRing()
    for _, p in ipairs(ringParts) do p.Transparency = 1 end
end
local function drawRing(center, radius, color)
    for i, p in ipairs(ringParts) do
        local a0, a1 = (i - 1) / RING_SEGMENTS * math.pi * 2, i / RING_SEGMENTS * math.pi * 2
        local p0 = center + Vector3.new(math.cos(a0), 0, math.sin(a0)) * radius
        local p1 = center + Vector3.new(math.cos(a1), 0, math.sin(a1)) * radius
        p.Size = Vector3.new(0.14, 0.14, (p1 - p0).Magnitude)
        p.CFrame = CFrame.lookAt((p0 + p1) * 0.5, p1)
        p.Color, p.Transparency = color, 0.2
    end
end



-- On-screen HUD: keybinds + active features ----------------------------------
local hud = make("Frame", {
    Name = "KFHud", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 14, 1, -14),
    Size = UDim2.fromOffset(190, 86), BackgroundColor3 = Color3.fromRGB(15, 23, 30),
    BackgroundTransparency = 0.25, BorderSizePixel = 0,
}, gui)
make("UICorner", {CornerRadius = UDim.new(0, 7)}, hud)
make("UIStroke", {Color = Color3.fromRGB(47, 83, 90), Thickness = 1}, hud)
local function hudLine(y, size)
    return make("TextLabel", {
        Position = UDim2.fromOffset(10, y), Size = UDim2.new(1, -20, 0, size + 4),
        BackgroundTransparency = 1, Font = Enum.Font.Code, Text = "", TextSize = size,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = Color3.fromRGB(221, 231, 237),
    }, hud)
end
local hudTitle = hudLine(6, 13); hudTitle.Text = "NAPOLEON HUB"; hudTitle.TextColor3 = Color3.fromRGB(87, 221, 211)
local hudStrafe, hudMode = hudLine(26, 12), hudLine(44, 12)
local hudActive = hudLine(64, 11)

connect(UIS.InputBegan, function(input, processed)
    if processed or UIS:GetFocusedTextBox() then return end
    if input.KeyCode == KEYS.Strafe then
        toggles[KEYS.Strafe] = not toggles[KEYS.Strafe]
    elseif input.KeyCode == KEYS.Mode then
        Config.CircleStrafeMode = Config.CircleStrafeMode == "Orbit" and "BehindBack" or "Orbit"
    end
end)

Config.FlySpeed   = Config.FlySpeed   or 60  -- fly studs/sec
Config.SpeedBoost = Config.SpeedBoost or 32  -- extra studs/sec added along move input
Config.JumpPower  = Config.JumpPower  or 130 -- Super Jump power

local function stopFly(humanoid)
    if flying and humanoid and platformStash ~= nil then humanoid.PlatformStand = platformStash end
    flying, platformStash = false, nil
end

-- Super-jump stashes/restores jump power. (Speed is a positional nudge in the
-- movement loop, not WalkSpeed, since the game overwrites WalkSpeed every frame.)
local savedJP, savedUseJP, savedJH
local function applyStatMods(humanoid)
    if not humanoid then return end
    if active and Config.SuperJump then
        if savedUseJP == nil then savedUseJP, savedJP, savedJH = humanoid.UseJumpPower, humanoid.JumpPower, humanoid.JumpHeight end
        humanoid.UseJumpPower = true
        humanoid.JumpPower = Config.JumpPower
    elseif savedUseJP ~= nil then
        humanoid.UseJumpPower, humanoid.JumpPower, humanoid.JumpHeight = savedUseJP, savedJP, savedJH
        savedUseJP = nil
    end
end

-- Free-fly: camera-relative WASD + space/shift, while PlatformStand holds physics
local function manualFly(dt, root, humanoid)
    if not flying then platformStash = humanoid.PlatformStand; flying = true end
    humanoid.PlatformStand = true
    local cam = Workspace.CurrentCamera
    local move = Vector3.zero
    if cam then
        local cf = cam.CFrame
        if UIS:IsKeyDown(Enum.KeyCode.W) then move += cf.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.S) then move -= cf.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.D) then move += cf.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.A) then move -= cf.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.Space) then move += Vector3.yAxis end
        if UIS:IsKeyDown(Enum.KeyCode.LeftShift) then move -= Vector3.yAxis end
    end
    if move.Magnitude > 0 then move = move.Unit end
    root.CFrame = root.CFrame + move * Config.FlySpeed * math.clamp(dt, 0, 0.1)
    root.AssemblyLinearVelocity = Vector3.zero
end

-- Unified movement controller (Heartbeat, after physics). Priority:
-- circle strafe (drives its own fly) > standalone fly > nothing. Speed and
-- super jump apply independently. One PlatformStand owner so nothing fights.
connect(RunService.Heartbeat, function(dt)
    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    pcall(applyStatMods, humanoid)
    if not (active and not renderFailed and root and humanoid and humanoid.Health > 0) then
        if flying then stopFly(humanoid) end
        hideRing()
        return
    end
    local busyUI = UIS:GetFocusedTextBox() or GuiService.MenuIsOpen
    local target = (Config.CircleStrafe and toggles[KEYS.Strafe] and not busyUI)
        and nearestEnemy(root.Position, Config.CircleRange) or nil
    if target and target.root then
        local tpos = target.root.Position
        if not flying then platformStash = humanoid.PlatformStand; flying = true end
        humanoid.PlatformStand = true
        local desired
        if Config.CircleStrafeMode == "BehindBack" then
            desired = tpos - target.root.CFrame.LookVector * Config.CircleRadius + Vector3.new(0, Config.CircleHeight, 0)
        else
            orbitAngle = orbitAngle + Config.CircleSpeed * math.clamp(dt, 0, 0.1)
            desired = tpos + Vector3.new(math.cos(orbitAngle), 0, math.sin(orbitAngle)) * Config.CircleRadius
                + Vector3.new(0, Config.CircleHeight, 0)
        end
        local goal = CFrame.lookAt(desired, Vector3.new(tpos.X, desired.Y, tpos.Z))
        root.CFrame = root.CFrame:Lerp(goal, math.clamp(Config.StrafeSmooth, 0.05, 1))
        root.AssemblyLinearVelocity = Vector3.zero
        drawRing(Vector3.new(tpos.X, tpos.Y - 2.5, tpos.Z), Config.CircleRadius, Color3.fromRGB(120, 200, 255))
        return
    end
    hideRing()
    if Config.Fly and not busyUI then
        manualFly(dt, root, humanoid)
        return
    elseif flying then
        stopFly(humanoid)
    end
    -- Speed: nudge the character along its real move input each frame. Survives
    -- the game re-setting WalkSpeed; adds on top of normal walking.
    if active and Config.Speed and not busyUI and humanoid.MoveDirection.Magnitude > 0.05 then
        root.CFrame = root.CFrame + humanoid.MoveDirection * Config.SpeedBoost * math.clamp(dt, 0, 0.1)
    end
end)

-- HUD refresh ----------------------------------------------------------------
connect(RunService.Heartbeat, function()
    hud.Visible = active and Config.ShowHud == true
    if not hud.Visible then return end
    local on, off = Color3.fromRGB(120, 230, 150), Color3.fromRGB(150, 160, 170)
    hudStrafe.Text = "[" .. KEYS.Strafe.Name .. "] Circle Strafe"
    hudStrafe.TextColor3 = toggles[KEYS.Strafe] and on or off
    hudMode.Text = "[" .. KEYS.Mode.Name .. "] Mode: " .. (Config.CircleStrafeMode == "BehindBack" and "Behind-Back" or "Orbit")
    hudMode.TextColor3 = Color3.fromRGB(200, 200, 210)
    local act = {}
    if toggles[KEYS.Strafe] then act[#act + 1] = "STRAFE" end
    if flying then act[#act + 1] = "FLY" end
    hudActive.Text = #act > 0 and ("ACTIVE: " .. table.concat(act, " ")) or "idle"
    hudActive.TextColor3 = #act > 0 and Color3.fromRGB(255, 219, 103) or off
end)

table.insert(destructors, function()
    hideRing()
    hideMeleeRing()
    local char = player.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    if flying and humanoid and platformStash ~= nil then humanoid.PlatformStand = platformStash end
    flying = false
    if humanoid and savedUseJP ~= nil then
        pcall(function()
            humanoid.UseJumpPower, humanoid.JumpPower, humanoid.JumpHeight = savedUseJP, savedJP, savedJH
        end)
    end
    if hud then hud:Destroy() end
end)

print("[Napoleon Hub] Loaded. Insert: menu. AIM starts OFF. Toggle [End] Circle Strafe ([B] mode). Click X to unload.")
return {Settings = Config, Unload = unload, RunMathTests = mathTests}
