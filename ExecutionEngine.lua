-- ============================================================================
-- ExecutionEngine.luau (Decoupled Loop Pipeline & Target Resolver)
-- ============================================================================

local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local Players          = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

local ExecutionEngine = {}
ExecutionEngine.__index = ExecutionEngine

-- Visualizer Constants
local COLOR_FRIEND  = Color3.fromRGB(46, 204, 113)
local COLOR_CORPSE  = Color3.fromRGB(150, 150, 160)
local COLOR_TARGET  = Color3.fromRGB(255, 180, 0)
local COLOR_MOD     = Color3.fromRGB(255, 45, 45)      -- Invisible Player / Mod (Red)
local COLOR_INV_NPC = Color3.fromRGB(255, 220, 0)     -- Invisible NPC (Yellow)
local DEFAULT_FOV   = 70

-- ----------------------------------------------------------------------------
-- FAIL-SAFE BONE & POSITION RESOLVER
-- ----------------------------------------------------------------------------
local function getTargetBonePosition(model, entity, targetSetting, realisticAim)
    local root = (entity and entity.RootPart) or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart")
    local head = (entity and entity.Head) or model:FindFirstChild("Head") or root

    -- Fallback to Model Pivot if no parts are found
    if not root and not head then
        local pivot = model:GetPivot()
        return pivot.Position, model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
    end

    local fallbackBone = head or root

    -- Realistic Mode (Neck Anchor + Humanized Perlin Noise)
    if realisticAim and head and root then
        local torso = model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
        local baseNeckPos

        if torso and torso:IsA("BasePart") and head:IsA("BasePart") then
            baseNeckPos = torso.Position:Lerp(head.Position, 0.72)
        elseif head:IsA("BasePart") then
            baseNeckPos = head.Position - Vector3.new(0, 0.55, 0)
        elseif root:IsA("BasePart") then
            baseNeckPos = root.Position + Vector3.new(0, 1.2, 0)
        else
            baseNeckPos = model:GetPivot().Position
        end

        local t = tick()
        local vertNoise = (math.noise(t * 3.2, 12.4, 0) * 0.18) + 0.24
        local horizNoise = math.noise(t * 2.1, 0, 84.1) * 0.08
        local camRight = Camera.CFrame.RightVector

        return baseNeckPos + Vector3.new(0, vertNoise, 0) + (camRight * horizNoise), fallbackBone
    end

    -- Standard Target Mode
    local targetPart = (targetSetting and model:FindFirstChild(targetSetting)) or fallbackBone
    if targetPart and targetPart:IsA("BasePart") then
        return targetPart.Position, targetPart
    end

    if fallbackBone and fallbackBone:IsA("BasePart") then
        return fallbackBone.Position, fallbackBone
    end

    return model:GetPivot().Position, fallbackBone
end

-- ----------------------------------------------------------------------------
-- CONSTRUCTOR
-- ----------------------------------------------------------------------------
function ExecutionEngine.new(stateManager, serviceLayer)
    local self = setmetatable({
        State    = stateManager,
        Services = serviceLayer,

        -- Shared Inter-Thread Pipeline Context
        PipelineContext = {
            BestAimPosition    = nil,
            BestSilentPosition = nil,
            LockedAimModel     = nil,
            LockedSilentModel  = nil,
            AimbotActive       = false,
            SilentAimActive    = false,
        },

        -- Buffers
        _aimCandidates    = {},
        _silentCandidates = {},

        -- Connections
        _heartbeatConn = nil,
        _renderConn    = nil,
    }, ExecutionEngine)

    -- FOV Restoration Listener
    self.State:Subscribe("Toggle_FOVChanger", function(enabled)
        if not enabled then
            Camera.FieldOfView = DEFAULT_FOV
        end
    end)

    return self
end

