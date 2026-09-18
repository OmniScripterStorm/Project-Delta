-- ============================================================================
-- NAPOLEON'S CONSOLE
-- ============================================================================

local CoreGui     = game:GetService("CoreGui")
local SoundService= game:GetService("SoundService")

-- ----------------------------------------------------------------------------
-- 1. SINGLETON TEARDOWN (Prevents Duplicate Loop & Memory Leaks)
-- ----------------------------------------------------------------------------
if shared.NeuralLinkInstance then
	pcall(function()
		shared.NeuralLinkInstance:Unload()
	end)
	shared.NeuralLinkInstance = nil
end

local existingGui = CoreGui:FindFirstChild("NeuralLink_AR_HUD")
if existingGui then
	existingGui:Destroy()
end

local existingPool = CoreGui:FindFirstChild("EE_HighlightPool")
if existingPool then
	existingPool:Destroy()
end

-- ----------------------------------------------------------------------------
-- 2. MODULE URL ENDPOINTS (GitHub Raw Architecture)
-- ----------------------------------------------------------------------------
local GITHUB_BASE = "https://raw.githubusercontent.com/OmniScripterStorm/Project-Delta/main/"

local MODULES = {
	State     = GITHUB_BASE .. "StateManager.lua",
	Service   = GITHUB_BASE .. "ServiceLayer.lua",
	Execution = GITHUB_BASE .. "ExecutionEngine.lua",
	HUD       = GITHUB_BASE .. "NeuralHUD.lua",
}

-- ----------------------------------------------------------------------------
-- 3. SECURE IMPORT PIPELINE (Fixed Error Capture)
-- ----------------------------------------------------------------------------
local function import(url, moduleName)
    local fetchSuccess, rawCode = pcall(function()
        return game:HttpGet(url)
    end)

    if not fetchSuccess or not rawCode or rawCode == "" then
        error(string.format("[NeuralLink Loader] HTTP Fetch Failed for '%s': %s", moduleName, tostring(rawCode)))
    end

    -- Detect GitHub 404 / HTML responses
    if rawCode == "404: Not Found" or rawCode:find("<!DOCTYPE html>") or rawCode:find("<html") then
        error(string.format("[NeuralLink Loader] Failed to fetch valid Luau source for '%s' from: %s", moduleName, url))
    end

    -- loadstring returns (closure, compileErr)
    local moduleClosure, compileErr = loadstring(rawCode)
    if not moduleClosure or typeof(moduleClosure) ~= "function" then
        error(string.format("[NeuralLink Loader] Syntax/Compilation Failed for '%s':\n%s", moduleName, tostring(compileErr)))
    end

    local executeSuccess, moduleTable = pcall(moduleClosure)
    if not executeSuccess then
        error(string.format("[NeuralLink Loader] Runtime Execution Failed for '%s':\n%s", moduleName, tostring(moduleTable)))
    end

    return moduleTable
end

-- ----------------------------------------------------------------------------
-- 4. BOOTSTRAP ORCHESTRATOR
-- ----------------------------------------------------------------------------
local NeuralLinkApp = {}
NeuralLinkApp.__index = NeuralLinkApp

function NeuralLinkApp.Boot()
	local self = setmetatable({}, NeuralLinkApp)

	print([[
    ╔═══════════════════════════════════════════════════════════╗
    ║      NEURAL-LINK v4.0 // BIONIC AR SYSTEM ONLINE          ║
    ║        Script Identity: SIL6 | Pure Luau Pipeline         ║
    ╚═══════════════════════════════════════════════════════════╝
	]])

	-- 1. Load Remote Modules
	local StateManagerClass   = import(MODULES.State, "StateManager")
	local ServiceLayerClass   = import(MODULES.Service, "ServiceLayer")
	local ExecutionEngineClass = import(MODULES.Execution, "ExecutionEngine")
	local NeuralHUDClass      = import(MODULES.HUD, "NeuralHUD")

	-- 2. Instantiate State & Config Layer
	self.State = StateManagerClass.new("NeuralLink_Settings.json")
	self.State:Load() -- Hydrate saved settings from filesystem

	-- 3. Instantiate Service Layer (Entities, Weapon Listener, Occlusion, Ballistics)
	self.Services = ServiceLayerClass.new(self.State)

	-- 4. Instantiate Execution Engine (Heartbeat Heavy Thread + RenderStepped Fast Path)
	self.Engine = ExecutionEngineClass.new(self.State, self.Services)
	self.Engine:Start()

	-- 5. Instantiate Augmented Reality Neural HUD & Holographic Menu
	self.HUD = NeuralHUDClass.new(self.State, self.Services, self.Engine)

	-- 6. Play Audio Feedback
	task.spawn(function()
		local bootSound = Instance.new("Sound")
		bootSound.SoundId = "rbxassetid://114690770534963"
		bootSound.Volume = 1.0
		bootSound.Parent = SoundService
		bootSound:Play()
		bootSound.Ended:Once(function()
			bootSound:Destroy()
		end)
	end)

	return self
end

function NeuralLinkApp:Unload()
	if self.Engine then
		pcall(function() self.Engine:Destroy() end)
	end
	if self.HUD and self.HUD.Gui then
		pcall(function() self.HUD.Gui:Destroy() end)
	end
	local pool = CoreGui:FindFirstChild("EE_HighlightPool")
	if pool then
		pool:Destroy()
	end
	warn("[NeuralLink] System de-synchronized and unloaded.")
end

-- ----------------------------------------------------------------------------
-- 5. SYSTEM INITIALIZATION
-- ----------------------------------------------------------------------------
local appInstance = NeuralLinkApp.Boot()
shared.NeuralLinkInstance = appInstance

return appInstance