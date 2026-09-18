-- ============================================================================
-- NeuralHUD.luau – AR Neural Interface with Radar, Ballistics & Full Controls
-- ============================================================================

local CoreGui          = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local StatsService     = game:GetService("Stats")
local Workspace        = game:GetService("Workspace")
local Players          = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

local NeuralHUD = {}
NeuralHUD.__index = NeuralHUD

-- ----------------------------------------------------------------------------
-- COLOR PALETTE & ASSETS
-- ----------------------------------------------------------------------------
local PALETTE = {
	Cyan       = Color3.fromRGB(0, 240, 255),
	Amber      = Color3.fromRGB(255, 180, 0),
	NeonRed    = Color3.fromRGB(255, 60, 60),
	Emerald    = Color3.fromRGB(60, 210, 80),
	DarkGlass  = Color3.fromRGB(6, 12, 18),
	PanelGlass = Color3.fromRGB(10, 20, 30),
	TextDim    = Color3.fromRGB(140, 160, 180),
	TextWhite  = Color3.fromRGB(225, 240, 250),
	Border     = Color3.fromRGB(0, 180, 210),
}

local TARGET_BONES = {"Head", "HumanoidRootPart", "UpperTorso", "LowerTorso"}

function NeuralHUD.new(stateManager, serviceLayer, executionEngine)
	local self = setmetatable({
		State     = stateManager,
		Services  = serviceLayer,
		Engine    = executionEngine,
		
		AccentColor = PALETTE.Cyan,
		MenuOpen    = false,
		
		RadarBlips  = {},
		RadarZoom   = 1.0,
	}, NeuralHUD)

	self:_BuildViewportRoot()
	self:_BuildARRerouteReticle()
	self:_BuildTelemetryHUD()
	self:_BuildRadarHUD()
	self:_BuildTacticalConsole()
	self:_HookInput()
	self:_StartRenderPipelines()

	return self
end

-- ----------------------------------------------------------------------------
-- 1. ROOT CONTAINER
-- ----------------------------------------------------------------------------
function NeuralHUD:_BuildViewportRoot()
	self.Gui = Instance.new("ScreenGui")
	self.Gui.Name = "NeuralLink_AR_HUD"
	self.Gui.ResetOnSpawn = false
	self.Gui.IgnoreGuiInset = true
	self.Gui.DisplayOrder = 99999
	self.Gui.Parent = CoreGui
end

-- ----------------------------------------------------------------------------
-- 2. AR RETICLE & PREDICTIVE LEAD PIP
-- ----------------------------------------------------------------------------
function NeuralHUD:_BuildARRerouteReticle()
	self.FOVRing = Instance.new("Frame")
	self.FOVRing.AnchorPoint = Vector2.new(0.5, 0.5)
	self.FOVRing.BackgroundTransparency = 1
	self.FOVRing.Visible = false
	self.FOVRing.Parent = self.Gui

	local ringStroke = Instance.new("UIStroke", self.FOVRing)
	ringStroke.Color = self.AccentColor
	ringStroke.Thickness = 1.2
	ringStroke.Transparency = 0.4
	self.RingStroke = ringStroke

	Instance.new("UICorner", self.FOVRing).CornerRadius = UDim.new(1, 0)

	-- Reticle Corner Brackets
	for i = 0, 3 do
		local bracket = Instance.new("Frame")
		bracket.Size = UDim2.new(0, 8, 0, 2)
		bracket.BackgroundColor3 = self.AccentColor
		bracket.BorderSizePixel = 0
		bracket.AnchorPoint = Vector2.new(0.5, 0.5)
		bracket.Position = UDim2.new(
			0.5 + math.cos(math.rad(i * 90)) * 0.52, 0,
			0.5 + math.sin(math.rad(i * 90)) * 0.52, 0
		)
		bracket.Rotation = i * 90
		bracket.Parent = self.FOVRing
	end

	-- Kinetic Intercept Lead Pip
	self.LeadPip = Instance.new("Frame")
	self.LeadPip.Size = UDim2.new(0, 10, 0, 10)
	self.LeadPip.AnchorPoint = Vector2.new(0.5, 0.5)
	self.LeadPip.BackgroundColor3 = PALETTE.Amber
	self.LeadPip.BackgroundTransparency = 0.2
	self.LeadPip.Rotation = 45
	self.LeadPip.Visible = false
	self.LeadPip.Parent = self.Gui
	
	local pipStroke = Instance.new("UIStroke", self.LeadPip)
	pipStroke.Color = Color3.new(1, 1, 1)
	pipStroke.Thickness = 1

	local leadLbl = Instance.new("TextLabel")
	leadLbl.Size = UDim2.new(0, 60, 0, 12)
	leadLbl.Position = UDim2.new(1, 4, 0, -2)
	leadLbl.BackgroundTransparency = 1
	leadLbl.Text = "LEAD // PIP"
	leadLbl.Font = Enum.Font.Code
	leadLbl.TextSize = 8
	leadLbl.TextColor3 = PALETTE.Amber
	leadLbl.TextXAlignment = Enum.TextXAlignment.Left
	leadLbl.Parent = self.LeadPip
