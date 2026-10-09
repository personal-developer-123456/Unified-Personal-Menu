-- UnifiedMenu (LocalScript or executor script)
-- One black, rounded menu that holds every module:
--   ESP, Radar, Speed (others), Meter (your own speed), PartHL (part highlighter),
--   PartDel (part deleter), Danger (catcher detector), Rec (path recorder),
--   Fly (magic carpet), Aim (aim assist)
--
-- How it works:
--   * One row per module: [name] [on/off switch]
--   * Flip a switch ON -> module starts and its own submenu opens
--   * Tap a module's NAME -> show/hide its submenu
--   * "-" button -> minimize into a ball. Tap the ball to bring it back. (RightShift does the same)
--   * Drag the title bar to move, drag the dotted corner to resize.
-- Re-running this script is safe: it cleans up the previous copy first.

local Players = game:GetService("Players")
local Teams = game:GetService("Teams")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local PathfindingService = game:GetService("PathfindingService")

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local lp = Players.LocalPlayer
while not lp do
	task.wait()
	lp = Players.LocalPlayer
end
local playerGui = lp:FindFirstChildOfClass("PlayerGui") or lp:WaitForChild("PlayerGui")

---------------------------------------------------------------------
-- RE-RUN SAFETY + GUI PARENT
-- (the old version could silently vanish or stack on a second run)
---------------------------------------------------------------------
local env = (typeof(getgenv) == "function" and getgenv()) or _G
if type(env.__UnifiedMenuCleanup) == "function" then
	pcall(env.__UnifiedMenuCleanup)
end
env.__UnifiedMenuCleanup = nil

local allConns = {}
local function track(conn)
	allConns[#allConns + 1] = conn
	return conn
end

local function pickGuiParent()
	-- 1) executor-hidden UI container
	local ok, h = pcall(function()
		return gethui and gethui()
	end)
	if ok and typeof(h) == "Instance" then
		return h
	end
	-- 2) CoreGui, only if we are really allowed to write to it
	local okc, cg = pcall(function()
		return game:GetService("CoreGui")
	end)
	if okc and cg then
		local probe = Instance.new("Folder")
		local okp = pcall(function()
			probe.Parent = cg
		end)
		local inCore = okp and probe.Parent == cg
		probe:Destroy()
		if inCore then
			return cg
		end
	end
	-- 3) normal PlayerGui
	return playerGui
end

local guiParent = pickGuiParent()

do -- remove leftovers from older runs / older versions
	local containers = { guiParent, playerGui }
	pcall(function()
		table.insert(containers, game:GetService("CoreGui"))
	end)
	for _, container in ipairs(containers) do
		pcall(function()
			for _, name in ipairs({ "UnifiedMenu", "ProximityRadar" }) do
				local old = container:FindFirstChild(name)
				while old do
					old:Destroy()
					old = container:FindFirstChild(name)
				end
			end
		end)
	end
end

---------------------------------------------------------------------
-- MENU SETTINGS
---------------------------------------------------------------------
local TOUCH = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled -- phone/tablet

local MENU = {
	defaultSize = Vector2.new(TOUCH and 124 or 104, 270), -- px (width, height) of the main menu
	minSize = Vector2.new(84, 200),
	maxSize = Vector2.new(260, 470),
	startPos = Vector2.new(20, 120),
	panelWidth = 170,                   -- width of the submenus
	ballSize = TOUCH and 44 or 32,
}

local THEME = {
	bg = Color3.fromRGB(10, 10, 12),
	row = Color3.fromRGB(24, 24, 28),
	field = Color3.fromRGB(36, 36, 42),
	stroke = Color3.fromRGB(52, 52, 60),
	text = Color3.fromRGB(240, 240, 245),
	muted = Color3.fromRGB(140, 140, 150),
	on = Color3.fromRGB(50, 200, 100),
	off = Color3.fromRGB(62, 62, 70),
}

local TITLE_H = TOUCH and 26 or 20
local ROW_H = TOUCH and 30 or 26

---------------------------------------------------------------------
-- UI FRAMEWORK (shared by everything so all menus look the same)
---------------------------------------------------------------------
local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do
		o[k] = v
	end
	if parent then
		o.Parent = parent
	end
	return o
end

local function round(parent, radius)
	return new("UICorner", { CornerRadius = radius or UDim.new(0, 10) }, parent)
end

local function outline(parent, color, thickness)
	return new("UIStroke", {
		Color = color or THEME.stroke,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local gui = new("ScreenGui", {
	Name = "UnifiedMenu",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 100,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
pcall(function()
	if syn and syn.protect_gui then
		syn.protect_gui(gui)
	end
end)
gui.Parent = guiParent

-- all menu frames use pixel-offset sizes/positions, so we can clamp reliably
local function clampToScreen(f)
	local cam = workspace.CurrentCamera
	if not cam then return end
	local vp = cam.ViewportSize
	local sc = f:FindFirstChildOfClass("UIScale")
	local k = sc and sc.Scale or 1
	local w, h = f.Size.X.Offset * k, f.Size.Y.Offset * k
	f.Position = UDim2.fromOffset(
		math.clamp(f.Position.X.Offset, 0, math.max(0, vp.X - w)),
		math.clamp(f.Position.Y.Offset, 0, math.max(0, vp.Y - h))
	)
end

local zCounter = 1
local function bringToFront(f)
	zCounter += 1
	f.ZIndex = zCounter
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function isMove(input)
	return input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch
end

-- drag `target` by grabbing `handle` (mouse + touch). onTap fires on a click without movement.
local function makeDraggable(handle, target, onTap)
	local dragging, moved = false, false
	local startMouse, startPos, startInput

	handle.InputBegan:Connect(function(input)
		if isPress(input) then
			dragging, moved = true, false
			startInput = input
			startMouse = input.Position
			startPos = target.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					if not moved and onTap then
						onTap()
					end
				end
			end)
		end
	end)

	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and isMove(input)
			and (input.UserInputType ~= Enum.UserInputType.Touch or input == startInput) then
			local d = input.Position - startMouse
			if d.Magnitude > (TOUCH and 8 or 5) then
				moved = true
			end
			if moved then
				target.Position = UDim2.fromOffset(startPos.X.Offset + d.X, startPos.Y.Offset + d.Y)
				clampToScreen(target)
			end
		end
	end))
end

-- rounded black panel. With a title bar + small button, or (noTitle) draggable by its whole body.
local function makePanel(titleText, size, pos, buttonText, noTitle)
	local frame = new("Frame", {
		Name = titleText,
		Size = UDim2.fromOffset(size.X, size.Y),
		Position = UDim2.fromOffset(pos.X, pos.Y),
		BackgroundColor3 = THEME.bg,
		BorderSizePixel = 0,
		Active = true,
	}, gui)
	round(frame, UDim.new(0, 10))
	outline(frame)
	new("UIScale", { Scale = 1 }, frame)

	local bar, title, btn
	if noTitle then
		makeDraggable(frame, frame)
	else
		bar = new("Frame", {
			Name = "Bar",
			Size = UDim2.new(1, 0, 0, TITLE_H),
			BackgroundTransparency = 1,
			Active = true,
		}, frame)

		title = new("TextLabel", {
			Name = "Title",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(8, 0),
			Size = UDim2.new(1, -(TITLE_H + 10), 1, 0),
			Font = Enum.Font.GothamBold,
			Text = titleText,
			TextColor3 = THEME.text,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, bar)

		btn = new("TextButton", {
			Name = "Btn",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -5, 0.5, 0),
			Size = UDim2.fromOffset(TOUCH and 22 or 14, TOUCH and 22 or 14),
			BackgroundColor3 = THEME.field,
			AutoButtonColor = false,
			Font = Enum.Font.GothamBold,
			Text = buttonText or "",
			TextColor3 = THEME.text,
			TextSize = 12,
			BorderSizePixel = 0,
		}, bar)
		round(btn, UDim.new(1, 0))

		makeDraggable(bar, frame)
	end

	frame.InputBegan:Connect(function(input)
		if isPress(input) then
			bringToFront(frame)
		end
	end)

	return { frame = frame, bar = bar, title = title, btn = btn }
end

-- pill-shaped on/off switch. Returns the button and a setter.
local function makeSwitch(initial, onChange)
	local on = initial and true or false

	local track = new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = THEME.off,
		BorderSizePixel = 0,
	})
	round(track, UDim.new(1, 0))

	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.new(0.5, -2, 1, -4),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
	}, track)
	round(knob, UDim.new(1, 0))

	local function paint(animate)
		local knobPos = UDim2.fromScale(on and 0.73 or 0.27, 0.5)
		local color = on and THEME.on or THEME.off
		if animate then
			local info = TweenInfo.new(0.12, Enum.EasingStyle.Quad)
			TweenService:Create(knob, info, { Position = knobPos }):Play()
			TweenService:Create(track, info, { BackgroundColor3 = color }):Play()
		else
			knob.Position = knobPos
			track.BackgroundColor3 = color
		end
	end

	track.MouseButton1Click:Connect(function()
		on = not on
		paint(true)
		if onChange then
			onChange(on)
		end
	end)

	paint(false)

	local function set(v)
		on = v and true or false
		paint(true)
	end
	return track, set
end

-- submenu row helpers --------------------------------------------------
local function addRow(body)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, ROW_H),
		BackgroundColor3 = THEME.row,
		BorderSizePixel = 0,
		LayoutOrder = #body:GetChildren(),
	}, body)
	round(row, UDim.new(0, 8))
	return row
end

local function addLabel(row, text, rightSpace)
	return new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(1, -rightSpace, 1, 0),
		Font = Enum.Font.Gotham,
		Text = text,
		TextColor3 = THEME.text,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, row)
end

local function addSwitchRow(body, label, initial, onChange)
	local row = addRow(body)
	addLabel(row, label, 48)
	local track = makeSwitch(initial, onChange)
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.Position = UDim2.new(1, -6, 0.5, 0)
	track.Size = UDim2.fromOffset(TOUCH and 40 or 30, TOUCH and 22 or 16)
	track.Parent = row
end

local function addNumberRow(body, label, value, minV, maxV, onChange)
	local row = addRow(body)
	addLabel(row, label, TOUCH and 76 or 66)

	local box = new("TextBox", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -5, 0.5, 0),
		Size = UDim2.fromOffset(TOUCH and 64 or 54, TOUCH and 24 or 18),
		BackgroundColor3 = THEME.field,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = THEME.text,
		PlaceholderColor3 = THEME.muted,
		ClearTextOnFocus = true,
		Text = string.format("%g", value),
	}, row)
	round(box, UDim.new(0, 6))

	box.FocusLost:Connect(function()
		local n = tonumber(box.Text)
		if n then
			value = math.clamp(n, minV, maxV)
			onChange(value)
		end
		box.Text = string.format("%g", value) -- revert if it wasn't a valid number
	end)
end


-- extra row helpers (used by the newer modules) -------------------------
-- (re-defined so it returns the setter, which lets panel switches stay in sync)
local function addSwitchRow(body, label, initial, onChange)
	local row = addRow(body)
	addLabel(row, label, TOUCH and 54 or 48)
	local track, set = makeSwitch(initial, onChange)
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.Position = UDim2.new(1, -6, 0.5, 0)
	track.Size = UDim2.fromOffset(TOUCH and 40 or 30, TOUCH and 22 or 16)
	track.Parent = row
	return set
