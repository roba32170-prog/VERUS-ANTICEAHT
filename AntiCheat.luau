local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

--================================================================================
-- CONFIGURATION MODULE
--================================================================================
local Config = {
	-- Game Physics Settings
	WALK_SPEED = 16,
	JUMP_POWER = 89.6, 
	GRAVITY = 196.2,

	-- Detection Tolerances
	TOLERANCES = {
		SPEED_MARGIN = 1,              -- Allowable speed deviation (studs/sec)
		JUMP_HEIGHT_MARGIN = 5,        -- Allowable jump height deviation (studs)
		VERTICAL_SPEED_MARGIN = 5,     -- Allowable vertical speed deviatio
		TELEPORT_DISTANCE = 100,       -- Max instant movement distance (studs)
		AIR_TIME_MAX = 0.0,              -- Max air time without flying (seconds)
		NO_CLIP_RAY_MARGIN = 2,        -- Raycast margin for noclip detection
	},

	-- Detection Thresholds (violations before WARNING)
	THRESHOLDS = {
		SPEED = 1,                -- Violations before warning
		JUMP = 1,
		FLY = 1,
		NOCLIP = 1,
		TELEPORT = 1,
		PHYSICS = 1,
		HUMANOID = 1,
		ATTRIBUTE = 1,
		ALLKILL = 1,              -- Instant action for all kill
	},

	-- Punishment Actions
	PUNISHMENT = {
		MAX_WARNINGS = 1,              -- Warnings before KICK
		KICK_ENABLED = true,
		BAN_ENABLED = false,           -- Requires DataStore integration
		RESET_POSITION = true,         -- Reset to last valid position
		LOG_ENABLED = true,
	},

	-- Anti-Bypass Measures
	ANTI_BYPASS = {
		SANITY_CHECK_INTERVAL = 1,     -- Check script integrity (seconds)
		DETECT_REMOTE_SPY = true,      -- Detect remote spy tools
		DETECT_NAME_SPOOF = true,      -- Detect name spoofing
		MAX_PING_COMPENSATION = 0.5,   -- Max ping compensation (seconds)
	},

	-- Performance Settings
	PERFORMANCE = {
		UPDATE_RATE = 0.1,             -- Detection update rate (seconds)
		POSITION_HISTORY_SIZE = 10,    -- Positions to store for analysis
		OPTIMIZE_DISTANCE = 500,       -- Distance to skip checks for far players
	},

	-- Debug Mode
	DEBUG_MODE = false,
}

--================================================================================
-- UTILITY MODULE
--================================================================================
local Utility = {}

function Utility:Log(message, player, severity)
	if not Config.PUNISHMENT.LOG_ENABLED then return end

	local playerName = player and player.Name or "SYSTEM"
	local timestamp = os.date("%Y-%m-%d %H:%M:%S")
	local logMessage = string.format("[ANTI-CHEAT][%s][%s] %s", timestamp, playerName, message)

	print(logMessage)

	-- Store in _G for external access
	if not _G.AntiCheatLogs then _G.AntiCheatLogs = {} end
	table.insert(_G.AntiCheatLogs, {
		timestamp = timestamp,
		player = playerName,
		message = message,
		severity = severity or "INFO"
	})
end

function Utility:DebugLog(message)
	if Config.DEBUG_MODE then
		print("[ANTI-CHEAT DEBUG] " .. message)
	end
end

function Utility:CalculateDistance(pos1, pos2)
	return (pos1 - pos2).Magnitude
end

function Utility:CalculateHorizontalDistance(pos1, pos2)
	return Vector3.new(pos1.X - pos2.X, 0, pos1.Z - pos2.Z).Magnitude
end

function Utility:CalculateVerticalSpeed(oldPos, newPos, deltaTime)
	if deltaTime <= 0 then return 0 end
	return math.abs(newPos.Y - oldPos.Y) / deltaTime
end

function Utility:Raycast(origin, direction, params)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {}

	local result = workspace:Raycast(origin, direction, raycastParams)
	return result
end

function Utility:GetGroundPosition(position)
	local rayResult = self:Raycast(position, Vector3.new(0, -1000, 0))
	if rayResult then
		return rayResult.Position.Y  -- Return Y value only
	end
	return position.Y - 100
end

function Utility:IsPositionValid(position)
	-- Check if position is within reasonable bounds
	if not position then return false end
	if math.abs(position.X) > 100000 or math.abs(position.Z) > 100000 then
		return false
	end
	if position.Y < -1000 or position.Y > 50000 then
		return false
	end
	return true
end

function Utility:Clamp(value, min, max)
	return math.max(min, math.min(max, value))
end

--================================================================================
-- PLAYER DATA TRACKER
--================================================================================
local PlayerTracker = {}