end

-- ----------------------------------------------------------------------------
-- 3. TELEMETRY AR CORNER (System Diagnostics)
-- ----------------------------------------------------------------------------
function NeuralHUD:_BuildTelemetryHUD()
	self.SysPanel = Instance.new("Frame")
	self.SysPanel.Size = UDim2.new(0, 210, 0, 48)
	self.SysPanel.Position = UDim2.new(1, -220, 0, 16)
	self.SysPanel.BackgroundColor3 = PALETTE.DarkGlass
	self.SysPanel.BackgroundTransparency = 0.25
	self.SysPanel.BorderSizePixel = 0
	self.SysPanel.Parent = self.Gui

	Instance.new("UICorner", self.SysPanel).CornerRadius = UDim.new(0, 4)

	local sysStroke = Instance.new("UIStroke", self.SysPanel)
	sysStroke.Color = self.AccentColor
	sysStroke.Thickness = 1
	sysStroke.Transparency = 0.5

	self.SysStatsLbl = Instance.new("TextLabel")
	self.SysStatsLbl.Size = UDim2.new(1, -12, 0, 16)
	self.SysStatsLbl.Position = UDim2.new(0, 8, 0, 6)
	self.SysStatsLbl.BackgroundTransparency = 1
	self.SysStatsLbl.Text = "FPS: --  |  Ping: --ms"
	self.SysStatsLbl.Font = Enum.Font.GothamSemibold
	self.SysStatsLbl.TextSize = 10
	self.SysStatsLbl.TextColor3 = PALETTE.TextWhite
	self.SysStatsLbl.TextXAlignment = Enum.TextXAlignment.Left
	self.SysStatsLbl.Parent = self.SysPanel

	self.WeaponStatsLbl = Instance.new("TextLabel")
	self.WeaponStatsLbl.Size = UDim2.new(1, -12, 0, 14)
	self.WeaponStatsLbl.Position = UDim2.new(0, 8, 0, 24)
	self.WeaponStatsLbl.BackgroundTransparency = 1
	self.WeaponStatsLbl.Text = "Weapon: -- | MV: -- | Drop: --"
	self.WeaponStatsLbl.Font = Enum.Font.Gotham
	self.WeaponStatsLbl.TextSize = 9
	self.WeaponStatsLbl.TextColor3 = PALETTE.TextDim
	self.WeaponStatsLbl.TextXAlignment = Enum.TextXAlignment.Left
	self.WeaponStatsLbl.Parent = self.SysPanel
end