end

local function addButton(parent, text, color, onClick)
	local b = new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = color or THEME.field,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = text,
		TextColor3 = THEME.text,
		TextSize = 11,
	}, parent)
	round(b, UDim.new(0, 8))
	if onClick then
		b.MouseButton1Click:Connect(onClick)
	end
	return b
end

-- a row of equally wide buttons. defs = { {text=, color=, onClick=}, ... }
local function addButtonRow(body, height, defs)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, height),
		BackgroundTransparency = 1,
		LayoutOrder = #body:GetChildren(),
	}, body)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, row)
	local n = #defs
	local buttons = {}
	for i, d in ipairs(defs) do
		local b = addButton(row, d.text, d.color, d.onClick)
		b.LayoutOrder = i
		b.Size = UDim2.new(1 / n, -(4 * (n - 1)) / n, 1, 0)
		buttons[i] = b
	end
	return buttons
end

local function addInputRow(body, placeholder)
	local row = addRow(body)
	local box = new("TextBox", {
		Position = UDim2.fromOffset(4, 3),
		Size = UDim2.new(1, -8, 1, -6),
		BackgroundColor3 = THEME.field,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = THEME.text,
		PlaceholderText = placeholder,
		PlaceholderColor3 = THEME.muted,
		ClearTextOnFocus = false,
		Text = "",
	}, row)
	round(box, UDim.new(0, 6))
	return box
end

local RED = Color3.fromRGB(200, 50, 50)

---------------------------------------------------------------------
-- MODULE 1: PLAYER HIGHLIGHT
-- Highlights real players only. Falls back to box adornments when invisible.
---------------------------------------------------------------------
local ESP = {
	title = "Player Highlight",
	short = "ESP",
	enabled = false,
	cfg = { includeSelf = false, invisThreshold = 0.9 },
}

local HIGHLIGHT_NAME = "PlayerHighlight"
local ADORN_PREFIX = "InvisESP_"
local ESP_FILL = Color3.fromRGB(255, 0, 0)
local ESP_OUTLINE = Color3.fromRGB(255, 255, 255)

local espConns = {}
local espBags = {} -- [character] = { connections }

local function espIsInvisible(character)
	local ref = character:FindFirstChild("Head")
		or character:FindFirstChild("Torso")
		or character:FindFirstChild("UpperTorso")
	return ref ~= nil and ref:IsA("BasePart") and ref.Transparency >= ESP.cfg.invisThreshold
end

