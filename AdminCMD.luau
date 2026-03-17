-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

-- DataStore for bans
local BanDataStore = DataStoreService:GetDataStore("NeonRun_Bans")
local TimeBanDataStore = DataStoreService:GetDataStore("NeonRun_TimeBans")

--================================================================================
-- CONFIGURATION
--================================================================================
local Config = {
	ADMIN_USER_IDS = {
		[10028905439] = true,
		-- Add more admin user IDs here
	},

	ADMIN_RANKS = {
		["Owner"] = 5,
		["HeadAdmin"] = 4,
		["Admin"] = 3,
		["Moderator"] = 2,
		["Helper"] = 1,
	},

	-- Permission levels
	PERMISSIONS = {
		KICK = 2,
		BAN = 3,
		TIMEBAN = 2,
		UNBAN = 3,
		SCAN = 2,
		VIEWLOGS = 1,
		RESET = 2,
		DEBUG = 4,
	},

	-- Ban message
	BAN_MESSAGE = "?? You have been banned from Neon Run!\n\nReason: %s\n\nContact an administrator if you believe this is an error.",
	TIMEBAN_MESSAGE = "?? You are temporarily banned from Neon Run!\n\nReason: %s\nTime remaining: %s\n\nContact an administrator if you believe this is an error.",
}

--================================================================================
-- GLOBAL ADMIN SYSTEM
--================================================================================
_G.AdminSystem = _G.AdminSystem or {
	BannedPlayers = {},
	TimeBannedPlayers = {},
	Logs = {},
	ConnectedPlayers = {},
}

local AdminSystem = _G.AdminSystem

--================================================================================
-- UTILITY FUNCTIONS
--================================================================================

local function Log(action, admin, target, reason)
	local entry = {
		timestamp = os.time(),
		date = os.date("%Y-%m-%d %H:%M:%S"),
		action = action,
		admin = admin and admin.Name or "SYSTEM",
		target = target,
		reason = reason or "No reason provided"
	}
	table.insert(AdminSystem.Logs, entry)

	-- Keep only last 500 logs
	if #AdminSystem.Logs > 500 then
		table.remove(AdminSystem.Logs, 1)
	end

	print(string.format("[ADMIN][%s] %s by %s | Target: %s | Reason: %s",
		entry.date, action, entry.admin, target or "N/A", reason or "N/A"))
end

local function GetAdminLevel(player)
	if not player then return 0 end

	-- Check user ID
	if Config.ADMIN_USER_IDS[player.UserId] then
		return 5 -- Max level for user ID admins
	end

	-- Check group rank (customize group ID)
	local rankName = player:GetRoleInGroup(0) -- Replace 0 with your group ID
	if Config.ADMIN_RANKS[rankName] then
		return Config.ADMIN_RANKS[rankName]
	end

	return 0
end

local function IsAdmin(player, requiredLevel)
	requiredLevel = requiredLevel or 1
	return GetAdminLevel(player) >= requiredLevel
end

local function FormatTime(seconds)
	if seconds < 60 then
		return string.format("%d seconds", seconds)
	elseif seconds < 3600 then
		return string.format("%d minutes", math.floor(seconds / 60))
	elseif seconds < 86400 then
		return string.format("%d hours", math.floor(seconds / 3600))
	else
		return string.format("%d days", math.floor(seconds / 86400))
	end
end