-- ----------------------------------------------------------------------------
-- 4. RADAR / MINIMAP SYSTEM
-- ----------------------------------------------------------------------------
function NeuralHUD:_BuildRadarHUD()
	local sz = self.State.Settings.RadarSize

	self.RadarFrame = Instance.new("Frame")
	self.RadarFrame.Size = UDim2.new(0, sz, 0, sz)
	self.RadarFrame.Position = UDim2.new(1, -(sz + 20), 1, -(sz + 20))
	self.RadarFrame.BackgroundColor3 = PALETTE.DarkGlass
	self.RadarFrame.BackgroundTransparency = 0.2
	self.RadarFrame.BorderSizePixel = 0
	self.RadarFrame.Visible = false
	self.RadarFrame.Parent = self.Gui

	Instance.new("UICorner", self.RadarFrame).CornerRadius = UDim.new(1, 0)
	local rStroke = Instance.new("UIStroke", self.RadarFrame)
	rStroke.Color = self.AccentColor
	rStroke.Thickness = 1.5
	rStroke.Transparency = 0.45

	self.RadarClip = Instance.new("Frame")
	self.RadarClip.Size = UDim2.new(1, 0, 1, 0)
	self.RadarClip.BackgroundTransparency = 1
	self.RadarClip.ClipsDescendants = true
	self.RadarClip.Parent = self.RadarFrame
	Instance.new("UICorner", self.RadarClip).CornerRadius = UDim.new(1, 0)

	local radarLbl = Instance.new("TextLabel")
	radarLbl.Size = UDim2.new(1, 0, 0, 16)
	radarLbl.Position = UDim2.new(0, 0, 0, 4)
	radarLbl.BackgroundTransparency = 1
	radarLbl.Text = "RADAR"
	radarLbl.TextSize = 8
	radarLbl.Font = Enum.Font.GothamBold
	radarLbl.TextColor3 = self.AccentColor
	radarLbl.ZIndex = 4
	radarLbl.Parent = self.RadarFrame

	local centerBlip = Instance.new("TextLabel")
	centerBlip.Size = UDim2.new(0, 16, 0, 16)
	centerBlip.Position = UDim2.new(0.5, -8, 0.5, -8)
	centerBlip.BackgroundTransparency = 1
	centerBlip.Text = "▲"
	centerBlip.TextColor3 = Color3.new(1, 1, 1)
	centerBlip.TextSize = 14
	centerBlip.ZIndex = 3
	centerBlip.Parent = self.RadarClip

	local function makeZoomBtn(text, pos, delta)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0, 20, 0, 20)
		b.Position = pos
		b.BackgroundColor3 = PALETTE.PanelGlass
		b.TextColor3 = Color3.new(1, 1, 1)
		b.TextSize = 13
		b.Text = text
		b.Font = Enum.Font.GothamBold
		b.BorderSizePixel = 0
		b.ZIndex = 5
		b.Parent = self.RadarFrame
		Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
		b.Activated:Connect(function()
			self.RadarZoom = math.clamp(self.RadarZoom + delta, 0.3, 4.0)
		end)
	end

	makeZoomBtn("+", UDim2.new(1, -12, 0.5, -22), -0.2)
	makeZoomBtn("−", UDim2.new(1, -12, 0.5, 4), 0.2)

	-- Draggable Radar
	local dragging, dragStart, startPos = false, nil, nil
	self.RadarFrame.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragStart = i.Position
			startPos = self.RadarFrame.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
			local delta = i.Position - dragStart
			self.RadarFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
	end)
end