local function espClean(character)
	for _, child in ipairs(character:GetChildren()) do
		if child.Name == HIGHLIGHT_NAME or child.Name:sub(1, #ADORN_PREFIX) == ADORN_PREFIX then
			child:Destroy()
		end
	end
end

local function espApply(player, character)
	if not character or player.Character ~= character then return end

	espClean(character)

	-- reset connections from a previous apply on this character
	if espBags[character] then
		for _, c in ipairs(espBags[character]) do
			c:Disconnect()
		end
	end
	local bag = {}
	espBags[character] = bag
	table.insert(bag, character.Destroying:Connect(function()
		for _, c in ipairs(bag) do
			c:Disconnect()
		end
		espBags[character] = nil
	end))

	local highlight = Instance.new("Highlight")
	highlight.Name = HIGHLIGHT_NAME
	highlight.FillColor = ESP_FILL
	highlight.OutlineColor = ESP_OUTLINE
	highlight.FillTransparency = 0.5
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = character
	highlight.Parent = character

	local adornments = {}

	local function update()
		if not character.Parent then return end
		local invisible = espIsInvisible(character)
		highlight.Enabled = not invisible
		for _, adorn in pairs(adornments) do
			adorn.Visible = invisible
		end
	end

	local function watchPart(part)
		if not part:IsA("BasePart") then return end
		table.insert(bag, part:GetPropertyChangedSignal("Transparency"):Connect(update))

		if part.Name == "HumanoidRootPart" or adornments[part] then return end
		local adorn = Instance.new("BoxHandleAdornment")
		adorn.Name = ADORN_PREFIX .. part.Name
		adorn.Adornee = part
		adorn.Size = part.Size
		adorn.Color3 = ESP_FILL
		adorn.Transparency = 0.5
		adorn.AlwaysOnTop = true
		adorn.ZIndex = 1
		adorn.Visible = false
		adorn.Parent = character
		adornments[part] = adorn

		table.insert(bag, part:GetPropertyChangedSignal("Size"):Connect(function()
			adorn.Size = part.Size
		end))
	end

	for _, part in ipairs(character:GetChildren()) do
		watchPart(part)
	end
	table.insert(bag, character.ChildAdded:Connect(function(part)
		watchPart(part)
		update()
	end))

	update()
end

local function espTrackPlayer(player)
	if player == lp and not ESP.cfg.includeSelf then return end

	table.insert(espConns, player.CharacterAdded:Connect(function(character)
		character:WaitForChild("Humanoid", 10)
		task.wait(0.2) -- let the body parts exist
		if ESP.enabled then
			espApply(player, character)
		end
	end))

	if player.Character then
		espApply(player, player.Character)
	end
end

function ESP.start()
	for _, p in ipairs(Players:GetPlayers()) do
		espTrackPlayer(p)
	end
	table.insert(espConns, Players.PlayerAdded:Connect(espTrackPlayer))
end

function ESP.stop()
	for _, c in ipairs(espConns) do
		c:Disconnect()
	end
	espConns = {}
	for character, bag in pairs(espBags) do
		for _, c in ipairs(bag) do
			c:Disconnect()
		end
		if character.Parent then
			espClean(character)
		end
	end
	espBags = {}
end

function ESP.buildSettings(body, restart)
	addSwitchRow(body, "Include self", ESP.cfg.includeSelf, function(v)
		ESP.cfg.includeSelf = v
		restart()
	end)
	addNumberRow(body, "Invisible at", ESP.cfg.invisThreshold, 0.1, 1, function(v)
		ESP.cfg.invisThreshold = v
		restart()
	end)
end

---------------------------------------------------------------------
-- MODULE 2: PROXIMITY RADAR
---------------------------------------------------------------------
local RADAR = {
	title = "Proximity Radar",
	short = "Radar",
	enabled = false,
	cfg = { circleSize = 180, maxDistance = 100, facingAngle = 40, teamHighlights = true },
}

local FULL_DISTANCE = 5      -- studs: fully visible at or under this
local MIN_VISIBILITY = 0.15  -- how faint the arrow is at max distance (0-1)
local TEAM_COLOR = Color3.fromRGB(0, 0, 255)
local ENEMY_COLOR = Color3.fromRGB(255, 0, 0)
local PALETTE = {
	Color3.fromRGB(255, 0, 0),
	Color3.fromRGB(160, 32, 240),
	Color3.fromRGB(255, 220, 0),
	Color3.fromRGB(0, 200, 0),
	Color3.fromRGB(255, 140, 0),
	Color3.fromRGB(255, 105, 180),
	Color3.fromRGB(0, 220, 220),
}
local ARROW_SIZE = 30
local ARROW_ARM_LENGTH = 18
local ARROW_THICKNESS = 3
local MAX_HIGHLIGHTS = 30
local BOX_WIDTH = 4
local BOX_HEIGHT = 6.5

local radarGui, radarRing
local radarConns = {}
local arrows = {}
local radarHighlights = {}
local teamColors = {}

local function makeArm(parent, rotation, xOffset)
	local arm = Instance.new("Frame")
	arm.AnchorPoint = Vector2.new(0.5, 0.5)
	arm.Size = UDim2.fromOffset(ARROW_THICKNESS, ARROW_ARM_LENGTH)
	arm.Position = UDim2.fromOffset(
		ARROW_SIZE / 2 + xOffset,
		ARROW_SIZE * 0.25 + ARROW_ARM_LENGTH * 0.35
	)
	arm.Rotation = rotation
	arm.BorderSizePixel = 0
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = arm
	arm.Parent = parent
	return arm
end

local function getArrow(plr)
	if arrows[plr] then return arrows[plr] end
	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Size = UDim2.fromOffset(ARROW_SIZE, ARROW_SIZE)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = radarRing

	local off = ARROW_ARM_LENGTH * 0.35
	makeArm(holder, 45, -off)
	makeArm(holder, -45, off)

	arrows[plr] = holder
	return holder
end

local function setArrowStyle(holder, color, transparency)
	for _, arm in ipairs(holder:GetChildren()) do
		if arm:IsA("Frame") then
			arm.BackgroundColor3 = color
			arm.BackgroundTransparency = transparency
		end
	end
end

local function removeHighlight(plr)
	local h = radarHighlights[plr]
	if h then
		h:Destroy()
		radarHighlights[plr] = nil
	end
end

local function countHighlights()
	local n = 0
	for _, o in pairs(radarHighlights) do
		if o:IsA("Highlight") then n += 1 end
	end
	return n
end

local function makeBox(root)
	local b = Instance.new("BillboardGui")
	b.Name = "RadarBox"
	b.Adornee = root
	b.AlwaysOnTop = true
	b.LightInfluence = 0
	b.Size = UDim2.new(BOX_WIDTH, 0, BOX_HEIGHT, 0)

	local f = Instance.new("Frame")
	f.Name = "Box"
	f.Size = UDim2.fromScale(1, 1)
	f.BorderSizePixel = 0
	f.Parent = b

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Parent = f

	b.Parent = root
	return b
end

local function setHighlight(plr, char, root, color, visibility)
	local obj = radarHighlights[plr]

	-- drop stale objects (respawn, etc.)
	if obj then
		local valid = (obj:IsA("Highlight") and obj.Parent == char)
			or (obj:IsA("BillboardGui") and obj.Parent == root)
		if not valid then
			removeHighlight(plr)
			obj = nil
		end
	end

	-- upgrade a box to a real highlight if a slot opened up
	if obj and obj:IsA("BillboardGui") and countHighlights() < MAX_HIGHLIGHTS then
		removeHighlight(plr)
		obj = nil
	end

	if not obj then
		if countHighlights() < MAX_HIGHLIGHTS then
			local ok, h = pcall(function()
				local h = Instance.new("Highlight")
				h.Name = "RadarHighlight"
				h.Adornee = char
				h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				h.Parent = char
				return h
			end)
			if ok then obj = h end
		end
		if not obj then
			obj = makeBox(root) -- fallback: vertical rectangle
		end
		radarHighlights[plr] = obj
	end

	if obj:IsA("Highlight") then
		obj.FillColor = color
		obj.OutlineColor = color
		obj.FillTransparency = 1 - (visibility * 0.5)
		obj.OutlineTransparency = 1 - visibility
	else
		local f = obj:FindFirstChild("Box")
		if f then
			f.BackgroundColor3 = color
			f.BackgroundTransparency = 1 - (visibility * 0.2)
			local st = f:FindFirstChildOfClass("UIStroke")
			if st then
				st.Color = color
				st.Transparency = 1 - visibility
			end
		end
	end
end

local function gameHasTeams()
	return #Teams:GetTeams() > 0
end

local function countKeys(t)
	local n = 0
	for _ in pairs(t) do n += 1 end
	return n
end

-- my team = blue, every other team gets its own color
local function getTeamColor(team)
	if team == nil then return ENEMY_COLOR end
	if lp.Team ~= nil and team == lp.Team then return TEAM_COLOR end
	if not teamColors[team] then
		teamColors[team] = PALETTE[(countKeys(teamColors) % #PALETTE) + 1]
	end
	return teamColors[team]
end

local function isFacingMe(root, myRoot)
	local toMe = myRoot.Position - root.Position
	toMe = Vector3.new(toMe.X, 0, toMe.Z)
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	if toMe.Magnitude < 0.001 or look.Magnitude < 0.001 then return false end
	return toMe.Unit:Dot(look.Unit) >= math.cos(math.rad(RADAR.cfg.facingAngle))
end

local function radarStep()
	if not radarRing then return end
	local camera = workspace.CurrentCamera
	if not camera then return end

	local myChar = lp.Character
	local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
	if not myRoot then
		for _, a in pairs(arrows) do a.Visible = false end
		for plr in pairs(radarHighlights) do removeHighlight(plr) end
		return
	end

	local radius = RADAR.cfg.circleSize / 2
	local maxDist = RADAR.cfg.maxDistance
	local hasTeams = gameHasTeams()

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= lp then
			local arrow = getArrow(plr)
			local char = plr.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")

			if root then
				local delta = root.Position - myRoot.Position
				local dist = delta.Magnitude

				if dist <= maxDist then
					local rel = camera.CFrame:VectorToObjectSpace(delta)
					local angle = math.atan2(rel.X, -rel.Z)

					arrow.Position = UDim2.fromOffset(
						radius + math.sin(angle) * radius,
						radius - math.cos(angle) * radius
					)
					arrow.Rotation = math.deg(angle)

					local t = math.clamp((maxDist - dist) / (maxDist - FULL_DISTANCE), 0, 1)
					local visibility = MIN_VISIBILITY + (1 - MIN_VISIBILITY) * t

					local color
					if hasTeams then
						color = getTeamColor(plr.Team)
						if RADAR.cfg.teamHighlights then
							setHighlight(plr, char, root, color, visibility)
						else
							removeHighlight(plr)
						end
					else
						color = isFacingMe(root, myRoot) and ENEMY_COLOR or TEAM_COLOR
						removeHighlight(plr)
					end

					setArrowStyle(arrow, color, 1 - visibility)
					arrow.Visible = true
				else
					arrow.Visible = false
					removeHighlight(plr)
				end
			else
				arrow.Visible = false
				removeHighlight(plr)
			end
		end
	end
end

function RADAR.start()
	radarGui = new("ScreenGui", {
		Name = "ProximityRadar",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		DisplayOrder = 1,
	}, guiParent)

	radarRing = new("Frame", {
		Name = "Ring",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(RADAR.cfg.circleSize, RADAR.cfg.circleSize),
		BackgroundTransparency = 1,
	}, radarGui)

	table.insert(radarConns, RunService.RenderStepped:Connect(radarStep))
	table.insert(radarConns, Players.PlayerRemoving:Connect(function(plr)
		if arrows[plr] then
			arrows[plr]:Destroy()
			arrows[plr] = nil
		end
		removeHighlight(plr)
	end))
	table.insert(radarConns, lp:GetPropertyChangedSignal("Team"):Connect(function()
		teamColors = {} -- re-assign colors if I switch teams
	end))
end

function RADAR.stop()
	for _, c in ipairs(radarConns) do
		c:Disconnect()
	end
	radarConns = {}
	for plr in pairs(radarHighlights) do
		removeHighlight(plr)
	end
	arrows = {}
	teamColors = {}
	if radarGui then
		radarGui:Destroy()
		radarGui, radarRing = nil, nil
	end
end

function RADAR.buildSettings(body)
	addNumberRow(body, "Range (studs)", RADAR.cfg.maxDistance, 10, 1000, function(v)
		RADAR.cfg.maxDistance = v
	end)
	addNumberRow(body, "Ring size (px)", RADAR.cfg.circleSize, 60, 600, function(v)
		RADAR.cfg.circleSize = v
		if radarRing then
			radarRing.Size = UDim2.fromOffset(v, v)
		end
	end)
	addNumberRow(body, "Facing angle", RADAR.cfg.facingAngle, 5, 180, function(v)
		RADAR.cfg.facingAngle = v
	end)
	addSwitchRow(body, "Team highlights", RADAR.cfg.teamHighlights, function(v)
		RADAR.cfg.teamHighlights = v
	end)
end

---------------------------------------------------------------------
-- MODULE 3: SPEED WATCH
---------------------------------------------------------------------
local SPEED = {
	title = "Speed Watch",
	short = "Speed",
	enabled = false,
	cfg = { speed = true, watch = true, base = 16 },
}

local SW = {
	TICK = 0.1,           -- how often speeds are sampled (seconds)
	WINDOW = 5,           -- seconds used for the average
	FLAG_OVER = 1,        -- flag players this many st/s above the base speed
	FLAG_MIN_TIME = 2,    -- must be fast for at least this long before flagging
	TELEPORT_CAP = 250,   -- ignore jumps faster than this (teleports/respawns)
	LOOK_ANGLE = 40,      -- degrees: how wide "looking at me" is
	LOOK_RANGE = 200,     -- studs
}

local records = {}
local swConns = {}

local function destroyGuis(rec)
	for _, k in ipairs({ "speedGui", "dotGui", "hl" }) do
		if rec[k] then
			rec[k]:Destroy()
			rec[k] = nil
		end
	end
	rec.label = nil
end

local function ensureGuis(rec, char, head)
	if not rec.speedGui then
		local g = Instance.new("BillboardGui")
		g.Name = "SW_Speed"
		g.Adornee = head
		g.Size = UDim2.fromOffset(72, 26)
		g.StudsOffset = Vector3.new(0, 2.2, 0)
		g.AlwaysOnTop = true
		g.MaxDistance = 300
		g.Parent = guiParent

		local lbl = Instance.new("TextLabel")
		lbl.BackgroundColor3 = Color3.fromRGB(10, 10, 12)
		lbl.BackgroundTransparency = 0.2
		lbl.BorderSizePixel = 0
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.Font = Enum.Font.GothamBold
		lbl.TextSize = 9
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.Parent = g
		Instance.new("UICorner", lbl).CornerRadius = UDim.new(0, 6)
		local stroke = Instance.new("UIStroke", lbl)
		stroke.Color = Color3.fromRGB(80, 80, 95)
		stroke.Thickness = 1
		rec.stroke = stroke

		rec.speedGui, rec.label = g, lbl
	end

	if not rec.dotGui then
		local g = Instance.new("BillboardGui")
		g.Name = "SW_Dot"
		g.Adornee = head
		g.Size = UDim2.fromOffset(14, 14)
		g.StudsOffset = Vector3.new(0, 3.7, 0)
		g.AlwaysOnTop = true
		g.MaxDistance = 300
		g.Parent = guiParent

		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromScale(1, 1)
		dot.BackgroundColor3 = Color3.fromRGB(60, 220, 90)
		dot.BorderSizePixel = 0
		dot.Parent = g
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

		rec.dotGui = g
	end

	if not rec.hl then
		local hl = Instance.new("Highlight")
		hl.Name = "SW_Flag"
		hl.Adornee = char
		hl.FillColor = Color3.fromRGB(255, 40, 40)
		hl.OutlineColor = Color3.fromRGB(255, 0, 0)
		hl.FillTransparency = 0.45
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Enabled = false
		hl.Parent = guiParent
		rec.hl = hl
	end
end

-- "is this player looking at me" (approximation: head direction + range + line of sight)
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function isLookingAtMe(char, head)
	local myChar = lp.Character
	local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
	if not myHrp then return false end

	local vec = myHrp.Position - head.Position
	local dist = vec.Magnitude
	if dist > SW.LOOK_RANGE or dist < 0.1 then return false end

	local angle = math.deg(math.acos(math.clamp(head.CFrame.LookVector:Dot(vec.Unit), -1, 1)))
	if angle > SW.LOOK_ANGLE then return false end

	rayParams.FilterDescendantsInstances = { char, myChar }
	return workspace:Raycast(head.Position, vec, rayParams) == nil
end

local function swUpdate(plr, rec, dt, now)
	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local head = char and char:FindFirstChild("Head")
	local hum = char and char:FindFirstChildOfClass("Humanoid")

	if not (hrp and head and hum) then
		destroyGuis(rec)
		rec.char = nil
		return
	end

	-- new character (respawn) -> reset stats
	if rec.char ~= char then
		destroyGuis(rec)
		rec.char = char
		rec.last = nil
		rec.samples = {}
		rec.speed = 0
	end

	-- speed in studs/s (horizontal only, so falling doesn't count)
	local pos = hrp.Position
	local seated = hum.SeatPart ~= nil
	if rec.last then
		local d = Vector3.new(pos.X - rec.last.X, 0, pos.Z - rec.last.Z).Magnitude / dt
		if d > SW.TELEPORT_CAP then
			rec.samples = {}
		elseif not seated then
			rec.speed = d
			table.insert(rec.samples, { t = now, s = d })
		end
	end
	rec.last = pos

	-- trim window + average
	while rec.samples[1] and rec.samples[1].t < now - SW.WINDOW do
		table.remove(rec.samples, 1)
	end
	local sum = 0
	for _, smp in ipairs(rec.samples) do
		sum = sum + smp.s
	end
	local avg = #rec.samples > 0 and sum / #rec.samples or 0

	local span = #rec.samples > 0 and (now - rec.samples[1].t) or 0
	local flagged = not seated and span >= SW.FLAG_MIN_TIME and avg >= SPEED.cfg.base + SW.FLAG_OVER

	ensureGuis(rec, char, head)

	rec.speedGui.Enabled = SPEED.cfg.speed
	rec.hl.Enabled = SPEED.cfg.speed and flagged
	if SPEED.cfg.speed then
		if seated then
			rec.label.Text = "seated"
		else
			rec.label.Text = string.format("%.1f st/s\navg %.1f", rec.speed, avg)
		end
		rec.label.TextColor3 = flagged and Color3.fromRGB(255, 90, 90) or Color3.new(1, 1, 1)
		rec.stroke.Color = flagged and Color3.fromRGB(255, 60, 60) or Color3.fromRGB(80, 80, 95)
	end

	rec.dotGui.Enabled = SPEED.cfg.watch and isLookingAtMe(char, head)
end

function SPEED.start()
	local acc = 0
	table.insert(swConns, RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < SW.TICK then return end
		local step = acc
		acc = 0
		local now = os.clock()

		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= lp then
				local rec = records[plr]
				if not rec then
					rec = { samples = {}, speed = 0 }
					records[plr] = rec
				end
				swUpdate(plr, rec, step, now)
			end
		end
	end))

	table.insert(swConns, Players.PlayerRemoving:Connect(function(plr)
		local rec = records[plr]
		if rec then
			destroyGuis(rec)
			records[plr] = nil
		end
	end))
end

function SPEED.stop()
	for _, c in ipairs(swConns) do
		c:Disconnect()
	end
	swConns = {}
	for _, rec in pairs(records) do
		destroyGuis(rec)
	end
	records = {}
end

function SPEED.buildSettings(body)
	addSwitchRow(body, "Speedometer", SPEED.cfg.speed, function(v)
		SPEED.cfg.speed = v
	end)
	addSwitchRow(body, "Look dot", SPEED.cfg.watch, function(v)
		SPEED.cfg.watch = v
	end)
	addNumberRow(body, "Base speed", SPEED.cfg.base, 0, 1000, function(v)
		SPEED.cfg.base = v
	end)
end

---------------------------------------------------------------------
-- MODULE 4: SPEEDOMETER (your own speed)  [from Speedometer]
---------------------------------------------------------------------
local METER = {
	title = "Speedometer",
	short = "Meter",
	enabled = false,
	compact = true,
	panelSize = Vector2.new(78, 40),
	cfg = { horizontalOnly = false, smoothing = 0.2, relaxTime = 1.0, relaxUpdate = 0.25 },
}

do
	local conn
	local lastPos, speed, relaxed, sinceUpdate = nil, 0, 0, 0
	local liveLabel, relaxLabel, velLabel
	local modeB = false

	function METER.buildSettings(frame)
		local function makeLabel(name, y, color, text)
			local l = new("TextLabel", {
				Name = name,
				BackgroundTransparency = 1,
				Position = UDim2.new(0, 0, y, 0),
				Size = UDim2.new(1, 0, 0.5, 0),
				Font = Enum.Font.GothamBold,
				TextColor3 = color,
				TextScaled = true,
				Text = text,
			}, frame)
			new("UIPadding", {
				PaddingLeft = UDim.new(0, 4),
				PaddingRight = UDim.new(0, 4),
				PaddingTop = UDim.new(0, 3),
				PaddingBottom = UDim.new(0, 2),
			}, l)
			return l
		end

		liveLabel = makeLabel("Live", 0, Color3.fromRGB(255, 255, 255), "0.0 stud/s")
		relaxLabel = makeLabel("Relaxed", 0.5, Color3.fromRGB(170, 255, 170), "~0.0 stud/s")

		velLabel = new("TextLabel", {
			Name = "VelocityMode",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextColor3 = Color3.fromRGB(255, 255, 255),
			Text = "0 stud/s",
			Visible = false,
		}, frame)

		-- small red switch OUTSIDE the bottom-right corner: live/relaxed <-> velocity mode
		local sw = new("TextButton", {
			Name = "ModeSwitch",
			Size = UDim2.fromOffset(TOUCH and 20 or 14, TOUCH and 20 or 14),
			Position = UDim2.new(1, 3, 1, 3),
			BackgroundColor3 = Color3.fromRGB(255, 0, 0),
			BorderSizePixel = 0,
			Text = "",
			AutoButtonColor = true,
		}, frame)
		round(sw, UDim.new(1, 0))
		sw.Activated:Connect(function()
			modeB = not modeB
			liveLabel.Visible = not modeB
			relaxLabel.Visible = not modeB
			velLabel.Visible = modeB
		end)
	end

	function METER.start()
		lastPos, speed, relaxed, sinceUpdate = nil, 0, 0, 0
		local cfg = METER.cfg
		conn = RunService.RenderStepped:Connect(function(dt)
			local char = lp.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if not root or dt <= 0 then
				lastPos = nil
				return
			end

			if modeB then
				velLabel.Text = math.floor(root.AssemblyLinearVelocity.Magnitude + 0.5) .. " stud/s"
			end

			local pos = root.Position
			if lastPos then
				local diff = pos - lastPos
				if cfg.horizontalOnly then
					diff = Vector3.new(diff.X, 0, diff.Z)
				end
				local raw = diff.Magnitude / dt

				speed = speed + (raw - speed) * (1 - cfg.smoothing)
				liveLabel.Text = string.format("%.1f stud/s", speed)

				local alpha = 1 - math.exp(-dt / cfg.relaxTime)
				relaxed = relaxed + (raw - relaxed) * alpha
				sinceUpdate += dt
				if sinceUpdate >= cfg.relaxUpdate then
					sinceUpdate = 0
					relaxLabel.Text = string.format("~%.1f stud/s", relaxed)
				end
			end
			lastPos = pos
		end)
	end

	function METER.stop()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		lastPos = nil
	end
end

---------------------------------------------------------------------
-- MODULE 5: PART HIGHLIGHTER  [from PartHighlighter]
-- type a name -> every Part / Model / Folder with that name gets highlighted
---------------------------------------------------------------------
local PHL = { title = "Part Highlighter", short = "PartHL", enabled = false, cfg = {} }

do
	local active = {}

	local function clear()
		for _, h in ipairs(active) do
			if h and h.Parent then
				h:Destroy()
			end
		end
		table.clear(active)
	end

	local function highlightObject(obj)
		if #active >= 31 then return end -- Roblox draws at most ~31 highlights at once
		if obj:IsA("Model") or obj:IsA("BasePart") then
			local h = Instance.new("Highlight")
			h.Name = "CustomSearchHighlight"
			h.FillColor = Color3.fromRGB(0, 255, 0)
			h.OutlineColor = Color3.fromRGB(255, 255, 255)
			h.FillTransparency = 0.3
			h.OutlineTransparency = 0
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.Adornee = obj
			h.Parent = obj
			table.insert(active, h)
		elseif obj:IsA("Folder") then
			-- a Highlight can't wrap a Folder, so light up what's inside it
			for _, child in ipairs(obj:GetChildren()) do
				highlightObject(child)
			end
		end
	end

	local function apply(query)
		clear()
		if query == "" then return end
		local q = query:lower()
		for _, obj in ipairs(workspace:GetDescendants()) do
			if obj.Name:lower() == q then
				highlightObject(obj)
			end
		end
	end

	function PHL.buildSettings(body)
		local box = addInputRow(body, "Name...")
		addButtonRow(body, ROW_H, {
			{ text = "Highlight", color = THEME.on, onClick = function()
				apply(box.Text:match("^%s*(.-)%s*$"))
			end },
			{ text = "Clear", color = RED, onClick = clear },
		})
	end

	function PHL.start() end
	function PHL.stop()
		clear()
	end
end

---------------------------------------------------------------------
-- MODULE 6: PART DELETER (local only)  [from PartDeleter]
-- type a name -> matching Parts / Models / Folders vanish for YOU only. Restore brings them back.
---------------------------------------------------------------------
local PDEL = { title = "Part Deleter", short = "PartDel", enabled = false, cfg = {} }

do
	local deleted = {}

	local function restore()
		for i = #deleted, 1, -1 do
			local item = deleted[i]
			pcall(function()
				item.object.Parent = item.parent
			end)
		end
		table.clear(deleted)
	end

	local function remove(query)
		if query == "" then return end
		local q = query:lower()
		local myChar = lp.Character
		for _, obj in ipairs(workspace:GetDescendants()) do
			if obj.Name:lower() == q
				and (obj:IsA("Folder") or obj:IsA("Model") or obj:IsA("BasePart"))
				and obj.Parent ~= nil
				and not (myChar and (obj == myChar or obj:IsDescendantOf(myChar)))
			then
				table.insert(deleted, { object = obj, parent = obj.Parent })
				obj.Parent = nil
			end
		end
	end

	function PDEL.buildSettings(body)
		local box = addInputRow(body, "Name...")
		addButtonRow(body, ROW_H, {
			{ text = "Delete", color = RED, onClick = function()
				remove(box.Text:match("^%s*(.-)%s*$"))
			end },
			{ text = "Restore", color = THEME.on, onClick = restore },
		})
	end

	function PDEL.start() end
	function PDEL.stop()
		restore() -- switching the module off puts everything back
	end
end

---------------------------------------------------------------------
-- MODULE 7: DANGER DETECTOR
-- Button "HL" = YOUR choice to start labelling. Anyone within 5 studs of a
-- "RoundSpawnerCatcher" model becomes "danger" (red vertical rectangle).
-- Danger player within 100 studs gets within 30 studs -> your WalkSpeed ramps to 40
-- in 0.2s and is re-applied every frame so the game can't reset it.
---------------------------------------------------------------------
local DANGER = {
	title = "Danger",
	short = "Danger",
	enabled = false,
	compact = true,
	keepPanel = true,
	panelSize = Vector2.new(50, 30),
	cfg = {
		scanRadius = 100,      -- only danger players closer than this are watched
		triggerRadius = 30,    -- boost starts at this distance
		releaseRadius = 36,    -- boost ends past this distance (stops flickering)
		boostSpeed = 40,
		rampTime = 0.2,
		catcherName = "RoundSpawnerCatcher",
		catcherRadius = 5,
		mark = false,          -- the HL button
	},
}

do
	local cfg = DANGER.cfg
	local conns = {}
	local catchers = {}
	local status = {} -- [player] = { char = character, tag = BillboardGui }
	local boost = { active = false, saved = nil, from = 16, t0 = 0 }
	local sinceScan = 0

	local function isCatcher(inst)
		return inst.Name == cfg.catcherName and (inst:IsA("Model") or inst:IsA("BasePart"))
	end

	-- distance from a point to an (oriented) box: 0 means "on / inside" it
	local function boxDist(cf, size, pos)
		local p = cf:PointToObjectSpace(pos)
		local half = size / 2
		return Vector3.new(
			math.max(math.abs(p.X) - half.X, 0),
			math.max(math.abs(p.Y) - half.Y, 0),
			math.max(math.abs(p.Z) - half.Z, 0)
		).Magnitude
	end

	local function makeTag(root)
		local b = Instance.new("BillboardGui")
		b.Name = "DangerTag"
		b.Adornee = root
		b.AlwaysOnTop = true
		b.LightInfluence = 0
		b.Size = UDim2.new(4, 0, 6.5, 0) -- tall rectangle
		local f = Instance.new("Frame")
		f.Size = UDim2.fromScale(1, 1)
		f.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
		f.BackgroundTransparency = 0.65
		f.BorderSizePixel = 0
		f.Parent = b
		local s = Instance.new("UIStroke")
		s.Color = Color3.fromRGB(255, 0, 0)
		s.Thickness = 2
		s.Parent = f
		b.Parent = guiParent
		return b
	end

	local function clearStatus(plr)
		local s = status[plr]
		if s then
			if s.tag then s.tag:Destroy() end
			status[plr] = nil
		end
	end

	local function clearAllStatus()
		for plr in pairs(status) do
			clearStatus(plr)
		end
	end

	local function scan()
		if not cfg.mark then
			if next(status) then clearAllStatus() end
			return
		end

		local boxes = {}
		for inst in pairs(catchers) do
			if inst.Parent then
				local cf, size
				if inst:IsA("Model") then
					cf, size = inst:GetBoundingBox()
				else
					cf, size = inst.CFrame, inst.Size
				end
				boxes[#boxes + 1] = { cf, size }
			else
				catchers[inst] = nil
			end
		end

		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= lp then
				local char = plr.Character
				local root = char and char:FindFirstChild("HumanoidRootPart")
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				local s = status[plr]
				if s and (s.char ~= char or not root or not hum or hum.Health <= 0) then
					clearStatus(plr)
					s = nil
				end
				if not s and root and hum and hum.Health > 0 then
					for _, b in ipairs(boxes) do
						if boxDist(b[1], b[2], root.Position) <= cfg.catcherRadius then
							status[plr] = { char = char, tag = makeTag(root) }
							break
						end
					end
				end
			end
		end
	end

	local function boostStep()
		local char = lp.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not (hum and root and hum.Health > 0) then
			boost.active, boost.saved = false, nil
			return
		end

		local nearest = math.huge
		for _, s in pairs(status) do
			local r = s.char and s.char:FindFirstChild("HumanoidRootPart")
			if r then
				local d = (r.Position - root.Position).Magnitude
				if d <= cfg.scanRadius and d < nearest then
					nearest = d
				end
			end
		end

		local threat = nearest <= (boost.active and cfg.releaseRadius or cfg.triggerRadius)
		if threat then
			if not boost.active then
				boost.active = true
				local cur = hum.WalkSpeed
				boost.saved = (cur ~= cfg.boostSpeed) and cur or 16
				boost.from = cur
				boost.t0 = os.clock()
			end
			if boost.from < cfg.boostSpeed then
				local a = math.clamp((os.clock() - boost.t0) / cfg.rampTime, 0, 1)
				hum.WalkSpeed = boost.from + (cfg.boostSpeed - boost.from) * a -- re-applied every frame
			end
		elseif boost.active then
			boost.active = false
			hum.WalkSpeed = boost.saved or 16
			boost.saved = nil
		end
	end

	function DANGER.start()
		catchers = {}
		for _, inst in ipairs(workspace:GetDescendants()) do
			if isCatcher(inst) then catchers[inst] = true end
		end
		table.insert(conns, workspace.DescendantAdded:Connect(function(inst)
			if isCatcher(inst) then catchers[inst] = true end
		end))
		table.insert(conns, workspace.DescendantRemoving:Connect(function(inst)
			catchers[inst] = nil
		end))
		table.insert(conns, Players.PlayerRemoving:Connect(clearStatus))
		table.insert(conns, RunService.Heartbeat:Connect(function(dt)
			sinceScan += dt
			if sinceScan >= 0.1 then
				sinceScan = 0
				local ok, err = pcall(scan)
				if not ok then warn("[UnifiedMenu] Danger scan: " .. tostring(err)) end
			end
			boostStep()
		end))
	end

	function DANGER.stop()
		for _, c in ipairs(conns) do c:Disconnect() end
		conns = {}
		clearAllStatus()
		if boost.active then
			local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
			if hum then hum.WalkSpeed = boost.saved or 16 end
		end
		boost.active, boost.saved = false, nil
		catchers = {}
	end

	function DANGER.buildSettings(frame)
		new("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 1),
			Size = UDim2.new(1, 0, 0, 11),
			Font = Enum.Font.GothamBold,
			Text = "DANGER",
			TextSize = 8,
			TextColor3 = THEME.muted,
		}, frame)

		local track, set = makeSwitch(DANGER.enabled, function(v)
			if DANGER.requestEnabled then DANGER.requestEnabled(v) end
		end)
		track.Position = UDim2.fromOffset(3, 14)
		track.Size = UDim2.fromOffset(24, 13)
		track.Parent = frame
		DANGER.syncSet = set

		local btn = addButton(frame, "HL", THEME.field, nil)
		btn.Position = UDim2.fromOffset(29, 14)
		btn.Size = UDim2.fromOffset(18, 13)
		btn.TextSize = 8
		round(btn, UDim.new(0, 4))

		local function paint()
			btn.BackgroundColor3 = cfg.mark and Color3.fromRGB(220, 50, 50) or THEME.field
		end
		btn.MouseButton1Click:Connect(function()
			cfg.mark = not cfg.mark
			paint()
			if not cfg.mark then clearAllStatus() end
		end)
		paint()
	end
end

---------------------------------------------------------------------
-- MODULE 8: PATH RECORDER (300x280)
-- Follows your sketch: Record draws the path from a start circle; Play first
-- walks "my spot" -> "spot start", then follows the recorded path.
-- Anti-derail: pure-pursuit lookahead (grows with speed), slows in corners,
-- re-snaps to the path if pushed off, jumps when stuck, replays recorded jumps.
---------------------------------------------------------------------
local REC = {
	title = "Path Recorder",
	short = "Rec",
	enabled = false,
	panelSize = Vector2.new(300, 280),
	cfg = { speed = 16, minStep = 1.5, showPath = true },
}

do
	local points, jumps = {}, {}
	local state = "idle" -- idle | recording | approach | playing
	local conns = {}
	local ui = {}
	local pathFolder, startMarker, endMarker
	local runId = 0
	local savedSpeed
	local fol
	local segPool = {}
	local curMap, curSize = nil, Vector2.new(280, 100)
	local recConn, jumpConn
	local lastRedraw, lastMe, lastStatus = 0, 0, 0
	local PLAY_BIND = "UnifiedMenu_PathPlay"
	local GROUND = 2.9
	local LINE_COLOR = Color3.fromRGB(80, 200, 255)
	local GREEN = Color3.fromRGB(60, 220, 90)

	local stopFollow, startFollow

	local function getParts()
		local char = lp.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if hum and root and hum.Health > 0 then
			return char, hum, root
		end
	end

	local function setStatus(text, color)
		if ui.status then
			ui.status.Text = text
			ui.status.TextColor3 = color or THEME.muted
		end
	end

	local function refreshButtons()
		if not ui.rec then return end
		local recording = state == "recording"
		local playing = state == "approach" or state == "playing"
		ui.rec.Text = recording and "Stop recording" or "Record"
		ui.rec.BackgroundColor3 = recording and RED or THEME.field
		ui.play.Text = playing and "Stop" or "Play path"
		ui.play.BackgroundColor3 = playing and RED or THEME.on
	end

	local function pdist(a, b)
		local d = a - b
		return math.sqrt(d.X * d.X + d.Z * d.Z + (d.Y * 0.5) ^ 2)
	end

	local function flat(v)
		return Vector3.new(v.X, 0, v.Z)
	end

	-- 3D path (client only) ---------------------------------------------
	local function applyFolderParent()
		if pathFolder then
			pathFolder.Parent = (REC.enabled and REC.cfg.showPath) and workspace or nil
		end
	end

	local function ensureFolder()
		if not pathFolder then
			pathFolder = Instance.new("Folder")
			pathFolder.Name = "PathViz"
			applyFolderParent()
		end
	end

	local function mkPart(size, cf, color, shape)
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = color
		p.Size = size
		p.CFrame = cf
		if shape then p.Shape = shape end
		p.Parent = pathFolder
		return p
	end

	local function clearWorld()
		if pathFolder then
			pathFolder:Destroy()
			pathFolder = nil
		end
		startMarker, endMarker = nil, nil
	end

	local function addWorldPoint(i)
		ensureFolder()
		local down = Vector3.new(0, GROUND, 0)
		local p = points[i] - down
		if i == 1 then
			startMarker = mkPart(Vector3.new(1.8, 1.8, 1.8), CFrame.new(p), GREEN, Enum.PartType.Ball)
			endMarker = mkPart(Vector3.new(1.2, 1.2, 1.2), CFrame.new(p), Color3.fromRGB(255, 70, 70), Enum.PartType.Ball)
		else
			local a = points[i - 1] - down
			local len = (p - a).Magnitude
			if len > 0.05 then
				mkPart(Vector3.new(0.3, 0.3, len), CFrame.lookAt(a, p) * CFrame.new(0, 0, -len / 2), LINE_COLOR)
			end
			if endMarker then endMarker.CFrame = CFrame.new(p) end
		end
	end

	-- 2D preview (the picture from your sketch) ---------------------------
	local function placeLine(f, a, b, thick)
		local d = b - a
		f.Size = UDim2.fromOffset(math.max(d.Magnitude, 1), thick)
		f.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
		f.Rotation = math.deg(math.atan2(d.Y, d.X))
		f.Visible = true
	end

	local function getSeg(i)
		local f = segPool[i]
		if not f then
			f = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = LINE_COLOR,
				BorderSizePixel = 0,
				ZIndex = 2,
			}, ui.canvas)
			segPool[i] = f
		end
		return f
	end

	local function buildMapper()
		if #points == 0 then return nil end
		local size = ui.canvas.AbsoluteSize
		if size.X < 20 or size.Y < 20 then size = Vector2.new(280, 100) end
		local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
		for _, p in ipairs(points) do
			minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
			minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
		end
		local pad = 16
		local w, h = math.max(maxX - minX, 1), math.max(maxZ - minZ, 1)
		local s = math.min((size.X - pad * 2) / w, (size.Y - pad * 2) / h)
		local ox, oy = (size.X - w * s) / 2, (size.Y - h * s) / 2
		return function(v)
			return Vector2.new(ox + (v.X - minX) * s, oy + (v.Z - minZ) * s)
		end, size
	end

	local function updateMe()
		if not (ui.meDot and ui.canvas) then return end
		local _, _, root = getParts()
		if not (curMap and root) then
			ui.meDot.Visible = false
			ui.link.Visible = false
			return
		end
		local m = curMap(root.Position)
		m = Vector2.new(math.clamp(m.X, 7, curSize.X - 7), math.clamp(m.Y, 7, curSize.Y - 7))
		ui.meDot.Position = UDim2.fromOffset(m.X, m.Y)
		ui.meDot.Visible = true
		if (state == "idle" or state == "approach") and #points > 0 then
			placeLine(ui.link, m, curMap(points[1]), 1)
		else
			ui.link.Visible = false
		end
	end

	local function redrawPreview()
		if not ui.canvas then return end
		lastRedraw = os.clock()
		for _, f in pairs(segPool) do f.Visible = false end

		local map, size = buildMapper()
		curMap, curSize = map, size or curSize
		if not map then
			ui.hint.Visible = true
			ui.startDot.Visible, ui.endDot.Visible = false, false
			ui.meDot.Visible, ui.link.Visible = false, false
			return
		end
		ui.hint.Visible = false

		local step = math.max(1, math.ceil(#points / 150))
		local prev = map(points[1])
		local n, i = 0, 1 + step
		while true do
			local idx = math.min(i, #points)
			local cur = map(points[idx])
			n += 1
			placeLine(getSeg(n), prev, cur, 2)
			prev = cur
			if idx >= #points then break end
			i += step
		end

		local s, e = map(points[1]), map(points[#points])
		ui.startDot.Position = UDim2.fromOffset(s.X, s.Y)
		ui.startDot.Visible = true
		ui.endDot.Position = UDim2.fromOffset(e.X, e.Y)
		ui.endDot.Visible = #points > 1
		updateMe()
	end

	-- recording -----------------------------------------------------------
	local function addPoint(p, isJump)
		table.insert(points, p)
		if isJump then jumps[#points] = true end
		addWorldPoint(#points)
	end

	local function stopRecord()
		if state ~= "recording" then return end
		state = "idle"
		if recConn then recConn:Disconnect() recConn = nil end
		if jumpConn then jumpConn:Disconnect() jumpConn = nil end
		setStatus(#points .. " points saved - press Play path", THEME.muted)
		refreshButtons()
		redrawPreview()
	end

	local function clearPath()
		stopFollow()
		stopRecord()
		points, jumps = {}, {}
		clearWorld()
		redrawPreview()
		setStatus("Path cleared", THEME.muted)
	end

	local function startRecord()
		stopFollow()
		local _, hum, root = getParts()
		if not root then
			setStatus("No character found", RED)
			return
		end
		points, jumps = {}, {}
		clearWorld()
		state = "recording"
		addPoint(root.Position)
		recConn = RunService.Heartbeat:Connect(function()
			local _, _, r = getParts()
			if not r then return end
			if (r.Position - points[#points]).Magnitude >= REC.cfg.minStep then
				addPoint(r.Position)
			end
			local now = os.clock()
			if now - lastRedraw > 0.25 then
				redrawPreview()
			end
			if now - lastStatus > 0.25 then
				lastStatus = now
				setStatus("RECORDING...  " .. #points .. " points", Color3.fromRGB(255, 110, 110))
			end
		end)
		jumpConn = hum.StateChanged:Connect(function(_, new)
			if new == Enum.HumanoidStateType.Jumping then
				local _, _, r = getParts()
				if r then addPoint(r.Position, true) end
			end
		end)
		refreshButtons()
		redrawPreview()
	end

	-- playback ------------------------------------------------------------
	local function stepFollow(dt)
		local f = fol
		if not f then return end
		local _, hum, root = getParts()
		if not root then
			stopFollow("Character lost", RED)
			return
		end

		local pts = f.pts
		local n = #pts
		local pos = root.Position
		local speed = math.clamp(REC.cfg.speed, 1, 500)

		-- 1) progress: nearest point in a forward window (never jumps far ahead)
		local best, bestD = f.idx, math.huge
		for i = f.idx, math.min(n, f.idx + 25) do
			local d = pdist(pos, pts[i])
			if d < bestD then bestD, best = d, i end
		end
		f.idx = best

		-- 2) derailed? re-snap to the closest point of the whole path
		local recovering = bestD > 8
		if recovering then
			f.recoverT += dt
			if f.recoverT > 0.4 then
				f.recoverT = 0
				local gb, gd = f.idx, bestD
				for i = 1, n do
					local d = pdist(pos, pts[i])
					if d < gd - 2 then gd, gb = d, i end
				end
				f.idx, bestD = gb, gd
				recovering = bestD > 8
			end
		else
			f.recoverT = 0
		end

		-- 3) finished?
		if f.idx >= n - 1 and pdist(pos, pts[n]) < 3.2 then
			local done = f.onDone
			if done then done() end
			return
		end

		-- 4) lookahead target; the faster you go, the further ahead we aim (no corner overshoot)
		local function pointAhead(dist)
			local acc, i = 0, f.idx
			local cur = pts[i]
			while i < n do
				local seg = (pts[i + 1] - cur).Magnitude
				if acc + seg >= dist then
					local a = seg > 0 and (dist - acc) / seg or 0
					return cur:Lerp(pts[i + 1], a)
				end
				acc += seg
				i += 1
				cur = pts[i]
			end
			return pts[n]
		end
		local look = math.clamp(speed * 0.22, 3, 16)
		local target = recovering and pts[f.idx] or pointAhead(look)

		-- 5) slow down for sharp corners
		local scale = 1
		local d1 = flat(target - pos)
		local d2 = flat(pointAhead(look * 2.2) - target)
		if d1.Magnitude > 0.1 and d2.Magnitude > 0.1 then
			local ang = math.acos(math.clamp(d1.Unit:Dot(d2.Unit), -1, 1))
			scale = math.clamp(1 - ang / 2.2, 0.35, 1)
		end
		if recovering then scale = math.min(scale, 0.6) end
		f.curSpeed += (speed * scale - f.curSpeed) * math.min(dt * 10, 1)
		hum.WalkSpeed = f.curSpeed

		-- 6) replay recorded jumps (earlier trigger at higher speed)
		for i = f.idx, math.min(n, f.idx + 2) do
			if f.flags[i] and f.lastJumpIdx ~= i and pdist(pos, pts[i]) < (1.5 + speed * 0.1) then
				f.lastJumpIdx = i
				hum.Jump = true
				break
			end
		end

		-- 7) stuck detection
		local now = os.clock()
		if now - f.lastCheck >= 0.5 then
			local moved = (pos - f.lastPos).Magnitude
			f.lastPos, f.lastCheck = pos, now
			f.stuck = (moved < 0.6) and (f.stuck + 0.5) or 0
			if f.stuck >= 0.5 then hum.Jump = true end
			if f.stuck >= 2 then
				f.idx = math.min(n, f.idx + 2)
				f.stuck = 1
			end
		end

		-- 8) walk (runs after the default controls so it wins)
		local dir = flat(target - pos)
		if dir.Magnitude > 0.2 then
			hum:Move(dir.Unit, false)
		else
			hum:Move(Vector3.zero, false)
		end

		if now - lastStatus > 0.25 then
			lastStatus = now
			if f.label == "approach" then
				setStatus(string.format("Walking to start... %d studs", math.floor(pdist(pos, pts[n]))), THEME.muted)
			else
				setStatus(string.format("Following path... %d%%", math.floor(f.idx / n * 100)), THEME.on)
			end
		end
	end

	startFollow = function(pts, flags, label, onDone)
		local _, hum, root = getParts()
		if not root then
			stopFollow("No character found", RED)
			return
		end
		pcall(function() RunService:UnbindFromRenderStep(PLAY_BIND) end)
		if not savedSpeed then savedSpeed = hum.WalkSpeed end
		fol = {
			pts = pts, flags = flags or {}, idx = 1, onDone = onDone, label = label,
			stuck = 0, lastPos = root.Position, lastCheck = os.clock(), lastJumpIdx = 0,
			curSpeed = math.clamp(REC.cfg.speed, 1, 500), recoverT = 0,
		}
		RunService:BindToRenderStep(PLAY_BIND, Enum.RenderPriority.Character.Value + 5, stepFollow)
	end

	stopFollow = function(msg, color)
		runId += 1
		pcall(function() RunService:UnbindFromRenderStep(PLAY_BIND) end)
		if fol then
			fol = nil
			local _, hum = getParts()
			if hum then
				hum:Move(Vector3.zero, false)
				if savedSpeed then hum.WalkSpeed = savedSpeed end
			end
		end
		savedSpeed = nil
		if state == "approach" or state == "playing" then state = "idle" end
		if msg then setStatus(msg, color) end
		refreshButtons()
	end

	local function beginPlay()
		if state == "approach" or state == "playing" then
			stopFollow("Stopped", THEME.muted)
			return
		end
		if #points < 2 then
			setStatus("Record a path first", RED)
			return
		end
		stopRecord()
		local _, _, root = getParts()
		if not root then
			setStatus("No character found", RED)
			return
		end

		runId += 1
		local myRun = runId
		local startPos = points[1]

		local function playMain()
			if runId ~= myRun then return end
			state = "playing"
			refreshButtons()
			startFollow(points, jumps, "path", function()
				stopFollow("Finished - path complete", THEME.on)
			end)
		end

		state = "approach"
		refreshButtons()
		updateMe()

		if pdist(root.Position, startPos) < 4 then
			playMain()
			return
		end

		setStatus("Finding way to start...", THEME.muted)
		task.spawn(function()
			local wps, wflags
			pcall(function()
				local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
				path:ComputeAsync(root.Position, startPos - Vector3.new(0, GROUND, 0))
				if path.Status == Enum.PathStatus.Success then
					wps, wflags = {}, {}
					for i, w in ipairs(path:GetWaypoints()) do
						wps[i] = w.Position + Vector3.new(0, GROUND, 0)
						if w.Action == Enum.PathWaypointAction.Jump then wflags[i] = true end
					end
				end
			end)
			if runId ~= myRun then return end -- cancelled meanwhile
			if not wps or #wps == 0 then
				wps, wflags = { startPos }, {} -- no navmesh: walk straight to the start
			end
			startFollow(wps, wflags, "approach", playMain)
		end)
	end

	-- panel ---------------------------------------------------------------
	function REC.buildSettings(body)
		local canvas = new("Frame", {
			Name = "Preview",
			Size = UDim2.new(1, 0, 0, 100),
			BackgroundColor3 = Color3.fromRGB(16, 16, 20),
			BorderSizePixel = 0,
			ClipsDescendants = true,
		}, body)
		round(canvas, UDim.new(0, 8))
		outline(canvas)
		ui.canvas = canvas

		ui.hint = new("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Font = Enum.Font.Gotham,
			Text = "Press Record, then walk your route",
			TextColor3 = THEME.muted,
			TextSize = 11,
		}, canvas)

		ui.link = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = THEME.muted,
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 1,
		}, canvas)

		-- start circle (+ label), like the ring in your sketch
		ui.startDot = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(14, 14),
			BackgroundTransparency = 1,
			Visible = false,
			ZIndex = 4,
		}, canvas)
		round(ui.startDot, UDim.new(1, 0))
		outline(ui.startDot, GREEN, 2)
		new("TextLabel", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(1, 4, 0.5, 0),
			Size = UDim2.fromOffset(40, 10),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "start",
			TextSize = 9,
			TextColor3 = GREEN,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, ui.startDot)

		ui.endDot = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(8, 8),
			BackgroundColor3 = Color3.fromRGB(255, 70, 70),
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 3,
		}, canvas)
		round(ui.endDot, UDim.new(1, 0))

		-- "my spot" circle
		ui.meDot = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(12, 12),
			BackgroundColor3 = Color3.fromRGB(70, 140, 255),
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 5,
		}, canvas)
		round(ui.meDot, UDim.new(1, 0))
		outline(ui.meDot, Color3.new(1, 1, 1), 1)
		new("TextLabel", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(1, 4, 0.5, 0),
			Size = UDim2.fromOffset(30, 10),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "me",
			TextSize = 9,
			TextColor3 = Color3.fromRGB(120, 170, 255),
			TextXAlignment = Enum.TextXAlignment.Left,
		}, ui.meDot)

		ui.status = new("TextLabel", {
			Size = UDim2.new(1, 0, 0, 14),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "Ready",
			TextColor3 = THEME.muted,
			TextSize = 11,
			LayoutOrder = #body:GetChildren(),
		}, body)

		local b = addButtonRow(body, 30, {
			{ text = "Record", color = THEME.field, onClick = function()
				if state == "recording" then stopRecord() else startRecord() end
			end },
			{ text = "Play path", color = THEME.on, onClick = beginPlay },
		})
		ui.rec, ui.play = b[1], b[2]

		addNumberRow(body, "Walk speed", REC.cfg.speed, 1, 500, function(v)
			REC.cfg.speed = v
		end)
		addSwitchRow(body, "Show 3D path", REC.cfg.showPath, function(v)
			REC.cfg.showPath = v
			applyFolderParent()
		end)
		addButtonRow(body, ROW_H, {
			{ text = "Clear path", color = THEME.field, onClick = clearPath },
		})

		track(canvas:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			redrawPreview()
		end))
		refreshButtons()
	end

	function REC.start()
		applyFolderParent()
		refreshButtons()
		task.defer(redrawPreview)
		table.insert(conns, RunService.Heartbeat:Connect(function()
			local now = os.clock()
			if now - lastMe > 0.1 then
				lastMe = now
				updateMe()
			end
		end))
	end

	function REC.stop()
		stopRecord()
		stopFollow()
		for _, c in ipairs(conns) do c:Disconnect() end
		conns = {}
		if pathFolder then pathFolder.Parent = nil end
	end
