local Workspace         = game:GetService("Workspace")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui           = game:GetService("CoreGui")
local Lighting          = game:GetService("Lighting")
local RunService        = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

local ServiceLayer = {}
ServiceLayer.__index = ServiceLayer

local MAX_HIGHLIGHTS   = 31
local STREAM_BATCH_SIZE = 40

local function toColor3(val)
    if typeof(val) == "Color3" then
        return val
    elseif type(val) == "table" then
        return Color3.new(val[1] or 1, val[2] or 1, val[3] or 1)
    end
    return Color3.new(1, 1, 1)
end

local function isProtectedAsset(inst)
    if not inst then return true end
    if inst:IsDescendantOf(Camera) or inst:IsDescendantOf(CoreGui) then
        return true
    end

    local ancestorModel = inst:IsA("Model") and inst or inst:FindFirstAncestorWhichIsA("Model")
    if ancestorModel then
        if Players:GetPlayerFromCharacter(ancestorModel) then
            return true
        end
    end

    return false
end

local function solveQuadratic(a, b, c)
    if math.abs(a) < 1e-6 then
        if math.abs(b) < 1e-6 then return nil, nil end
        local r = -c / b
        return r, r
    end
    local disc = b * b - 4 * a * c
    if disc < 0 then return nil, nil end
    local discRoot = math.sqrt(disc)
    local q = (b > 0) and (-0.5 * (b + discRoot)) or (-0.5 * (b - discRoot))
    local r1, r2 = q / a, c / q
    return (r1 < r2) and r1 or r2, (r1 < r2) and r2 or r1
end

function ServiceLayer.new(stateManager)
    local self = setmetatable({
        State = stateManager,

        Entities    = {},
        Corpses     = {},
        FriendCache = {},

        Weapon = {
            Name = "Unknown",
            MuzzleVelocity = 800,
            Drop = Workspace.Gravity,
        },
        _weaponConns = {},

        HighlightPool = {},
        BillboardPool = {},
        _poolFolder   = nil,

        RaycastParams = RaycastParams.new(),
        IgnoreBuffer  = {},

        ProbeOffsets = {
            Vector3.new(0, 0, 0),
            Vector3.new(0, 0.45, 0),
            Vector3.new(0, -0.45, 0),
            Vector3.new(0.45, 0, 0),
            Vector3.new(-0.45, 0, 0),
            Vector3.new(0, 0, 0.45),
            Vector3.new(0, 0, -0.45),
        },

        _streamQueue       = {},
        _optimizerConn     = nil,
        _queueHeartbeat    = nil,
        _originalLighting  = {},

        _fullbrightConns   = {},
        _originalLightingFB = {},
    }, ServiceLayer)

    self:_InitRaycasting()
    self:_InitVisualPools()
    self:_InitEntityRegistry()
    self:_InitWeaponService()
    self:_InitOptimizerPipeline()
    self:_InitFullbrightPipeline()

    return self
end