function PlayerTracker:New(player)
	local tracker = {
		player = player,
		positions = {},
		velocities = {},
		lastUpdate = tick(),
		lastGroundedTime = tick(),
		lastValidPosition = nil,
		isGrounded = true,
		wasInAir = false,
		airTime = 0,
		violations = {
			SPEED = 0,
			JUMP = 0,
			FLY = 0,
			NOCLIP = 0,
			TELEPORT = 0,
			PHYSICS = 0,
			HUMANOID = 0,
			ATTRIBUTE = 0,
			ALLKILL = 0,
		},
		totalWarnings = 0,
		isPunished = false,
		character = player.Character,
		humanoid = nil,
		rootPart = nil,
		lastHealth = 100,
		respawnTime = 0,
		bypassUntil = 0,  -- Timestamp until which detection is bypassed
	}

	setmetatable(tracker, {__index = self})
	return tracker
end

function PlayerTracker:SetBypass(duration)
	self.bypassUntil = tick() + duration
	Utility:Log("Bypass enabled for " .. duration .. " seconds", self.player, "INFO")
end

function PlayerTracker:IsBypassed()
	return tick() < self.bypassUntil
end

function PlayerTracker:UpdateCharacter()
	self.character = self.player.Character
	if self.character then
		self.humanoid = self.character:FindFirstChild("Humanoid")
		self.rootPart = self.character:FindFirstChild("HumanoidRootPart")
	end
end

function PlayerTracker:RecordPosition(position)
	table.insert(self.positions, 1, {
		position = position,
		time = tick()
	})

	-- Keep only last N positions
	while #self.positions > Config.PERFORMANCE.POSITION_HISTORY_SIZE do
		table.remove(self.positions)
	end
end

function PlayerTracker:GetLastPosition()
	if #self.positions > 0 then
		return self.positions[1].position, self.positions[1].time
	end
	return nil, nil
end

function PlayerTracker:GetVelocity()
	if #self.positions >= 2 then
		local current = self.positions[1]
		local previous = self.positions[2]
		local deltaTime = current.time - previous.time

		if deltaTime > 0 then
			return (current.position - previous.position) / deltaTime
		end
	end
	return Vector3.new(0, 0, 0)
end

function PlayerTracker:AddViolation(violationType)
	if self.violations[violationType] then
		self.violations[violationType] = self.violations[violationType] + 1
		return self.violations[violationType]
	end
	return 0
end

function PlayerTracker:ResetViolations()
	for key in pairs(self.violations) do
		self.violations[key] = 0
	end
	self.totalWarnings = 0
end

function PlayerTracker:CheckGrounded()
	if not self.rootPart then return true end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {self.character}

	local result = workspace:Raycast(
		self.rootPart.Position,
		Vector3.new(0, -4, 0),
		rayParams
	)

	self.isGrounded = result ~= nil

	if self.isGrounded then
		self.lastGroundedTime = tick()
		self.airTime = 0
	end

	return self.isGrounded
end

--================================================================================
-- DETECTION MODULES
--================================================================================

-- Helper function to check if player is in vertical motion (should bypass)
local function IsVerticalMotion(velocity, threshold)
	threshold = threshold or 5
	return math.abs(velocity.Y) > threshold
end

-- Speed Hack Detection (Horizontal movement only)
local SpeedDetection = {}

function SpeedDetection:Check(tracker)
	if not tracker.rootPart or not tracker.humanoid then return false end

	local velocity = tracker:GetVelocity()

	--  BYPASS: Skip if in vertical motion (falling or rising)
	if IsVerticalMotion(velocity, 8) then
		Utility:DebugLog("Speed check bypassed - vertical motion: " .. velocity.Y)
		return false
	end

	--  BYPASS: Skip if in air (not grounded)
	if not tracker.isGrounded then
		return false
	end

	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local maxAllowedSpeed = Config.WALK_SPEED + Config.TOLERANCES.SPEED_MARGIN

	-- Check MoveState for running/walking
	local state = tracker.humanoid:GetState()
	if state == Enum.HumanoidStateType.Running or 
		state == Enum.HumanoidStateType.RunningNoPhysics then
		if horizontalSpeed > maxAllowedSpeed then
			local violationCount = tracker:AddViolation("SPEED")
			Utility:Log(string.format(
				"Speed Hack Detected! Speed: %.2f, Max: %.2f, Violations: %d",
				horizontalSpeed, maxAllowedSpeed, violationCount
				), tracker.player, "WARNING")
			return true
		end
	end

	return false
end

-- Jump Hack Detection (Disabled - vertical motion is now bypassed)
local JumpDetection = {}

function JumpDetection:Check(tracker)
	if not tracker.rootPart or not tracker.humanoid then return false end

	local velocity = tracker:GetVelocity()

	--  BYPASS: Skip if in vertical motion (falling or rising)
	if IsVerticalMotion(velocity, 5) then
		Utility:DebugLog("Jump check bypassed - vertical motion: " .. velocity.Y)
		return false
	end

	--  BYPASS: Skip if in air
	if not tracker.isGrounded then
		return false
	end

	-- Only check when grounded and not in vertical motion
	-- This effectively disables jump hack detection for legitimate jumps/falls
	return false
end

-- Fly Hack Detection (Only detect horizontal floating, not vertical motion)
local FlyDetection = {}