end

---------------------------------------------------------------------
-- MODULE 9: MAGIC CARPET (180x100)
-- A client-side rectangle under your feet that follows you.
-- Hold E = up, Q = down (or the two buttons on touch).
---------------------------------------------------------------------
local FLY = {
	title = "Magic Carpet",
	short = "Fly",
	enabled = false,
	keepPanel = true,
	panelSize = Vector2.new(180, 100),
	cfg = { climbSpeed = 22, size = 7 },
}

do
	local conns = {}
	local carpet, targetY
	local keyUp, keyDown, btnUp, btnDown = false, false, false, false

	local function destroyCarpet()
		if carpet then
			carpet:Destroy()
			carpet = nil
		end
		targetY = nil
	end

	local function makeCarpet()
		carpet = Instance.new("Part")
		carpet.Name = "MagicCarpet"
		carpet.Anchored = true
		carpet.CanCollide = true
		carpet.CastShadow = false
		carpet.Size = Vector3.new(FLY.cfg.size, 0.4, FLY.cfg.size)
		carpet.Material = Enum.Material.Neon
		carpet.Color = Color3.fromRGB(150, 60, 255)
		carpet.Transparency = 0.15
		carpet.Parent = workspace
	end

	local function typing()
		return UserInputService:GetFocusedTextBox() ~= nil
	end

	function FLY.start()
		keyUp, keyDown = false, false
		makeCarpet()

		table.insert(conns, UserInputService.InputBegan:Connect(function(input)
			if typing() then return end
			if input.KeyCode == Enum.KeyCode.E then keyUp = true
			elseif input.KeyCode == Enum.KeyCode.Q then keyDown = true end
		end))
		table.insert(conns, UserInputService.InputEnded:Connect(function(input)
			if input.KeyCode == Enum.KeyCode.E then keyUp = false
			elseif input.KeyCode == Enum.KeyCode.Q then keyDown = false end
		end))
		table.insert(conns, lp.CharacterAdded:Connect(function()
			targetY = nil
		end))

		table.insert(conns, RunService.Heartbeat:Connect(function(dt)
			local char = lp.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if not (root and hum and hum.Health > 0) then return end
			if not carpet or not carpet.Parent then makeCarpet() end

			if not targetY then
				targetY = root.Position.Y - 3.25 -- right under your feet
			end

			local dy = ((keyUp or btnUp) and 1 or 0) - ((keyDown or btnDown) and 1 or 0)
			if dy ~= 0 then
				targetY += dy * FLY.cfg.climbSpeed * dt
				local v = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(v.X, dy * FLY.cfg.climbSpeed, v.Z) -- ride along
			end
			carpet.CFrame = CFrame.new(root.Position.X, targetY, root.Position.Z)
		end))
	end

	function FLY.stop()
		for _, c in ipairs(conns) do c:Disconnect() end
		conns = {}
		keyUp, keyDown, btnUp, btnDown = false, false, false, false
		destroyCarpet()
	end

	function FLY.buildSettings(body)
		FLY.syncSet = addSwitchRow(body, "Carpet", FLY.enabled, function(v)
			if FLY.requestEnabled then FLY.requestEnabled(v) end
		end)
		local b = addButtonRow(body, 28, {
			{ text = "Q  Down", color = THEME.field },
			{ text = "E  Up", color = THEME.field },
		})
		local function hold(button, setter)
			button.InputBegan:Connect(function(input)
				if isPress(input) then setter(true) end
			end)
			button.InputEnded:Connect(function(input)
				if isPress(input) then setter(false) end
			end)
		end
		hold(b[1], function(v) btnDown = v end)
		hold(b[2], function(v) btnUp = v end)
	end