local function FindPlayer(query)
	query = query:lower()
	local matches = {}

	for _, player in ipairs(Players:GetPlayers()) do
		if player.Name:lower():sub(1, #query) == query then
			table.insert(matches, player)
		elseif tostring(player.UserId):lower():sub(1, #query) == query then
			table.insert(matches, player)
		end
	end

	return matches[1], matches
end

--================================================================================
-- BAN SYSTEM
--================================================================================

local function LoadBans()
	local success, data = pcall(function()
		return BanDataStore:GetAsync("BannedPlayers") or {}
	end)
	if success then
		AdminSystem.BannedPlayers = data
	end
end

local function SaveBans()
	pcall(function()
		BanDataStore:SetAsync("BannedPlayers", AdminSystem.BannedPlayers)
	end)
end

local function LoadTimeBans()
	local success, data = pcall(function()
		return TimeBanDataStore:GetAsync("TimeBannedPlayers") or {}
	end)
	if success then
		AdminSystem.TimeBannedPlayers = data
	end
end

local function SaveTimeBans()
	pcall(function()
		TimeBanDataStore:SetAsync("TimeBannedPlayers", AdminSystem.TimeBannedPlayers)
	end)
end

local function IsBanned(userId)
	-- Check permanent ban
	if AdminSystem.BannedPlayers[tostring(userId)] then
		return true, "Permanent", AdminSystem.BannedPlayers[tostring(userId)]
	end

	-- Check time ban
	local timeBan = AdminSystem.TimeBannedPlayers[tostring(userId)]
	if timeBan then
		if os.time() < timeBan.endTime then
			return true, "Temporary", timeBan
		else
			-- Time ban expired, remove it
			AdminSystem.TimeBannedPlayers[tostring(userId)] = nil
			SaveTimeBans()
		end
	end

	return false
end

local function BanPlayer(admin, target, reason)
	if not IsAdmin(admin, Config.PERMISSIONS.BAN) then
		return false, "Insufficient permissions"
	end

	reason = reason or "No reason provided"

	AdminSystem.BannedPlayers[tostring(target.UserId)] = {
		reason = reason,
		admin = admin.Name,
		date = os.date("%Y-%m-%d %H:%M:%S"),
		playerName = target.Name
	}

	SaveBans()
	Log("BAN", admin, target.Name, reason)

	target:Kick(string.format(Config.BAN_MESSAGE, reason))
	return true, string.format("Banned %s permanently", target.Name)
end

local function TimeBanPlayer(admin, target, duration, reason)
	if not IsAdmin(admin, Config.PERMISSIONS.TIMEBAN) then
		return false, "Insufficient permissions"
	end

	reason = reason or "No reason provided"

	local endTime = os.time() + duration

	AdminSystem.TimeBannedPlayers[tostring(target.UserId)] = {
		reason = reason,
		admin = admin.Name,
		date = os.date("%Y-%m-%d %H:%M:%S"),
		endTime = endTime,
		playerName = target.Name
	}

	SaveTimeBans()
	Log("TIMEBAN", admin, target.Name, string.format("%s | Duration: %s", reason, FormatTime(duration)))

	local remaining = FormatTime(duration)
	target:Kick(string.format(Config.TIMEBAN_MESSAGE, reason, remaining))
	return true, string.format("Time banned %s for %s", target.Name, remaining)
end

local function UnbanPlayer(admin, targetName)
	if not IsAdmin(admin, Config.PERMISSIONS.UNBAN) then
		return false, "Insufficient permissions"
	end

	-- Check permanent bans
	for userId, banData in pairs(AdminSystem.BannedPlayers) do
		if banData.playerName:lower() == targetName:lower() then
			AdminSystem.BannedPlayers[userId] = nil
			SaveBans()
			Log("UNBAN", admin, targetName, "Removed permanent ban")
			return true, string.format("Unbanned %s", targetName)
		end
	end

	-- Check time bans
	for userId, banData in pairs(AdminSystem.TimeBannedPlayers) do
		if banData.playerName:lower() == targetName:lower() then
			AdminSystem.TimeBannedPlayers[userId] = nil
			SaveTimeBans()
			Log("UNBAN", admin, targetName, "Removed time ban")
			return true, string.format("Unbanned %s", targetName)
		end
	end

	return false, "Player not found in ban list"
end

local function KickPlayer(admin, target, reason)
	if not IsAdmin(admin, Config.PERMISSIONS.KICK) then
		return false, "Insufficient permissions"
	end

	reason = reason or "Kicked by administrator"

	Log("KICK", admin, target.Name, reason)
	target:Kick("?? You have been kicked!\n\nReason: " .. reason)
	return true, string.format("Kicked %s", target.Name)
end

--================================================================================
-- HACK SCANNER
--================================================================================

local function ScanPlayer(target)
	local scanResults = {
		playerName = target.Name,
		userId = target.UserId,
		timestamp = os.time(),
		flags = {},
		violations = {},
		riskLevel = "LOW",
		riskScore = 0
	}

	-- Get tracker from anti-cheat
	local tracker = _G.PlayerTrackers and _G.PlayerTrackers[target]

	if tracker then
		-- Copy violations
		for k, v in pairs(tracker.violations) do
			scanResults.violations[k] = v
			if v > 0 then
				scanResults.riskScore = scanResults.riskScore + v * 10
				table.insert(scanResults.flags, k .. " violations: " .. v)
			end
		end

		-- Check total warnings
		scanResults.totalWarnings = tracker.totalWarnings or 0
		scanResults.riskScore = scanResults.riskScore + scanResults.totalWarnings * 20
	end

	-- Scan character
	local character = target.Character
	if character then
		local humanoid = character:FindFirstChild("Humanoid")
		local rootPart = character:FindFirstChild("HumanoidRootPart")

		if humanoid then
			-- Check WalkSpeed
			if humanoid.WalkSpeed ~= 52 then
				table.insert(scanResults.flags, "Modified WalkSpeed: " .. humanoid.WalkSpeed)
				scanResults.riskScore = scanResults.riskScore + 30
			end

			-- Check JumpPower
			if humanoid.JumpPower ~= 89.6 then
				table.insert(scanResults.flags, "Modified JumpPower: " .. humanoid.JumpPower)
				scanResults.riskScore = scanResults.riskScore + 30
			end

			-- Check Health
			if humanoid.Health > humanoid.MaxHealth then
				table.insert(scanResults.flags, "Health exceeds max: " .. humanoid.Health .. "/" .. humanoid.MaxHealth)
				scanResults.riskScore = scanResults.riskScore + 50
			end

			-- Check for god mode
			if humanoid.MaxHealth > 1000 then
				table.insert(scanResults.flags, "Abnormal MaxHealth: " .. humanoid.MaxHealth)
				scanResults.riskScore = scanResults.riskScore + 100
			end
		end

		-- Check for illegal BodyMovers
		for _, child in ipairs(character:GetDescendants()) do
			if child:IsA("BodyVelocity") or child:IsA("BodyGyro") or child:IsA("BodyPosition") or child:IsA("BodyThrust") then
				if not child:GetAttribute("Legitimate") then
					table.insert(scanResults.flags, "Illegal BodyMover: " .. child.ClassName .. " (" .. child.Name .. ")")
					scanResults.riskScore = scanResults.riskScore + 40
				end
			end

			-- Check for script injection
			if child:IsA("LocalScript") or child:IsA("ModuleScript") then
				table.insert(scanResults.flags, "Injected Script: " .. child.Name)
				scanResults.riskScore = scanResults.riskScore + 80
			end
		end

		-- Check position validity
		if rootPart then
			local pos = rootPart.Position
			if math.abs(pos.X) > 10000 or math.abs(pos.Z) > 10000 or pos.Y > 5000 or pos.Y < -500 then
				table.insert(scanResults.flags, "Abnormal Position: " .. tostring(pos))
				scanResults.riskScore = scanResults.riskScore + 20
			end
		end
	end

	-- Determine risk level
	if scanResults.riskScore >= 100 then
		scanResults.riskLevel = "CRITICAL"
	elseif scanResults.riskScore >= 60 then
		scanResults.riskLevel = "HIGH"
	elseif scanResults.riskScore >= 30 then
		scanResults.riskLevel = "MEDIUM"
	else
		scanResults.riskLevel = "LOW"
	end

	return scanResults
end

local function ScanAllPlayers(admin)
	if not IsAdmin(admin, Config.PERMISSIONS.SCAN) then
		return false, "Insufficient permissions"
	end

	local results = {}

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= admin then
			table.insert(results, ScanPlayer(player))
		end
	end

	-- Sort by risk score
	table.sort(results, function(a, b)
		return a.riskScore > b.riskScore
	end)

	Log("SCAN", admin, "ALL PLAYERS", "Server-wide hack scan")
	return true, results
end

--================================================================================
-- GUI CREATION
--================================================================================

local function CreateAdminPanel(player)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return end

	-- Remove existing panel
	local existing = playerGui:FindFirstChild("AdminPanel")
	if existing then existing:Destroy() end

	-- Main ScreenGui
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "AdminPanel"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Main Frame
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0.6, 0, 0.7, 0)
	mainFrame.Position = UDim2.new(0.2, 0, 0.15, 0)
	mainFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
	mainFrame.BorderSizePixel = 0
	mainFrame.Visible = false

	local mainCorner = Instance.new("UICorner")
	mainCorner.CornerRadius = UDim.new(0, 12)
	mainCorner.Parent = mainFrame

	local mainStroke = Instance.new("UIStroke")
	mainStroke.Color = Color3.fromRGB(60, 60, 80)
	mainStroke.Thickness = 2
	mainStroke.Parent = mainFrame

	-- Title Bar
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0.08, 0)
	titleBar.Position = UDim2.new(0, 0, 0, 0)
	titleBar.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
	titleBar.BorderSizePixel = 0
	titleBar.Parent = mainFrame

	local titleCorner = Instance.new("UICorner")
	titleCorner.CornerRadius = UDim.new(0, 12)
	titleCorner.Parent = titleBar

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(0.5, 0, 1, 0)
	titleLabel.Position = UDim2.new(0.25, 0, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	titleLabel.TextScaled = true
	titleLabel.Font = Enum.Font.GothamBold
	titleLabel.Text = "??? NEON RUN ADMIN PANEL"
	titleLabel.Parent = titleBar

	-- Close Button
	local closeButton = Instance.new("TextButton")
	closeButton.Name = "CloseButton"
	closeButton.Size = UDim2.new(0.06, 0, 0.7, 0)
	closeButton.Position = UDim2.new(0.93, 0, 0.15, 0)
	closeButton.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
	closeButton.TextColor3 = Color3.new(1, 1, 1)
	closeButton.TextScaled = true
	closeButton.Font = Enum.Font.GothamBold
	closeButton.Text = "?"
	closeButton.Parent = titleBar

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 6)
	closeCorner.Parent = closeButton

	-- Left Panel - Player List
	local leftPanel = Instance.new("Frame")
	leftPanel.Name = "LeftPanel"
	leftPanel.Size = UDim2.new(0.4, 0, 0.88, 0)
	leftPanel.Position = UDim2.new(0, 0, 0.1, 0)
	leftPanel.BackgroundColor3 = Color3.fromRGB(30, 30, 42)
	leftPanel.BorderSizePixel = 0
	leftPanel.Parent = mainFrame

	-- Player List Header
	local playerHeader = Instance.new("TextLabel")
	playerHeader.Size = UDim2.new(1, 0, 0.06, 0)
	playerHeader.Position = UDim2.new(0, 0, 0, 0)
	playerHeader.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
	playerHeader.BackgroundTransparency = 0
	playerHeader.TextColor3 = Color3.fromRGB(200, 200, 200)
	playerHeader.TextScaled = true
	playerHeader.Font = Enum.Font.GothamSemibold
	playerHeader.Text = "?? PLAYERS"
	playerHeader.Parent = leftPanel

	-- Scrolling Frame for Players
	local playerScroll = Instance.new("ScrollingFrame")
	playerScroll.Name = "PlayerScroll"
	playerScroll.Size = UDim2.new(0.95, 0, 0.92, 0)
	playerScroll.Position = UDim2.new(0.025, 0, 0.07, 0)
	playerScroll.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
	playerScroll.BorderSizePixel = 0
	playerScroll.ScrollBarThickness = 6
	playerScroll.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 150)
	playerScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	playerScroll.Parent = leftPanel

	local scrollCorner = Instance.new("UICorner")
	scrollCorner.CornerRadius = UDim.new(0, 8)
	scrollCorner.Parent = playerScroll

	local playerLayout = Instance.new("UIListLayout")
	playerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	playerLayout.Padding = UDim.new(0, 4)
	playerLayout.Parent = playerScroll

	-- Right Panel - Actions
	local rightPanel = Instance.new("Frame")
	rightPanel.Name = "RightPanel"
	rightPanel.Size = UDim2.new(0.6, 0, 0.88, 0)
	rightPanel.Position = UDim2.new(0.4, 0, 0.1, 0)
	rightPanel.BackgroundColor3 = Color3.fromRGB(28, 28, 40)
	rightPanel.BorderSizePixel = 0
	rightPanel.Parent = mainFrame

	-- Tabs
	local tabsFrame = Instance.new("Frame")
	tabsFrame.Name = "TabsFrame"
	tabsFrame.Size = UDim2.new(1, -10, 0.06, 0)
	tabsFrame.Position = UDim2.new(0, 5, 0, 5)
	tabsFrame.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
	tabsFrame.BorderSizePixel = 0
	tabsFrame.Parent = rightPanel

	local tabsCorner = Instance.new("UICorner")
	tabsCorner.CornerRadius = UDim.new(0, 6)
	tabsCorner.Parent = tabsFrame

	local tabsLayout = Instance.new("UIListLayout")
	tabsLayout.FillDirection = Enum.FillDirection.Horizontal
	tabsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabsLayout.Padding = UDim.new(0, 5)
	tabsLayout.Parent = tabsFrame

	-- Tab Buttons
	local tabNames = {"Actions", "Scan", "Logs", "Bans"}
	local tabButtons = {}

	for i, tabName in ipairs(tabNames) do
		local tab = Instance.new("TextButton")
		tab.Name = tabName .. "Tab"
		tab.Size = UDim2.new(0.23, 0, 0.8, 0)
		tab.Position = UDim2.new(0.01 + (i - 1) * 0.24, 0, 0.1, 0)
		tab.BackgroundColor3 = i == 1 and Color3.fromRGB(70, 130, 180) or Color3.fromRGB(50, 50, 65)
		tab.TextColor3 = Color3.new(1, 1, 1)
		tab.TextScaled = true
		tab.Font = Enum.Font.GothamSemibold
		tab.Text = tabName
		tab.Parent = tabsFrame

		local tabCorner = Instance.new("UICorner")
		tabCorner.CornerRadius = UDim.new(0, 4)
		tabCorner.Parent = tab

		tabButtons[tabName] = tab
	end

	-- Content Frame
	local contentFrame = Instance.new("Frame")
	contentFrame.Name = "ContentFrame"
	contentFrame.Size = UDim2.new(1, -10, 0.92, 0)
	contentFrame.Position = UDim2.new(0, 5, 0.07, 0)
	contentFrame.BackgroundColor3 = Color3.fromRGB(32, 32, 45)
	contentFrame.BorderSizePixel = 0
	contentFrame.Parent = rightPanel

	local contentCorner = Instance.new("UICorner")
	contentCorner.CornerRadius = UDim.new(0, 8)
	contentCorner.Parent = contentFrame

	-- Actions Content
	local actionsContent = Instance.new("ScrollingFrame")
	actionsContent.Name = "ActionsContent"
	actionsContent.Size = UDim2.new(1, 0, 1, 0)
	actionsContent.BackgroundColor3 = Color3.fromRGB(32, 32, 45)
	actionsContent.BackgroundTransparency = 0
	actionsContent.BorderSizePixel = 0
	actionsContent.ScrollBarThickness = 6
	actionsContent.Visible = true
	actionsContent.Parent = contentFrame

	local actionsLayout = Instance.new("UIListLayout")
	actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionsLayout.Padding = UDim.new(0, 10)
	actionsLayout.Parent = actionsContent

	-- Selected Player Display
	local selectedFrame = Instance.new("Frame")
	selectedFrame.Size = UDim2.new(1, -20, 0, 50)
	selectedFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
	selectedFrame.Parent = actionsContent

	local selectedCorner = Instance.new("UICorner")
	selectedCorner.CornerRadius = UDim.new(0, 6)
	selectedCorner.Parent = selectedFrame

	local selectedLabel = Instance.new("TextLabel")
	selectedLabel.Name = "SelectedLabel"
	selectedLabel.Size = UDim2.new(1, -20, 1, 0)
	selectedLabel.Position = UDim2.new(0, 10, 0, 0)
	selectedLabel.BackgroundTransparency = 1
	selectedLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	selectedLabel.TextScaled = true
	selectedLabel.Font = Enum.Font.GothamSemibold
	selectedLabel.Text = "Select a player from the list"
	selectedLabel.TextXAlignment = Enum.TextXAlignment.Left
	selectedLabel.Parent = selectedFrame

	-- Action Buttons
	local actionButtons = {
		{name = "Kick", color = Color3.fromRGB(200, 100, 50), action = "kick"},
		{name = "Ban", color = Color3.fromRGB(180, 50, 50), action = "ban"},
		{name = "Time Ban (1h)", color = Color3.fromRGB(150, 80, 50), action = "timeban1h"},
		{name = "Time Ban (24h)", color = Color3.fromRGB(150, 60, 40), action = "timeban24h"},
		{name = "Reset Violations", color = Color3.fromRGB(50, 150, 100), action = "reset"},
		{name = "Check Stats", color = Color3.fromRGB(50, 100, 180), action = "check"},
	}

	for _, btnData in ipairs(actionButtons) do
		local btn = Instance.new("TextButton")
		btn.Name = btnData.name .. "Button"
		btn.Size = UDim2.new(1, -20, 0, 40)
		btn.BackgroundColor3 = btnData.color
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.TextScaled = true
		btn.Font = Enum.Font.GothamSemibold
		btn.Text = btnData.name
		btn.Parent = actionsContent

		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, 6)
		btnCorner.Parent = btn
	end

	-- Scan Content
	local scanContent = Instance.new("ScrollingFrame")
	scanContent.Name = "ScanContent"
	scanContent.Size = UDim2.new(1, 0, 1, 0)
	scanContent.BackgroundTransparency = 0
	scanContent.BackgroundColor3 = Color3.fromRGB(32, 32, 45)
	scanContent.BorderSizePixel = 0
	scanContent.ScrollBarThickness = 6
	scanContent.Visible = false
	scanContent.Parent = contentFrame

	local scanLayout = Instance.new("UIListLayout")
	scanLayout.SortOrder = Enum.SortOrder.LayoutOrder
	scanLayout.Padding = UDim.new(0, 8)
	scanLayout.Parent = scanContent

	-- Scan Button
	local scanAllBtn = Instance.new("TextButton")
	scanAllBtn.Name = "ScanAllButton"
	scanAllBtn.Size = UDim2.new(1, -20, 0, 45)
	scanAllBtn.BackgroundColor3 = Color3.fromRGB(100, 50, 150)
	scanAllBtn.TextColor3 = Color3.new(1, 1, 1)
	scanAllBtn.TextScaled = true
	scanAllBtn.Font = Enum.Font.GothamBold
	scanAllBtn.Text = "?? SCAN ALL PLAYERS"
	scanAllBtn.Parent = scanContent

	local scanBtnCorner = Instance.new("UICorner")
	scanBtnCorner.CornerRadius = UDim.new(0, 6)
	scanBtnCorner.Parent = scanAllBtn

	-- Logs Content
	local logsContent = Instance.new("ScrollingFrame")
	logsContent.Name = "LogsContent"
	logsContent.Size = UDim2.new(1, 0, 1, 0)
	logsContent.BackgroundTransparency = 0
	logsContent.BackgroundColor3 = Color3.fromRGB(32, 32, 45)
	logsContent.BorderSizePixel = 0
	logsContent.ScrollBarThickness = 6
	logsContent.Visible = false
	logsContent.Parent = contentFrame

	local logsLayout = Instance.new("UIListLayout")
	logsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	logsLayout.Padding = UDim.new(0, 4)
	logsLayout.Parent = logsContent

	-- Bans Content
	local bansContent = Instance.new("ScrollingFrame")
	bansContent.Name = "BansContent"
	bansContent.Size = UDim2.new(1, 0, 1, 0)
	bansContent.BackgroundTransparency = 0
	bansContent.BackgroundColor3 = Color3.fromRGB(32, 32, 45)
	bansContent.BorderSizePixel = 0
	bansContent.ScrollBarThickness = 6
	bansContent.Visible = false
	bansContent.Parent = contentFrame

	local bansLayout = Instance.new("UIListLayout")
	bansLayout.SortOrder = Enum.SortOrder.LayoutOrder
	bansLayout.Padding = UDim.new(0, 4)
	bansLayout.Parent = bansContent

	-- Unban Input
	local unbanFrame = Instance.new("Frame")
	unbanFrame.Size = UDim2.new(1, -20, 0, 50)
	unbanFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
	unbanFrame.Parent = bansContent

	local unbanCorner = Instance.new("UICorner")
	unbanCorner.CornerRadius = UDim.new(0, 6)
	unbanCorner.Parent = unbanFrame

	local unbanInput = Instance.new("TextBox")
	unbanInput.Name = "UnbanInput"
	unbanInput.Size = UDim2.new(0.65, 0, 0.7, 0)
	unbanInput.Position = UDim2.new(0.02, 0, 0.15, 0)
	unbanInput.BackgroundColor3 = Color3.fromRGB(50, 50, 65)
	unbanInput.TextColor3 = Color3.new(1, 1, 1)
	unbanInput.PlaceholderText = "Enter player name to unban"
	unbanInput.PlaceholderColor3 = Color3.fromRGB(150, 150, 150)
	unbanInput.TextScaled = true
	unbanInput.Font = Enum.Font.Gotham
	unbanInput.Parent = unbanFrame

	local unbanCorner2 = Instance.new("UICorner")
	unbanCorner2.CornerRadius = UDim.new(0, 4)
	unbanCorner2.Parent = unbanInput

	local unbanButton = Instance.new("TextButton")
	unbanButton.Name = "UnbanButton"
	unbanButton.Size = UDim2.new(0.28, 0, 0.7, 0)
	unbanButton.Position = UDim2.new(0.69, 0, 0.15, 0)
	unbanButton.BackgroundColor3 = Color3.fromRGB(50, 150, 100)
	unbanButton.TextColor3 = Color3.new(1, 1, 1)
	unbanButton.TextScaled = true
	unbanButton.Font = Enum.Font.GothamSemibold
	unbanButton.Text = "UNBAN"
	unbanButton.Parent = unbanFrame

	local unbanBtnCorner = Instance.new("UICorner")
	unbanBtnCorner.CornerRadius = UDim.new(0, 4)
	unbanBtnCorner.Parent = unbanButton

	-- Assemble
	mainFrame.Parent = screenGui
	screenGui.Parent = playerGui

	-- Store references
	return {
		screenGui = screenGui,
		mainFrame = mainFrame,
		playerScroll = playerScroll,
		selectedLabel = selectedLabel,
		actionsContent = actionsContent,
		scanContent = scanContent,
		logsContent = logsContent,
		bansContent = bansContent,
		tabButtons = tabButtons,
		closeButton = closeButton,
		scanAllBtn = scanAllBtn,
		unbanInput = unbanInput,
		unbanButton = unbanButton
	}