function NeuralHUD:_UpdateRadar()
	if not self.State.Toggles.Radar then
		self.RadarFrame.Visible = false
		return
	end

	self.RadarFrame.Visible = true
	local newSz = self.State.Settings.RadarSize
	if math.abs(self.RadarFrame.AbsoluteSize.X - newSz) > 1 then
		self.RadarFrame.Size = UDim2.new(0, newSz, 0, newSz)
	end

	local char = LocalPlayer.Character
	if not char or not char:FindFirstChild("HumanoidRootPart") then return end
	local root = char.HumanoidRootPart
	local range = self.State.Settings.RadarRange * self.RadarZoom

	for _, pl in ipairs(Players:GetPlayers()) do
		if pl ~= LocalPlayer then
			local pChar = pl.Character
			local blip = self.RadarBlips[pl]
			if not blip then
				blip = Instance.new("TextLabel")
				blip.Size = UDim2.new(0, 12, 0, 12)
				blip.BackgroundTransparency = 1
				blip.Text = "▲"
				blip.TextSize = 11
				blip.ZIndex = 2
				blip.Parent = self.RadarClip
				self.RadarBlips[pl] = blip
			end

			if pChar and pChar:FindFirstChild("HumanoidRootPart") then
				local hum = pChar:FindFirstChildOfClass("Humanoid")
				if hum and hum.Health > 0 then
					local relCF = root.CFrame:ToObjectSpace(pChar.HumanoidRootPart.CFrame)
					local rp = relCF.Position
					local dist = math.sqrt(rp.X^2 + rp.Z^2)

					if dist <= range then
						blip.Visible = true
						local radius = self.RadarFrame.AbsoluteSize.X / 2
						local scale = radius / range
						blip.Position = UDim2.new(0.5, rp.X * scale - 6, 0.5, rp.Z * scale - 6)
						local _, yRot, _ = relCF:ToOrientation()
						blip.Rotation = -math.deg(yRot)
						
						if self.State.Toggles.FriendCheck and self.Services:IsFriend(pl) then
							blip.TextColor3 = PALETTE.Emerald
						else
							blip.TextColor3 = PALETTE.NeonRed
						end
					else
						blip.Visible = false
					end
				else
					blip.Visible = false
				end
			else
				blip.Visible = false
			end
		end
	end

	for pl, blip in pairs(self.RadarBlips) do
		if not pl.Parent then
			blip:Destroy()
			self.RadarBlips[pl] = nil
		end
	end
end

-- ----------------------------------------------------------------------------
-- 5. HOLOGRAPHIC TACTICAL CONSOLE (Menu)
-- ----------------------------------------------------------------------------
function NeuralHUD:_BuildTacticalConsole()
	self.Console = Instance.new("CanvasGroup")
	self.Console.Name = "NeuralConsole"
	self.Console.Size = UDim2.new(0, 810, 0, 440)
	self.Console.Position = UDim2.new(0.5, -405, 0.5, -220)
	self.Console.BackgroundColor3 = PALETTE.DarkGlass
	self.Console.BackgroundTransparency = 0.08
	self.Console.BorderSizePixel = 0
	self.Console.Visible = false
	self.Console.Parent = self.Gui

	Instance.new("UICorner", self.Console).CornerRadius = UDim.new(0, 6)
	local stroke = Instance.new("UIStroke", self.Console)
	stroke.Color = self.AccentColor
	stroke.Thickness = 1.5

	-- Title Bar
	local topBar = Instance.new("Frame")
	topBar.Size = UDim2.new(1, 0, 0, 30)
	topBar.BackgroundColor3 = PALETTE.PanelGlass
	topBar.BorderSizePixel = 0
	topBar.Parent = self.Console

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Size = UDim2.new(0, 300, 1, 0)
	titleLbl.Position = UDim2.new(0, 12, 0, 0)
	titleLbl.BackgroundTransparency = 1
	titleLbl.Text = "◈ NAPOLEON'S CONSOLE // NEURAL AR INTERFACE"
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 11
	titleLbl.TextColor3 = self.AccentColor
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.Parent = topBar

	-- Columns Container
	local colContainer = Instance.new("Frame")
	colContainer.Size = UDim2.new(1, -20, 1, -42)
	colContainer.Position = UDim2.new(0, 10, 0, 36)
	colContainer.BackgroundTransparency = 1
	colContainer.Parent = self.Console

	local colLayout = Instance.new("UIListLayout", colContainer)
	colLayout.FillDirection = Enum.FillDirection.Horizontal
	colLayout.Padding = UDim.new(0, 8)

	-- 4 Main Columns
	self.ColCombat  = self:_CreateColumn("Combat", colContainer)
	self.ColESP     = self:_CreateColumn("ESP", colContainer)
	self.ColVisuals = self:_CreateColumn("Visuals", colContainer)
	self.ColConfig  = self:_CreateColumn("Config", colContainer)

	self:_PopulateWidgets()
