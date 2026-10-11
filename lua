--[[
	AntiShiftLock v2
	Turns off forced "shift lock" / locked camera on touch devices:
	  - the character being locked to the camera direction
	    (RotationType, AutoRotate, CFrame / BodyGyro / AlignOrientation locks)
	  - mouse lock (MouseBehavior = LockCenter, custom lock loops, lock flags)
	  - the "Follow" camera that automatically swings to stay behind you

	Works as a normal LocalScript or when run from an executor
	(it never uses the `script` object).
	Run it ONCE while you're in the game. Running it again just replaces the old copy.
	A small status panel shows what is being forced off (tap its X to hide it).
]]

--------------------------------------------------------------------------
-- SETTINGS
--------------------------------------------------------------------------
local CFG = {
	ONLY_ON_TOUCH_DEVICES = false, -- true = do nothing on PC / console
	SHOW_HUD = true,               -- small status panel on screen
	PRINT_LOG = false,             -- also print what got fixed to the console

	FORCE_AUTOROTATE = true,       -- keep Humanoid.AutoRotate switched on
	RESET_CAMERA_OFFSET = true,    -- remove the over-the-shoulder camera offset
	FORCE_CLASSIC_CAMERA = true,   -- stop the auto-rotating "Follow" touch camera
	AUTO_FACE_MOVEMENT = true,     -- if the game keeps snapping your character to face the camera, turn it back
	ALLOW_FIRST_PERSON = true,     -- hands off while fully zoomed into first person
	TURN_SPEED = 14,               -- how fast AUTO_FACE_MOVEMENT turns the character (higher = snappier)

	-- Names that lock scripts pass to RunService:BindToRenderStep().
	-- If you find the one your game uses, add it here.
	KILL_BINDINGS = {
		"ShiftLock", "Shiftlock", "shiftlock", "shiftLock",
		"MobileShiftLock", "MobileShiftlock", "ShiftLockMobile",
		"CustomShiftLock", "ForceShiftLock", "MouseLock", "LockCenter",
	},
}

--------------------------------------------------------------------------
-- SETUP
--------------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local gameSettings = UserSettings():GetService("UserGameSettings")
local env = (getgenv and getgenv()) or _G

-- replace any older copy of this script that is still running
if type(env.__AntiShiftLockStop) == "function" then
	pcall(env.__AntiShiftLockStop)
end

if CFG.ONLY_ON_TOUCH_DEVICES and not UserInputService.TouchEnabled then
	print("[AntiShiftLock] not a touch device, so this script is idle")
	return
end

local connections = {}
local RENDER_NAMES = { "AntiShiftLockPre", "AntiShiftLockPost" }
local stopped = false

local counts, rates, snapshot = {}, {}, {}
local lastCulprit = "-"
local lastLogged = {}

local mouseLockController = nil
local lockTimer, facingLocked, overrideFrames = 0, false, 0
local angMove, angCam = nil, nil
local overrideYaw = nil
local lastConstraintSweep, lastToggleSweep = -1, -1
local hudGui, hudLabel = nil, nil

local function fixed(what)
	counts[what] = (counts[what] or 0) + 1
	lastCulprit = what
	if CFG.PRINT_LOG then
		local now = os.clock()
		if now - (lastLogged[what] or -10) >= 2 then
			lastLogged[what] = now
			print("[AntiShiftLock] turned off: " .. what)
		end
	end
end

local function getParts()
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	return humanoid, humanoid.RootPart or character:FindFirstChild("HumanoidRootPart"), character
end

local function inFirstPerson()
	if player.CameraMode == Enum.CameraMode.LockFirstPerson then
		return true
	end
	local camera = workspace.CurrentCamera
	if camera and camera.CameraType == Enum.CameraType.Custom then
		return (camera.CFrame.Position - camera.Focus.Position).Magnitude < 1.1
	end
	return false
end