end

--================================================================================
-- REMOTE EVENTS
--================================================================================

-- Create remotes
local function CreateRemotes()
	local folder = Instance.new("Folder")
	folder.Name = "AdminRemotes"

	local remotes = {
		"TogglePanel", "GetPlayers", "KickPlayer", "BanPlayer", 
		"TimeBanPlayer", "UnbanPlayer", "ScanAll", "ScanPlayer",
		"GetLogs", "GetBans", "ResetPlayer", "CheckPlayer"
	}

	for _, remoteName in ipairs(remotes) do
		local remote = Instance.new("RemoteEvent")
		remote.Name = remoteName
		remote.Parent = folder
	end

	-- Functions
	local funcNames = {"GetPlayerList", "GetScanResults", "GetBanList", "GetLogList"}
	for _, funcName in ipairs(funcNames) do
		local func = Instance.new("RemoteFunction")
		func.Name = funcName
		func.Parent = folder
	end

	folder.Parent = ReplicatedStorage
	return folder
end

local adminRemotes = ReplicatedStorage:FindFirstChild("AdminRemotes")
if not adminRemotes then
	adminRemotes = CreateRemotes()
end

--================================================================================
-- REMOTE HANDLERS
--================================================================================

local panels = {}

adminRemotes.TogglePanel.OnServerEvent:Connect(function(player)
	if not IsAdmin(player) then return end

	if not panels[player] then
		panels[player] = CreateAdminPanel(player)
	end

	local panel = panels[player]
	if panel and panel.mainFrame then
		panel.mainFrame.Visible = not panel.mainFrame.Visible
	end
end)