function ServiceLayer:IsRagdollCorpse(model)
    if not model or not model:IsA("Model") or model == LocalPlayer.Character then
        return false
    end

    if self.Entities[model] and self.Entities[model].Humanoid.Health > 0 then
        return false
    end

    local hum = model:FindFirstChildOfClass("Humanoid")
    if hum then
        if hum.Health <= 0 then return true end
        local state = hum:GetState()
        if state == Enum.HumanoidStateType.Dead or state == Enum.HumanoidStateType.Ragdoll or state == Enum.HumanoidStateType.Physics then
            return true
        end
    end

    local constraintCount = 0
    for _, desc in ipairs(model:GetChildren()) do
        if desc:IsA("BallSocketConstraint") or desc:IsA("HingeConstraint") or desc:IsA("NoCollisionConstraint") then
            constraintCount = constraintCount + 1
            if constraintCount >= 2 then
                return true
            end
        end
    end

    local hasDisabledMotors = false
    for _, desc in ipairs(model:GetDescendants()) do
        if desc:IsA("Motor6D") and not desc.Enabled then
            hasDisabledMotors = true
            break
        end
    end
    if hasDisabledMotors and (model:FindFirstChild("Head") or model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso")) then
        return true
    end

    local lowerName = model.Name:lower()
    if lowerName:find("corpse") or lowerName:find("ragdoll") or lowerName:find("dead") or lowerName:find("body") then
        return true
    end

    local parentName = model.Parent and model.Parent.Name:lower() or ""
    if parentName:find("corpse") or parentName:find("ragdoll") or parentName:find("debris") then
        return true
    end

    return false
end

function ServiceLayer:IsEntityInvisible(model, entity)
    if not model or not model.Parent then return false end

    local checkedCount = 0
    local invisibleCount = 0

    local children = model:GetChildren()
    for i = 1, #children do
        local child = children[i]
        if child:IsA("BasePart") and child.Name ~= "HumanoidRootPart" then
            checkedCount = checkedCount + 1
            local ltm = 0
            pcall(function() ltm = child.LocalTransparencyModifier end)
            if child.Transparency >= 0.85 or ltm >= 0.85 then
                invisibleCount = invisibleCount + 1
            end
        end
    end

    if checkedCount == 0 then
        local descendants = model:GetDescendants()
        for i = 1, #descendants do
            local desc = descendants[i]
            if desc:IsA("BasePart") and desc.Name ~= "HumanoidRootPart" then
                checkedCount = checkedCount + 1
                local ltm = 0
                pcall(function() ltm = desc.LocalTransparencyModifier end)
                if desc.Transparency >= 0.85 or ltm >= 0.85 then
                    invisibleCount = invisibleCount + 1
                end
            end
        end
    end

    return checkedCount > 0 and (invisibleCount == checkedCount)
end

function ServiceLayer:RegisterCorpse(model)
    if not model or self.Corpses[model] then return end

    local root = model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChild("Torso")
        or model:FindFirstChild("UpperTorso")
        or model:FindFirstChild("Head")
        or model:FindFirstChildWhichIsA("BasePart")

    if root then
        self.Corpses[model] = {
            Model     = model,
            RootPart  = root,
            Timestamp = tick(),
        }

        model.AncestryChanged:Once(function(_, parent)
            if not parent then
                self.Corpses[model] = nil
            end
        end)
    end
end

function ServiceLayer:_RegisterEntity(model, player)
    if not model or model == LocalPlayer.Character or self.Entities[model] then return end

    local function attemptBind()
        if not model.Parent or self.Entities[model] then return false end

        local hum = model:FindFirstChildOfClass("Humanoid")
        local root = model:FindFirstChild("HumanoidRootPart")
            or model:FindFirstChild("Torso")
            or model:FindFirstChild("UpperTorso")
            or model.PrimaryPart
            or model:FindFirstChildWhichIsA("BasePart")
        local head = model:FindFirstChild("Head") or root

        if hum and root and hum.Health > 0 then
            self.Entities[model] = {
                Model    = model,
                Player   = player or Players:GetPlayerFromCharacter(model),
                Humanoid = hum,
                RootPart = root,
                Head     = head,
                IsPlayer = (player ~= nil) or (Players:GetPlayerFromCharacter(model) ~= nil),
            }

            hum.Died:Once(function()
                self.Entities[model] = nil
                self:RegisterCorpse(model)
            end)

            model.AncestryChanged:Once(function(_, parent)
                if not parent then
                    self.Entities[model] = nil
                end
            end)
            return true
        end
        return false
    end

    if not attemptBind() then
        local conn
        conn = model.ChildAdded:Connect(function()
            if attemptBind() then
                conn:Disconnect()
            end
        end)

        task.delay(5, function()
            if conn.Connected then
                conn:Disconnect()
            end
        end)
    end
end

function ServiceLayer:_InitEntityRegistry()
    local function watchPlayer(pl)
        if pl == LocalPlayer then return end

        if pl.Character then
            self:_RegisterEntity(pl.Character, pl)
        end
        pl.CharacterAdded:Connect(function(c)
            self:_RegisterEntity(c, pl)
        end)
    end

    for _, pl in ipairs(Players:GetPlayers()) do
        watchPlayer(pl)
    end
    Players.PlayerAdded:Connect(watchPlayer)

    Players.PlayerRemoving:Connect(function(pl)
        self.FriendCache[pl.UserId] = nil
        for model, data in pairs(self.Entities) do
            if data.Player == pl then
                self.Entities[model] = nil
            end
        end
    end)

    local function evaluateInstance(inst)
        if not inst:IsA("Model") or inst == LocalPlayer.Character then return end

        task.defer(function()
            if not inst.Parent then return end

            if self:IsRagdollCorpse(inst) then
                self:RegisterCorpse(inst)
                return
            end

            if inst:FindFirstChildOfClass("Humanoid") then
                local plr = Players:GetPlayerFromCharacter(inst)
                self:_RegisterEntity(inst, plr)
            end
        end)
    end

    for _, desc in ipairs(Workspace:GetDescendants()) do
        evaluateInstance(desc)
    end

    Workspace.DescendantAdded:Connect(function(desc)
        evaluateInstance(desc)
    end)
end

function ServiceLayer:IsFriend(player)
    if not player or player == LocalPlayer then return false end
    if self.FriendCache[player.UserId] ~= nil then
        return self.FriendCache[player.UserId]
    end
    self.FriendCache[player.UserId] = false
    task.spawn(function()
        local ok, res = pcall(function() return LocalPlayer:IsFriendsWith(player.UserId) end)
        if ok then self.FriendCache[player.UserId] = res end
    end)
    return self.FriendCache[player.UserId]
end

function ServiceLayer:_InitVisualPools()
    local folder = CoreGui:FindFirstChild("NL_VisualPool") or Instance.new("Folder")
    folder.Name = "NL_VisualPool"
    folder.Parent = CoreGui
    self._poolFolder = folder

    self.HighlightPool = table.create(MAX_HIGHLIGHTS)
    for i = 1, MAX_HIGHLIGHTS do
        local hl = Instance.new("Highlight")
        hl.Name = "VHL_" .. i
        hl.FillTransparency = 0.5
        hl.OutlineTransparency = 0.1
        hl.Enabled = false
        hl.Parent = folder

        self.HighlightPool[i] = {
            Instance    = hl,
            InUse       = false,
            TargetModel = nil,
        }
    end
end

function ServiceLayer:BeginVisualFrame()
    for i = 1, MAX_HIGHLIGHTS do
        self.HighlightPool[i].InUse = false
    end
    for i = 1, #self.BillboardPool do
        self.BillboardPool[i].InUse = false
    end
end

function ServiceLayer:AssignHighlight(model, color)
    color = toColor3(color)
    local targetSlot = nil

    for i = 1, MAX_HIGHLIGHTS do
        local slot = self.HighlightPool[i]
        if slot.TargetModel == model then
            targetSlot = slot
            break
        end
    end

    if not targetSlot then
        for i = 1, MAX_HIGHLIGHTS do
            local slot = self.HighlightPool[i]
            if not slot.InUse then
                targetSlot = slot
                break
            end
        end
    end

    if targetSlot then
        targetSlot.InUse = true
        targetSlot.TargetModel = model

        local inst = targetSlot.Instance
        if inst.Adornee ~= model then inst.Adornee = model end
        if inst.FillColor ~= color then inst.FillColor = color end
        if not inst.Enabled then inst.Enabled = true end
        return inst
    end

    return nil
end

function ServiceLayer:AssignBillboardTag(adorneePart, nameText, distText, color)
    color = toColor3(color)
    local targetSlot = nil

    for _, slot in ipairs(self.BillboardPool) do
        if slot.Instance.Adornee == adorneePart then
            targetSlot = slot
            break
        end
    end

    if not targetSlot then
        for _, slot in ipairs(self.BillboardPool) do
            if not slot.InUse then
                targetSlot = slot
                break
            end
        end
    end

    if targetSlot then
        targetSlot.InUse = true
        local bb = targetSlot.Instance
        if bb.Adornee ~= adorneePart then bb.Adornee = adorneePart end
        if targetSlot.NameLabel.Text ~= nameText then targetSlot.NameLabel.Text = nameText end
        if targetSlot.NameLabel.TextColor3 ~= color then targetSlot.NameLabel.TextColor3 = color end
        if targetSlot.DistLabel.Text ~= distText then targetSlot.DistLabel.Text = distText end
        if targetSlot.BoxStroke.Color ~= color then targetSlot.BoxStroke.Color = color end
        if not bb.Enabled then bb.Enabled = true end
        return bb
    end

    local bb = Instance.new("BillboardGui")
    bb.Name = "VBillboard_" .. (#self.BillboardPool + 1)
    bb.Size = UDim2.new(0, 140, 0, 36)
    bb.StudsOffset = Vector3.new(0, 2.5, 0)
    bb.AlwaysOnTop = true
    bb.MaxDistance = 2500
    bb.Adornee = adorneePart
    bb.Enabled = true
    bb.Parent = self._poolFolder

    local nameLbl = Instance.new("TextLabel")
    nameLbl.Size = UDim2.new(1, 0, 0, 16)
    nameLbl.Position = UDim2.new(0, 0, 0, 0)
    nameLbl.BackgroundTransparency = 1
    nameLbl.Text = nameText
    nameLbl.TextColor3 = color
    nameLbl.Font = Enum.Font.GothamBold
    nameLbl.TextSize = self.State.Settings.ChamsTextSize
    nameLbl.TextStrokeTransparency = 0.3
    nameLbl.Parent = bb

    local distLbl = Instance.new("TextLabel")
    distLbl.Size = UDim2.new(1, 0, 0, 14)
    distLbl.Position = UDim2.new(0, 0, 0, 16)
    distLbl.BackgroundTransparency = 1
    distLbl.Text = distText
    distLbl.TextColor3 = Color3.fromRGB(220, 235, 245)
    distLbl.Font = Enum.Font.Gotham
    distLbl.TextSize = math.max(8, self.State.Settings.ChamsTextSize - 3)
    distLbl.TextStrokeTransparency = 0.4
    distLbl.Parent = bb

    local boxStroke = Instance.new("UIStroke")
    boxStroke.Thickness = 1
    boxStroke.Color = color
    boxStroke.Transparency = 0.8
    boxStroke.Parent = nameLbl

    table.insert(self.BillboardPool, {
        Instance   = bb,
        NameLabel  = nameLbl,
        DistLabel  = distLbl,
        BoxStroke  = boxStroke,
        InUse      = true,
    })
    return bb
end

function ServiceLayer:EndVisualFrame()
    for i = 1, MAX_HIGHLIGHTS do
        local slot = self.HighlightPool[i]
        if not slot.InUse and slot.Instance.Enabled then
            slot.Instance.Enabled = false
            slot.Instance.Adornee = nil
            slot.TargetModel = nil
        end
    end

    for _, slot in ipairs(self.BillboardPool) do
        if not slot.InUse and slot.Instance.Enabled then
            slot.Instance.Enabled = false
            slot.Instance.Adornee = nil
        end
    end
end

function ServiceLayer:_InitWeaponService()
    local function fetch()
        pcall(function()
            local pData = ReplicatedStorage:FindFirstChild("Players")
            local plr = pData and pData:FindFirstChild(LocalPlayer.Name)
            local status = plr and plr:FindFirstChild("Status")
            local gVars = status and status:FindFirstChild("GameplayVariables")
            local eqTool = gVars and gVars:FindFirstChild("EquippedTool")
            if not eqTool then return end

            local wName = eqTool.Value
            if typeof(wName) == "Instance" then wName = wName.Name end
            if type(wName) ~= "string" or wName == "" then return end
            self.Weapon.Name = wName

            local inv = plr:FindFirstChild("Inventory")
            local weaponObj = inv and inv:FindFirstChild(wName)
            local att = weaponObj and weaponObj:FindFirstChild("Attachments")
            if not att then return end

            local magObj = nil
            for _, child in ipairs(att:GetChildren()) do
                if child:IsA("ObjectValue") and (child.Name:lower():find("mag") or child.Name:lower():find("rnd")) then
                    magObj = child
                    break
                end
            end
            if not magObj then return end

            local ammoName = magObj.Name
            local loadedAmmo = magObj:FindFirstChild("LoadedAmmo")
            if loadedAmmo and loadedAmmo:GetChildren()[1] then
                local attr = loadedAmmo:GetChildren()[1]:GetAttribute("AmmoType")
                if attr and attr ~= "" then ammoName = attr end
            end

            local ammoFolder = ReplicatedStorage:FindFirstChild("AmmoTypes")
            local ammoData = ammoFolder and ammoFolder:FindFirstChild(ammoName)
            if ammoData then
                self.Weapon.MuzzleVelocity = ammoData:GetAttribute("MuzzleVelocity") or 800
                self.Weapon.Drop = ammoData:GetAttribute("ProjectileDrop") or Workspace.Gravity
            end
        end)
    end

    local function bind()
        for _, c in ipairs(self._weaponConns) do c:Disconnect() end
        table.clear(self._weaponConns)

        local pData = ReplicatedStorage:WaitForChild("Players", 5)
        local pFolder = pData and pData:WaitForChild(LocalPlayer.Name, 5)
        local status = pFolder and pFolder:WaitForChild("Status", 5)
        local gVars = status and status:WaitForChild("GameplayVariables", 5)
        local eqTool = gVars and gVars:WaitForChild("EquippedTool", 5)
        if not eqTool then return end

        fetch()
        table.insert(self._weaponConns, eqTool.Changed:Connect(fetch))
        table.insert(self._weaponConns, eqTool.AttributeChanged:Connect(fetch))
    end

    bind()
    LocalPlayer.CharacterAdded:Connect(function()
        task.wait(0.5)
        bind()
    end)
end

function ServiceLayer:_InitRaycasting()
    self.RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
    self.RaycastParams.IgnoreWater = true
    self.RaycastParams.RespectCanCollide = false
end

function ServiceLayer:UpdateIgnoreList(myChar)
    table.clear(self.IgnoreBuffer)
    if myChar then table.insert(self.IgnoreBuffer, myChar) end
    table.insert(self.IgnoreBuffer, Camera)
    if self._poolFolder then table.insert(self.IgnoreBuffer, self._poolFolder) end
    self.RaycastParams.FilterDescendantsInstances = self.IgnoreBuffer
end

function ServiceLayer:CheckBasicOcclusion(originPos, targetPos, targetChar)
    local dir = targetPos - originPos
    local result = Workspace:Raycast(originPos, dir, self.RaycastParams)
    if not result then return true end
    local hit = result.Instance
    return hit and (hit:IsDescendantOf(targetChar) or (not hit.CanCollide and hit.Transparency > 0.5))
end

function ServiceLayer:CheckFineOcclusion(originPos, part, targetChar)
    if not part then return nil end
    local partCF = part.CFrame
    local size = part.Size

    if self:CheckBasicOcclusion(originPos, partCF.Position, targetChar) then
        return partCF.Position
    end

    for i = 2, #self.ProbeOffsets do
        local worldPoint = partCF:PointToWorldSpace(self.ProbeOffsets[i] * size)
        if self:CheckBasicOcclusion(originPos, worldPoint, targetChar) then
            return worldPoint
        end
    end
    return nil
end

function ServiceLayer:SolveBallistics(origin, targetPos, targetVel, muzzleVel, gravity, mult)
    mult = mult or 1.0
    local gravVec = Vector3.new(0, gravity, 0)
    local disp = targetPos - origin

    local a = 0.25 * gravVec:Dot(gravVec)
    local b = gravVec:Dot(disp) - (muzzleVel * muzzleVel)
    local c = disp:Dot(disp)

    local u1, u2 = solveQuadratic(a, b, c)
    local time = 0

    if u1 and u1 > 0 then time = math.sqrt(u1)
    elseif u2 and u2 > 0 then time = math.sqrt(u2)
    else time = disp.Magnitude / muzzleVel end

    if targetVel.Magnitude > 0.05 then
        for _ = 1, 2 do
            local pPos = targetPos + (targetVel * (time * mult))
            local nDisp = pPos - origin
            local nb = gravVec:Dot(nDisp) - (muzzleVel * muzzleVel)
            local nc = nDisp:Dot(nDisp)
            local nu1, nu2 = solveQuadratic(a, nb, nc)
            if nu1 and nu1 > 0 then time = math.sqrt(nu1)
            elseif nu2 and nu2 > 0 then time = math.sqrt(nu2) end
        end
    end

    time = time * mult
    local drop = 0.5 * gravity * (time * time)
    return Vector3.new(
        targetPos.X + (targetVel.X * time),
        targetPos.Y + (targetVel.Y * time) + drop,
        targetPos.Z + (targetVel.Z * time)
    )
end

function ServiceLayer:GetAimPart()
    local vm = Camera:FindFirstChild("ViewModel")
    return vm and vm:FindFirstChild("Item") and vm.Item:FindFirstChild("Offsets") and vm.Item.Offsets:FindFirstChild("AimPart")
end

function ServiceLayer:_SanitizeInstance(inst)
    if not inst or isProtectedAsset(inst) then return end

    if inst:IsA("BasePart") then
        inst.Material = Enum.Material.SmoothPlastic
        inst.Reflectance = 0
        inst.CastShadow = false

        if inst:IsA("MeshPart") then
            inst.TextureID = ""
        end

        if inst.Anchored then
            inst.CanTouch = false
            if not inst.CanCollide then
                inst.CanQuery = false
            end
        end
    elseif inst:IsA("SpecialMesh") then
        inst.TextureId = ""
    elseif inst:IsA("Decal") or inst:IsA("Texture") then
        inst.Transparency = 1
    elseif inst:IsA("SurfaceAppearance") then
        inst:Destroy()
    elseif inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam")
        or inst:IsA("Fire") or inst:IsA("Smoke") or inst:IsA("Sparkles") then
        inst.Enabled = false
    elseif inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight") then
        inst.Enabled = false
        inst.Shadows = false
    end
end

function ServiceLayer:TuneGraphicsPipeline()
    pcall(function()
        local rSettings = settings():GetService("RenderSettings")
        rSettings.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level01

        Lighting.FogStart = 0
        Lighting.FogEnd = 1e8
        Lighting.GlobalShadows = false
        Lighting.EnvironmentDiffuseScale = 0
        Lighting.EnvironmentSpecularScale = 0
        Lighting.Brightness = 2

        for _, v in ipairs(Lighting:GetChildren()) do
            if v:IsA("PostEffect") or v:IsA("Atmosphere") or v:IsA("Clouds") or v:IsA("Sky") then
                if v:IsA("PostEffect") then
                    v.Enabled = false
                else
                    v:Destroy()
                end
            end
        end

        local terrain = Workspace.Terrain
        if terrain then
            terrain.Decoration = false
            terrain.WaterWaveSize = 0
            terrain.WaterWaveSpeed = 0
            terrain.WaterReflectance = 0
            terrain.WaterTransparency = 1
        end
    end)
end

function ServiceLayer:OptimizeWorkspace()
    self:TuneGraphicsPipeline()
    for _, inst in ipairs(Workspace:GetDescendants()) do
        self:_SanitizeInstance(inst)
    end
end

function ServiceLayer:_InitOptimizerPipeline()
    self._originalLighting.GlobalShadows = Lighting.GlobalShadows
    self._originalLighting.FogEnd = Lighting.FogEnd

    local queueHead = 1

    self._queueHeartbeat = RunService.Heartbeat:Connect(function()
        if not self.State.Toggles.FPSBoost or queueHead > #self._streamQueue then return end

        local count = 0
        local queue = self._streamQueue
        local qLen = #queue
        while queueHead <= qLen and count < STREAM_BATCH_SIZE do
            local inst = queue[queueHead]
            queue[queueHead] = false
            queueHead = queueHead + 1
            if inst and inst.Parent then
                self:_SanitizeInstance(inst)
            end
            count = count + 1
        end

        if queueHead > 256 then
            local compacted = {}
            for i = queueHead, qLen do
                local item = queue[i]
                if item then table.insert(compacted, item) end
            end
            self._streamQueue = compacted
            queueHead = 1
        end
    end)

    self.State:Subscribe("Toggle_FPSBoost", function(enabled)
        if enabled then
            self:OptimizeWorkspace()

            if not self._optimizerConn then
                self._optimizerConn = Workspace.DescendantAdded:Connect(function(desc)
                    if self.State.Toggles.FPSBoost then
                        table.insert(self._streamQueue, desc)
                    end
                end)
            end
        else
            table.clear(self._streamQueue)
            queueHead = 1
            if self._optimizerConn then
                self._optimizerConn:Disconnect()
                self._optimizerConn = nil
            end

            pcall(function()
                Lighting.GlobalShadows = self._originalLighting.GlobalShadows or true
                Lighting.FogEnd = self._originalLighting.FogEnd or 10000
                for _, v in ipairs(Lighting:GetChildren()) do
                    if v:IsA("PostEffect") then
                        v.Enabled = true
                    end
                end
                local terrain = Workspace.Terrain
                if terrain then
                    terrain.Decoration = true
                end
            end)
        end
    end)
end

function ServiceLayer:_InitFullbrightPipeline()
    local function applyFullbright()
        if not self.State.Toggles.Fullbright then return end

        pcall(function()
            Lighting.Ambient = Color3.fromRGB(200, 200, 200)
            Lighting.OutdoorAmbient = Color3.fromRGB(200, 200, 200)
            Lighting.Brightness = 2
            Lighting.GlobalShadows = false
            Lighting.ExposureCompensation = 0.25
            Lighting.FogEnd = 1e6
        end)
    end

    self.State:Subscribe("Toggle_Fullbright", function(enabled)
        for _, conn in ipairs(self._fullbrightConns) do
            conn:Disconnect()
        end
        table.clear(self._fullbrightConns)

        if enabled then
            pcall(function()
                self._originalLightingFB.Ambient = Lighting.Ambient
                self._originalLightingFB.OutdoorAmbient = Lighting.OutdoorAmbient
                self._originalLightingFB.Brightness = Lighting.Brightness
                self._originalLightingFB.GlobalShadows = Lighting.GlobalShadows
                self._originalLightingFB.ExposureCompensation = Lighting.ExposureCompensation
                self._originalLightingFB.FogEnd = Lighting.FogEnd
            end)

            applyFullbright()

            table.insert(self._fullbrightConns, Lighting:GetPropertyChangedSignal("Ambient"):Connect(applyFullbright))
            table.insert(self._fullbrightConns, Lighting:GetPropertyChangedSignal("OutdoorAmbient"):Connect(applyFullbright))
            table.insert(self._fullbrightConns, Lighting:GetPropertyChangedSignal("Brightness"):Connect(applyFullbright))
            table.insert(self._fullbrightConns, Lighting:GetPropertyChangedSignal("GlobalShadows"):Connect(applyFullbright))
            table.insert(self._fullbrightConns, Lighting:GetPropertyChangedSignal("ExposureCompensation"):Connect(applyFullbright))
        else
            pcall(function()
                Lighting.Ambient = self._originalLightingFB.Ambient or Color3.fromRGB(128, 128, 128)
                Lighting.OutdoorAmbient = self._originalLightingFB.OutdoorAmbient or Color3.fromRGB(128, 128, 128)
                Lighting.Brightness = self._originalLightingFB.Brightness or 1
                Lighting.GlobalShadows = (self._originalLightingFB.GlobalShadows ~= nil and self._originalLightingFB.GlobalShadows) or true
                Lighting.ExposureCompensation = self._originalLightingFB.ExposureCompensation or 0
                Lighting.FogEnd = self._originalLightingFB.FogEnd or 10000
            end)
        end
    end)
end

return ServiceLayer