end

---------------------------------------------------------------------
-- MODULE 10: AIM ASSIST (300x250)
-- Turns the camera toward the closest player (to your crosshair) inside the FOV.
-- Part choice, team check, wall check, movement prediction.
---------------------------------------------------------------------
local AIM = {
	title = "Aim Assist",
	short = "Aim",
	enabled = false,
	keepPanel = true,
	panelSize = Vector2.new(300, 250),
	listPad = 2,
	cfg = {
		teamCheck = true,   -- true = never aim at teammates
		wallCheck = true,   -- true = skip targets behind walls
		prediction = true,
		predictTime = 0.12, -- seconds of target movement to lead
		part = "Head",
		fov = 250,          -- px radius around the screen center
		maxDistance = 300,  -- studs: ignore players farther than this
		smooth = 1,         -- 1 = snap, lower = softer
	},
}

do
	local cfg = AIM.cfg
	local BIND = "UnifiedMenu_Aim"
	local PARTS = { "Head", "Torso", "HumanoidRootPart" }
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.IgnoreWater = true

	local function getAimPart(char)
		if cfg.part == "Torso" then
			return char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
		end
		return char:FindFirstChild(cfg.part)
	end

	local function isTeammate(plr)
		if not cfg.teamCheck then return false end
		return lp.Team ~= nil and plr.Team ~= nil and lp.Team == plr.Team
	end

	local function visible(targetPos, targetChar, myChar)
		local cam = workspace.CurrentCamera
		local origin = cam.CFrame.Position
		local ignore = { targetChar }
		if myChar then table.insert(ignore, myChar) end
		for _ = 1, 6 do
			rp.FilterDescendantsInstances = ignore
			local res = workspace:Raycast(origin, targetPos - origin, rp)
			if not res then return true end
			local hit = res.Instance
			if hit.Transparency >= 0.9 or not hit.CanCollide then
				table.insert(ignore, hit) -- glass / invisible parts don't count as walls
			else
				return false
			end
		end
		return false
	end

	local function step()
		local cam = workspace.CurrentCamera
		local myChar = lp.Character
		if not (cam and myChar) then return end
		local center = cam.ViewportSize / 2

		local bestPart, bestPx = nil, cfg.fov
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= lp and not isTeammate(plr) then
				local char = plr.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				local part = char and getAimPart(char)
				if hum and hum.Health > 0 and part
					and (part.Position - cam.CFrame.Position).Magnitude <= cfg.maxDistance then
					local v, onScreen = cam:WorldToViewportPoint(part.Position)
					if onScreen then
						local px = (Vector2.new(v.X, v.Y) - center).Magnitude
						if px < bestPx and (not cfg.wallCheck or visible(part.Position, char, myChar)) then
							bestPart, bestPx = part, px
						end
					end
				end
			end
		end
		if not bestPart then return end

		local aimPos = bestPart.Position
		if cfg.prediction then
			aimPos += bestPart.AssemblyLinearVelocity * cfg.predictTime
		end
		local goal = CFrame.lookAt(cam.CFrame.Position, aimPos)
		cam.CFrame = cam.CFrame:Lerp(goal, math.clamp(cfg.smooth, 0.02, 1))
	end

	function AIM.start()
		pcall(function() RunService:UnbindFromRenderStep(BIND) end)
		RunService:BindToRenderStep(BIND, Enum.RenderPriority.Camera.Value + 1, step)
	end

	function AIM.stop()
		pcall(function() RunService:UnbindFromRenderStep(BIND) end)
	end

	function AIM.buildSettings(body)
		AIM.syncSet = addSwitchRow(body, "Aim assist", AIM.enabled, function(v)
			if AIM.requestEnabled then AIM.requestEnabled(v) end
		end)
		addSwitchRow(body, "Skip teammates", cfg.teamCheck, function(v) cfg.teamCheck = v end)
		addSwitchRow(body, "Wall check", cfg.wallCheck, function(v) cfg.wallCheck = v end)
		addSwitchRow(body, "Prediction", cfg.prediction, function(v) cfg.prediction = v end)

		local row = addRow(body)
		addLabel(row, "Target part", 110)
		local btn = addButton(row, cfg.part, THEME.field)
		btn.AnchorPoint = Vector2.new(1, 0.5)
		btn.Position = UDim2.new(1, -5, 0.5, 0)
		btn.Size = UDim2.fromOffset(100, 18)
		btn.TextSize = 10
		round(btn, UDim.new(0, 6))
		btn.MouseButton1Click:Connect(function()
			local i = table.find(PARTS, cfg.part) or 1
			cfg.part = PARTS[(i % #PARTS) + 1]
			btn.Text = cfg.part
		end)

		addNumberRow(body, "Predict (sec)", cfg.predictTime, 0, 1, function(v) cfg.predictTime = v end)
		addNumberRow(body, "Max dist (studs)", cfg.maxDistance, 10, 5000, function(v) cfg.maxDistance = v end)
		addNumberRow(body, "FOV (px)", cfg.fov, 20, 2000, function(v) cfg.fov = v end)
		addNumberRow(body, "Smoothing", cfg.smooth, 0.02, 1, function(v) cfg.smooth = v end)
	end
end

---------------------------------------------------------------------
-- MAIN MENU
---------------------------------------------------------------------
local modules = { ESP, RADAR, SPEED, METER, PHL, PDEL, DANGER, REC, FLY, AIM }
local alive = true

local main = makePanel("MENU", MENU.defaultSize, MENU.startPos, "-")
main.title.TextScaled = true
new("UITextSizeConstraint", { MaxTextSize = 12, MinTextSize = 5 }, main.title)

-- container for the module rows (scales with the menu size)
local MROW = TOUCH and 32 or 24
local list = new("ScrollingFrame", {
	Name = "List",
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 2,
	ScrollBarImageColor3 = THEME.muted,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	Position = UDim2.fromOffset(4, TITLE_H + 2),
	Size = UDim2.new(1, -8, 1, -(TITLE_H + 2 + 16)),
}, main.frame)
new("UIListLayout", {
	Padding = UDim.new(0, 3),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, list)

-- minimized ball
local ball = new("TextButton", {
	Name = "Ball",
	Text = "",
	AutoButtonColor = false,
	Size = UDim2.fromOffset(MENU.ballSize, MENU.ballSize),
	Position = UDim2.fromOffset(MENU.startPos.X, MENU.startPos.Y),
	BackgroundColor3 = THEME.bg,
	BorderSizePixel = 0,
	Visible = false,
	Active = true,
}, gui)
round(ball, UDim.new(1, 0))
outline(ball, THEME.stroke, 1.5)

local ballCore = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(12, 12),
	BackgroundColor3 = THEME.off,
	BorderSizePixel = 0,
}, ball)
round(ballCore, UDim.new(1, 0))

local function refreshBall()
	local any = false
	for _, m in ipairs(modules) do
		if m.enabled then any = true end
	end
	ballCore.BackgroundColor3 = any and THEME.on or THEME.off
end

-- submenus -------------------------------------------------------------
local function restartModule(mod)
	if mod.enabled then
		mod.stop()
		mod.start()
	end
end

local function placePanel(mod, index)
	local cam = workspace.CurrentCamera
	local vpX = cam and cam.ViewportSize.X or 800
	local mx, my = main.frame.Position.X.Offset, main.frame.Position.Y.Offset
	local mw = main.frame.Size.X.Offset
	local sc = mod.panel.frame:FindFirstChildOfClass("UIScale")
	local fs = mod.panel.frame.Size
	if sc then
		local vpY = cam and cam.ViewportSize.Y or 400
		local fit = math.min((vpX - 8) / fs.X.Offset, (vpY - 8) / fs.Y.Offset, 1)
		sc.Scale = math.clamp(fit, 0.5, 1)
		if mod.compact and TOUCH then sc.Scale = 1.35 end -- tiny panels get finger-sized
	end
	local pw = fs.X.Offset * (sc and sc.Scale or 1)
	local x = mx + mw + 8
	if x + pw > vpX then
		x = mx - pw - 8
	end
	mod.panel.frame.Position = UDim2.fromOffset(x, my + (index - 1) * 24)
	clampToScreen(mod.panel.frame)
end

local function ensurePanel(mod, index)
	if mod.panel then return mod.panel end
	local restart = function()
		restartModule(mod)
	end

	-- tiny panels (Danger 50x30, Meter): no title bar, drag by the body
	if mod.compact then
		local panel = makePanel(mod.title, mod.panelSize, Vector2.new(0, 0), nil, true)
		mod.panel = panel
		mod.buildSettings(panel.frame, restart, mod)
		placePanel(mod, index)
		return panel
	end

	local fixed = mod.panelSize
	local width = fixed and fixed.X or MENU.panelWidth
	local panel = makePanel(mod.title, Vector2.new(width, fixed and fixed.Y or 80), Vector2.new(0, 0), "x")
	panel.btn.Text = "×"
	panel.btn.MouseButton1Click:Connect(function()
		panel.frame.Visible = false
	end)

	local body
	if fixed then
		body = new("ScrollingFrame", {
			Name = "Body",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(6, TITLE_H + 2),
			Size = UDim2.new(1, -12, 1, -(TITLE_H + 6)),
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = THEME.muted,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
		}, panel.frame)
	else
		body = new("Frame", {
			Name = "Body",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(6, TITLE_H + 2),
			Size = UDim2.new(1, -12, 1, -(TITLE_H + 8)),
		}, panel.frame)
	end
	local layout = new("UIListLayout", {
		Padding = UDim.new(0, mod.listPad or 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, body)

	local function fit()
		panel.frame.Size = UDim2.fromOffset(width, TITLE_H + 10 + layout.AbsoluteContentSize.Y)
	end
	if not fixed then
		layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)
	end

	mod.panel = panel
	mod.buildSettings(body, restart, mod)
	if not fixed then fit() end
	placePanel(mod, index)
	return panel
end

-- show a submenu; on touch screens only one big submenu stays open
local function showPanel(mod)
	if TOUCH and not mod.compact then
		for _, m in ipairs(modules) do
			if m ~= mod and not m.compact and m.panel then
				m.panel.frame.Visible = false
			end
		end
	end
	mod.panel.frame.Visible = true
	bringToFront(mod.panel.frame)
end

-- module rows ----------------------------------------------------------
local rows = {} -- [mod] = { index, nameBtn, setSwitch }

local function setModuleEnabled(mod, value)
	if value == mod.enabled then return end
	local info = rows[mod]

	if value then
		local okP, panel = pcall(ensurePanel, mod, info.index)
		if not okP then
			warn("[UnifiedMenu] " .. mod.title .. " panel failed: " .. tostring(panel))
			panel = nil
		end
		local ok, err = pcall(mod.start)
		if not ok then
			warn("[UnifiedMenu] " .. mod.title .. " failed to start: " .. tostring(err))
			info.setSwitch(false)
			if mod.syncSet then mod.syncSet(false) end
			return
		end
		mod.enabled = true
		if panel then
			showPanel(mod)
		end
	else
		mod.enabled = false
		local ok, err = pcall(mod.stop)
		if not ok then warn("[UnifiedMenu] " .. mod.title .. " failed to stop: " .. tostring(err)) end
		if mod.panel and not mod.keepPanel then
			mod.panel.frame.Visible = false
		end
	end

	info.setSwitch(value)
	if mod.syncSet then mod.syncSet(value) end
	info.nameBtn.TextColor3 = value and THEME.text or THEME.muted
	refreshBall()
end

for index, mod in ipairs(modules) do
	local row = new("Frame", {
		Name = mod.short,
		Size = UDim2.new(1, -4, 0, MROW),
		BackgroundColor3 = THEME.row,
		BorderSizePixel = 0,
		LayoutOrder = index,
	}, list)
	round(row, UDim.new(0, 8))

	local nameBtn = new("TextButton", {
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Size = UDim2.new(0.58, 0, 1, 0),
		Font = Enum.Font.GothamBold,
		Text = mod.short,
		TextScaled = true,
		TextColor3 = THEME.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)
	new("UITextSizeConstraint", { MaxTextSize = 13, MinTextSize = 5 }, nameBtn)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, 6),
		PaddingTop = UDim.new(0, 3),
		PaddingBottom = UDim.new(0, 3),
	}, nameBtn)

	local track, setSwitch = makeSwitch(false, function(v)
		setModuleEnabled(mod, v)
	end)
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.Position = UDim2.new(1, -4, 0.5, 0)
	track.Size = UDim2.fromScale(0.4, 0.6)
	new("UIAspectRatioConstraint", { AspectRatio = 1.8 }, track)
	track.Parent = row

	rows[mod] = { index = index, nameBtn = nameBtn, setSwitch = setSwitch }
	mod.requestEnabled = function(v)
		setModuleEnabled(mod, v)
	end

	-- tap the name: show/hide this module's submenu
	nameBtn.MouseButton1Click:Connect(function()
		if mod.panel and (mod.enabled or mod.keepPanel) then
			if mod.panel.frame.Visible then
				mod.panel.frame.Visible = false
			else
				showPanel(mod)
			end
		elseif not mod.enabled then
			-- not running yet: turn it on (opens its submenu)
			setModuleEnabled(mod, true)
		end
	end)