adminRemotes.GetPlayers.OnServerEvent:Connect(function(player)
	if not IsAdmin(player) then return end

	local panel = panels[player]
	if not panel then return end

	-- Clear existing
	for _, child in ipairs(panel.playerScroll:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	-- Add players
	local yPos = 0
	for _, plr in ipairs(Players:GetPlayers()) do
		local playerFrame = Instance.new("Frame")
		playerFrame.Size = UDim2.new(1, 0, 0, 35)
		playerFrame.BackgroundColor3 = plr == player and Color3.fromRGB(50, 100, 50) or Color3.fromRGB(40, 40, 55)
		playerFrame.BorderSizePixel = 0
		playerFrame.LayoutOrder = yPos
		playerFrame.Parent = panel.playerScroll

		local frameCorner = Instance.new("UICorner")
		frameCorner.CornerRadius = UDim.new(0, 4)
		frameCorner.Parent = playerFrame

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(0.7, 0, 1, 0)
		nameLabel.Position = UDim2.new(0.02, 0, 0, 0)
		nameLabel.BackgroundTransparency = 1
		nameLabel.TextColor3 = Color3.new(1, 1, 1)
		nameLabel.TextScaled = true
		nameLabel.Font = Enum.Font.GothamSemibold
		nameLabel.Text = plr.Name
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.Parent = playerFrame

		-- Risk indicator
		local tracker = _G.PlayerTrackers and _G.PlayerTrackers[plr]
		local riskColor = Color3.fromRGB(50, 200, 50) -- Green
		if tracker and tracker.totalWarnings and tracker.totalWarnings > 0 then
			riskColor = Color3.fromRGB(200, 200, 50) -- Yellow
			if tracker.totalWarnings >= 2 then
				riskColor = Color3.fromRGB(200, 100, 50) -- Orange
			end
			if tracker.totalWarnings >= 3 then
				riskColor = Color3.fromRGB(200, 50, 50) -- Red
			end
		end

		local riskDot = Instance.new("Frame")
		riskDot.Size = UDim2.new(0.08, 0, 0.6, 0)
		riskDot.Position = UDim2.new(0.88, 0, 0.2, 0)
		riskDot.BackgroundColor3 = riskColor
		riskDot.Parent = playerFrame

		local riskCorner = Instance.new("UICorner")
		riskCorner.CornerRadius = UDim.new(1, 0)
		riskCorner.Parent = riskDot

		-- Click to select
		playerFrame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				panel.selectedLabel.Text = "Selected: " .. plr.Name .. " (ID: " .. plr.UserId .. ")"
				panel.selectedPlayer = plr
			end
		end)

		yPos = yPos + 1
	end

	panel.playerScroll.CanvasSize = UDim2.new(0, 0, yPos * 0.15, 0)
end)

