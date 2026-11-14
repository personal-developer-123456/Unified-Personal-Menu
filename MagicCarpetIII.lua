--[[
	MAGIC CARPET  (v3 - executor friendly)
	-------------------------------------------------------------
	EXECUTOR (mobile or PC)
	  Open this file, select all, copy, paste into your executor, Execute.
	  A "Magic Carpet" pop-up appears when it loads. If something breaks,
	  the pop-up shows the error text.

	STUDIO
	  StarterPlayer > StarterPlayerScripts > insert a LocalScript
	  (must be a LocalScript, not a Script), paste, Play.

	MINI MENU
	  ^ / v          fly forward / back   (in LIFT mode: go up / down)
	  < / >          turn left / right
	  green screen   tap to switch FLY <-> LIFT (also shows your height)
	                 tap it when it says OFF (or ERR) to hop on
	  Jump           hop off the carpet

	MOBILE
	  The normal joystick also flies the carpet (push up = forward,
	  left/right = turn). The menu is a bit bigger on touch screens.

	KEYBOARD
	  W / S = forward / back    A / D = turn    E / Q = up / down
]]

-- pop-up message (works even when you can't see the console)
local function notify(text)
	task.spawn(function()
		for _ = 1, 10 do
			local ok = pcall(function()
				game:GetService("StarterGui"):SetCore("SendNotification", {
					Title = "Magic Carpet",
					Text = text,
					Duration = 8,
				})
			end)
			if ok then return end
			task.wait(0.5)
		end
	end)
end

local function main()
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local UserInputService = game:GetService("UserInputService")

	-- wait for the game + player (executors can run before they're ready)
	if not game:IsLoaded() then game.Loaded:Wait() end
	local player = Players.LocalPlayer
	local waited = 0
	while not player and waited < 5 do
		task.wait(0.1)
		waited = waited + 0.1
		player = Players.LocalPlayer
	end
	if not player then
		warn("[MagicCarpet] No LocalPlayer - in Studio this must be a LocalScript, not a Script.")
		return
	end

	-- if you run it twice, shut the old copy down first
	local env = _G
	pcall(function()
		if getgenv then env = getgenv() end
	end)
	if env.MagicCarpetShutdown then
		pcall(env.MagicCarpetShutdown)
	end

	------------------------------------------------------------------
	-- SETTINGS
	------------------------------------------------------------------
	local CARPET_SIZE      = Vector3.new(7, 0.4, 9)      -- width, thickness, length
	local CARPET_COLOR     = Color3.fromRGB(178, 34, 52)
	local TRIM_COLOR       = Color3.fromRGB(240, 192, 64)
	local HOVER_HEIGHT     = 3                           -- starting height above ground
	local FLY_SPEED        = 45                          -- studs / second
	local LIFT_SPEED       = 25
	local TURN_SPEED       = 2                           -- radians / second
	local MENU_SIZE        = UDim2.fromOffset(120, 76)   -- keep it small
	local MENU_POSITION    = UDim2.new(0, 12, 0.5, 0)    -- left side, middle
	local MENU_ANCHOR      = Vector2.new(0, 0.5)
	local TOUCH_MENU_SCALE = 1.25                        -- menu size multiplier on phones

	------------------------------------------------------------------
	-- STATE
	------------------------------------------------------------------
	local riding = false
	local mode = "FLY"
	local carpet, base, weld, mover, aligner
	local screen -- the green screen button (made below)
	local yaw = 0
	local velocity = Vector3.zero
	local mountedAt = 0
	local saved = nil
	local jumpConn = nil
	local controls = nil
	local kb, ui = {}, {} -- held inputs from keyboard / menu buttons

	local conns = {}
	local function on(signal, fn)
		local c = signal:Connect(fn)
		table.insert(conns, c)
		return c
	end

	------------------------------------------------------------------
	-- BUILD THE CARPET
	------------------------------------------------------------------
	local function buildCarpet()
		local W, T, L = CARPET_SIZE.X, CARPET_SIZE.Y, CARPET_SIZE.Z
		local block = Enum.PartType.Block
		local cylinder = Enum.PartType.Cylinder

		local model = Instance.new("Model")
		model.Name = "MagicCarpet"

		local main = Instance.new("Part")
		main.Name = "Base"
		main.Size = CARPET_SIZE
		main.Color = CARPET_COLOR
		main.Material = Enum.Material.Fabric
		main.TopSurface = Enum.SurfaceType.Smooth
		main.BottomSurface = Enum.SurfaceType.Smooth
		main.Parent = model
		model.PrimaryPart = main

		-- small non-colliding decoration welded to the base
		local function decor(shape, size, offset, color)
			local p = Instance.new("Part")
			p.Shape = shape
			p.Size = size
			p.Color = color
			p.Material = Enum.Material.Fabric
			p.TopSurface = Enum.SurfaceType.Smooth
			p.BottomSurface = Enum.SurfaceType.Smooth
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.Massless = true
			p.CFrame = main.CFrame * offset
			p.Parent = model

			local w = Instance.new("WeldConstraint")
			w.Part0 = main
			w.Part1 = p
			w.Parent = p
		end

		local top = T / 2 + 0.04
		local flat = CFrame.Angles(0, 0, math.rad(90)) -- lays a cylinder flat

		-- gold trim: two sides + back
		for _, s in ipairs({ -1, 1 }) do
			decor(block, Vector3.new(0.3, 0.1, L - 0.6), CFrame.new(s * (W / 2 - 0.45), top, 0), TRIM_COLOR)
		end
		decor(block, Vector3.new(W - 0.6, 0.1, 0.3), CFrame.new(0, top, L / 2 - 0.45), TRIM_COLOR)

		-- raised rolled edge at the front (like your drawing)
		decor(cylinder, Vector3.new(W, 0.6, 0.6), CFrame.new(0, T / 2 + 0.1, -L / 2 + 0.3), Color3.fromRGB(130, 20, 38))

		-- center medallion
		decor(cylinder, Vector3.new(0.1, 3.2, 3.2), CFrame.new(0, top, 0) * flat, TRIM_COLOR)
		decor(cylinder, Vector3.new(0.12, 2.2, 2.2), CFrame.new(0, top + 0.01, 0) * flat, CARPET_COLOR)
		decor(cylinder, Vector3.new(0.14, 1.0, 1.0), CFrame.new(0, top + 0.02, 0) * flat, TRIM_COLOR)

		-- fringe at both ends
		local count = 12
		for i = 1, count do
			local x = -W / 2 + (i - 0.5) * (W / count)
			decor(block, Vector3.new(0.2, 0.12, 0.8), CFrame.new(x, 0, -(L / 2 + 0.35)), TRIM_COLOR)
			decor(block, Vector3.new(0.2, 0.12, 0.8), CFrame.new(x, 0, L / 2 + 0.35), TRIM_COLOR)
		end

		return model, main
	end

	------------------------------------------------------------------
	-- MOUNT / DISMOUNT
	------------------------------------------------------------------
	local function cleanup()
		riding = false
		velocity = Vector3.zero
		table.clear(kb)
		table.clear(ui)

		if jumpConn then
			jumpConn:Disconnect()
			jumpConn = nil
		end
		if weld then weld:Destroy() end
		if carpet then carpet:Destroy() end
		carpet, base, weld, mover, aligner = nil, nil, nil, nil, nil

		if saved and saved.humanoid and saved.humanoid.Parent then
			saved.humanoid.WalkSpeed = saved.WalkSpeed
			saved.humanoid.JumpPower = saved.JumpPower
			saved.humanoid.JumpHeight = saved.JumpHeight
			saved.humanoid.AutoRotate = saved.AutoRotate
		end
		saved = nil

		if screen then screen.Text = "OFF" end
	end

	local function dismount()
		if riding then cleanup() end
	end

	local function mount()
		if riding then return end

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root or humanoid.Health <= 0 then return end

		-- work out where the feet are, so the carpet sits right under them
		local boxCFrame, boxSize = character:GetBoundingBox()
		local feetY = boxCFrame.Position.Y - boxSize.Y / 2

		local look = root.CFrame.LookVector
		yaw = math.atan2(-look.X, -look.Z)
		velocity = Vector3.zero
		mode = "FLY"

		carpet, base = buildCarpet()
		local carpetY = feetY + HOVER_HEIGHT - CARPET_SIZE.Y / 2 - 0.05
		carpet:PivotTo(CFrame.new(root.Position.X, carpetY, root.Position.Z) * CFrame.Angles(0, yaw, 0))
		character:PivotTo(character:GetPivot() + Vector3.new(0, HOVER_HEIGHT, 0))
		root.AssemblyLinearVelocity = Vector3.zero
		carpet.Parent = workspace

		local attachment = Instance.new("Attachment")
		attachment.Parent = base

		mover = Instance.new("LinearVelocity")
		mover.Attachment0 = attachment
		mover.RelativeTo = Enum.ActuatorRelativeTo.World
		mover.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		mover.MaxForce = math.huge
		mover.VectorVelocity = Vector3.zero
		mover.Parent = base

		aligner = Instance.new("AlignOrientation")
		aligner.Mode = Enum.OrientationAlignmentMode.OneAttachment
		aligner.Attachment0 = attachment
		aligner.MaxTorque = math.huge
		aligner.Responsiveness = 20
		aligner.CFrame = CFrame.Angles(0, yaw, 0)
		aligner.Parent = base

		-- stick the player to the carpet
		weld = Instance.new("WeldConstraint")
		weld.Part0 = base
		weld.Part1 = root
		weld.Parent = base

		saved = {
			humanoid = humanoid,
			WalkSpeed = humanoid.WalkSpeed,
			JumpPower = humanoid.JumpPower,
			JumpHeight = humanoid.JumpHeight,
			AutoRotate = humanoid.AutoRotate,
		}
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
		humanoid.AutoRotate = false

		mountedAt = os.clock()
		riding = true

		-- jump (space or the mobile jump button) = hop off
		jumpConn = humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
			if humanoid.Jump and riding and os.clock() - mountedAt > 0.5 then
				cleanup()
			end
		end)
	end

	-- if anything goes wrong, say so on screen instead of silently dying
	local function safeMount()
		local ok, err = pcall(mount)
		if not ok then
			warn("[MagicCarpet] couldn't start the carpet: " .. tostring(err))
			cleanup()
			if screen then screen.Text = "ERR" end
			notify("Carpet error: " .. string.sub(tostring(err), 1, 150))
		end
	end

	------------------------------------------------------------------
	-- MINI MENU
	------------------------------------------------------------------
	local gui = Instance.new("ScreenGui")
	gui.Name = "CarpetMenu"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50

	-- executors: hidden UI folder / CoreGui work best. Studio: PlayerGui.
	local parents = {}
	pcall(function()
		if gethui then table.insert(parents, gethui()) end
	end)
	pcall(function()
		table.insert(parents, game:GetService("CoreGui"))
	end)
	table.insert(parents, player:WaitForChild("PlayerGui"))

	for _, p in ipairs(parents) do
		pcall(function()
			gui.Parent = p
		end)
		if gui.Parent == p then break end
	end
	if not gui.Parent then
		error("couldn't put the menu on screen")
	end

	local frame = Instance.new("Frame")
	frame.Name = "Menu"
	frame.Size = MENU_SIZE
	frame.Position = MENU_POSITION
	frame.AnchorPoint = MENU_ANCHOR
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.Parent = gui

	local frameStroke = Instance.new("UIStroke")
	frameStroke.Thickness = 3
	frameStroke.Color = Color3.new(0, 0, 0)
	frameStroke.Parent = frame

	if UserInputService.TouchEnabled then
		local uiScale = Instance.new("UIScale")
		uiScale.Scale = TOUCH_MENU_SCALE
		uiScale.Parent = frame
	end

	local function makeButton(text, x, y, w, h, color)
		local b = Instance.new("TextButton")
		b.Text = text
		b.Position = UDim2.fromScale(x, y)
		b.Size = UDim2.fromScale(w, h)
		b.BackgroundColor3 = color or Color3.new(1, 1, 1)
		b.TextColor3 = Color3.new(0, 0, 0)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 18
		b.AutoButtonColor = true
		b.Parent = frame

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.5
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Parent = b
		return b
	end

	-- same layout as the sketch: screen + up on top, < > + down below
	screen = makeButton("OFF", 0.06, 0.12, 0.54, 0.32, Color3.fromRGB(127, 255, 0))
	screen.Font = Enum.Font.Code
	screen.TextScaled = true
	local sizeLimit = Instance.new("UITextSizeConstraint")
	sizeLimit.MaxTextSize = 14
	sizeLimit.Parent = screen

	local upBtn    = makeButton("^", 0.66, 0.12, 0.28, 0.32)
	local leftBtn  = makeButton("<", 0.06, 0.56, 0.25, 0.32)
	local rightBtn = makeButton(">", 0.35, 0.56, 0.25, 0.32)
	local downBtn  = makeButton("v", 0.66, 0.56, 0.28, 0.32)

	print("[MagicCarpet] menu loaded")

	-- hold a button = keep doing the thing
	local function hold(button, getKey)
		button.InputBegan:Connect(function(input)
			local t = input.UserInputType
			if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end

			local key = getKey()
			ui[key] = true

			local conn
			conn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					conn:Disconnect()
					ui[key] = nil
				end
			end)
		end)
	end

	hold(upBtn,    function() return mode == "FLY" and "fwd" or "up" end)
	hold(downBtn,  function() return mode == "FLY" and "back" or "down" end)
	hold(leftBtn,  function() return "left" end)
	hold(rightBtn, function() return "right" end)

	screen.Activated:Connect(function()
		if riding then
			mode = (mode == "FLY") and "LIFT" or "FLY"
		else
			safeMount()
		end
	end)

	------------------------------------------------------------------
	-- KEYBOARD + JUMP + MOBILE JOYSTICK
	------------------------------------------------------------------
	local KEYS = {
		[Enum.KeyCode.W] = "fwd",
		[Enum.KeyCode.S] = "back",
		[Enum.KeyCode.A] = "left",
		[Enum.KeyCode.D] = "right",
		[Enum.KeyCode.E] = "up",
		[Enum.KeyCode.Q] = "down",
	}

	on(UserInputService.InputBegan, function(input, processed)
		if processed then return end
		local name = KEYS[input.KeyCode]
		if name then kb[name] = true end
	end)

	on(UserInputService.InputEnded, function(input)
		local name = KEYS[input.KeyCode]
		if name then kb[name] = false end
	end)

	on(UserInputService.JumpRequest, function()
		if riding and os.clock() - mountedAt > 0.5 then
			cleanup()
		end
	end)

	-- grab Roblox's own controls so the mobile joystick can steer the carpet
	task.spawn(function()
		local ok, result = pcall(function()
			local scripts = player:WaitForChild("PlayerScripts", 10)
			local module = scripts:WaitForChild("PlayerModule", 10)
			return require(module):GetControls()
		end)
		if ok and result then controls = result end
	end)

	------------------------------------------------------------------
	-- FLY!
	------------------------------------------------------------------
	local function axis(plus, minus)
		local p = (kb[plus] or ui[plus]) and 1 or 0
		local m = (kb[minus] or ui[minus]) and 1 or 0
		return p - m
	end

	local function step(dt)
		if not (base and base.Parent) then
			cleanup()
			return
		end

		-- joystick: x = right, z = back (so forward is negative z)
		local stick = Vector3.zero
		if controls then
			local ok, v = pcall(controls.GetMoveVector, controls)
			if ok and v then stick = v end
		end

		local forward = math.clamp(axis("fwd", "back") - stick.Z, -1, 1)
		local turn    = math.clamp(axis("left", "right") - stick.X, -1, 1)
		local lift    = axis("up", "down")

		yaw = yaw + turn * TURN_SPEED * dt
		aligner.CFrame = CFrame.Angles(0, yaw, 0)

		local heading = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
		local target = heading * (forward * FLY_SPEED) + Vector3.new(0, lift * LIFT_SPEED, 0)

		velocity = velocity:Lerp(target, math.min(dt * 5, 1)) -- smooth start / stop
		mover.VectorVelocity = velocity

		screen.Text = string.format("%s %dm", mode, math.floor(base.Position.Y + 0.5))
	end

	on(RunService.Heartbeat, function(dt)
		if not riding then return end
		local ok, err = pcall(step, dt)
		if not ok then
			warn("[MagicCarpet] flight error: " .. tostring(err))
			cleanup()
			notify("Carpet error: " .. string.sub(tostring(err), 1, 150))
		end
	end)

	------------------------------------------------------------------
	-- START (auto-mount whenever you spawn)
	------------------------------------------------------------------
	local function onCharacter(character)
		local humanoid = character:WaitForChild("Humanoid")
		character:WaitForChild("HumanoidRootPart")
		on(humanoid.Died, dismount)

		task.wait(0.5)
		if player.Character == character then
			safeMount()
		end
	end

	on(player.CharacterRemoving, cleanup)
	on(player.CharacterAdded, onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end

	env.MagicCarpetShutdown = function()
		for _, c in ipairs(conns) do c:Disconnect() end
		cleanup()
		gui:Destroy()
	end

	notify("Loaded! Menu is on the left side.")
end

local ok, err = xpcall(main, function(e)
	return tostring(e)
end)
if not ok then
	warn("[MagicCarpet] ERROR: " .. tostring(err))
	notify("ERROR: " .. string.sub(tostring(err), 1, 180))
end