end

-- resize grip (bottom-right dots) --------------------------------------
local grip = new("TextButton", {
	Name = "Grip",
	Text = "",
	AutoButtonColor = false,
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -3, 1, -3),
	Size = UDim2.fromOffset(TOUCH and 28 or 16, TOUCH and 28 or 16),
}, main.frame)
local GRIP_PAD = TOUCH and 12 or 0
for _, p in ipairs({ { 11, 11 }, { 11, 5 }, { 5, 11 } }) do
	local dot = new("Frame", {
		Position = UDim2.fromOffset(p[1] + GRIP_PAD, p[2] + GRIP_PAD),
		Size = UDim2.fromOffset(3, 3),
		BackgroundColor3 = THEME.muted,
		BorderSizePixel = 0,
	}, grip)
	round(dot, UDim.new(1, 0))
end

do
	local resizing = false
	local startMouse, startSize

	grip.InputBegan:Connect(function(input)
		if isPress(input) then
			resizing = true
			startMouse = input.Position
			startSize = Vector2.new(main.frame.Size.X.Offset, main.frame.Size.Y.Offset)
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					resizing = false
				end
			end)
		end
	end)

	track(UserInputService.InputChanged:Connect(function(input)
		if resizing and isMove(input) then
			local d = input.Position - startMouse
			local w = math.clamp(startSize.X + d.X, MENU.minSize.X, MENU.maxSize.X)
			local h = math.clamp(startSize.Y + d.Y, MENU.minSize.Y, MENU.maxSize.Y)
			main.frame.Size = UDim2.fromOffset(w, h)
			clampToScreen(main.frame)
		end
	end))