adminRemotes.KickPlayer.OnServerEvent:Connect(function(player, targetName, reason)
	if not IsAdmin(player, Config.PERMISSIONS.KICK) then return end

	local target = FindPlayer(targetName)
	if target then
		KickPlayer(player, target, reason)
	end
end)

adminRemotes.BanPlayer.OnServerEvent:Connect(function(player, targetName, reason)
	if not IsAdmin(player, Config.PERMISSIONS.BAN) then return end

	local target = FindPlayer(targetName)
	if target then
		BanPlayer(player, target, reason)
	end
end)

adminRemotes.TimeBanPlayer.OnServerEvent:Connect(function(player, targetName, duration, reason)
	if not IsAdmin(player, Config.PERMISSIONS.TIMEBAN) then return end

	local target = FindPlayer(targetName)
	if target then
		TimeBanPlayer(player, target, duration, reason)
	end
end)

adminRemotes.UnbanPlayer.OnServerEvent:Connect(function(player, targetName)
	local success, message = UnbanPlayer(player, targetName)
	-- Response handled by client
end)

adminRemotes.ScanAll.OnServerEvent:Connect(function(player)
	if not IsAdmin(player, Config.PERMISSIONS.SCAN) then return end

	local success, results = ScanAllPlayers(player)
	if success then
		adminRemotes.ScanAll:FireClient(player, results)
	end
end)