function FlyDetection:Check(tracker)
	if not tracker.rootPart then return false end

	local velocity = tracker:GetVelocity()

	--  BYPASS: Skip if in vertical motion (falling or rising)
	if IsVerticalMotion(velocity, 5) then
		Utility:DebugLog("Fly check bypassed - vertical motion: " .. velocity.Y)
		return false
	end

	local isGrounded = tracker:CheckGrounded()

	if not isGrounded then
		tracker.airTime = tracker.airTime + Config.PERFORMANCE.UPDATE_RATE

		-- Check for hovering/flying (only horizontal float, NOT vertical motion)
		if tracker.airTime > Config.TOLERANCES.AIR_TIME_MAX then
			local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude

			--  MODIFIED: Only flag if moving horizontally AND not falling/rising
			-- This means: horizontal movement + no vertical movement = suspicious
			if horizontalSpeed > 5 and math.abs(velocity.Y) < 1 then
				-- Moving horizontally but not falling/rising = fly hack
				local violationCount = tracker:AddViolation("FLY")
				Utility:Log(string.format(
					"Fly Hack Detected! Air Time: %.2fs, H-Speed: %.2f, V-Speed: %.2f, Violations: %d",
					tracker.airTime, horizontalSpeed, velocity.Y, violationCount
					), tracker.player, "WARNING")
				return true
			end

			-- Check for sustained altitude (hovering)
			if #tracker.positions >= 5 then
				local altitudeChanges = 0
				for i = 1, 4 do
					altitudeChanges = altitudeChanges + 
						math.abs(tracker.positions[i].position.Y - tracker.positions[i+1].position.Y)
				end

				if altitudeChanges < 1 and horizontalSpeed > 0 then
					local violationCount = tracker:AddViolation("FLY")
					Utility:Log(string.format(
						"Hover Hack Detected! Air Time: %.2fs, Violations: %d",
						tracker.airTime, violationCount
						), tracker.player, "WARNING")
					return true
				end
			end
		end
	else
		tracker.airTime = 0
	end

	return false
end

-- NoClip Detection (Skip if vertical motion)
local NoClipDetection = {}

function NoClipDetection:Check(tracker)
	if not tracker.rootPart then return false end
	if #tracker.positions < 2 then return false end

	local velocity = tracker:GetVelocity()

	--  BYPASS: Skip if in vertical motion (falling or rising through platforms)
	if IsVerticalMotion(velocity, 8) then
		Utility:DebugLog("NoClip check bypassed - vertical motion: " .. velocity.Y)
		return false
	end

	local currentPos = tracker.positions[1].position
	local previousPos = tracker.positions[2].position

	--  Calculate horizontal distance only
	local horizontalDistance = Vector3.new(currentPos.X - previousPos.X, 0, currentPos.Z - previousPos.Z).Magnitude
	local verticalDistance = math.abs(currentPos.Y - previousPos.Y)

	-- Skip if movement is mostly vertical
	if verticalDistance > horizontalDistance then
		return false
	end

	local distance = Utility:CalculateDistance(currentPos, previousPos)

	-- Don't check for very short distances
	if distance < 1 then return false end

	local direction = (currentPos - previousPos).Unit
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {tracker.character}

	-- Raycast from previous position to current
	local result = workspace:Raycast(previousPos, direction * distance, rayParams)

	if result then
		local hitPart = result.Instance

		-- Check if it's a solid wall/part that should block movement
		if hitPart and hitPart.CanCollide then
			-- Check if the part is in the way
			local hitDistance = Utility:CalculateDistance(previousPos, result.Position)

			if hitDistance < distance - Config.TOLERANCES.NO_CLIP_RAY_MARGIN then
				-- Passed through a solid object
				local violationCount = tracker:AddViolation("NOCLIP")
				Utility:Log(string.format(
					"NoClip Detected! Passed through: %s, Distance: %.2f, Violations: %d",
					hitPart.Name, hitDistance, violationCount
					), tracker.player, "WARNING")
				return true
			end
		end
	end

	-- Multi-raycast check for diagonal movement
	local offsetPositions = {
		Vector3.new(0, 1, 0),
		Vector3.new(0, 2, 0),
		Vector3.new(0, -1, 0),
	}

	for _, offset in ipairs(offsetPositions) do
		local result = workspace:Raycast(
			previousPos + offset, 
			direction * distance, 
			rayParams
		)
		if result and result.Instance and result.Instance.CanCollide then
			local hitDistance = Utility:CalculateDistance(previousPos + offset, result.Position)
			if hitDistance < distance - Config.TOLERANCES.NO_CLIP_RAY_MARGIN then
				local violationCount = tracker:AddViolation("NOCLIP")
				Utility:Log(string.format(
					"NoClip Detected (Multi-ray)! Passed through: %s, Violations: %d",
					result.Instance.Name, violationCount
					), tracker.player, "WARNING")
				return true
			end
		end
	end

	return false
end

-- Teleport Detection (Horizontal only - skip vertical motion)
local TeleportDetection = {}