end

function NeuralHUD:_CreateColumn(title, parent)
	local col = Instance.new("Frame")
	col.Size = UDim2.new(0.25, -6, 1, 0)
	col.BackgroundColor3 = PALETTE.PanelGlass
	col.BackgroundTransparency = 0.4
	col.BorderSizePixel = 0
	col.Parent = parent
	Instance.new("UICorner", col).CornerRadius = UDim.new(0, 4)

	local stroke = Instance.new("UIStroke", col)
	stroke.Color = self.AccentColor
	stroke.Thickness = 1
	stroke.Transparency = 0.7

	local hdr = Instance.new("TextLabel")
	hdr.Size = UDim2.new(1, -10, 0, 22)
	hdr.Position = UDim2.new(0, 6, 0, 2)
	hdr.BackgroundTransparency = 1
	hdr.Text = title
	hdr.Font = Enum.Font.GothamBold
	hdr.TextSize = 11
	hdr.TextColor3 = self.AccentColor
	hdr.TextXAlignment = Enum.TextXAlignment.Left
	hdr.Parent = col

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, -6, 1, -28)
	scroll.Position = UDim2.new(0, 3, 0, 26)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 2
	scroll.ScrollBarImageColor3 = self.AccentColor
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = col

	local lay = Instance.new("UIListLayout", scroll)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Padding = UDim.new(0, 3)

	return scroll
end

-- ----------------------------------------------------------------------------
-- 6. UI WIDGET BUILDERS
-- ----------------------------------------------------------------------------
function NeuralHUD:_AddToggle(parent, label, toggleKey, order)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, -6, 0, 24)
	btn.BackgroundColor3 = PALETTE.DarkGlass
	btn.BackgroundTransparency = 0.3
	btn.BorderSizePixel = 0
	btn.LayoutOrder = order or 1
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.Parent = parent
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 3)

	local bStroke = Instance.new("UIStroke", btn)
	bStroke.Thickness = 1
	bStroke.Color = PALETTE.Border
	bStroke.Transparency = 0.8

	local tLbl = Instance.new("TextLabel")
	tLbl.Size = UDim2.new(1, -30, 1, 0)
	tLbl.Position = UDim2.new(0, 6, 0, 0)
	tLbl.BackgroundTransparency = 1
	tLbl.Text = label
	tLbl.Font = Enum.Font.Gotham
	tLbl.TextSize = 10
	tLbl.TextColor3 = PALETTE.TextDim
	tLbl.TextXAlignment = Enum.TextXAlignment.Left
	tLbl.Parent = btn

	local statusBox = Instance.new("Frame")
	statusBox.Size = UDim2.new(0, 10, 0, 10)
	statusBox.Position = UDim2.new(1, -16, 0.5, -5)
	statusBox.BackgroundColor3 = PALETTE.DarkGlass
	statusBox.BorderSizePixel = 0
	statusBox.Parent = btn
	Instance.new("UICorner", statusBox).CornerRadius = UDim.new(0, 2)

	local sStroke = Instance.new("UIStroke", statusBox)
	sStroke.Thickness = 1
	sStroke.Color = self.AccentColor

	local function updateVisual()
		local active = self.State.Toggles[toggleKey]
		statusBox.BackgroundColor3 = active and self.AccentColor or PALETTE.DarkGlass
		tLbl.TextColor3 = active and PALETTE.TextWhite or PALETTE.TextDim
		bStroke.Transparency = active and 0.3 or 0.8
	end

	btn.MouseButton1Click:Connect(function()
		self.State:SetToggle(toggleKey, not self.State.Toggles[toggleKey])
		updateVisual()
	end)

	updateVisual()
end