end

-- minimize / restore ---------------------------------------------------
local minimized = false
local minAnchor = Vector2.new(0, 0)
local hiddenPanels = {}

local function minimize()
	if minimized then return end
	minimized = true

	minAnchor = Vector2.new(main.frame.Position.X.Offset, main.frame.Position.Y.Offset)
	ball.Position = UDim2.fromOffset(minAnchor.X, minAnchor.Y)

	hiddenPanels = {}
	for _, mod in ipairs(modules) do
		if mod.panel and mod.panel.frame.Visible then
			table.insert(hiddenPanels, mod.panel.frame)
			mod.panel.frame.Visible = false
		end
	end

	main.frame.Visible = false
	ball.Visible = true
	clampToScreen(ball)
end

local function restore()
	if not minimized then return end
	minimized = false

	-- the menu comes back where the ball was left; submenus move with it
	local dx = ball.Position.X.Offset - minAnchor.X
	local dy = ball.Position.Y.Offset - minAnchor.Y

	ball.Visible = false
	main.frame.Position = UDim2.fromOffset(main.frame.Position.X.Offset + dx, main.frame.Position.Y.Offset + dy)
	main.frame.Visible = true
	clampToScreen(main.frame)
	bringToFront(main.frame)

	for _, f in ipairs(hiddenPanels) do
		f.Position = UDim2.fromOffset(f.Position.X.Offset + dx, f.Position.Y.Offset + dy)
		f.Visible = true
		clampToScreen(f)
	end
	hiddenPanels = {}