function TeleportDetection:Check(tracker)
	if not tracker.rootPart then return false end
	if #tracker.positions < 2 then return false end

	local velocity = tracker:GetVelocity()

	--  BYPASS: Skip if in vertical motion (falling or rising)
	if IsVerticalMotion(velocity, 10) then
		Utility:DebugLog("Teleport check bypassed - vertical motion: " .. velocity.Y)
		return false
	end

	local currentPos = tracker.positions[1].position
	local previousPos = tracker.positions[2].position
	local deltaTime = tracker.positions[1].time - tracker.positions[2].time

	if deltaTime <= 0 then return false end

	--  Calculate HORIZONTAL distance only (ignore vertical)
	local horizontalDistance = Vector3.new(currentPos.X - previousPos.X, 0, currentPos.Z - previousPos.Z).Magnitude
	local verticalDistance = math.abs(currentPos.Y - previousPos.Y)

	-- Skip if movement is mostly vertical (falling/jumping)
	if verticalDistance > horizontalDistance * 1.5 then
		return false
	end

	local maxDistance = (Config.WALK_SPEED + Config.TOLERANCES.SPEED_MARGIN * 2) * deltaTime + 
		Config.TOLERANCES.TELEPORT_DISTANCE * 0.1

	-- Calculate if HORIZONTAL distance is impossibly large
	if horizontalDistance > Config.TOLERANCES.TELEPORT_DISTANCE then
		-- Check if this might be a legitimate respawn
		if tracker.humanoid and tracker.humanoid.Health < tracker.lastHealth then
			tracker.lastHealth = tracker.humanoid.Health
			return false -- Took damage, might be knockback
		end

		local violationCount = tracker:AddViolation("TELEPORT")
		Utility:Log(string.format(
			"Teleport Detected! H-Distance: %.2f studs in %.3fs, Violations: %d",
			horizontalDistance, deltaTime, violationCount
			), tracker.player, "WARNING")
		return true
	end

	-- Instant teleport check (horizontal only)
	if horizontalDistance > maxDistance * 3 then
		local violationCount = tracker:AddViolation("TELEPORT")
		Utility:Log(string.format(
			"Instant Teleport Detected! H-Distance: %.2f, Max: %.2f, Violations: %d",
			horizontalDistance, maxDistance * 3, violationCount
			), tracker.player, "WARNING")
		return true
	end

	return false
end

-- Physics Manipulation Detection
local PhysicsDetection = {}

function PhysicsDetection:Check(tracker)
	if not tracker.rootPart or not tracker.humanoid then return false end

	-- Check for modified walk speed
	if tracker.humanoid.WalkSpeed ~= Config.WALK_SPEED then
		-- Allow slight variations from game mechanics
		if math.abs(tracker.humanoid.WalkSpeed - Config.WALK_SPEED) > 1 then
			tracker.humanoid.WalkSpeed = Config.WALK_SPEED
			local violationCount = tracker:AddViolation("PHYSICS")
			Utility:Log(string.format(
				"WalkSpeed Manipulation! Set: %.1f, Expected: %.1f, Violations: %d",
				tracker.humanoid.WalkSpeed, Config.WALK_SPEED, violationCount
				), tracker.player, "WARNING")
			return true
		end
	end

	-- Check for modified jump power
	if tracker.humanoid.JumpPower ~= Config.JUMP_POWER then
		if math.abs(tracker.humanoid.JumpPower - Config.JUMP_POWER) > 1 then
			tracker.humanoid.JumpPower = Config.JUMP_POWER
			local violationCount = tracker:AddViolation("PHYSICS")
			Utility:Log(string.format(
				"JumpPower Manipulation! Set: %.1f, Expected: %.1f, Violations: %d",
				tracker.humanoid.JumpPower, Config.JUMP_POWER, violationCount
				), tracker.player, "WARNING")
			return true
		end
	end

	-- Check for gravity manipulation
	if workspace.Gravity ~= Config.GRAVITY then
		if math.abs(workspace.Gravity - Config.GRAVITY) > 0.5 then
			workspace.Gravity = Config.GRAVITY
			Utility:Log(string.format(
				"Gravity Manipulation! Set: %.1f, Expected: %.1f",
				workspace.Gravity, Config.GRAVITY
				), tracker.player, "WARNING")
			-- Don't count against player - this is a workspace-level check
		end
	end

	-- Check for BodyMovers that shouldn't exist (common fly hack method)
	for _, child in ipairs(tracker.character:GetDescendants()) do
		if child:IsA("BodyVelocity") or child:IsA("BodyGyro") or child:IsA("BodyPosition") then
			-- Check if it's a legitimate game object
			if not child:GetAttribute("Legitimate") then
				child:Destroy()
				local violationCount = tracker:AddViolation("PHYSICS")
				Utility:Log(string.format(
					"Illegal BodyMover Detected! Type: %s, Name: %s, Violations: %d",
					child.ClassName, child.Name, violationCount
					), tracker.player, "WARNING")
				return true
			end
		end
	end

	return false
end

--================================================================================
-- HUMANOID MANIPULATION DETECTION
--================================================================================
local HumanoidDetection = {}

