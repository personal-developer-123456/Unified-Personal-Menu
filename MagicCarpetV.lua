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

	MENU
	  Header         drag it to move the menu, "-" / "+" to fold it up
	  Status bar     shows what the carpet is doing and your height.
	                 Tap it when it says "Off carpet" to hop back on
	  Fly / Lift     fly forward and back, or go straight up and down
	  Arrows         up / down = forward / back (in Lift: rise / sink)
	                 left / right = turn
	  Speed box      type any number to set how fast the carpet goes
	  Disable        removes the carpet and stops it from appearing
	                 on respawn. Press Enable to bring it back
	  Jump           hop off the carpet

	MOBILE
	  The normal joystick also flies the carpet (push up = forward,
	  left/right = turn).

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
	local TweenService = game:GetService("TweenService")

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
	local FLY_SPEED        = 45                          -- starting speed (studs / second)
	local LIFT_SPEED       = 25                          -- up/down speed at the starting speed
	local MIN_SPEED        = 0                           -- lowest / highest speed the box accepts
	local MAX_SPEED        = 10000
	local TURN_SPEED       = 2                           -- radians / second
	local MENU_POSITION    = UDim2.new(0, 12, 0.5, -134) -- top-left corner: left side, middle
	local TOUCH_MENU_SCALE = 1                           -- menu size multiplier on phones

	------------------------------------------------------------------
	-- STATE
	------------------------------------------------------------------
	local enabled = true          -- the Disable / Enable button
	local riding = false
	local lastError = false
	local mode = "FLY"
	local flySpeed = FLY_SPEED    -- changed by the speed box
	local liftRatio = LIFT_SPEED / FLY_SPEED
	local carpet, base, weld, mover, aligner
	local yaw = 0
	local velocity = Vector3.zero
	local mountedAt = 0
	local saved = nil
	local jumpConn = nil
	local controls = nil
	local kb, ui = {}, {} -- held inputs from keyboard / menu buttons

	-- filled in by the menu section below
	local refreshUI, updateStatus

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

		if refreshUI then refreshUI() end
	end

	local function dismount()
		if riding then cleanup() end
	end

	local function mount()
		if riding or not enabled then return end

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
		if ok then
			lastError = false
		else
			warn("[MagicCarpet] couldn't start the carpet: " .. tostring(err))
			cleanup()
			lastError = true
			notify("Carpet error: " .. string.sub(tostring(err), 1, 150))
		end
		if refreshUI then refreshUI() end
	end

	-- the Disable / Enable button
	local function setEnabled(value)
		enabled = value
		lastError = false
		if enabled then
			safeMount()
		else
			cleanup() -- drops the carpet and gives your character back
		end
		if refreshUI then refreshUI() end
	end

	------------------------------------------------------------------
	-- MENU
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

	-- palette: carpet red + gold on a deep plum
	local C = {
		bg      = Color3.fromRGB(24, 20, 29),
		inset   = Color3.fromRGB(16, 13, 20),
		panel   = Color3.fromRGB(42, 36, 50),
		press   = Color3.fromRGB(128, 98, 32),
		text    = Color3.fromRGB(240, 235, 226),
		muted   = Color3.fromRGB(140, 132, 152),
		dark    = Color3.fromRGB(32, 24, 10),
		green   = Color3.fromRGB(86, 204, 124),
		amber   = TRIM_COLOR,
		red     = Color3.fromRGB(224, 78, 90),
		redBtn  = Color3.fromRGB(150, 40, 54),
		greenBtn = Color3.fromRGB(40, 128, 80),
	}

	local MENU_W, HEADER_H, BODY_H = 204, 28, 238
	local MENU_H = HEADER_H + 1 + BODY_H

	local function new(class, props, parent)
		local obj = Instance.new(class)
		for key, value in pairs(props) do
			obj[key] = value
		end
		obj.Parent = parent
		return obj
	end

	local function round(obj, radius)
		new("UICorner", { CornerRadius = UDim.new(0, radius) }, obj)
	end

	local function circle(obj)
		new("UICorner", { CornerRadius = UDim.new(1, 0) }, obj)
	end

	local frame = new("Frame", {
		Name = "Menu",
		Size = UDim2.fromOffset(MENU_W, MENU_H),
		Position = MENU_POSITION,
		BackgroundColor3 = C.bg,
		BorderSizePixel = 0,
		Active = true,
		ClipsDescendants = true,
	}, gui)
	round(frame, 12)
	new("UIStroke", { Color = TRIM_COLOR, Thickness = 1.5, Transparency = 0.5 }, frame)

	if UserInputService.TouchEnabled then
		new("UIScale", { Scale = TOUCH_MENU_SCALE }, frame)
	end

	-- header (drag here to move the menu)
	local header = new("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, HEADER_H),
		BackgroundColor3 = Color3.new(1, 1, 1), -- the gradient below supplies the color
		BorderSizePixel = 0,
		Active = true,
	}, frame)
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(96, 28, 46), Color3.fromRGB(44, 22, 36)),
		Rotation = 90,
	}, header)

	new("TextLabel", {
		Name = "Title",
		Text = "Magic Carpet III",
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = TRIM_COLOR,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -48, 1, 0),
	}, header)

	local minBtn = new("TextButton", {
		Name = "Minimize",
		Text = "-",
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		TextColor3 = C.text,
		BackgroundColor3 = Color3.fromRGB(30, 18, 28),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(22, 20),
	}, header)
	round(minBtn, 6)

	-- thin gold line under the header
	new("Frame", {
		Name = "Divider",
		Position = UDim2.fromOffset(0, HEADER_H),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = TRIM_COLOR,
		BackgroundTransparency = 0.7,
		BorderSizePixel = 0,
	}, frame)

	local body = new("Frame", {
		Name = "Body",
		Position = UDim2.fromOffset(0, HEADER_H + 1),
		Size = UDim2.fromOffset(MENU_W, BODY_H),
		BackgroundTransparency = 1,
	}, frame)

	------------------------------------------------------------------
	-- status bar
	------------------------------------------------------------------
	local statusBtn = new("TextButton", {
		Name = "Status",
		Text = "",
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextScaled = true,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = C.inset,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.fromOffset(188, 28),
	}, body)
	round(statusBtn, 8)
	new("UIPadding", { PaddingLeft = UDim.new(0, 26), PaddingRight = UDim.new(0, 8) }, statusBtn)
	new("UITextSizeConstraint", { MinTextSize = 8, MaxTextSize = 13 }, statusBtn)

	local statusDot = new("Frame", {
		Name = "Dot",
		BackgroundColor3 = C.amber,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, -18, 0.5, 0), -- sits in the left padding
		Size = UDim2.fromOffset(8, 8),
	}, statusBtn)
	circle(statusDot)

	------------------------------------------------------------------
	-- Fly / Lift switch
	------------------------------------------------------------------
	local function modeButton(text, x)
		local b = new("TextButton", {
			Text = text,
			Font = Enum.Font.GothamBold,
			TextSize = 13,
			TextColor3 = C.muted,
			BackgroundColor3 = C.panel,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Position = UDim2.fromOffset(x, 42),
			Size = UDim2.fromOffset(92, 24),
		}, body)
		round(b, 8)
		return b
	end

	local flyBtn  = modeButton("Fly", 8)
	local liftBtn = modeButton("Lift", 104)

	------------------------------------------------------------------
	-- arrow pad (a rotated triangle, so every arrow is the same glyph)
	------------------------------------------------------------------
	local arrows = {}

	local function padButton(x, y, rotation)
		local b = new("TextButton", {
			Text = "",
			BackgroundColor3 = C.panel,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Position = UDim2.fromOffset(x, y),
			Size = UDim2.fromOffset(56, 36),
		}, body)
		round(b, 8)

		local arrow = new("TextLabel", {
			Text = "\u{25B2}",
			Font = Enum.Font.GothamBold,
			TextSize = 15,
			TextColor3 = C.muted,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			Rotation = rotation,
		}, b)
		table.insert(arrows, arrow)
		return b
	end

	local upBtn    = padButton(74, 74, 0)
	local leftBtn  = padButton(8, 116, -90)
	local downBtn  = padButton(74, 116, 180)
	local rightBtn = padButton(140, 116, 90)

	-- hold a button = keep doing the thing
	local function hold(button, getKey)
		button.InputBegan:Connect(function(input)
			local t = input.UserInputType
			if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end

			local key = getKey()
			ui[key] = true
			button.BackgroundColor3 = C.press

			local conn
			conn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					conn:Disconnect()
					ui[key] = nil
					button.BackgroundColor3 = C.panel
				end
			end)
		end)
	end

	hold(upBtn,    function() return mode == "FLY" and "fwd" or "up" end)
	hold(downBtn,  function() return mode == "FLY" and "back" or "down" end)
	hold(leftBtn,  function() return "left" end)
	hold(rightBtn, function() return "right" end)

	------------------------------------------------------------------
	-- speed box (type any number)
	------------------------------------------------------------------
	new("TextLabel", {
		Text = "Speed",
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = C.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 160),
		Size = UDim2.fromOffset(70, 30),
	}, body)

	local speedBox = new("TextBox", {
		Name = "SpeedBox",
		Text = tostring(FLY_SPEED),
		PlaceholderText = "studs/s",
		PlaceholderColor3 = C.muted,
		ClearTextOnFocus = false,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = TRIM_COLOR,
		BackgroundColor3 = C.inset,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(88, 160),
		Size = UDim2.fromOffset(108, 30),
	}, body)
	round(speedBox, 8)
	local speedStroke = new("UIStroke", { Color = TRIM_COLOR, Thickness = 1, Transparency = 1 }, speedBox)

	-- turn whatever was typed into a speed (ignores anything that isn't a number)
	local function applySpeed(value)
		local n = tonumber(value)
		if n and n == n then
			flySpeed = math.clamp(math.floor(n * 100 + 0.5) / 100, MIN_SPEED, MAX_SPEED)
			return true
		end
		return false
	end

	-- while typing: only digits and dots, and the carpet follows the number right away
	speedBox:GetPropertyChangedSignal("Text"):Connect(function()
		local cleaned = speedBox.Text:gsub("[^%d%.]", "")
		if cleaned ~= speedBox.Text then
			speedBox.Text = cleaned
			return
		end
		applySpeed(cleaned)
	end)

	speedBox.Focused:Connect(function()
		speedStroke.Transparency = 0.1
	end)

	-- when you finish typing: tidy the box (a bad entry goes back to the current speed)
	speedBox.FocusLost:Connect(function()
		speedStroke.Transparency = 1
		applySpeed(speedBox.Text)
		speedBox.Text = tostring(flySpeed)
	end)

	------------------------------------------------------------------
	-- enable / disable button
	------------------------------------------------------------------
	local toggleBtn = new("TextButton", {
		Name = "Toggle",
		Text = "Disable carpet",
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = C.text,
		BackgroundColor3 = C.redBtn,
		BorderSizePixel = 0,
		AutoButtonColor = true,
		Position = UDim2.fromOffset(8, 198),
		Size = UDim2.fromOffset(188, 32),
	}, body)
	round(toggleBtn, 8)

	------------------------------------------------------------------
	-- dragging (menu header)
	------------------------------------------------------------------
	local function isPress(input)
		local t = input.UserInputType
		return t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch
	end

	-- calls onMove(position) while the pointer that started on `startInput` is held down
	local function beginDrag(startInput, onMove)
		local moveConn, endConn
		local function stop()
			if moveConn then moveConn:Disconnect() end
			if endConn then endConn:Disconnect() end
		end

		moveConn = UserInputService.InputChanged:Connect(function(input)
			local t = input.UserInputType
			if t == Enum.UserInputType.MouseMovement or (t == Enum.UserInputType.Touch and input == startInput) then
				onMove(input.Position)
			end
		end)
		endConn = startInput.Changed:Connect(function()
			if startInput.UserInputState == Enum.UserInputState.End then stop() end
		end)
	end

	header.InputBegan:Connect(function(input)
		if not isPress(input) then return end
		local startPointer = input.Position
		local startPos = frame.AbsolutePosition
		beginDrag(input, function(pos)
			local screenSize = gui.AbsoluteSize
			local x = math.clamp(startPos.X + (pos.X - startPointer.X), 0, math.max(screenSize.X - 60, 0))
			local y = math.clamp(startPos.Y + (pos.Y - startPointer.Y), 0, math.max(screenSize.Y - HEADER_H, 0))
			frame.Position = UDim2.fromOffset(x, y)
		end)
	end)

	-- fold the menu up to just the header
	local collapsed = false
	minBtn.Activated:Connect(function()
		collapsed = not collapsed
		minBtn.Text = collapsed and "+" or "-"
		if collapsed then body.Visible = false end
		TweenService:Create(
			frame,
			TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.fromOffset(MENU_W, collapsed and HEADER_H or MENU_H) }
		):Play()
		if not collapsed then body.Visible = true end
	end)

	------------------------------------------------------------------
	-- keep the menu in sync with what the carpet is doing
	------------------------------------------------------------------
	updateStatus = function()
		local text, dot, color
		if not enabled then
			text, dot, color = "Disabled", C.red, C.muted
		elseif lastError then
			text, dot, color = "Error. Tap to retry", C.red, C.text
		elseif riding and base then
			local verb = (mode == "FLY") and "Flying" or "Lifting"
			text = string.format("%s at %d m", verb, math.floor(base.Position.Y + 0.5))
			dot, color = C.green, C.text
		else
			text, dot, color = "Off carpet. Tap to mount", C.amber, C.text
		end

		if statusBtn.Text ~= text then statusBtn.Text = text end
		statusBtn.TextColor3 = color
		statusDot.BackgroundColor3 = dot
	end

	refreshUI = function()
		updateStatus()

		-- Fly / Lift highlight (dim when you're not on the carpet)
		local isFly = riding and mode == "FLY"
		local isLift = riding and mode == "LIFT"
		flyBtn.BackgroundColor3  = isFly and TRIM_COLOR or C.panel
		flyBtn.TextColor3        = isFly and C.dark or (riding and C.text or C.muted)
		liftBtn.BackgroundColor3 = isLift and TRIM_COLOR or C.panel
		liftBtn.TextColor3       = isLift and C.dark or (riding and C.text or C.muted)

		for _, arrow in ipairs(arrows) do
			arrow.TextColor3 = riding and C.text or C.muted
		end

		if enabled then
			toggleBtn.Text = "Disable carpet"
			toggleBtn.BackgroundColor3 = C.redBtn
		else
			toggleBtn.Text = "Enable carpet"
			toggleBtn.BackgroundColor3 = C.greenBtn
		end
	end

	statusBtn.Activated:Connect(function()
		if enabled and not riding then
			lastError = false
			safeMount()
		end
	end)

	flyBtn.Activated:Connect(function()
		if riding then
			mode = "FLY"
			refreshUI()
		end
	end)

	liftBtn.Activated:Connect(function()
		if riding then
			mode = "LIFT"
			refreshUI()
		end
	end)

	toggleBtn.Activated:Connect(function()
		setEnabled(not enabled)
	end)

	refreshUI()
	print("[MagicCarpet] menu loaded")

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
		local target = heading * (forward * flySpeed) + Vector3.new(0, lift * flySpeed * liftRatio, 0)

		velocity = velocity:Lerp(target, math.min(dt * 5, 1)) -- smooth start / stop
		mover.VectorVelocity = velocity

		updateStatus()
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
		if player.Character == character and enabled then
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