-- Roblox's own shift lock controller (normally doesn't exist on touch devices,
-- but if the game / PlayerModule created one, this switches it off).
task.spawn(function()
	local ok, controller = pcall(function()
		local scripts = player:WaitForChild("PlayerScripts", 10)
		local playerModule = require(scripts:WaitForChild("PlayerModule", 10))
		return playerModule:GetCameras().activeMouseLockController
	end)
	if ok then
		mouseLockController = controller
	end
end)

--------------------------------------------------------------------------
-- LAYERS. Each one is wrapped so a bug in one can never stop the others.
--------------------------------------------------------------------------
local layers = {}

local function newLayer(name, fn)
	local layer = { name = name, fn = fn, errors = 0, dead = false, lastError = nil }
	table.insert(layers, layer)
	return layer
end

local function run(layer, ...)
	if layer.dead then
		return
	end
	local ok, err = pcall(layer.fn, ...)
	if not ok then
		layer.errors += 1
		layer.lastError = tostring(err)
		if layer.errors >= 5 then
			layer.dead = true
		end
	end
end

-- 1) The engine's "face the camera" switch, mouse lock, AutoRotate, shoulder camera.
local L_props = newLayer("props", function()
	if CFG.ALLOW_FIRST_PERSON and inFirstPerson() then
		return
	end

	if gameSettings.RotationType ~= Enum.RotationType.MovementRelative then
		gameSettings.RotationType = Enum.RotationType.MovementRelative
		fixed("RotationType")
	end

	if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		fixed("MouseBehavior")
	end

	if mouseLockController then
		pcall(mouseLockController.EnableMouseLock, mouseLockController, false)
	end

	local humanoid = getParts()
	if humanoid then
		if CFG.FORCE_AUTOROTATE and not humanoid.AutoRotate then
			humanoid.AutoRotate = true
			fixed("AutoRotate")
		end
		if CFG.RESET_CAMERA_OFFSET and humanoid.CameraOffset ~= Vector3.zero then
			humanoid.CameraOffset = Vector3.zero
			fixed("CameraOffset")
		end
	end
end)

-- 2) The camera that automatically rotates to stay behind you on touch devices.
local L_camera = newLayer("camera", function()
	if not CFG.FORCE_CLASSIC_CAMERA then
		return
	end
	local classic = Enum.DevTouchCameraMovementMode.Classic
	if player.DevTouchCameraMode ~= classic then
		player.DevTouchCameraMode = classic
		fixed("TouchCamera")
	end
end)

-- 3) Custom lock loops that were started with BindToRenderStep (does nothing if the name isn't bound).
local L_bindings = newLayer("bindings", function()
	for _, name in ipairs(CFG.KILL_BINDINGS) do
		RunService:UnbindFromRenderStep(name)
	end
end)

-- 4) On/off flags (BoolValues / attributes) with "shiftlock" or "mouselock" in the name.
local function isLockName(name)
	name = string.lower(name)
	return string.find(name, "shiftlock", 1, true) ~= nil
		or string.find(name, "shift_lock", 1, true) ~= nil
		or string.find(name, "mouselock", 1, true) ~= nil
end

local L_toggles = newLayer("toggles", function()
	local now = os.clock()
	if now - lastToggleSweep < 0.1 then
		return
	end
	lastToggleSweep = now

	local holders = { player }
	if player.Character then
		table.insert(holders, player.Character)
	end
	for _, holder in ipairs(holders) do
		for name, value in pairs(holder:GetAttributes()) do
			if value == true and isLockName(name) then
				holder:SetAttribute(name, false)
				fixed("flag " .. name)
			end
		end
		for _, child in ipairs(holder:GetChildren()) do
			if child:IsA("BoolValue") and child.Value == true and isLockName(child.Name) then
				child.Value = false
				fixed("flag " .. child.Name)
			end
		end
	end
end)