function HumanoidDetection:Check(tracker)
	if not tracker.character or not tracker.humanoid then return false end

	local humanoid = tracker.humanoid
	local violations = false

	-- Check for god mode (health hacking)
	if humanoid.Health > humanoid.MaxHealth then
		humanoid.Health = humanoid.MaxHealth
		local violationCount = tracker:AddViolation("HUMANOID")
		Utility:Log(string.format(
			"God Mode Detected! Health: %.1f/%.1f, Violations: %d",
			humanoid.Health, humanoid.MaxHealth, violationCount
			), tracker.player, "WARNING")
		violations = true
	end

	-- Check for abnormal max health
	if humanoid.MaxHealth > 1000 then
		humanoid.MaxHealth = 100
		humanoid.Health = math.min(humanoid.Health, 100)
		local violationCount = tracker:AddViolation("HUMANOID")
		Utility:Log(string.format(
			"Abnormal MaxHealth! Set: %.1f, Violations: %d",
			humanoid.MaxHealth, violationCount
			), tracker.player, "WARNING")
		violations = true
	end

	-- Check for walk speed hacks (already covered in Physics but extra check)
	if humanoid.WalkSpeed > 100 then
		humanoid.WalkSpeed = Config.WALK_SPEED
		local violationCount = tracker:AddViolation("HUMANOID")
		Utility:Log(string.format(
			"Extreme WalkSpeed! Set: %.1f, Violations: %d",
			humanoid.WalkSpeed, violationCount
			), tracker.player, "WARNING")
		violations = true
	end

	-- Check for platform stand (can be used for exploits)
	if humanoid.PlatformStand then
		humanoid.PlatformStand = false
		local violationCount = tracker:AddViolation("HUMANOID")
		Utility:Log(string.format(
			"PlatformStand Exploit! Violations: %d",
			violationCount
			), tracker.player, "WARNING")
		violations = true
	end

	-- Check for injected scripts in character
	for _, child in ipairs(tracker.character:GetDescendants()) do
		if child:IsA("LocalScript") or child:IsA("ModuleScript") then
			-- Check if it's a legitimate game script
			if not child:GetAttribute("Legitimate") then
				child:Destroy()
				local violationCount = tracker:AddViolation("HUMANOID")
				Utility:Log(string.format(
					"Injected Script in Character! Name: %s, Violations: %d",
					child.Name, violationCount
					), tracker.player, "WARNING")
				violations = true
			end
		end

		-- Check for HopperBins/Tools with suspicious names
		if child:IsA("Tool") or child:IsA("HopperBin") then
			local lowerName = child.Name:lower()
			if lowerName:find("hack") or lowerName:find("exploit") or 
				lowerName:find("admin") or lowerName:find("kill") then
				child:Destroy()
				local violationCount = tracker:AddViolation("HUMANOID")
				Utility:Log(string.format(
					"Suspicious Tool Detected! Name: %s, Violations: %d",
					child.Name, violationCount
					), tracker.player, "WARNING")
				violations = true
			end
		end
	end

	return violations
end

--================================================================================
-- ALL KILL DETECTION
--================================================================================
local AllKillDetection = {}
local recentDeaths = {} -- Track recent deaths to detect patterns

function AllKillDetection:CheckDeath(victim, killer)
	if not killer or killer == victim then return end

	local now = tick()

	-- Initialize killer's death record
	if not recentDeaths[killer.UserId] then
		recentDeaths[killer.UserId] = {
			count = 0,
			deaths = {},
			lastReset = now
		}
	end

	local record = recentDeaths[killer.UserId]

	-- Reset if too much time has passed
	if now - record.lastReset > 10 then
		record.count = 0
		record.deaths = {}
		record.lastReset = now
	end

	-- Record this death
	table.insert(record.deaths, {victim = victim.Name, time = now})
	record.count = record.count + 1

	-- Clean old records
	local i = 1
	while i <= #record.deaths do
		if now - record.deaths[i].time > 10 then
			table.remove(record.deaths, i)
		else
			i = i + 1
		end
	end

	-- Check for all-kill pattern (5+ kills in 10 seconds)
	if record.count >= 5 then
		local tracker = _G.PlayerTrackers and _G.PlayerTrackers[killer]
		if tracker then
			local violationCount = tracker:AddViolation("ALLKILL")
			Utility:Log(string.format(
				"ALL KILL DETECTED! Player: %s killed %d players in 10 seconds! Violations: %d",
				killer.Name, record.count, violationCount
				), killer, "CRITICAL")

			-- Auto-kick for all kill
			if violationCount >= 1 then
				killer:Kick("?? [Neon Run Anti-Cheat]\n\nKicked for: All Kill Hack\n\nMultiple kills detected in short time.")
			end
		end

		record.count = 0
		record.deaths = {}
	end
end

--================================================================================
-- ATTRIBUTE/PROPERTY PROTECTION
--================================================================================
local AttributeProtection = {}