function NeuralHUD:_AddSlider(parent, label, settingKey, minV, maxV, order)
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, -6, 0, 36)
	frame.BackgroundTransparency = 1
	frame.LayoutOrder = order or 1
	frame.Parent = parent

	local tLbl = Instance.new("TextLabel")
	tLbl.Size = UDim2.new(0.6, 0, 0, 14)
	tLbl.Position = UDim2.new(0, 4, 0, 2)
	tLbl.BackgroundTransparency = 1
	tLbl.Text = label
	tLbl.Font = Enum.Font.Gotham
	tLbl.TextSize = 9
	tLbl.TextColor3 = PALETTE.TextDim
	tLbl.TextXAlignment = Enum.TextXAlignment.Left
	tLbl.Parent = frame

	local vLbl = Instance.new("TextLabel")
	vLbl.Size = UDim2.new(0.38, 0, 0, 14)
	vLbl.Position = UDim2.new(0.6, 0, 0, 2)
	vLbl.BackgroundTransparency = 1
	vLbl.Text = tostring(self.State.Settings[settingKey])
	vLbl.Font = Enum.Font.GothamBold
	vLbl.TextSize = 9
	vLbl.TextColor3 = self.AccentColor
	vLbl.TextXAlignment = Enum.TextXAlignment.Right
	vLbl.Parent = frame

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, -8, 0, 3)
	track.Position = UDim2.new(0, 4, 0, 22)
	track.BackgroundColor3 = Color3.fromRGB(20, 35, 45)
	track.BorderSizePixel = 0
	track.Parent = frame

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = self.AccentColor
	fill.BorderSizePixel = 0
	fill.Parent = track

	local function setRatio(ratio)
		ratio = math.clamp(ratio, 0, 1)
		local val
		local range = maxV - minV
		if range <= 5 then
			val = math.floor((minV + range * ratio) * 100) / 100
		elseif range <= 20 then
			val = math.floor((minV + range * ratio) * 10) / 10
		else
			val = math.floor(minV + range * ratio)
		end
		self.State:SetSetting(settingKey, val)
		vLbl.Text = tostring(val)
		fill.Size = UDim2.new(ratio, 0, 1, 0)
	end

	local initRatio = (self.State.Settings[settingKey] - minV) / (maxV - minV)
	fill.Size = UDim2.new(math.clamp(initRatio, 0, 1), 0, 1, 0)

	local dragging = false
	local hitBtn = Instance.new("TextButton")
	hitBtn.Size = UDim2.new(1, 0, 1, 10)
	hitBtn.Position = UDim2.new(0, 0, 0, -5)
	hitBtn.BackgroundTransparency = 1
	hitBtn.Text = ""
	hitBtn.Parent = track

	hitBtn.InputBegan:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging = true end
	end)
	UserInputService.InputChanged:Connect(function(inp)
		if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then
			setRatio((inp.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
	end)
end

function NeuralHUD:_AddCycler(parent, label, options, settingKey, idxKey, order)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -6, 0, 26)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order or 1
	row.Parent = parent

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(0.4, 0, 1, 0)
	lbl.Position = UDim2.new(0, 4, 0, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text = label
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 9
	lbl.TextColor3 = PALETTE.TextDim
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Parent = row

	local prev = Instance.new("TextButton")
	prev.Size = UDim2.new(0, 14, 0, 14)
	prev.Position = UDim2.new(1, -90, 0.5, -7)
	prev.BackgroundTransparency = 1
	prev.Text = "◀"
	prev.Font = Enum.Font.GothamBold
	prev.TextSize = 9
	prev.TextColor3 = PALETTE.TextDim
	prev.Parent = row

	local vLbl = Instance.new("TextLabel")
	vLbl.Size = UDim2.new(0, 56, 1, 0)
	vLbl.Position = UDim2.new(1, -74, 0, 0)
	vLbl.BackgroundTransparency = 1
	vLbl.Font = Enum.Font.GothamSemibold
	vLbl.TextSize = 9
	vLbl.TextColor3 = PALETTE.TextWhite
	vLbl.Parent = row

	local nxt = Instance.new("TextButton")
	nxt.Size = UDim2.new(0, 14, 0, 14)
	nxt.Position = UDim2.new(1, -16, 0.5, -7)
	nxt.BackgroundTransparency = 1
	nxt.Text = "▶"
	nxt.Font = Enum.Font.GothamBold
	nxt.TextSize = 9
	nxt.TextColor3 = PALETTE.TextDim
	nxt.Parent = row

	local function refresh()
		local idx = self.State.Indices[idxKey] or 1
		local selected = options[idx]
		vLbl.Text = tostring(selected)
		self.State:SetSetting(settingKey, selected)
	end

	prev.MouseButton1Click:Connect(function()
		local idx = (self.State.Indices[idxKey] or 1) - 1
		if idx < 1 then idx = #options end
		self.State.Indices[idxKey] = idx
		refresh()
	end)

	nxt.MouseButton1Click:Connect(function()
		local idx = (self.State.Indices[idxKey] or 1) + 1
		if idx > #options then idx = 1 end
		self.State.Indices[idxKey] = idx
		refresh()
	end)

	refresh()
end

function NeuralHUD:_AddActionButton(parent, label, callback, order)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, -6, 0, 24)
	btn.BackgroundColor3 = Color3.fromRGB(0, 80, 105)
	btn.Text = label
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 9
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.LayoutOrder = order or 1
	btn.Parent = parent
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 3)

	btn.MouseButton1Click:Connect(callback)