-- 5) Character facing. If the game keeps forcing the character to face the camera
--    (for example by setting its CFrame every frame), detect it and turn it back.
local BAD_STATES = {
	[Enum.HumanoidStateType.Seated] = true,
	[Enum.HumanoidStateType.Climbing] = true,
	[Enum.HumanoidStateType.Swimming] = true,
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.GettingUp] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
	[Enum.HumanoidStateType.Physics] = true,
	[Enum.HumanoidStateType.Flying] = true,
	[Enum.HumanoidStateType.Dead] = true,
}

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function angleBetween(a, b)
	local d = a.Unit:Dot(b.Unit)
	return math.deg(math.acos(math.clamp(d, -1, 1)))
end

local L_facing = newLayer("facing", function(dt)
	local humanoid, root, character = getParts()
	local camera = workspace.CurrentCamera
	if not (humanoid and root and camera) then
		lockTimer, overrideYaw = 0, nil
		return
	end
	if CFG.ALLOW_FIRST_PERSON and inFirstPerson() then
		overrideYaw = nil
		return
	end

	-- detect "facing the camera while moving sideways / backwards"
	local velocity = flat(root.AssemblyLinearVelocity)
	local look = flat(root.CFrame.LookVector)
	local camLook = flat(camera.CFrame.LookVector)
	angMove, angCam = nil, nil
	if velocity.Magnitude > 5 and look.Magnitude > 0.1 and camLook.Magnitude > 0.1 then
		angMove = angleBetween(look, velocity)
		angCam = angleBetween(look, camLook)
		if angMove > 60 and angCam < 30 then
			lockTimer += dt
		else
			lockTimer = math.max(0, lockTimer - dt * 2)
		end
	else
		lockTimer = math.max(0, lockTimer - dt * 0.5)
	end
	if lockTimer > 0.5 then
		facingLocked = true -- stays on for the rest of the session
	end

	if not (CFG.AUTO_FACE_MOVEMENT and facingLocked) then
		overrideYaw = nil
		return
	end

	-- switch off rotation constraints that some games use to hold the facing
	local now = os.clock()
	if now - lastConstraintSweep > 0.25 then
		lastConstraintSweep = now
		for _, d in ipairs(character:GetDescendants()) do
			if d:IsA("BodyGyro") then
				if d.MaxTorque ~= Vector3.zero then
					d.MaxTorque = Vector3.zero
					fixed("BodyGyro")
				end
			elseif d:IsA("AlignOrientation") then
				if d.Enabled then
					d.Enabled = false
					fixed("AlignOrientation")
				end
			end
		end
	end

	-- turn the character toward where you are steering it
	local move = flat(humanoid.MoveDirection)
	local cf = root.CFrame
	if move.Magnitude < 0.1 or cf.UpVector.Y < 0.7 or humanoid.Sit or BAD_STATES[humanoid:GetState()] then
		overrideYaw = nil
		return
	end
	if overrideYaw == nil then
		overrideYaw = math.atan2(-look.X, -look.Z)
	end
	local target = math.atan2(-move.X, -move.Z)
	local diff = (target - overrideYaw + math.pi) % (2 * math.pi) - math.pi
	overrideYaw += diff * math.clamp(dt * CFG.TURN_SPEED, 0, 1)
	root.CFrame = CFrame.new(cf.Position) * CFrame.Angles(0, overrideYaw, 0)
	overrideFrames += 1
end)

--------------------------------------------------------------------------
-- STATUS PANEL
--------------------------------------------------------------------------
local function pickGuiParent()
	local ok, ui = pcall(function()
		return gethui and gethui()
	end)
	if ok and typeof(ui) == "Instance" then
		return ui
	end
	local probe = Instance.new("Folder")
	local okCore = pcall(function()
		probe.Parent = game:GetService("CoreGui")
	end)
	probe:Destroy()
	if okCore then
		return game:GetService("CoreGui")
	end
	return player:WaitForChild("PlayerGui")
end