function AttributeProtection:Check(tracker)
	if not tracker.rootPart then return false end

	local violations = false

	-- Check for abnormal properties on root part
	if tracker.rootPart.CanCollide == false then
		-- Could be noclip hack
		if not tracker.rootPart:GetAttribute("LegitimateNoCollide") then
			tracker.rootPart.CanCollide = true
			local violationCount = tracker:AddViolation("ATTRIBUTE")
			Utility:Log(string.format(
				"CanCollide Disabled! Violations: %d",
				violationCount
				), tracker.player, "WARNING")
			violations = true
		end
	end

	-- Check for transparency hacks (invisible player)
	if tracker.rootPart.Transparency > 0.5 then
		if not tracker.rootPart:GetAttribute("LegitimateInvisible") then
			tracker.rootPart.Transparency = 0
			local violationCount = tracker:AddViolation("ATTRIBUTE")
			Utility:Log(string.format(
				"Invisibility Hack! Transparency: %.2f, Violations: %d",
				tracker.rootPart.Transparency, violationCount
				), tracker.player, "WARNING")
			violations = true
		end
	end

	-- Check for anchored root part (can be fly hack)
	if tracker.rootPart.Anchored and not tracker.isGrounded then
		if not tracker.rootPart:GetAttribute("LegitimateAnchor") then
			tracker.rootPart.Anchored = false
			local violationCount = tracker:AddViolation("ATTRIBUTE")
			Utility:Log(string.format(
				"Illegal Anchoring! Violations: %d",
				violationCount
				), tracker.player, "WARNING")
			violations = true
		end
	end

	-- Check for massless hack
	if tracker.rootPart.Massless then
		tracker.rootPart.Massless = false
		local violationCount = tracker:AddViolation("ATTRIBUTE")
		Utility:Log(string.format(
			"Massless Hack! Violations: %d",
			violationCount
			), tracker.player, "WARNING")
		violations = true
	end

	-- Check character parts
	for _, part in ipairs(tracker.character:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
			if part.Transparency > 0.9 and part.Name:lower():find("head") then
				part.Transparency = 0
				local violationCount = tracker:AddViolation("ATTRIBUTE")
				Utility:Log(string.format(
					"Head Transparency Hack! Violations: %d",
					violationCount
					), tracker.player, "WARNING")
				violations = true
			end
		end
	end

	return violations
end

--================================================================================
-- PUNISHMENT HANDLER
--================================================================================
local PunishmentHandler = {}

function PunishmentHandler:Execute(tracker, violationType)
	if not tracker or tracker.isPunished then return end

	local threshold = Config.THRESHOLDS[violationType] or 3
	local violations = tracker.violations[violationType] or 0

	-- Check if violation count reached threshold
	if violations >= threshold then
		-- Reset position first (with nil check)
		if Config.PUNISHMENT.RESET_POSITION and tracker.lastValidPosition and tracker.rootPart then
			tracker.rootPart.CFrame = CFrame.new(tracker.lastValidPosition)
		end

		-- Increment warning count (ensure it's a number)
		tracker.totalWarnings = (tracker.totalWarnings or 0) + 1

		-- Calculate remaining warnings before kick (with nil safety)
		local maxWarnings = Config.PUNISHMENT.MAX_WARNINGS or 3
		local remainingWarnings = maxWarnings - tracker.totalWarnings

		-- Check if should kick
		if tracker.totalWarnings >= maxWarnings then
			if Config.PUNISHMENT.KICK_ENABLED then
				self:KickPlayer(tracker.player, violationType, tracker.totalWarnings)
			end
		else
			-- Send warning with remaining count
			self:WarnPlayer(tracker.player, violationType, violations, remainingWarnings)
		end

		-- Reset violation counter for this type after action
		tracker.violations[violationType] = 0
	end
end

function PunishmentHandler:WarnPlayer(player, violationType, count, remainingWarnings)
	-- Send warning to player
	local function sendWarning()
		local playerGui = player:FindFirstChild("PlayerGui")
		if not playerGui then return end

		local screenGui = Instance.new("ScreenGui")
		screenGui.Name = "AntiCheatWarning"
		screenGui.ResetOnSpawn = false

		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(0.5, 0, 0.2, 0)
		frame.Position = UDim2.new(0.25, 0, 0.1, 0)
		frame.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
		frame.BorderSizePixel = 0

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 12)
		corner.Parent = frame

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 100, 100)
		stroke.Thickness = 3
		stroke.Parent = frame

		-- Warning icon and title
		local title = Instance.new("TextLabel")
		title.Size = UDim2.new(1, 0, 0.3, 0)
		title.Position = UDim2.new(0, 0, 0, 0)
		title.BackgroundTransparency = 1
		title.TextColor3 = Color3.new(1, 1, 1)
		title.TextScaled = true
		title.Font = Enum.Font.GothamBold
		title.Text = "?? ANTI-CHEAT WARNING ??"
		title.Parent = frame

		-- Violation type
		local violation = Instance.new("TextLabel")
		violation.Size = UDim2.new(1, 0, 0.25, 0)
		violation.Position = UDim2.new(0, 0, 0.35, 0)
		violation.BackgroundTransparency = 1
		violation.TextColor3 = Color3.fromRGB(255, 200, 200)
		violation.TextScaled = true
		violation.Font = Enum.Font.GothamSemibold
		violation.Text = violationType .. " Detected!"
		violation.Parent = frame

		-- Remaining warnings
		local remaining = Instance.new("TextLabel")
		remaining.Size = UDim2.new(1, 0, 0.25, 0)
		remaining.Position = UDim2.new(0, 0, 0.65, 0)
		remaining.BackgroundTransparency = 1
		remaining.TextColor3 = Color3.new(1, 1, 0.8)
		remaining.TextScaled = true
		remaining.Font = Enum.Font.Gotham
		remaining.Text = string.format("Warnings remaining: %d", remainingWarnings)
		remaining.Parent = frame

		frame.Parent = screenGui
		screenGui.Parent = playerGui

		Debris:AddItem(screenGui, 5)
	end

	local success, err = pcall(sendWarning)
	if not success then
		Utility:Log("Failed to send warning: " .. tostring(err), player, "ERROR")
	end

	local tracker = _G.PlayerTrackers and _G.PlayerTrackers[player]
	local totalWarns = tracker and tracker.totalWarnings or 0

	Utility:Log(string.format(
		"Warning #%d issued for %s (Violations: %d, Remaining: %d)",
		totalWarns, violationType, count, remainingWarnings
		), player, "WARNING")