adminRemotes.ResetPlayer.OnServerEvent:Connect(function(player, targetName)
	if not IsAdmin(player, Config.PERMISSIONS.RESET) then return end

	local target = FindPlayer(targetName)
	if target then
		local tracker = _G.PlayerTrackers and _G.PlayerTrackers[target]
		if tracker then
			for k in pairs(tracker.violations) do
				tracker.violations[k] = 0
			end
			tracker.totalWarnings = 0
			Log("RESET", player, target.Name, "Violations reset")
		end
	end
end)

--================================================================================
-- PLAYER CONNECTIONS
--================================================================================

Players.PlayerAdded:Connect(function(player)
	-- Check bans
	local banned, banType, banData = IsBanned(player.UserId)
	if banned then
		if banType == "Permanent" then
			player:Kick(string.format(Config.BAN_MESSAGE, banData.reason))
		else
			local remaining = banData.endTime - os.time()
			player:Kick(string.format(Config.TIMEBAN_MESSAGE, banData.reason, FormatTime(remaining)))
		end
		return
	end

	-- Track connected players
	AdminSystem.ConnectedPlayers[player.UserId] = {
		name = player.Name,
		joinTime = os.time(),
		ip = "--" -- Can't get IP on Roblox
	}

	Log("JOIN", nil, player.Name, "Player joined")

	-- Chat commands
	player.Chatted:Connect(function(message)
		-- Command processing
		if message:sub(1, 1) == ":" then
			ProcessChatCommand(player, message)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	Log("LEAVE", nil, player.Name, "Player left")
	AdminSystem.ConnectedPlayers[player.UserId] = nil
	panels[player] = nil
end)

--================================================================================
-- CHAT COMMANDS
--================================================================================

function ProcessChatCommand(player, message)
	local args = {}
	for word in message:sub(2):gmatch("%S+") do
		table.insert(args, word)
	end

	if #args == 0 then return end

	local command = args[1]:lower()

	if command == "admin" then
		if IsAdmin(player) then
			if panels[player] then
				panels[player].mainFrame.Visible = not panels[player].mainFrame.Visible
			else
				panels[player] = CreateAdminPanel(player)
			end
		end
	elseif command == "kick" and args[2] then
		local target = FindPlayer(args[2])
		if target then
			KickPlayer(player, target, args[3] and table.concat(args, " ", 3))
		end
	elseif command == "ban" and args[2] then
		local target = FindPlayer(args[2])
		if target then
			BanPlayer(player, target, args[3] and table.concat(args, " ", 3))
		end
	elseif command == "scan" then
		if args[2] then
			local target = FindPlayer(args[2])
			if target then
				local result = ScanPlayer(target)
				Log("SCAN", player, target.Name, "Risk: " .. result.riskLevel .. " (" .. result.riskScore .. ")")
			end
		else
			ScanAllPlayers(player)
		end
	end
end

--================================================================================
-- INITIALIZATION
--================================================================================

LoadBans()
LoadTimeBans()

-- Cleanup time bans periodically
spawn(function()
	while true do
		wait(60)
		local changed = false
		for userId, banData in pairs(AdminSystem.TimeBannedPlayers) do
			if os.time() >= banData.endTime then
				AdminSystem.TimeBannedPlayers[userId] = nil
				changed = true
			end
		end
		if changed then
			SaveTimeBans()
		end
	end
end)

print("[Neon Run] Advanced Admin System Loaded")
print("[Neon Run] Type :admin in chat to open the panel")

--[[
    Chat Commands:
    :admin          - Toggle admin panel
    :kick <player> [reason]  - Kick player
    :ban <player> [reason]   - Ban player permanently
    :scan [player]  - Scan all players or specific player
    
    GUI Features:
    - Player list with risk indicators
    - Kick, Ban, Time Ban buttons
    - Hack Scanner
    - Logs viewer
    - Ban management
]]--