local function buildHud()
	local gui = Instance.new("ScreenGui")
	gui.Name = "AntiShiftLockHUD"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 999999
	gui.IgnoreGuiInset = true

	local label = Instance.new("TextLabel")
	label.Name = "Status"
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.35
	label.BorderSizePixel = 0
	label.Position = UDim2.fromOffset(60, 84)
	label.Size = UDim2.fromOffset(390, 176)
	label.Font = Enum.Font.Code
	label.TextSize = 14
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = "AntiShiftLock starting..."
	label.Parent = gui

	-- X button on the panel: tap it to hide the panel
	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.Position = UDim2.new(1, -28, 0, 0) -- top right of the panel
	closeButton.Size = UDim2.fromOffset(28, 28)
	closeButton.BackgroundColor3 = Color3.fromRGB(160, 30, 30)
	closeButton.BackgroundTransparency = 0.2
	closeButton.BorderSizePixel = 0
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextSize = 14
	closeButton.TextColor3 = Color3.new(1, 1, 1)
	closeButton.Text = "X"
	closeButton.Parent = label

	-- tiny square button in the bottom right corner: only visible while the
	-- panel is hidden, tap it to bring the panel back
	local openButton = Instance.new("TextButton")
	openButton.Name = "Open"
	openButton.AnchorPoint = Vector2.new(1, 1)
	openButton.Position = UDim2.new(1, -6, 1, -6)
	openButton.Size = UDim2.fromOffset(22, 22)
	openButton.BackgroundColor3 = Color3.new(0, 0, 0)
	openButton.BackgroundTransparency = 0.35
	openButton.BorderSizePixel = 0
	openButton.Font = Enum.Font.GothamBold
	openButton.TextSize = 12
	openButton.TextColor3 = Color3.new(1, 1, 1)
	openButton.Text = "i"
	openButton.Visible = false
	openButton.Parent = gui

	local function setPanelVisible(visible)
		label.Visible = visible
		closeButton.Visible = visible
		openButton.Visible = not visible
	end

	-- touch taps only (mouse clicks and other inputs are ignored)
	local function onTap(button, callback)
		button.Activated:Connect(function(input)
			if input and input.UserInputType == Enum.UserInputType.Touch then
				callback()
			end
		end)
	end

	-- drag the panel with one finger (touch only, mouse is ignored).
	-- the panel stays inside the screen so it can't get lost off the edge.
	label.Active = true
	local dragTouch, dragStart, startPos = nil, nil, nil
	local didDrag = false
	local DRAG_THRESHOLD = 8 -- pixels you have to move before it counts as a drag

	local function beginDrag(input)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		if dragTouch then
			return
		end
		didDrag = false
		dragTouch = input
		dragStart = input.Position
		startPos = label.Position
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End and dragTouch == input then
				dragTouch = nil
			end
		end)
	end
	label.InputBegan:Connect(beginDrag)
	closeButton.InputBegan:Connect(beginDrag)

	table.insert(connections, UserInputService.InputChanged:Connect(function(input)
		if not dragTouch or input ~= dragTouch then
			return
		end
		local delta = input.Position - dragStart
		if not didDrag and delta.Magnitude < DRAG_THRESHOLD then
			return
		end
		didDrag = true
		local screen = gui.AbsoluteSize
		local x = math.clamp(startPos.X.Offset + delta.X, 0, math.max(0, screen.X - label.AbsoluteSize.X))
		local y = math.clamp(startPos.Y.Offset + delta.Y, 0, math.max(0, screen.Y - label.AbsoluteSize.Y))
		label.Position = UDim2.fromOffset(x, y)
	end))

	onTap(closeButton, function()
		if didDrag then
			return -- that was a drag that ended on the X, not a tap
		end
		setPanelVisible(false)
	end)
	onTap(openButton, function()
		setPanelVisible(true)
	end)

	gui.Parent = pickGuiParent()
	hudGui, hudLabel = gui, label
end