end

-- ----------------------------------------------------------------------------
-- 7. POPULATE CONSOLE WIDGETS
-- ----------------------------------------------------------------------------
function NeuralHUD:_PopulateWidgets()
	-- COMBAT
	self:_AddToggle(self.ColCombat, "AimAssist", "Aimbot", 1)
	self:_AddToggle(self.ColCombat, "Realistic Mode", "RealisticAim", 2)
	self:_AddSlider(self.ColCombat, "Smoothness", "AimbotSmoothness", 0.01, 1.0, 3)
	self:_AddSlider(self.ColCombat, "Aim FOV", "AimbotFOV", 40, 500, 4)
	self:_AddSlider(self.ColCombat, "Y Offset", "AimbotYOffset", -10, 10, 5)
	self:_AddCycler(self.ColCombat, "Target Bone", TARGET_BONES, "AimbotTarget", "CurrentTargetIdx", 6)
	self:_AddSlider(self.ColCombat, "Time Multiplier", "PredictionMultiplier", 0.5, 3.0, 7)
	self:_AddToggle(self.ColCombat, "Silent Aim", "SilentAim", 8)
	self:_AddSlider(self.ColCombat, "Silent FOV", "SilentAimFOV", 40, 500, 9)
	self:_AddCycler(self.ColCombat, "Silent Bone", TARGET_BONES, "SilentAimTarget", "CurrentSilentTargetIdx", 10)
	self:_AddToggle(self.ColCombat, "FOV Circle", "FOVCircle", 11)
	self:_AddToggle(self.ColCombat, "Wall Check", "WallCheck", 12)
	self:_AddToggle(self.ColCombat, "Friend Check", "FriendCheck", 13)
	self:_AddToggle(self.ColCombat, "Target NPCs", "NPCs", 14)

	-- ESP
	self:_AddToggle(self.ColESP, "Master ESP System", "ESP", 1)
	self:_AddSlider(self.ColESP, "Tag Text Size", "ChamsTextSize", 8, 24, 2)
	self:_AddToggle(self.ColESP, "Wall Check Occlusion", "WallCheck", 3)
	self:_AddToggle(self.ColESP, "Friend Highlight", "FriendCheck", 4)

	-- VISUALS
	self:_AddToggle(self.ColVisuals, "Fullbright", "Fullbright", 1)
	self:_AddToggle(self.ColVisuals, "No Fog", "NoFog", 2)
	self:_AddToggle(self.ColVisuals, "No Grass", "NoGrass", 3)
	self:_AddToggle(self.ColVisuals, "Camera FOV", "FOVChanger", 4)
	self:_AddSlider(self.ColVisuals, "FOV Value", "CameraFOV", 40, 120, 5)
	self:_AddSlider(self.ColVisuals, "Zoom FOV", "ZoomFOV", 1, 50, 6)
	self:_AddToggle(self.ColVisuals, "Radar / Minimap", "Radar", 7)
	self:_AddSlider(self.ColVisuals, "Map Size", "RadarSize", 120, 280, 8)
	self:_AddSlider(self.ColVisuals, "Radar Range", "RadarRange", 50, 500, 9)

	-- CONFIG
	self:_AddToggle(self.ColConfig, "FPS / Ping HUD", "FPSHud", 1)
	self:_AddToggle(self.ColConfig, "FPS Booster", "FPSBoost", 2)
	self:_AddActionButton(self.ColConfig, "Optimize Map Now", function()
		self.Services:OptimizeWorkspace()
	end, 3)
	self:_AddActionButton(self.ColConfig, "Save Config", function()
		self.State:Save()
	end, 4)
	self:_AddActionButton(self.ColConfig, "Load Config", function()
		self.State:Load()
	end, 5)