end

function PunishmentHandler:KickPlayer(player, violationType, totalWarnings)
	if not player then return end

	local tracker = _G.PlayerTrackers and _G.PlayerTrackers[player]
	if tracker then
		tracker.isPunished = true
	end

	Utility:Log(string.format(
		"KICKING PLAYER: %s | Reason: %s | Total Warnings: %d",
		player.Name, violationType, totalWarnings
		), player, "CRITICAL")

	player:Kick(string.format(
		"?? [Neon Run Anti-Cheat]\n\nYou have been kicked for: %s\n\nTotal Warnings: %d\n\nIf you believe this is an error, please contact an administrator.",
		violationType, totalWarnings
		))
end

--================================================================================
-- MAIN ANTI-CHEAT CONTROLLER
--================================================================================
local AntiCheat = {
	trackers = {},
	running = false,
	lastSanityCheck = 0,
}

_G.PlayerTrackers = AntiCheat.trackers

function AntiCheat:Initialize()
	Utility:Log("Anti-Cheat System Initializing...", nil, "INFO")

	-- Set initial workspace gravity
	workspace.Gravity = Config.GRAVITY

	-- Connect player events
	Players.PlayerAdded:Connect(function(player)
		self:OnPlayerAdded(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:OnPlayerRemoving(player)
	end)

	-- Handle existing players (for late script execution)
	for _, player in ipairs(Players:GetPlayers()) do
		self:OnPlayerAdded(player)
	end

	-- Start detection loop
	self.running = true
	spawn(function()
		self:DetectionLoop()
	end)

	-- Start sanity check loop
	spawn(function()
		self:SanityCheckLoop()
	end)

	Utility:Log("Anti-Cheat System Initialized Successfully!", nil, "INFO")
end

function AntiCheat:OnPlayerAdded(player)
	Utility:Log("Player joined: " .. player.Name, player, "INFO")

	-- Create tracker
	local tracker = PlayerTracker:New(player)
	self.trackers[player] = tracker

	-- Setup character monitoring
	player.CharacterAdded:Connect(function(character)
		self:OnCharacterAdded(player, character)
	end)

	-- Handle existing character
	if player.Character then
		self:OnCharacterAdded(player, player.Character)
	end
end

function AntiCheat:OnPlayerRemoving(player)
	Utility:Log("Player left: " .. player.Name, player, "INFO")
	self.trackers[player] = nil
end

function AntiCheat:OnCharacterAdded(player, character)
	local tracker = self.trackers[player]
	if not tracker then return end


	wait(0.5)

	tracker:UpdateCharacter()

	if tracker.humanoid then

		tracker.humanoid.WalkSpeed = Config.WALK_SPEED
		tracker.humanoid.JumpPower = Config.JUMP_POWER


		tracker.humanoid.StateChanged:Connect(function(oldState, newState)
			if newState == Enum.HumanoidStateType.Landed then
				tracker.airTime = 0
				tracker.isGrounded = true
			elseif newState == Enum.HumanoidStateType.Freefall or
				newState == Enum.HumanoidStateType.Jumping then
				tracker.isGrounded = false
			end
		end)


		tracker.humanoid.HealthChanged:Connect(function(newHealth)
			tracker.lastHealth = newHealth
		end)

		tracker.humanoid.Died:Connect(function()
			local creator = tracker.humanoid:FindFirstChild("creator")
			if creator and creator.Value and creator.Value:IsA("Player") then
				AllKillDetection:CheckDeath(player, creator.Value)
			end
		end)
	end

	if tracker.rootPart then
		tracker.lastValidPosition = tracker.rootPart.Position
		tracker:RecordPosition(tracker.rootPart.Position)
	end


	tracker:ResetViolations()
	tracker.respawnTime = tick()

	Utility:Log("Character initialized", player, "INFO")
end

function AntiCheat:DetectionLoop()
	while self.running do
		for player, tracker in pairs(self.trackers) do
			if tracker.rootPart and tracker.humanoid and tracker.humanoid.Health > 0 then

				if tick() - tracker.respawnTime < 2 then
					continue
				end

				if tracker:IsBypassed() then
					Utility:DebugLog("Detection bypassed for " .. player.Name)
					continue
				end

				tracker:RecordPosition(tracker.rootPart.Position)

				tracker:CheckGrounded()

				if tracker.isGrounded then
					tracker.lastValidPosition = tracker.rootPart.Position
				end

				local detections = {
					{name = "SPEED", check = SpeedDetection:Check(tracker)},
					{name = "JUMP", check = JumpDetection:Check(tracker)},
					{name = "FLY", check = FlyDetection:Check(tracker)},
					{name = "NOCLIP", check = NoClipDetection:Check(tracker)},
					{name = "TELEPORT", check = TeleportDetection:Check(tracker)},
					{name = "PHYSICS", check = PhysicsDetection:Check(tracker)},
					{name = "HUMANOID", check = HumanoidDetection:Check(tracker)},
					{name = "ATTRIBUTE", check = AttributeProtection:Check(tracker)},
				}

				for _, detection in ipairs(detections) do
					if detection.check then
						PunishmentHandler:Execute(tracker, detection.name)
					end
				end

				tracker:UpdateCharacter()
			end
		end

		wait(Config.PERFORMANCE.UPDATE_RATE)
	end
end

function AntiCheat:SanityCheckLoop()
	while self.running do
		-- Verify workspace gravity
		if workspace.Gravity ~= Config.GRAVITY then
			workspace.Gravity = Config.GRAVITY
			Utility:Log("Gravity restored to " .. Config.GRAVITY, nil, "INFO")
		end

		for player, tracker in pairs(self.trackers) do
			if tracker.humanoid then
				if tracker.humanoid.WalkSpeed ~= Config.WALK_SPEED then
					tracker.humanoid.WalkSpeed = Config.WALK_SPEED
				end

				if tracker.humanoid.JumpPower ~= Config.JUMP_POWER then
					tracker.humanoid.JumpPower = Config.JUMP_POWER
				end
			end
		end

		wait(Config.ANTI_BYPASS.SANITY_CHECK_INTERVAL)
	end
end

--================================================================================
-- PUBLIC API
--================================================================================

function AntiCheat:GetPlayerStats(player)
	local tracker = self.trackers[player]
	if not tracker then return nil end

	return {
		violations = tracker.violations,
		warnings = tracker.totalWarnings,
		isGrounded = tracker.isGrounded,
		airTime = tracker.airTime,
		lastPosition = tracker.lastValidPosition,
	}
end

function AntiCheat:ForceCheck(player)
	local tracker = self.trackers[player]
	if not tracker then return false end

	SpeedDetection:Check(tracker)
	JumpDetection:Check(tracker)
	FlyDetection:Check(tracker)
	NoClipDetection:Check(tracker)
	TeleportDetection:Check(tracker)
	PhysicsDetection:Check(tracker)

	return true
end

function AntiCheat:ResetPlayer(player)
	local tracker = self.trackers[player]
	if not tracker then return false end

	tracker:ResetViolations()
	Utility:Log("Player violations reset", player, "INFO")
	return true
end

function AntiCheat:GetLogs()
	return _G.AntiCheatLogs or {}
end

function AntiCheat:SetDebugMode(enabled)
	Config.DEBUG_MODE = enabled
	Utility:Log("Debug mode set to: " .. tostring(enabled), nil, "INFO")
end

function AntiCheat:SetBypass(player, duration)
	local tracker = self.trackers[player]
	if not tracker then return false end

	tracker:SetBypass(duration)
	return true
end


local bypassRemote = Instance.new("RemoteEvent")
bypassRemote.Name = "AntiCheatBypass"
bypassRemote.Parent = ReplicatedStorage

bypassRemote.OnServerEvent:Connect(function(player, action, duration)
	if action == "TeleportBypass" then
		local tracker = AntiCheat.trackers[player]
		if tracker then
			tracker:SetBypass(duration or 0.5)
		end
	end
end)

Utility:Log("Bypass RemoteEvent registered", nil, "INFO")

if Config.ANTI_BYPASS.DETECT_REMOTE_SPY then

	local validRemotes = {}

	local function validateRemoteCall(player, remoteName, ...)
		local args = {...}

		for _, arg in ipairs(args) do
			if type(arg) == "string" then
				local lowerArg = arg:lower()
				if lowerArg:find("admin") or lowerArg:find("script") or
					lowerArg:find("inject") or lowerArg:find("exploit") or
					lowerArg:find("hack") or lowerArg:find("cheat") then
					Utility:Log("Suspicious remote call from " .. player.Name .. ": " .. lowerArg, player, "CRITICAL")
					return false
				end
			end

			if type(arg) == "table" then
				local success, encoded = pcall(function()
					return game:GetService("HttpService"):JSONEncode(arg)
				end)
				if success then
					local lowerEncoded = encoded:lower()
					if lowerEncoded:find("hack") or lowerEncoded:find("exploit") then
						Utility:Log("Suspicious table argument from " .. player.Name, player, "CRITICAL")
						return false
					end
				end
			end
		end

		return true
	end

	_G.ValidateRemoteCall = validateRemoteCall
end


AntiCheat:Initialize()

return AntiCheat