-- ----------------------------------------------------------------------------
-- PIPELINE START
-- ----------------------------------------------------------------------------
function ExecutionEngine:Start()
    -- ------------------------------------------------------------------------
    -- 1. HEAVY THREAD (Heartbeat): Physics, Occlusion, Ballistics & Visuals
    -- ------------------------------------------------------------------------
    self._heartbeatConn = RunService.Heartbeat:Connect(function()
        local char = LocalPlayer.Character
        if not char then return end

        local originPart = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
        local originPos = originPart and originPart.Position or Camera.CFrame.Position
        local mousePos = UserInputService:GetMouseLocation()

        -- Update raycast ignore buffers & mark-and-sweep visual frame
        self.Services:UpdateIgnoreList(char)
        self.Services:BeginVisualFrame()

        table.clear(self._aimCandidates)
        table.clear(self._silentCandidates)

        local aimbotHeld  = self.State.Toggles.Aimbot and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
        local silentAimOn = self.State.Toggles.SilentAim
        local wallCheckOn = self.State.Toggles.WallCheck
        local targetNPCs  = self.State.Toggles.NPCs
        local realisticOn = self.State.Toggles.RealisticAim
        local espOn       = self.State.Toggles.ESP

        local mv   = self.Services.Weapon.MuzzleVelocity
        local drop = self.Services.Weapon.Drop
        local mult = self.State.Settings.PredictionMultiplier
        local camCF = Camera.CFrame

        -- --------------------------------------------------------------------
        -- A. PROCESS LIVING ENTITIES
        -- --------------------------------------------------------------------
        for model, entity in pairs(self.Services.Entities) do
            if model.Parent and entity.Humanoid and entity.Humanoid.Health > 0 and entity.RootPart and entity.RootPart.Parent then
                local isInvisible = self.Services:IsEntityInvisible(model, entity)
                entity.IsInvisible = isInvisible

                -- Moderator Check: Invisible players are completely ignored by the aiming system
                if entity.IsPlayer and isInvisible then
                    continue
                end

                if not entity.IsPlayer and not targetNPCs then
                    continue
                end

                local root = entity.RootPart
                local rootPos = root.Position
                local toTarget = rootPos - camCF.Position
                local dist3D = toTarget.Magnitude

                if camCF.LookVector:Dot(toTarget.Unit) > 0.05 then
                    local screenPos, onScreen = Camera:WorldToViewportPoint(rootPos)
                    local dist2D = onScreen and (Vector2.new(screenPos.X, screenPos.Y) - mousePos).Magnitude or math.huge
                    local isFriend = entity.IsPlayer and self.Services:IsFriend(entity.Player)

                    if not (self.State.Toggles.FriendCheck and isFriend) then
                        local targetVel = root.AssemblyLinearVelocity

                        -- Aimbot Target Candidate
                        if aimbotHeld and dist2D <= self.State.Settings.AimbotFOV then
                            local targetPos, targetBone = getTargetBonePosition(model, entity, self.State.Settings.AimbotTarget, realisticOn)
                            local predicted = self.Services:SolveBallistics(originPos, targetPos, targetVel, mv, drop, mult)
                            
                            table.insert(self._aimCandidates, {
                                Model    = model,
                                Position = predicted,
                                Bone     = targetBone,
                                Score    = dist2D + (dist3D * 0.1),
                            })
                        end

                        -- Silent Aim Target Candidate
                        if silentAimOn and dist2D <= self.State.Settings.SilentAimFOV then
                            local targetPos, targetBone = getTargetBonePosition(model, entity, self.State.Settings.SilentAimTarget, realisticOn)
                            local predicted = self.Services:SolveBallistics(originPos, targetPos, targetVel, mv, drop, mult)
                            
                            table.insert(self._silentCandidates, {
                                Model    = model,
                                Position = predicted,
                                Bone     = targetBone,
                                Score    = dist2D + (dist3D * 0.1),
                            })
                        end
                    end
                end
            else
                self.Services.Entities[model] = nil
            end
        end

        -- --------------------------------------------------------------------
        -- B. RESOLVE AIMBOT TARGET
        -- --------------------------------------------------------------------
        self.PipelineContext.BestAimPosition = nil
        self.PipelineContext.LockedAimModel = nil
        if #self._aimCandidates > 0 then
            table.sort(self._aimCandidates, function(a, b) return a.Score < b.Score end)
            for i = 1, #self._aimCandidates do
                local candidate = self._aimCandidates[i]
                if wallCheckOn and candidate.Bone then
                    local visiblePoint = self.Services:CheckFineOcclusion(originPos, candidate.Bone, candidate.Model)
                    if visiblePoint then
                        self.PipelineContext.BestAimPosition = candidate.Position + Vector3.new(0, self.State.Settings.AimbotYOffset, 0)
                        self.PipelineContext.LockedAimModel = candidate.Model
                        break
                    end
                else
                    self.PipelineContext.BestAimPosition = candidate.Position + Vector3.new(0, self.State.Settings.AimbotYOffset, 0)
                    self.PipelineContext.LockedAimModel = candidate.Model
                    break
                end
            end
        end

        -- --------------------------------------------------------------------
        -- C. RESOLVE SILENT AIM TARGET
        -- --------------------------------------------------------------------
        self.PipelineContext.BestSilentPosition = nil
        self.PipelineContext.LockedSilentModel = nil
        if #self._silentCandidates > 0 then
            table.sort(self._silentCandidates, function(a, b) return a.Score < b.Score end)
            for i = 1, #self._silentCandidates do
                local candidate = self._silentCandidates[i]
                if wallCheckOn and candidate.Bone then
                    local visiblePoint = self.Services:CheckFineOcclusion(originPos, candidate.Bone, candidate.Model)
                    if visiblePoint then
                        self.PipelineContext.BestSilentPosition = candidate.Position
                        self.PipelineContext.LockedSilentModel = candidate.Model
                        break
                    end
                else
                    self.PipelineContext.BestSilentPosition = candidate.Position
                    self.PipelineContext.LockedSilentModel = candidate.Model
                    break
                end
            end
        end

        self.PipelineContext.AimbotActive = (aimbotHeld and self.PipelineContext.BestAimPosition ~= nil)
        self.PipelineContext.SilentAimActive = (silentAimOn and self.PipelineContext.BestSilentPosition ~= nil)

        -- --------------------------------------------------------------------
        -- D. UNIFIED VISUAL PIPELINE
        -- --------------------------------------------------------------------
        if espOn then
            local activeLock = self.PipelineContext.LockedAimModel or self.PipelineContext.LockedSilentModel

            -- 1. Living Targets
            for model, entity in pairs(self.Services.Entities) do
                local isInvisible = (entity.IsInvisible ~= nil) and entity.IsInvisible or self.Services:IsEntityInvisible(model, entity)
                if not entity.IsPlayer and not targetNPCs and not isInvisible then
                    continue
                end

                local root = entity.RootPart
                if root and root.Parent then
                    local head = entity.Head or root
                    local isFriend = entity.IsPlayer and self.Services:IsFriend(entity.Player)
                    local isLockedTarget = (model == activeLock)
                    local dist = math.floor((root.Position - camCF.Position).Magnitude)

                    local isVisible = self.Services:CheckBasicOcclusion(originPos, head.Position, model)
                    local baseColor = isVisible and self.State.Settings.VisibleColor or self.State.Settings.HiddenColor

                    local isModPlayer = entity.IsPlayer and isInvisible
                    local isInvNPC    = (not entity.IsPlayer) and isInvisible

                    local tagColor = baseColor
                    local tagPrefix = ""

                    if isModPlayer then
                        tagColor = COLOR_MOD
                        tagPrefix = "[MOD] "
                    elseif isInvNPC then
                        tagColor = COLOR_INV_NPC
                        tagPrefix = "[INV] "
                    elseif isFriend then
                        tagColor = COLOR_FRIEND
                    end

                    -- Highlight on invisible, locks, and friends
                    if isModPlayer then
                        self.Services:AssignHighlight(model, COLOR_MOD)
                    elseif isInvNPC then
                        self.Services:AssignHighlight(model, COLOR_INV_NPC)
                    elseif isLockedTarget then
                        self.Services:AssignHighlight(model, COLOR_TARGET)
                    elseif isFriend then
                        self.Services:AssignHighlight(model, COLOR_FRIEND)
                    end

                    -- Billboard Tag for all living entities
                    local entityName = tagPrefix .. (entity.Player and entity.Player.DisplayName or model.Name)
                    self.Services:AssignBillboardTag(head, entityName, string.format("[%dm]", dist), tagColor)
                end
            end

            -- 2. Corpses & Ragdolls
            for model, corpse in pairs(self.Services.Corpses) do
                if model.Parent and (tick() - corpse.Timestamp < 60) then
                    self.Services:AssignHighlight(model, COLOR_CORPSE)
                else
                    self.Services.Corpses[model] = nil
                end
            end
        end

        -- Finalize visualizer pool state
        self.Services:EndVisualFrame()
    end)

    -- ------------------------------------------------------------------------
    -- 2. FAST RENDER PATH (RenderStepped): Camera & Viewmodel Transforms
    -- ------------------------------------------------------------------------
    self._renderConn = RunService.RenderStepped:Connect(function()
        if self.State.Toggles.FOVChanger then
            Camera.FieldOfView = self.State.Settings.CameraFOV
        end

        if self.PipelineContext.AimbotActive and self.PipelineContext.BestAimPosition then
            Camera.CFrame = Camera.CFrame:Lerp(
                CFrame.lookAt(Camera.CFrame.Position, self.PipelineContext.BestAimPosition),
                self.State.Settings.AimbotSmoothness
            )
        end

        if self.PipelineContext.SilentAimActive and self.PipelineContext.BestSilentPosition then
            local aimPart = self.Services:GetAimPart()
            if aimPart then
                aimPart.CFrame = CFrame.lookAt(aimPart.Position, self.PipelineContext.BestSilentPosition)
            end
        end
    end)
end

function ExecutionEngine:Destroy()
    if self._heartbeatConn then
        self._heartbeatConn:Disconnect()
        self._heartbeatConn = nil
    end
    if self._renderConn then
        self._renderConn:Disconnect()
        self._renderConn = nil
    end

    Camera.FieldOfView = DEFAULT_FOV
end

return ExecutionEngine