end

main.btn.MouseButton1Click:Connect(minimize)
makeDraggable(ball, ball, restore)

-- RightShift = minimize / restore
track(UserInputService.InputBegan:Connect(function(input, processed)
	if processed or UserInputService:GetFocusedTextBox() then return end
	if input.KeyCode == Enum.KeyCode.RightShift then
		if minimized then restore() else minimize() end
	end
end))

do
	local cam = workspace.CurrentCamera
	local sc = main.frame:FindFirstChildOfClass("UIScale")
	if cam and sc then
		local vp = cam.ViewportSize
		sc.Scale = math.clamp(math.min((vp.X - 8) / main.frame.Size.X.Offset, (vp.Y - 8) / main.frame.Size.Y.Offset, 1), 0.6, 1)
	end
end
clampToScreen(main.frame)
refreshBall()

---------------------------------------------------------------------
-- SAFETY NET: keep the menu alive + clean shutdown on re-run
---------------------------------------------------------------------
task.spawn(function()
	while alive do
		if gui.Parent ~= guiParent then
			pcall(function()
				gui.Parent = guiParent
			end)
		end
		gui.Enabled = true
		task.wait(1)
	end
end)

env.__UnifiedMenuCleanup = function()
	alive = false
	for _, mod in ipairs(modules) do
		if mod.enabled then
			mod.enabled = false
			pcall(mod.stop)
		end
	end
	for _, c in ipairs(allConns) do
		pcall(function() c:Disconnect() end)
	end
	pcall(function() gui:Destroy() end)
end

print("[UnifiedMenu] loaded - parent: " .. guiParent:GetFullName() .. "  (tap the '-' button / ball, or RightShift on keyboard)")
