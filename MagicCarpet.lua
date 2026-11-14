--[[
	MAGIC CARPET
	-------------------------------------------------------------
	SETUP
	  Roblox Studio > StarterPlayer > StarterPlayerScripts
	  Insert a LocalScript, paste this whole file in, press Play.

	MINI MENU
	  ^ / v          fly forward / back   (in LIFT mode: go up / down)
	  < / >          turn left / right
	  green screen   tap to switch FLY <-> LIFT (also shows your height)
	                 tap it when it says OFF to hop back on
	  Jump           hop off the carpet

	KEYBOARD
	  W / S = forward / back    A / D = turn    E / Q = up / down
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

------------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------------
local CARPET_SIZE   = Vector3.new(7, 0.4, 9)        -- width, thickness, length
local CARPET_COLOR  = Color3.fromRGB(178, 34, 52)
local TRIM_COLOR    = Color3.fromRGB(240, 192, 64)
local HOVER_HEIGHT  = 3                             -- starting height above ground
local FLY_SPEED     = 45                            -- studs / second
local LIFT_SPEED    = 25
local TURN_SPEED    = 2                             -- radians / second
local MENU_SIZE     = UDim2.fromOffset(120, 76)     -- keep it small
local MENU_POSITION = UDim2.new(0, 12, 0.5, 0)      -- left side, middle
local MENU_ANCHOR   = Vector2.new(0, 0.5)

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
local kb, ui = {}, {} -- held inputs from keyboard / menu buttons

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
	aligner.MaxAngularVelocity = math.huge
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
end

local function dismount()
	if not riding then return end
	riding = false
	velocity = Vector3.zero
	table.clear(kb)
	table.clear(ui)

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

------------------------------------------------------------------
-- MINI MENU
------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "CarpetMenu"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = MENU_SIZE
frame.Position = MENU_POSITION
frame.AnchorPoint = MENU_ANCHOR
frame.BackgroundColor3 = Color3.new(1, 1, 1)
frame.Parent = gui

local frameStroke = Instance.new("UIStroke")
frameStroke.Thickness = 3
frameStroke.Color = Color3.new(0, 0, 0)
frameStroke.Parent = frame

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
		mount()
	end
end)

------------------------------------------------------------------
-- KEYBOARD + JUMP
------------------------------------------------------------------
local KEYS = {
	[Enum.KeyCode.W] = "fwd",  [Enum.KeyCode.S] = "back",
	[Enum.KeyCode.A] = "left", [Enum.KeyCode.D] = "right",
	[Enum.KeyCode.E] = "up",   [Enum.KeyCode.Q] = "down",
}

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	local name = KEYS[input.KeyCode]
	if name then kb[name] = true end
end)

UserInputService.InputEnded:Connect(function(input)
	local name = KEYS[input.KeyCode]
	if name then kb[name] = false end
end)

UserInputService.JumpRequest:Connect(function()
	if riding and os.clock() - mountedAt > 0.5 then
		dismount()
	end
end)

------------------------------------------------------------------
-- FLY!
------------------------------------------------------------------
local function axis(plus, minus)
	local p = (kb[plus] or ui[plus]) and 1 or 0
	local m = (kb[minus] or ui[minus]) and 1 or 0
	return p - m
end

RunService.Heartbeat:Connect(function(dt)
	if not riding then return end
	if not (base and base.Parent) then
		dismount()
		return
	end

	yaw = yaw + axis("left", "right") * TURN_SPEED * dt
	aligner.CFrame = CFrame.Angles(0, yaw, 0)

	local heading = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	local target = heading * (axis("fwd", "back") * FLY_SPEED)
		+ Vector3.new(0, axis("up", "down") * LIFT_SPEED, 0)

	velocity = velocity:Lerp(target, math.min(dt * 5, 1)) -- smooth start / stop
	mover.VectorVelocity = velocity

	screen.Text = string.format("%s %dm", mode, math.floor(base.Position.Y + 0.5))
end)

------------------------------------------------------------------
-- START (auto-mount whenever you spawn)
------------------------------------------------------------------
local function onCharacter(character)
	local humanoid = character:WaitForChild("Humanoid")
	character:WaitForChild("HumanoidRootPart")
	humanoid.Died:Connect(dismount)

	task.wait(0.5)
	if player.Character == character then
		mount()
	end
end

player.CharacterRemoving:Connect(dismount)
player.CharacterAdded:Connect(onCharacter)
if player.Character then
	task.spawn(onCharacter, player.Character)
end