end

-- ----------------------------------------------------------------------------
-- 8. INPUT & MENU TOGGLE
-- ----------------------------------------------------------------------------
function NeuralHUD:_HookInput()
	UserInputService.InputBegan:Connect(function(inp, proc)
		if proc then return end
		if inp.KeyCode == self.State.Keybinds.OpenKey then
			self.MenuOpen = not self.MenuOpen
			self.Console.Visible = self.MenuOpen
			UserInputService.MouseBehavior = self.MenuOpen and Enum.MouseBehavior.Default or Enum.MouseBehavior.LockCenter
		end
	end)
end

-- ----------------------------------------------------------------------------
-- 9. RENDER STEPPED PIPELINE
-- ----------------------------------------------------------------------------
function NeuralHUD:_StartRenderPipelines()
	local lastFpsTick = tick()
	local frameCount = 0
	local smoothFps = 60

	RunService.RenderStepped:Connect(function(dt)
		local mousePos = UserInputService:GetMouseLocation()

		-- FOV Reticle Update
		if self.State.Toggles.FOVCircle and not self.MenuOpen then
			self.FOVRing.Visible = true
			self.FOVRing.Size = UDim2.new(0, self.State.Settings.AimbotFOV * 2, 0, self.State.Settings.AimbotFOV * 2)
			self.FOVRing.Position = UDim2.new(0, mousePos.X, 0, mousePos.Y)
		else
			self.FOVRing.Visible = false
		end

		-- AR Ballistic Lead Pip
		local bestAim = self.Engine.PipelineContext.BestAimPosition or self.Engine.PipelineContext.BestSilentPosition
		if bestAim then
			local sPos, onScreen = Camera:WorldToViewportPoint(bestAim)
			if onScreen then
				self.LeadPip.Visible = true
				self.LeadPip.Position = UDim2.new(0, sPos.X, 0, sPos.Y)
			else
				self.LeadPip.Visible = false
			end
		else
			self.LeadPip.Visible = false
		end

		-- Update Radar Frame
		self:_UpdateRadar()

		-- Telemetry HUD Refresh (Throttled to 2 Hz)
		frameCount = frameCount + 1
		if tick() - lastFpsTick >= 0.5 then
			smoothFps = math.round(frameCount / (tick() - lastFpsTick))
			frameCount = 0
			lastFpsTick = tick()

			local ping = 0
			pcall(function()
				ping = math.round(StatsService.Network.ServerStatsItem["Data Ping"]:GetValue())
			end)

			self.SysPanel.Visible = self.State.Toggles.FPSHud
			self.SysStatsLbl.Text = string.format("FPS: %d  |  Ping: %dms", smoothFps, ping)
			self.WeaponStatsLbl.Text = string.format(
				"Weapon: %s | MV: %d | Drop: %.1f",
				self.Services.Weapon.Name,
				math.round(self.Services.Weapon.MuzzleVelocity),
				self.Services.Weapon.Drop
			)
		end
	end)
end

return NeuralHUD