local function updateHud()
	if not hudLabel then
		return
	end
	local humanoid = getParts()
	local camera = workspace.CurrentCamera

	local function degrees(v)
		return v and string.format("%.0f", v) or "-"
	end

	local total, perSecond = 0, 0
	for key, value in pairs(counts) do
		total += value
		perSecond += rates[key] or 0
	end

	local broken = {}
	for _, layer in ipairs(layers) do
		if layer.dead then
			table.insert(broken, layer.name .. ": " .. string.sub(layer.lastError or "?", 1, 50))
		end
	end

	local lines = {
		"AntiShiftLock v2",
		"facing locked to cam: " .. (facingLocked and ("YES, override on (" .. overrideFrames .. ")") or "no"),
		("face vs move %s | vs cam %s deg"):format(degrees(angMove), degrees(angCam)),
		"RotationType: " .. gameSettings.RotationType.Name,
		"MouseBehavior: " .. UserInputService.MouseBehavior.Name,
		"AutoRotate: " .. tostring(humanoid and humanoid.AutoRotate),
		"Camera: " .. (camera and camera.CameraType.Name or "?")
			.. " / subject: " .. ((camera and camera.CameraSubject) and camera.CameraSubject.ClassName or "?"),
		"TouchCam dev: " .. player.DevTouchCameraMode.Name .. " user: " .. gameSettings.TouchCameraMovementMode.Name,
		("fixes: %d total, %d per sec"):format(total, perSecond),
		"last: " .. lastCulprit,
		(#broken == 0) and "layers: all ok" or ("OFF " .. table.concat(broken, "; ")),
	}
	hudLabel.Text = table.concat(lines, "\n")
end

local function refreshRates()
	for key, value in pairs(counts) do
		rates[key] = value - (snapshot[key] or 0)
		snapshot[key] = value
	end
end

--------------------------------------------------------------------------
-- HOOKS: run just before the camera, after everything else, and on every
-- physics step, so nothing can sneak a lock back on.
--------------------------------------------------------------------------
local function onPre()
	run(L_props)
	run(L_camera)
end

local function onPost(dt)
	run(L_props)
	run(L_camera)
	run(L_bindings)
	run(L_toggles)
	run(L_facing, dt)
end

local function onStep()
	run(L_props)
end

local function stop()
	if stopped then
		return
	end
	stopped = true
	for _, connection in ipairs(connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	for _, name in ipairs(RENDER_NAMES) do
		pcall(function()
			RunService:UnbindFromRenderStep(name)
		end)
	end
	if hudGui then
		pcall(function()
			hudGui:Destroy()
		end)
	end
end
env.__AntiShiftLockStop = stop

for _, name in ipairs(RENDER_NAMES) do
	RunService:UnbindFromRenderStep(name)
end
RunService:BindToRenderStep(RENDER_NAMES[1], Enum.RenderPriority.Camera.Value - 1, onPre)
RunService:BindToRenderStep(RENDER_NAMES[2], Enum.RenderPriority.Last.Value, onPost)
table.insert(connections, RunService.Stepped:Connect(onStep))
table.insert(connections, RunService.Heartbeat:Connect(onStep))

-- react instantly if something flips these back
pcall(function()
	table.insert(connections, UserInputService:GetPropertyChangedSignal("MouseBehavior"):Connect(onStep))
end)
pcall(function()
	table.insert(connections, gameSettings:GetPropertyChangedSignal("RotationType"):Connect(onStep))
end)
pcall(function()
	table.insert(connections, player:GetPropertyChangedSignal("DevTouchCameraMode"):Connect(function()
		run(L_camera)
	end))
end)

if CFG.SHOW_HUD then
	pcall(buildHud)
	task.spawn(function()
		local n = 0
		while not stopped do
			pcall(updateHud)
			n += 1
			if n % 5 == 0 then
				pcall(refreshRates)
			end
			task.wait(0.2)
		end
	end)
end

print("[AntiShiftLock] v2 running")
