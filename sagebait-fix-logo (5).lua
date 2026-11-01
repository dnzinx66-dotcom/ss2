local function bootstrapCompatibility()
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local fenv = getfenv(1)
    local missing = {}

    local function grab(name)
        for _, source in ipairs({ fenv, genv, _G }) do
            local found, value = pcall(function()
                return source[name]
            end)
            if found and type(value) == "function" then
                return value
            end
        end
        return nil
    end

    local function grabTable(name)
        local found, value = pcall(function()
            return fenv[name] or genv[name]
        end)
        if found and type(value) == "table" then
            return value
        end
        return nil
    end

    local function publish(name, value)
        if not value then
            table.insert(missing, name)
            return
        end
        pcall(function()
            genv[name] = value
        end)
        pcall(function()
            fenv[name] = value
        end)
    end

    local connectionsOf = grab("getconnections") or grab("get_signal_cons")
    publish("getconnections", connectionsOf)
    local writeable = grab("make_writeable")
    local readonly = grab("make_readonly")
    local debugMeta = debug and debug.getmetatable

    publish("getrawmetatable", grab("getrawmetatable") or grab("get_raw_metatable") or debugMeta)

    publish("setreadonly", grab("setreadonly") or grab("set_readonly") or (writeable and readonly and function(target, state)
        if state then
            readonly(target)
        else
            writeable(target)
        end
    end))

    publish("getnamecallmethod", grab("getnamecallmethod") or grab("get_namecall_method"))

    local setIdentity = grab("setthreadidentity") or grab("set_thread_identity")
    local readIdentity = grab("getthreadidentity") or grab("get_thread_identity")

    if setIdentity then
        publish("setthreadidentity", setIdentity)
    end
    if readIdentity then
        publish("getthreadidentity", readIdentity)
    end

    local native = grab("firesignal") or grab("fire_signal")
    local viaConnections = connectionsOf and function(signal, ...)
        for _, connection in ipairs(connectionsOf(signal)) do
            pcall(connection.Fire, connection, ...)
        end
    end

    if native and viaConnections then
        local probe = Instance.new("BindableEvent")
        local landed = false
        probe.Event:Connect(function()
            landed = true
        end)
        pcall(native, probe.Event, true)
        task.wait(0.1)
        probe:Destroy()
        if not landed then
            native = nil
        end
    end

    local fire = native or viaConnections
    publish("firesignal", fire and function(signal, ...)
        if not setIdentity then
            return fire(signal, ...)
        end
        local restore = readIdentity and readIdentity()
        pcall(setIdentity, 2)
        pcall(fire, signal, ...)
        if restore then
            pcall(setIdentity, restore)
        end
    end)

    publish("loadstring", grab("loadstring") or grab("load"))

    local send = grab("request") or grab("http_request")
    if not send then
        local syntax = grabTable("syn") or grabTable("http") or grabTable("fluxus")
        send = syntax and syntax.request
    end

    publish("httpGet", function(url)
        local reached, body = pcall(function()
            return game:HttpGet(url)
        end)
        if reached and type(body) == "string" and #body > 0 then
            return body
        end
        if send then
            local sent, response = pcall(send, { Url = url, Method = "GET" })
            if sent and type(response) == "table" and type(response.Body) == "string" then
                return response.Body
            end
        end
        error("TWINHUB: no working HTTP method for " .. tostring(url), 0)
    end)

    local hidden = grab("gethui") or grab("get_hidden_gui")
    local guard = grab("protect_gui")
    if not guard then
        local syntax = grabTable("syn")
        guard = syntax and syntax.protect_gui
    end
    publish("hidegui", function(gui)
        if guard then pcall(guard, gui) end
        if hidden then
            local reached, container = pcall(hidden)
            if reached and typeof(container) == "Instance" then
                gui.Parent = container
                return
            end
        end
        local pulled, core = pcall(game.GetService, game, "CoreGui")
        if pulled and core then
            local placed = pcall(function() gui.Parent = core end)
            if placed then return end
        end
        gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    end)

    if #missing > 0 then
        warn("TWINHUB: this executor has no " .. table.concat(missing, ", ") .. " - features that need them stay off")
    end
end

bootstrapCompatibility()

local hookNamecall

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local prior = rawget(genv, "TWINHUB_SESSION") or genv.TWINHUB_SESSION
    local carried = type(prior) == "table" and prior.vault or nil
    if type(prior) == "table" and type(prior.unload) == "function" then
        pcall(prior.unload)
    end
    local session = {}
    session.vault = carried

    -- Central __namecall registry: one real hook on the metatable, any number of
    -- named handlers stacked on top of it. Newest handler runs first (same order
    -- the old per-feature hooks had), unload walks the stack LIFO.
    local hub = { stack = {}, byId = {}, installed = false, dead = false }
    local dispatch

    dispatch = function(level, self, method, ...)
        while level > 0 do
            local entry = hub.stack[level]
            if entry and entry.alive then
                return entry.callback(entry.below, self, method, ...)
            end
            level = level - 1
        end
        return hub.original(self, ...)
    end

    local function central(self, ...)
        return dispatch(#hub.stack, self, getnamecallmethod(), ...)
    end

    local function writeNamecall(meta, value)
        pcall(setreadonly, meta, false)
        local written = pcall(function()
            meta.__namecall = value
        end)
        pcall(setreadonly, meta, true)
        return written
    end

    -- callback(callNext, self, method, ...): call callNext(self, method, ...) to continue the chain.
    -- Registering the same id again only swaps the callback, it never stacks a second hook.
    -- Returns a release function (or nil when the executor can't hook).
    hookNamecall = function(id, callback, onUnload)
        if hub.dead then return nil end
        if type(id) ~= "string" or type(callback) ~= "function" then return nil end

        local current = hub.byId[id]
        if current and current.alive then
            current.callback = callback
            current.onUnload = onUnload or current.onUnload
            return current.release
        end

        if not (getrawmetatable and setreadonly and getnamecallmethod) then return nil end

        if not hub.installed then
            local meta = getrawmetatable(game)
            if not meta then return nil end
            local live = meta.__namecall
            if live ~= central then
                hub.original = live
                if not writeNamecall(meta, central) then return nil end
            end
            hub.mt = meta
            hub.installed = true
        end

        local entry = {
            id = id,
            callback = callback,
            onUnload = onUnload,
            alive = true,
            index = #hub.stack + 1,
        }
        entry.below = function(self, method, ...)
            return dispatch(entry.index - 1, self, method, ...)
        end
        entry.release = function()
            if not entry.alive then return end
            entry.alive = false
            if hub.byId[id] == entry then
                hub.byId[id] = nil
            end
            if type(entry.onUnload) == "function" then
                pcall(entry.onUnload)
            end
            while #hub.stack > 0 and not hub.stack[#hub.stack].alive do
                hub.stack[#hub.stack] = nil
            end
        end

        hub.stack[entry.index] = entry
        hub.byId[id] = entry
        return entry.release
    end

    -- LIFO teardown: last handler installed is the first one released, then the
    -- original metamethod goes back. If another script wrapped us in the meantime
    -- we leave the central hook in place as a pure pass-through instead of cutting
    -- their wrapper out of the chain.
    session.unhook = function()
        hub.dead = true
        for level = #hub.stack, 1, -1 do
            local entry = hub.stack[level]
            hub.stack[level] = nil
            if entry then
                entry.alive = false
                hub.byId[entry.id] = nil
                if type(entry.onUnload) == "function" then
                    pcall(entry.onUnload)
                end
            end
        end
        if hub.installed and hub.mt and rawget(hub.mt, "__namecall") == central then
            writeNamecall(hub.mt, hub.original)
        end
        hub.installed = false
    end
    session.unload = function()
        if session.vault and session.vault.inventory then
            pcall(function()
                local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
                local inventory = Knit.GetController("InventoryController")
                if inventory and inventory.Inventory then
                    inventory.Inventory:set(session.vault.inventory)
                end
            end)
        end
        if session.ui and session.ui.Unload then
            pcall(function()
                session.ui:Unload()
            end)
        end
        for _, link in ipairs(session.links or {}) do
            pcall(function()
                link:Disconnect()
            end)
        end
        pcall(function()
            local tagged = {}
            for _, name in ipairs(session.tags or {}) do
                tagged[name] = true
            end
            if not next(tagged) then return end
            local holders = {}
            if type(gethui) == "function" then
                local reached, container = pcall(gethui)
                if reached and container then table.insert(holders, container) end
            end
            table.insert(holders, game:GetService("CoreGui"))
            if workspace.CurrentCamera then
                table.insert(holders, workspace.CurrentCamera)
            end
            local players = game:GetService("Players")
            if players.LocalPlayer then
                local pg = players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
                if pg then table.insert(holders, pg) end
            end
            for _, holder in ipairs(holders) do
                for _, child in ipairs(holder:GetChildren()) do
                    if tagged[child.Name] then
                        child:Destroy()
                    end
                end
            end
            for _, model in ipairs(workspace:GetChildren()) do
                if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
                    for _, child in ipairs(model:GetChildren()) do
                        if tagged[child.Name] then
                            child:Destroy()
                        end
                    end
                end
            end
            for _, other in ipairs(players:GetPlayers()) do
                if other.Character then
                    for _, child in ipairs(other.Character:GetChildren()) do
                        if tagged[child.Name] then
                            child:Destroy()
                        end
                    end
                end
            end
        end)
        pcall(session.unhook)
    end
    session.links = {}
    session.tags = {}
    genv.TWINHUB_SESSION = session
end

local Library = (function()
    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local TweenService = game:GetService("TweenService")
    local GuiService = game:GetService("GuiService")
    local HttpService = game:GetService("HttpService")
    local LocalPlayer = Players.LocalPlayer

    local Theme = {
        Accent = Color3.fromRGB(208, 240, 64),
        AccentSoft = Color3.fromRGB(34, 42, 12),
        Shell = Color3.fromRGB(10, 10, 10),
        ShellTop = Color3.fromRGB(10, 10, 10),
        Panel = Color3.fromRGB(14, 14, 14),
        Raised = Color3.fromRGB(24, 24, 24),
        Sunken = Color3.fromRGB(8, 8, 8),
        Line = Color3.fromRGB(48, 48, 48),
        LineSoft = Color3.fromRGB(28, 28, 28),
        Text = Color3.fromRGB(236, 236, 236),
        SubText = Color3.fromRGB(138, 138, 138),
        Faint = Color3.fromRGB(84, 84, 84),
    }

    local PILL = UDim.new(1, 0)
    local EASE = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

    local function resolveFont(name, fallback)
        local ok, font = pcall(function()
            return Enum.Font[name]
        end)
        if ok and font then
            return font
        end
        return fallback
    end

    local Fonts = {
        Bold = resolveFont("MontserratBold", Enum.Font.GothamBold),
        Medium = resolveFont("MontserratMedium", Enum.Font.GothamMedium),
    }

    local Lib = {
        Options = {},
        Toggles = {},
        Theme = Theme,
        Fonts = Fonts,
        CornerRadius = 14,
        ForceCheckbox = false,
        ShowToggleFrameInKeybinds = true,
        NotifySide = "Right",
        Unloaded = false,
        ToggleKeybind = nil,
        DefaultToggleKey = "RightShift",
    }

    local conns = {}
    local panels = {}
    local pickers = {}
    local pages = {}
    local configFolder = "TWINHUB"

    local function new(class, props, parent)
        local inst = Instance.new(class)
        for key, value in pairs(props) do
            inst[key] = value
        end
        if parent then
            inst.Parent = parent
        end
        return inst
    end

    local function round(inst, radius, tracked)
        local corner = new("UICorner", { CornerRadius = radius }, inst)
        if tracked then
            table.insert(panels, corner)
        end
        return corner
    end

    local function outline(inst, color, thickness, transparency)
        return new("UIStroke", {
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            LineJoinMode = Enum.LineJoinMode.Round,
            Color = color or Theme.Line,
            Thickness = thickness or 1,
            Transparency = transparency or 0,
        }, inst)
    end

    local function pad(inst, left, right, top, bottom)
        return new("UIPadding", {
            PaddingLeft = UDim.new(0, left or 0),
            PaddingRight = UDim.new(0, right or 0),
            PaddingTop = UDim.new(0, top or 0),
            PaddingBottom = UDim.new(0, bottom or 0),
        }, inst)
    end

    local function stack(inst, gap, dir)
        return new("UIListLayout", {
            FillDirection = dir or Enum.FillDirection.Vertical,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, gap or 0),
        }, inst)
    end

    local function glide(inst, props, speed)
        local anim = TweenService:Create(inst, speed and TweenInfo.new(speed, Enum.EasingStyle.Quart, Enum.EasingDirection.Out) or EASE, props)
        anim:Play()
        return anim
    end

    local function bind(signal, fn)
        local link = signal:Connect(fn)
        table.insert(conns, link)
        return link
    end

    local function tag()
        return string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))
    end

    local Root = new("ScreenGui", {
        Name = tag(),
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        AutoLocalize = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9999,
    })

    do
        local placed = false
        if type(hidegui) == "function" then
            placed = pcall(hidegui, Root)
        end
        if not placed or not Root.Parent then
            Root.Parent = LocalPlayer:WaitForChild("PlayerGui")
        end
        pcall(function()
            UserInputService.MouseIconEnabled = true
        end)
    end

    local TipCard = new("Frame", {
        BackgroundColor3 = Theme.Raised,
        BorderSizePixel = 0,
        AutomaticSize = Enum.AutomaticSize.XY,
        Size = UDim2.fromOffset(0, 0),
        Visible = false,
        ZIndex = 190,
    }, Root)
    round(TipCard, UDim.new(0, 6))
    outline(TipCard, Theme.Accent, 1, 0.6)
    pad(TipCard, 10, 10, 6, 6)

    local TipText = new("TextLabel", {
        BackgroundTransparency = 1,
        AutomaticSize = Enum.AutomaticSize.XY,
        Font = Fonts.Medium,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "",
        ZIndex = 191,
    }, TipCard)

    local NotifyHolder = new("Frame", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -18, 0, 18),
        Size = UDim2.fromOffset(300, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        ZIndex = 180,
    }, Root)
    stack(NotifyHolder, 8)

    local KeybindFrame = new("Frame", {
        Position = UDim2.fromOffset(24, 120),
        Size = UDim2.fromOffset(190, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 60,
    }, Root)
    round(KeybindFrame, UDim.new(0, Lib.CornerRadius), true)
    outline(KeybindFrame, Theme.LineSoft, 1)
    pad(KeybindFrame, 14, 14, 12, 14)
    stack(KeybindFrame, 8)

    new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1,
        Font = Fonts.Bold,
        TextSize = 12,
        TextColor3 = Theme.Accent,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "Keybinds",
        LayoutOrder = 0,
        ZIndex = 61,
    }, KeybindFrame)

    local KeybindList = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = 1,
        ZIndex = 61,
    }, KeybindFrame)
    stack(KeybindList, 4)

    Lib.KeybindFrame = KeybindFrame
    Lib.Root = Root

    local function pointer()
        return UserInputService:GetMouseLocation() + Vector2.new(0, GuiService:GetGuiInset().Y)
    end

    local function attachTip(frame, text)
        if not text or text == "" then
            return
        end
        bind(frame.MouseEnter, function()
            TipText.Text = text
            local at = pointer()
            TipCard.Position = UDim2.fromOffset(at.X + 16, at.Y + 18)
            TipCard.Visible = true
        end)
        bind(frame.MouseMoved, function()
            if TipCard.Visible then
                local at = pointer()
                TipCard.Position = UDim2.fromOffset(at.X + 16, at.Y + 18)
            end
        end)
        bind(frame.MouseLeave, function()
            TipCard.Visible = false
        end)
    end

    function Lib:Notify(payload, seconds)
        local text = payload
        if type(payload) == "table" then
            text = payload.Description or payload.Title or payload.Text or ""
            seconds = seconds or payload.Time
        end

        local card = new("Frame", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = Theme.Raised,
            BorderSizePixel = 0,
            BackgroundTransparency = 1,
            ZIndex = 181,
        }, NotifyHolder)
        round(card, UDim.new(0, 8))
        local edge = outline(card, Theme.Line, 1, 1)
        pad(card, 16, 12, 10, 10)

        local bar = new("Frame", {
            Position = UDim2.fromOffset(-9, 12),
            Size = UDim2.fromOffset(3, 16),
            BackgroundColor3 = Theme.Accent,
            BorderSizePixel = 0,
            BackgroundTransparency = 1,
            ZIndex = 182,
        }, card)
        round(bar, PILL)

        local body = new("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Font = Fonts.Medium,
            TextSize = 13,
            TextColor3 = Theme.Text,
            TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
            Text = tostring(text),
            ZIndex = 182,
        }, card)

        glide(card, { BackgroundTransparency = 0 })
        glide(edge, { Transparency = 0 })
        glide(bar, { BackgroundTransparency = 0 })
        glide(body, { TextTransparency = 0 })

        task.delay(seconds or 4, function()
            if not card.Parent then
                return
            end
            glide(card, { BackgroundTransparency = 1 })
            glide(edge, { Transparency = 1 })
            glide(bar, { BackgroundTransparency = 1 })
            glide(body, { TextTransparency = 1 })
            task.wait(0.24)
            card:Destroy()
        end)
    end

    function Lib:SetNotifySide(side)
        Lib.NotifySide = side
        if side == "Left" then
            NotifyHolder.AnchorPoint = Vector2.new(0, 0)
            NotifyHolder.Position = UDim2.new(0, 18, 0, 18)
        else
            NotifyHolder.AnchorPoint = Vector2.new(1, 0)
            NotifyHolder.Position = UDim2.new(1, -18, 0, 18)
        end
    end

    local function refreshKeybindList()
        for _, child in ipairs(KeybindList:GetChildren()) do
            if child:IsA("Frame") then
                child:Destroy()
            end
        end
        local order = 0
        for _, picker in ipairs(pickers) do
            if not picker.NoUI and picker.Value and picker.Value ~= "" then
                order = order + 1
                local row = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 20),
                    BackgroundTransparency = 1,
                    LayoutOrder = order,
                    ZIndex = 62,
                }, KeybindList)
                new("TextLabel", {
                    Size = UDim2.new(1, -54, 1, 0),
                    BackgroundTransparency = 1,
                    Font = Fonts.Medium,
                    TextSize = 12,
                    TextColor3 = Theme.SubText,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = picker.Label,
                    ZIndex = 62,
                }, row)
                local chip = new("Frame", {
                    AnchorPoint = Vector2.new(1, 0.5),
                    Position = UDim2.new(1, 0, 0.5, 0),
                    Size = UDim2.fromOffset(52, 18),
                    BackgroundColor3 = Theme.Sunken,
                    BorderSizePixel = 0,
                    ZIndex = 62,
                }, row)
                round(chip, UDim.new(0, 5))
                outline(chip, Theme.Line, 1)
                new("TextLabel", {
                    Size = UDim2.fromScale(1, 1),
                    BackgroundTransparency = 1,
                    Font = Fonts.Bold,
                    TextSize = 10,
                    TextColor3 = Theme.Accent,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = picker.Value,
                    ZIndex = 63,
                }, chip)
            end
        end
    end

    local function dragify(handle, target)
        local holding, origin, base = false, nil, nil
        bind(handle.InputBegan, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                holding = true
                origin = input.Position
                base = target.Position
            end
        end)
        bind(handle.InputEnded, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                holding = false
            end
        end)
        bind(UserInputService.InputChanged, function(input)
            if not holding then
                return
            end
            if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
                local shift = input.Position - origin
                target.Position = UDim2.new(base.X.Scale, base.X.Offset + shift.X, base.Y.Scale, base.Y.Offset + shift.Y)
            end
        end)
    end

    dragify(KeybindFrame, KeybindFrame)

    local function makeGroup(holder)
        local Group = { Holder = holder, Order = 0 }

        local function slot(height, auto)
            Group.Order = Group.Order + 1
            local frame = new("Frame", {
                Size = UDim2.new(1, 0, 0, height or 0),
                BackgroundTransparency = 1,
                LayoutOrder = Group.Order,
            }, holder)
            if auto then
                frame.AutomaticSize = Enum.AutomaticSize.Y
            end
            return frame
        end

        local function caption(parent, text)
            return new("TextLabel", {
                Size = UDim2.new(1, 0, 0, 14),
                BackgroundTransparency = 1,
                Font = Fonts.Medium,
                TextSize = 12,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = text,
                LayoutOrder = 0,
            }, parent)
        end

        function Group:AddToggle(index, opts)
            opts = opts or {}
            local row = slot(30)

            local label = new("TextLabel", {
                Size = UDim2.new(1, -60, 1, 0),
                BackgroundTransparency = 1,
                Font = Fonts.Medium,
                TextSize = 13,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = opts.Text or index,
            }, row)

            local box = Lib.ForceCheckbox
            local track = new("Frame", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, 0, 0.5, 0),
                Size = box and UDim2.fromOffset(16, 16) or UDim2.fromOffset(38, 20),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
            }, row)
            round(track, box and UDim.new(0, 4) or PILL)
            local edge = outline(track, Theme.Line, 1)

            local knob = new("Frame", {
                Position = box and UDim2.fromOffset(4, 4) or UDim2.fromOffset(3, 3),
                Size = box and UDim2.fromOffset(8, 8) or UDim2.fromOffset(14, 14),
                BackgroundColor3 = Theme.Faint,
                BorderSizePixel = 0,
            }, track)
            round(knob, box and UDim.new(0, 2) or PILL)

            local hit = new("TextButton", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = "",
                AutoButtonColor = false,
            }, row)
            attachTip(hit, opts.Tooltip)

            local Toggle = { Value = false, Type = "Toggle", Index = index, Callbacks = {} }

            local function paint()
                if Toggle.Value then
                    glide(track, { BackgroundColor3 = Theme.AccentSoft })
                    glide(edge, { Color = Theme.Accent })
                    glide(knob, { BackgroundColor3 = Theme.Accent })
                    glide(label, { TextColor3 = Theme.Text })
                    if not box then
                        glide(knob, { Position = UDim2.fromOffset(21, 3) })
                    end
                else
                    glide(track, { BackgroundColor3 = Theme.Sunken })
                    glide(edge, { Color = Theme.Line })
                    glide(knob, { BackgroundColor3 = Theme.Faint })
                    glide(label, { TextColor3 = Theme.SubText })
                    if not box then
                        glide(knob, { Position = UDim2.fromOffset(3, 3) })
                    end
                end
            end

            function Toggle:SetValue(value, silent)
                Toggle.Value = value and true or false
                paint()
                if silent then
                    return
                end
                if opts.Callback then
                    task.spawn(opts.Callback, Toggle.Value)
                end
                for _, fn in ipairs(Toggle.Callbacks) do
                    task.spawn(fn, Toggle.Value)
                end
            end

            function Toggle:OnChanged(fn)
                table.insert(Toggle.Callbacks, fn)
                task.spawn(fn, Toggle.Value)
                return Toggle
            end

            bind(hit.MouseButton1Click, function()
                Toggle:SetValue(not Toggle.Value)
            end)

            Toggle:SetValue(opts.Default and true or false, true)
            if opts.Default then
                if opts.Callback then
                    task.spawn(opts.Callback, true)
                end
            end

            Lib.Toggles[index] = Toggle
            return Toggle
        end

        function Group:AddSlider(index, opts)
            opts = opts or {}
            local wrap = slot(44)
            attachTip(wrap, opts.Tooltip)

            local label = new("TextLabel", {
                Size = UDim2.new(1, -70, 0, 16),
                BackgroundTransparency = 1,
                Font = Fonts.Medium,
                TextSize = 13,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = opts.Text or index,
            }, wrap)

            local readout = new("TextLabel", {
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.new(1, 0, 0, 0),
                Size = UDim2.fromOffset(70, 16),
                BackgroundTransparency = 1,
                Font = Fonts.Bold,
                TextSize = 12,
                TextColor3 = Theme.Accent,
                TextXAlignment = Enum.TextXAlignment.Right,
                Text = "0",
            }, wrap)

            local track = new("Frame", {
                Position = UDim2.new(0, 0, 0, 26),
                Size = UDim2.new(1, 0, 0, 4),
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
            }, wrap)
            round(track, PILL)

            local fill = new("Frame", {
                Size = UDim2.new(0, 0, 1, 0),
                BackgroundColor3 = Theme.Accent,
                BorderSizePixel = 0,
            }, track)
            round(fill, PILL)

            local knob = new("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.new(0, 0, 0.5, 0),
                Size = UDim2.fromOffset(12, 12),
                BackgroundColor3 = Theme.Text,
                BorderSizePixel = 0,
                ZIndex = 3,
            }, track)
            round(knob, PILL)

            local minimum = opts.Min or 0
            local maximum = opts.Max or 100
            local digits = opts.Rounding or 0
            local step = 10 ^ digits

            local Slider = { Value = opts.Default or minimum, Type = "Slider", Index = index, Min = minimum, Max = maximum, Callbacks = {} }

            local function paint()
                local span = maximum - minimum
                local ratio = span > 0 and math.clamp((Slider.Value - minimum) / span, 0, 1) or 0
                fill.Size = UDim2.new(ratio, 0, 1, 0)
                knob.Position = UDim2.new(ratio, 0, 0.5, 0)
                readout.Text = tostring(Slider.Value) .. (opts.Suffix or "")
            end

            function Slider:SetValue(value, silent)
                value = tonumber(value) or minimum
                value = math.clamp(value, minimum, maximum)
                value = math.floor(value * step + 0.5) / step
                Slider.Value = value
                paint()
                if silent then
                    return
                end
                if opts.Callback then
                    task.spawn(opts.Callback, value)
                end
                for _, fn in ipairs(Slider.Callbacks) do
                    task.spawn(fn, value)
                end
            end

            function Slider:OnChanged(fn)
                table.insert(Slider.Callbacks, fn)
                task.spawn(fn, Slider.Value)
                return Slider
            end

            local sliding = false

            local function seek(x)
                local width = track.AbsoluteSize.X
                if width <= 0 then
                    return
                end
                local ratio = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
                Slider:SetValue(minimum + (maximum - minimum) * ratio)
            end

            bind(track.InputBegan, function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    sliding = true
                    glide(knob, { Size = UDim2.fromOffset(16, 16) })
                    seek(input.Position.X)
                end
            end)
            bind(UserInputService.InputEnded, function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    if sliding then
                        sliding = false
                        glide(knob, { Size = UDim2.fromOffset(12, 12) })
                    end
                end
            end)
            bind(UserInputService.InputChanged, function(input)
                if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                    seek(input.Position.X)
                end
            end)

            Slider:SetValue(opts.Default or minimum, true)
            if opts.Default ~= nil and opts.Callback then
                task.spawn(opts.Callback, Slider.Value)
            end

            Lib.Options[index] = Slider
            return Slider
        end

        function Group:AddDropdown(index, opts)
            opts = opts or {}
            local wrap = slot(0, true)
            stack(wrap, 6)
            attachTip(wrap, opts.Tooltip)

            caption(wrap, opts.Text or index)

            local button = new("TextButton", {
                Size = UDim2.new(1, 0, 0, 32),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
                Font = Fonts.Medium,
                TextSize = 13,
                TextColor3 = Theme.Text,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = "",
                AutoButtonColor = false,
                LayoutOrder = 1,
            }, wrap)
            round(button, UDim.new(0, 8))
            local edge = outline(button, Theme.Line, 1)
            pad(button, 12, 30, 0, 0)

            local arrow = new("TextLabel", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, -12, 0.5, 0),
                Size = UDim2.fromOffset(12, 12),
                BackgroundTransparency = 1,
                Font = Fonts.Bold,
                TextSize = 13,
                TextColor3 = Theme.SubText,
                Text = ">",
                Rotation = 90,
            }, button)

            local panel = new("Frame", {
                Size = UDim2.new(1, 0, 0, 0),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
                Visible = false,
                LayoutOrder = 2,
                ClipsDescendants = true,
            }, wrap)
            round(panel, UDim.new(0, 8))
            outline(panel, Theme.Line, 1)

            local scroll = new("ScrollingFrame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollBarThickness = 2,
                ScrollBarImageColor3 = Theme.Line,
                ScrollingDirection = Enum.ScrollingDirection.Y,
            }, panel)
            stack(scroll, 2)
            pad(scroll, 4, 6, 4, 4)

            local Dropdown = { Value = nil, Type = "Dropdown", Index = index, Values = opts.Values or {}, Callbacks = {}, Open = false }
            local rows = {}

            local function paint()
                button.Text = tostring(Dropdown.Value or "--")
                for value, row in pairs(rows) do
                    if value == Dropdown.Value then
                        glide(row.Frame, { BackgroundColor3 = Theme.AccentSoft })
                        glide(row.Edge, { Transparency = 0, Color = Theme.Accent })
                        glide(row.Label, { TextColor3 = Theme.Text })
                    else
                        glide(row.Frame, { BackgroundColor3 = Theme.Raised })
                        glide(row.Edge, { Transparency = 1, Color = Theme.Line })
                        glide(row.Label, { TextColor3 = Theme.SubText })
                    end
                end
            end

            function Dropdown:SetValue(value, silent)
                Dropdown.Value = value
                paint()
                if silent then
                    return
                end
                if opts.Callback then
                    task.spawn(opts.Callback, value)
                end
                for _, fn in ipairs(Dropdown.Callbacks) do
                    task.spawn(fn, value)
                end
            end

            function Dropdown:OnChanged(fn)
                table.insert(Dropdown.Callbacks, fn)
                task.spawn(fn, Dropdown.Value)
                return Dropdown
            end

            local function collapse()
                Dropdown.Open = false
                panel.Visible = false
                panel.Size = UDim2.new(1, 0, 0, 0)
                glide(arrow, { Rotation = 90 })
                glide(edge, { Color = Theme.Line })
            end

            function Dropdown:SetValues(values)
                Dropdown.Values = values or {}
                rows = {}
                for _, child in ipairs(scroll:GetChildren()) do
                    if child:IsA("TextButton") then
                        child:Destroy()
                    end
                end
                for order, value in ipairs(Dropdown.Values) do
                    local entry = new("TextButton", {
                        Size = UDim2.new(1, 0, 0, 26),
                        BackgroundColor3 = Theme.Raised,
                        BorderSizePixel = 0,
                        Font = Fonts.Medium,
                        TextSize = 13,
                        TextColor3 = Theme.SubText,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        Text = "",
                        AutoButtonColor = false,
                        LayoutOrder = order,
                    }, scroll)
                    round(entry, UDim.new(0, 6))
                    local entryEdge = outline(entry, Theme.Line, 1, 1)
                    local entryLabel = new("TextLabel", {
                        Size = UDim2.new(1, -24, 1, 0),
                        Position = UDim2.fromOffset(12, 0),
                        BackgroundTransparency = 1,
                        Font = Fonts.Medium,
                        TextSize = 13,
                        TextColor3 = Theme.SubText,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        Text = tostring(value),
                    }, entry)
                    rows[value] = { Frame = entry, Edge = entryEdge, Label = entryLabel }
                    bind(entry.MouseButton1Click, function()
                        Dropdown:SetValue(value)
                        collapse()
                    end)
                end
                paint()
            end

            bind(button.MouseButton1Click, function()
                Dropdown.Open = not Dropdown.Open
                if Dropdown.Open then
                    local height = math.clamp(#Dropdown.Values * 28 + 8, 36, 176)
                    panel.Visible = true
                    panel.Size = UDim2.new(1, 0, 0, 0)
                    glide(panel, { Size = UDim2.new(1, 0, 0, height) })
                    glide(arrow, { Rotation = 270 })
                    glide(edge, { Color = Theme.Accent })
                else
                    collapse()
                end
            end)

            Dropdown:SetValues(opts.Values or {})
            Dropdown:SetValue(opts.Default, true)
            if opts.Default ~= nil and opts.Callback then
                task.spawn(opts.Callback, opts.Default)
            end

            Lib.Options[index] = Dropdown
            return Dropdown
        end

        function Group:AddInput(index, opts)
            opts = opts or {}
            local wrap = slot(0, true)
            stack(wrap, 6)
            attachTip(wrap, opts.Tooltip)

            caption(wrap, opts.Text or index)

            local field = new("TextBox", {
                Size = UDim2.new(1, 0, 0, 32),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
                Font = Fonts.Medium,
                TextSize = 13,
                TextColor3 = Theme.Text,
                PlaceholderColor3 = Theme.Faint,
                PlaceholderText = opts.Placeholder or "",
                TextXAlignment = Enum.TextXAlignment.Left,
                ClearTextOnFocus = false,
                Text = opts.Default or "",
                LayoutOrder = 1,
            }, wrap)
            round(field, UDim.new(0, 8))
            local edge = outline(field, Theme.Line, 1)
            pad(field, 12, 12, 0, 0)

            local Input = { Value = opts.Default or "", Type = "Input", Index = index, Callbacks = {} }

            local function push(value)
                Input.Value = value
                if opts.Callback then
                    task.spawn(opts.Callback, value)
                end
                for _, fn in ipairs(Input.Callbacks) do
                    task.spawn(fn, value)
                end
            end

            function Input:SetValue(value, silent)
                value = tostring(value or "")
                field.Text = value
                if silent then
                    Input.Value = value
                    return
                end
                push(value)
            end

            function Input:OnChanged(fn)
                table.insert(Input.Callbacks, fn)
                task.spawn(fn, Input.Value)
                return Input
            end

            bind(field.Focused, function()
                glide(edge, { Color = Theme.Accent })
            end)

            bind(field.FocusLost, function()
                glide(edge, { Color = Theme.Line })
                local value = field.Text
                if opts.Numeric and value ~= "" and not tonumber(value) then
                    field.Text = Input.Value
                    return
                end
                push(value)
            end)

            if not opts.Finished then
                bind(field:GetPropertyChangedSignal("Text"), function()
                    if field:IsFocused() then
                        local value = field.Text
                        if opts.Numeric and value ~= "" and not tonumber(value) then
                            return
                        end
                        push(value)
                    end
                end)
            end

            Lib.Options[index] = Input
            return Input
        end

        function Group:AddButton(a, b)
            local text, action
            if type(a) == "table" then
                text = a.Text
                action = a.Func or a.Callback
            else
                text = a
                action = b
            end

            local wrap = slot(34)
            local button = new("TextButton", {
                Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
                Font = Fonts.Bold,
                TextSize = 13,
                TextColor3 = Theme.Text,
                Text = text or "Button",
                AutoButtonColor = false,
            }, wrap)
            round(button, UDim.new(0, 8))
            local edge = outline(button, Theme.Line, 1)

            bind(button.MouseEnter, function()
                glide(button, { BackgroundColor3 = Theme.AccentSoft })
                glide(edge, { Color = Theme.Accent })
            end)
            bind(button.MouseLeave, function()
                glide(button, { BackgroundColor3 = Theme.Raised })
                glide(edge, { Color = Theme.Line })
            end)
            bind(button.MouseButton1Click, function()
                glide(button, { BackgroundColor3 = Theme.Accent }, 0.08)
                task.delay(0.1, function()
                    glide(button, { BackgroundColor3 = Theme.Raised })
                end)
                if action then
                    task.spawn(action)
                end
            end)

            local Button = { Instance = button }
            function Button:SetText(value)
                button.Text = value
            end
            return Button
        end

        function Group:AddDivider()
            local wrap = slot(10)
            local line = new("Frame", {
                AnchorPoint = Vector2.new(0, 0.5),
                Position = UDim2.new(0, 0, 0.5, 0),
                Size = UDim2.new(1, 0, 0, 1),
                BackgroundColor3 = Theme.LineSoft,
                BorderSizePixel = 0,
            }, wrap)
            return { Instance = line }
        end

        function Group:AddLabel(text, wrapped)
            local wrap = slot(0, true)

            local label = new("TextLabel", {
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 1,
                Font = Fonts.Medium,
                TextSize = 13,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextWrapped = wrapped and true or false,
                Text = text or "",
            }, wrap)

            local Label = { Instance = label }

            function Label:SetText(value)
                label.Text = value
                return Label
            end

            function Label:AddKeyPicker(index, opts)
                opts = opts or {}
                label.Size = UDim2.new(1, -66, 0, 0)

                local chip = new("TextButton", {
                    AnchorPoint = Vector2.new(1, 0),
                    Position = UDim2.new(1, 0, 0, 0),
                    Size = UDim2.fromOffset(62, 22),
                    BackgroundColor3 = Theme.Sunken,
                    BorderSizePixel = 0,
                    Font = Fonts.Bold,
                    TextSize = 12,
                    TextColor3 = Theme.Accent,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = "",
                    AutoButtonColor = false,
                }, wrap)
                round(chip, UDim.new(0, 6))
                local edge = outline(chip, Theme.Line, 1)

                local Picker = {
                    Value = opts.Default or "",
                    Mode = opts.Mode or "Toggle",
                    Type = "KeyPicker",
                    Index = index,
                    Label = opts.Text or text or index,
                    NoUI = opts.NoUI and true or false,
                    Active = false,
                    Callbacks = {},
                    Listening = false,
                }

                local function paint()
                    chip.Text = Picker.Listening and "..." or (Picker.Value ~= "" and Picker.Value or "None")
                    glide(edge, { Color = Picker.Listening and Theme.Accent or Theme.Line })
                end

                function Picker:SetValue(value, silent)
                    if type(value) == "table" then
                        Picker.Mode = value[2] or Picker.Mode
                        value = value[1]
                    end
                    Picker.Value = tostring(value or "")
                    paint()
                    refreshKeybindList()
                    if not silent then
                        for _, fn in ipairs(Picker.Callbacks) do
                            task.spawn(fn, Picker.Value)
                        end
                    end
                end

                function Picker:OnChanged(fn)
                    table.insert(Picker.Callbacks, fn)
                    return Picker
                end

                function Picker:GetState()
                    return Picker.Active
                end

                bind(chip.MouseButton1Click, function()
                    Picker.Listening = true
                    paint()
                end)

                bind(UserInputService.InputBegan, function(input, processed)
                    if Picker.Listening then
                        if input.UserInputType == Enum.UserInputType.Keyboard then
                            Picker.Listening = false
                            if input.KeyCode == Enum.KeyCode.Backspace then
                                Picker:SetValue("")
                            else
                                Picker:SetValue(input.KeyCode.Name)
                            end
                        end
                        return
                    end
                    if processed or Picker.Value == "" then
                        return
                    end
                    if UserInputService:GetFocusedTextBox() then
                        return
                    end
                    if input.UserInputType ~= Enum.UserInputType.Keyboard then
                        return
                    end
                    if input.KeyCode.Name ~= Picker.Value then
                        return
                    end
                    if Picker.Mode == "Toggle" then
                        Picker.Active = not Picker.Active
                    else
                        Picker.Active = true
                    end
                    if opts.Callback then
                        task.spawn(opts.Callback, Picker.Active)
                    end
                end)

                bind(UserInputService.InputEnded, function(input)
                    if Picker.Mode == "Hold" and input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode.Name == Picker.Value then
                        Picker.Active = false
                        if opts.Callback then
                            task.spawn(opts.Callback, false)
                        end
                    end
                end)

                table.insert(pickers, Picker)
                Picker:SetValue(opts.Default or "", true)
                Lib.Options[index] = Picker
                return Picker
            end

            return Label
        end

        return Group
    end

    local Shell, Scale, TabRail, PageHolder, ActiveTab

    function Lib:CreateWindow(config)
        config = config or {}

        Shell = new("Frame", {
            Name = tag(),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(820, 540),
            BackgroundColor3 = Theme.Shell,
            BackgroundTransparency = 0.05,
            BorderSizePixel = 0,
            ClipsDescendants = true,
            Visible = false,
        }, Root)
        round(Shell, UDim.new(0, 16), true)
        outline(Shell, Theme.Accent, 1, 0.75)
        Scale = new("UIScale", { Scale = 1 }, Shell)

        local function refit()
            if not Scale then return end
            local view = Root.AbsoluteSize
            if view.X < 1 or view.Y < 1 then
                local camera = workspace.CurrentCamera
                view = camera and camera.ViewportSize or Vector2.new(1280, 720)
            end
            local fit = math.min(1, (view.X - 24) / 820, (view.Y - 24) / 540)
            Scale.Scale = math.clamp(math.min(Lib.DPI or 1, fit), 0.35, 2)
        end
        Lib.Refit = refit
        bind(Root:GetPropertyChangedSignal("AbsoluteSize"), refit)
        task.defer(refit)
        new("UIGradient", {
            Rotation = 90,
            Color = ColorSequence.new(Color3.fromRGB(58, 58, 58), Theme.Shell),
        }, Shell)

        local top = new("Frame", {
            Size = UDim2.new(1, 0, 0, 56),
            BackgroundTransparency = 1,
        }, Shell)
        dragify(top, Shell)

        local logo = new("ImageLabel", {
            Position = UDim2.fromOffset(18, 15),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Raised,
            BorderSizePixel = 0,
            ScaleType = Enum.ScaleType.Fit,
            Image = config.Icon and ("rbxassetid://" .. tostring(config.Icon)) or "",
        }, top)
        round(logo, PILL)
        outline(logo, Theme.Accent, 1)

        new("TextLabel", {
            Position = UDim2.fromOffset(54, 13),
            Size = UDim2.fromOffset(240, 18),
            BackgroundTransparency = 1,
            Font = Fonts.Bold,
            TextSize = 16,
            TextColor3 = Theme.Text,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = config.Title or "Menu",
        }, top)

        new("TextLabel", {
            Position = UDim2.fromOffset(54, 31),
            Size = UDim2.fromOffset(300, 14),
            BackgroundTransparency = 1,
            Font = Fonts.Medium,
            TextSize = 12,
            TextColor3 = Theme.SubText,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = config.Footer or "",
        }, top)

        local hideButton = new("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -18, 0.5, 0),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Raised,
            BorderSizePixel = 0,
            Font = Fonts.Bold,
            TextSize = 13,
            TextColor3 = Theme.SubText,
            Text = "X",
            AutoButtonColor = false,
        }, top)
        round(hideButton, UDim.new(0, 8))
        local hideEdge = outline(hideButton, Theme.Line, 1)
        bind(hideButton.MouseEnter, function()
            glide(hideButton, { BackgroundColor3 = Theme.AccentSoft })
            glide(hideEdge, { Color = Theme.Accent })
        end)
        bind(hideButton.MouseLeave, function()
            glide(hideButton, { BackgroundColor3 = Theme.Raised })
            glide(hideEdge, { Color = Theme.Line })
        end)
        bind(hideButton.MouseButton1Click, function()
            Shell.Visible = false
        end)

        local headerLine = new("Frame", {
            Position = UDim2.fromOffset(0, 56),
            Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = Color3.new(1, 1, 1),
            BorderSizePixel = 0,
        }, Shell)
        new("UIGradient", {
            Color = ColorSequence.new(Theme.Accent, Theme.LineSoft),
            Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.8) }),
        }, headerLine)

        local headNumber, headTitle, headSub

        -- Troca a cor de destaque por aba.
        -- Chrome (cabecalho, trilho, titulo da secao) e repintado a cada troca.
        -- Cada aba so e repintada na primeira visita (depois fica em cache), evitando travar.
        local function softOf(c)
            return Color3.new(c.R * 0.16, c.G * 0.16, c.B * 0.16)
        end

        local knownAccents = { Theme.Accent }
        local knownSofts = { Theme.AccentSoft }
        local pageTint = {}

        local function registerTint(accent, soft)
            for _, c in ipairs(knownAccents) do
                if c == accent then return end
            end
            table.insert(knownAccents, accent)
            table.insert(knownSofts, soft)
        end

        local function paintTree(root, skip, newA, newS)
            local function mapC(c)
                for i, a in ipairs(knownAccents) do
                    if c == a then return newA end
                    if c == knownSofts[i] then return newS end
                end
                return nil
            end

            local stack = { root }
            while #stack > 0 do
                local d = table.remove(stack)
                if d ~= skip then
                    if d:IsA("GuiObject") then
                        local n = mapC(d.BackgroundColor3)
                        if n then d.BackgroundColor3 = n end
                        if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
                            n = mapC(d.TextColor3)
                            if n then d.TextColor3 = n end
                        end
                        if d:IsA("ImageLabel") or d:IsA("ImageButton") then
                            n = mapC(d.ImageColor3)
                            if n then d.ImageColor3 = n end
                        end
                        if d:IsA("ScrollingFrame") then
                            n = mapC(d.ScrollBarImageColor3)
                            if n then d.ScrollBarImageColor3 = n end
                        end
                    elseif d:IsA("UIStroke") then
                        local n = mapC(d.Color)
                        if n then d.Color = n end
                    elseif d:IsA("UIGradient") then
                        local kps, changed = {}, false
                        for i, kp in ipairs(d.Color.Keypoints) do
                            local n = mapC(kp.Value)
                            if n then
                                changed = true
                                kps[i] = ColorSequenceKeypoint.new(kp.Time, n)
                            else
                                kps[i] = kp
                            end
                        end
                        if changed then d.Color = ColorSequence.new(kps) end
                    end
                    for _, child in ipairs(d:GetChildren()) do
                        table.insert(stack, child)
                    end
                end
            end
        end

        local function retint(newAccent, page)
            local newSoft = softOf(newAccent)
            registerTint(newAccent, newSoft)
            Theme.Accent = newAccent
            Theme.AccentSoft = newSoft
            paintTree(Shell, PageHolder, newAccent, newSoft)
            if page and pageTint[page] ~= newAccent then
                paintTree(page, nil, newAccent, newSoft)
                pageTint[page] = newAccent
            end
        end

        local body = new("Frame", {
            Position = UDim2.fromOffset(0, 57),
            Size = UDim2.new(1, 0, 1, -57),
            BackgroundTransparency = 1,
        }, Shell)

        new("Frame", {
            Position = UDim2.fromOffset(58, 0),
            Size = UDim2.new(0, 1, 1, -28),
            BackgroundColor3 = Theme.LineSoft,
            BorderSizePixel = 0,
        }, body)

        TabRail = new("ScrollingFrame", {
            Position = UDim2.fromOffset(0, 10),
            Size = UDim2.new(0, 58, 1, -38),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollBarThickness = 0,
            ScrollingDirection = Enum.ScrollingDirection.Y,
        }, body)
        stack(TabRail, 8)
        pad(TabRail, 9, 9, 0, 0)

        local sectionHead = new("Frame", {
            Position = UDim2.fromOffset(58, 0),
            Size = UDim2.new(1, -58, 0, 52),
            BackgroundTransparency = 1,
        }, body)

        headNumber = new("TextLabel", {
            Position = UDim2.fromOffset(18, 6),
            Size = UDim2.fromOffset(60, 40),
            BackgroundTransparency = 1,
            Font = Fonts.Bold,
            TextSize = 30,
            TextColor3 = Theme.Accent,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = "",
        }, sectionHead)

        headTitle = new("TextLabel", {
            Position = UDim2.fromOffset(84, 9),
            Size = UDim2.new(1, -100, 0, 20),
            BackgroundTransparency = 1,
            Font = Fonts.Bold,
            TextSize = 17,
            TextColor3 = Theme.Text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = "",
        }, sectionHead)

        headSub = new("TextLabel", {
            Position = UDim2.fromOffset(84, 30),
            Size = UDim2.new(1, -100, 0, 14),
            BackgroundTransparency = 1,
            Font = Fonts.Medium,
            TextSize = 11,
            TextColor3 = Theme.SubText,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Text = "",
        }, sectionHead)

        new("Frame", {
            Position = UDim2.fromOffset(58, 52),
            Size = UDim2.new(1, -58, 0, 1),
            BackgroundColor3 = Theme.LineSoft,
            BorderSizePixel = 0,
        }, body)

        PageHolder = new("Frame", {
            Position = UDim2.fromOffset(58, 53),
            Size = UDim2.new(1, -58, 1, -81),
            BackgroundTransparency = 1,
        }, body)

        local statusBar = new("Frame", {
            Position = UDim2.new(0, 0, 1, -28),
            Size = UDim2.new(1, 0, 0, 28),
            BackgroundColor3 = Theme.Sunken,
            BorderSizePixel = 0,
        }, body)
        new("Frame", {
            Position = UDim2.new(0, 0, 0, 0),
            Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = Theme.LineSoft,
            BorderSizePixel = 0,
        }, statusBar)
        new("TextLabel", {
            Position = UDim2.fromOffset(18, 0),
            Size = UDim2.new(0.7, 0, 1, 0),
            BackgroundTransparency = 1,
            Font = Fonts.Bold,
            TextSize = 10,
            TextColor3 = Theme.Accent,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = "SESSÃO ATIVA",
        }, statusBar)

        local minimized = false
        local fullSize = Shell.Size

        local minButton = new("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -50, 0.5, 0),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Raised,
            BorderSizePixel = 0,
            Font = Fonts.Bold,
            TextSize = 14,
            TextColor3 = Theme.SubText,
            Text = "-",
            AutoButtonColor = false,
        }, top)
        round(minButton, UDim.new(0, 8))
        local minEdge = outline(minButton, Theme.Line, 1)

        bind(minButton.MouseEnter, function()
            glide(minButton, { BackgroundColor3 = Theme.AccentSoft })
            glide(minEdge, { Color = Theme.Accent })
        end)
        bind(minButton.MouseLeave, function()
            glide(minButton, { BackgroundColor3 = Theme.Raised })
            glide(minEdge, { Color = Theme.Line })
        end)

        local function setMinimized(state)
            minimized = state and true or false
            if minButton and minButton.Parent then
                minButton.Text = minimized and "+" or "-"
            end
            if not minimized then
                body.Visible = true
            end
            glide(Shell, { Size = minimized and UDim2.new(fullSize.X.Scale, fullSize.X.Offset, 0, 56) or fullSize }, 0.22)
            if minimized then
                task.delay(0.24, function()
                    if minimized then
                        body.Visible = false
                    end
                end)
            end
        end

        bind(minButton.MouseButton1Click, function()
            setMinimized(not minimized)
        end)

        local Window = { Instance = Shell }

        function Window:SetMinimized(state)
            setMinimized(state)
        end

        function Window:IsMinimized()
            return minimized
        end

        function Window:AddTab(name, icon, accent, subtitle)
            local tint = accent or Theme.Accent
            local button = new("TextButton", {
                Size = UDim2.fromOffset(40, 40),
                BackgroundTransparency = 1,
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
                Font = Fonts.Bold,
                TextSize = 13,
                TextColor3 = Theme.SubText,
                Text = string.format("%02d", #pages + 1),
                AutoButtonColor = false,
                LayoutOrder = #pages + 1,
            }, TabRail)
            round(button, UDim.new(0, 8))

            local mark = new("Frame", {
                AnchorPoint = Vector2.new(0, 1),
                Position = UDim2.new(0, 0, 1, 0),
                Size = UDim2.new(0, 0, 0, 2),
                BackgroundColor3 = tint,
                BorderSizePixel = 0,
            }, button)

            local page = new("Frame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Visible = false,
            }, PageHolder)
            pad(page, 18, 18, 12, 0)

            local left = new("ScrollingFrame", {
                Size = UDim2.new(0.5, -7, 1, 0),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollBarThickness = 2,
                ScrollBarImageColor3 = Theme.Line,
                ScrollingDirection = Enum.ScrollingDirection.Y,
            }, page)
            stack(left, 14)
            pad(left, 2, 10, 2, 16)

            local right = new("ScrollingFrame", {
                Position = UDim2.new(0.5, 7, 0, 0),
                Size = UDim2.new(0.5, -7, 1, 0),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollBarThickness = 2,
                ScrollBarImageColor3 = Theme.Line,
                ScrollingDirection = Enum.ScrollingDirection.Y,
            }, page)
            stack(right, 14)
            pad(right, 2, 10, 2, 16)

            local Tab = { Page = page, Left = left, Right = right, Button = button }

            function Tab:Select()
                retint(tint, page)
                for _, other in ipairs(pages) do
                    other.Page.Visible = false
                    glide(other.Button, { BackgroundTransparency = 1, TextColor3 = Theme.SubText })
                end
                page.Visible = true
                glide(button, { BackgroundTransparency = 0, BackgroundColor3 = tint, TextColor3 = Color3.fromRGB(10, 10, 10) })
                headNumber.Text = button.Text
                headNumber.TextColor3 = tint
                headTitle.Text = name
                headSub.Text = subtitle or ""
                ActiveTab = Tab
            end

            local function makeBox(column, title)
                local box = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundColor3 = Theme.Panel,
                    BorderSizePixel = 0,
                    LayoutOrder = #column:GetChildren(),
                }, column)
                round(box, UDim.new(0, Lib.CornerRadius), true)
                outline(box, Theme.LineSoft, 1)
                pad(box, 16, 16, 14, 16)

                local head = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 22),
                    BackgroundTransparency = 1,
                    LayoutOrder = 0,
                }, box)

                new("TextLabel", {
                    Size = UDim2.new(1, 0, 1, 0),
                    BackgroundTransparency = 1,
                    Font = Fonts.Bold,
                    TextSize = 12,
                    TextColor3 = Theme.Accent,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = string.upper(title or ""),
                }, head)

                new("Frame", {
                    AnchorPoint = Vector2.new(0, 1),
                    Position = UDim2.new(0, 0, 1, 0),
                    Size = UDim2.new(1, 0, 0, 1),
                    BackgroundColor3 = Theme.LineSoft,
                    BorderSizePixel = 0,
                }, head)

                local body = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundTransparency = 1,
                    LayoutOrder = 1,
                }, box)
                stack(body, 12)
                pad(body, 0, 0, 10, 0)

                stack(box, 0)
                return makeGroup(body)
            end

            function Tab:AddLeftGroupbox(title)
                return makeBox(left, title)
            end

            function Tab:AddRightGroupbox(title)
                return makeBox(right, title)
            end

            bind(button.MouseButton1Click, function()
                Tab:Select()
            end)
            bind(button.MouseEnter, function()
                if ActiveTab ~= Tab then
                    glide(button, { TextColor3 = Theme.Text })
                end
            end)
            bind(button.MouseLeave, function()
                if ActiveTab ~= Tab then
                    glide(button, { TextColor3 = Theme.SubText })
                end
            end)

            table.insert(pages, { Page = page, Button = button, Edge = mark, Label = button, Mark = mark })
            if #pages == 1 then
                Tab:Select()
            end
            return Tab
        end

        function Window:SetCornerRadius(radius)
            Lib.CornerRadius = radius
            for _, corner in ipairs(panels) do
                corner.CornerRadius = UDim.new(0, radius)
            end
        end

        function Window:Toggle()
            Shell.Visible = not Shell.Visible
        end

        Lib.Window = Window
        Lib:SetNotifySide(config.NotifySide or "Right")

        Shell.Visible = true
        Shell.Size = UDim2.fromOffset(820, 500)
        glide(Shell, { Size = UDim2.fromOffset(820, 540) }, 0.28)

        return Window
    end

    bind(UserInputService.InputBegan, function(input, processed)
        if processed or Lib.Unloaded or not Shell then
            return
        end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then
            return
        end
        if UserInputService:GetFocusedTextBox() then
            return
        end
        local wanted = Lib.ToggleKeybind and Lib.ToggleKeybind.Value or Lib.DefaultToggleKey
        if wanted ~= "" and input.KeyCode.Name == wanted then
            Shell.Visible = not Shell.Visible
        end
    end)

    function Lib:SetDPIScale(percent)
        Lib.DPI = math.clamp((tonumber(percent) or 100) / 100, 0.5, 2)
        if Lib.Refit then
            Lib.Refit()
        elseif Scale then
            Scale.Scale = Lib.DPI
        end
    end

    function Lib:Unload()
        Lib.Unloaded = true
        for _, link in ipairs(conns) do
            pcall(function()
                link:Disconnect()
            end)
        end
        conns = {}

        local genv = (type(getgenv) == "function" and getgenv()) or _G
        local session = rawget(genv, "TWINHUB_SESSION") or genv.TWINHUB_SESSION
        if type(session) == "table" then
            if type(session.unhook) == "function" then
                pcall(session.unhook)
            end
            for _, link in ipairs(session.links or {}) do
                pcall(function()
                    link:Disconnect()
                end)
            end
            session.links = {}
            pcall(function()
                local tagged = {}
                for _, name in ipairs(session.tags or {}) do
                    tagged[name] = true
                end
                if not next(tagged) then return end
                local holders = {}
                if type(gethui) == "function" then
                    local reached, container = pcall(gethui)
                    if reached and container then table.insert(holders, container) end
                end
                table.insert(holders, game:GetService("CoreGui"))
                if workspace.CurrentCamera then
                    table.insert(holders, workspace.CurrentCamera)
                end
                if LocalPlayer then
                    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
                    if pg then table.insert(holders, pg) end
                end
                for _, holder in ipairs(holders) do
                    for _, child in ipairs(holder:GetChildren()) do
                        if tagged[child.Name] then
                            child:Destroy()
                        end
                    end
                end
                for _, model in ipairs(workspace:GetChildren()) do
                    if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
                        for _, child in ipairs(model:GetChildren()) do
                            if tagged[child.Name] then
                                child:Destroy()
                            end
                        end
                    end
                end
                for _, other in ipairs(Players:GetPlayers()) do
                    if other.Character then
                        for _, child in ipairs(other.Character:GetChildren()) do
                            if tagged[child.Name] then
                                child:Destroy()
                            end
                        end
                    end
                end
            end)
        end

        Root:Destroy()
    end

    local function fileApi()
        local write = rawget(_G, "writefile") or writefile
        local read = rawget(_G, "readfile") or readfile
        local list = rawget(_G, "listfiles") or listfiles
        local exists = rawget(_G, "isfile") or isfile
        local folder = rawget(_G, "isfolder") or isfolder
        local mkdir = rawget(_G, "makefolder") or makefolder
        local remove = rawget(_G, "delfile") or delfile
        if type(write) ~= "function" or type(read) ~= "function" or type(list) ~= "function" then
            return nil
        end
        return { write = write, read = read, list = list, exists = exists, folder = folder, mkdir = mkdir, remove = remove }
    end

    function Lib:SetConfigFolder(name)
        configFolder = name
    end

    local function ensureFolder(api)
        if api.folder and api.mkdir then
            if not api.folder(configFolder) then
                api.mkdir(configFolder)
            end
            if not api.folder(configFolder .. "/configs") then
                api.mkdir(configFolder .. "/configs")
            end
        end
    end

    local function collect()
        local dump = { toggles = {}, options = {} }
        for index, toggle in pairs(Lib.Toggles) do
            dump.toggles[index] = toggle.Value
        end
        for index, option in pairs(Lib.Options) do
            if option.Type == "KeyPicker" then
                dump.options[index] = { option.Value, option.Mode }
            else
                dump.options[index] = option.Value
            end
        end
        return dump
    end

    local function restore(dump)
        for index, value in pairs(dump.toggles or {}) do
            local toggle = Lib.Toggles[index]
            if toggle then
                toggle:SetValue(value)
            end
        end
        for index, value in pairs(dump.options or {}) do
            local option = Lib.Options[index]
            if option and option.SetValue then
                option:SetValue(value)
            end
        end
    end

    function Lib:SaveConfig(name)
        local api = fileApi()
        if not api or not name or name == "" then
            return false
        end
        ensureFolder(api)
        local ok, encoded = pcall(HttpService.JSONEncode, HttpService, collect())
        if not ok then
            return false
        end
        return pcall(api.write, configFolder .. "/configs/" .. name .. ".json", encoded)
    end

    function Lib:LoadConfig(name)
        local api = fileApi()
        if not api or not name or name == "" then
            return false
        end
        local ok, raw = pcall(api.read, configFolder .. "/configs/" .. name .. ".json")
        if not ok or type(raw) ~= "string" then
            return false
        end
        local parsed, dump = pcall(HttpService.JSONDecode, HttpService, raw)
        if not parsed or type(dump) ~= "table" then
            return false
        end
        restore(dump)
        return true
    end

    function Lib:ListConfigs()
        local api = fileApi()
        local found = {}
        if not api then
            return found
        end
        ensureFolder(api)
        local ok, entries = pcall(api.list, configFolder .. "/configs")
        if not ok or type(entries) ~= "table" then
            return found
        end
        for _, path in ipairs(entries) do
            local name = string.match(path, "([^/\\]+)%.json$")
            if name then
                table.insert(found, name)
            end
        end
        return found
    end

    function Lib:LoadAutoloadConfig()
        local api = fileApi()
        if not api then
            return
        end
        local ok, name = pcall(api.read, configFolder .. "/autoload.txt")
        if ok and type(name) == "string" and name ~= "" then
            Lib:LoadConfig(name)
        end
    end

    function Lib:BuildConfigSection(tab)
        local group = tab:AddRightGroupbox("Configuration")
        local api = fileApi()

        if not api then
            group:AddLabel("This executor has no file API, configs are off", true)
            return group
        end

        local nameBox = group:AddInput("ConfigName", {
            Default = "",
            Text = "Config name",
            Placeholder = "default",
        })

        local picker = group:AddDropdown("ConfigList", {
            Values = Lib:ListConfigs(),
            Default = nil,
            Text = "Saved configs",
        })

        group:AddButton({
            Text = "Create",
            Func = function()
                if Lib:SaveConfig(nameBox.Value) then
                    picker:SetValues(Lib:ListConfigs())
                    Lib:Notify("Saved config " .. nameBox.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Load",
            Func = function()
                if picker.Value and Lib:LoadConfig(picker.Value) then
                    Lib:Notify("Loaded config " .. picker.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Overwrite",
            Func = function()
                if picker.Value and Lib:SaveConfig(picker.Value) then
                    Lib:Notify("Overwrote config " .. picker.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Delete",
            Func = function()
                if picker.Value and api.remove then
                    pcall(api.remove, configFolder .. "/configs/" .. picker.Value .. ".json")
                    picker:SetValues(Lib:ListConfigs())
                    picker:SetValue(nil, true)
                    Lib:Notify("Deleted config")
                end
            end,
        })

        group:AddButton({
            Text = "Refresh list",
            Func = function()
                picker:SetValues(Lib:ListConfigs())
            end,
        })

        local autoLabel = group:AddLabel("Autoload: none", true)

        group:AddButton({
            Text = "Set as autoload",
            Func = function()
                if picker.Value then
                    pcall(api.write, configFolder .. "/autoload.txt", picker.Value)
                    autoLabel:SetText("Autoload: " .. picker.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Clear autoload",
            Func = function()
                pcall(api.write, configFolder .. "/autoload.txt", "")
                autoLabel:SetText("Autoload: none")
            end,
        })

        local ok, current = pcall(api.read, configFolder .. "/autoload.txt")
        if ok and type(current) == "string" and current ~= "" then
            autoLabel:SetText("Autoload: " .. current)
        end

        return group
    end

    return Lib
end)()

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.TWINHUB_SESSION
    if type(session) == "table" then
        session.ui = Library
    end
end

local Options = Library.Options
local Toggles = Library.Toggles

Library.ForceCheckbox = false
Library.ShowToggleFrameInKeybinds = true

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera
local _AC = require(game:GetService("ReplicatedFirst").Controllers.AnimationController)

local MARK = string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))
local MARK2 = string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.TWINHUB_SESSION
    if type(session) == "table" and type(session.tags) == "table" then
        table.insert(session.tags, MARK)
        table.insert(session.tags, MARK2)
    end
end

local function track(connection)
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.TWINHUB_SESSION
    if type(session) == "table" and type(session.links) == "table" then
        table.insert(session.links, connection)
    end
    return connection
end

local hitboxEnabled = false
local hitboxScale = 5.0
local hitboxReach = 5.0
local hitboxHooked = false
local hitboxFollow = nil
local hitboxColor = Color3.fromRGB(0, 0, 255)
local hitboxTransparency = 0.3
local hitboxBoxes = {}
local SpikeReach = { reach = 300.0, expiry = 0 }

local redirectSpikeEnabled = false
local redirectSpikeInstalled = false
local sanjuTiltEnabled = false
local sanjuTiltInstalled = false
local maxChargeEnabled = false
local maxChargeHookActive = false
local newSilentSpikeEnabled = false
local newSpikeButton = nil
local stopBallButton = nil
local aimButton = nil
local stopBallVisible = false
local aimVisible = false
local dashButton = nil
local akariDashEnabled = false
local leadFeetEnabled = false
local leadFeetButton = nil
local leadFeetLink = nil
local espJumpEnabled = false
local espHighlights = {}
local espConnections = {}
local desyncEnabled = false
local desyncConnection = nil
local autoReceiveEnabled = false
local Receive = { range = 10, lead = 0.35, stamp = 0, gap = 0.2 }
local maxServeEnabled = false
local maxServeHookActive = false
local airMovement = false
local airMovementSpeed = 16
local bodyVelocity = nil
local autoShiftLockEnabled = false
local shiftLockConnection = nil
local hitEffectEnabled = false
local selectedEffect = "SupernovaScoreEffect"
local hasFired = false
local isLocalHit = false
local hitConnection = nil
local hitConnection2 = nil
local hitRemovedConnection = nil
local playerCardEnabled = false
local selectedCard = "UltimateChampionPlayerCard"
local hasFiredCard = false
local isProcessing = false
local cardConnection = nil
local cardList = {}
local selectedJersey = "DragonTuxedoJersey"
local pickedTeam = nil
local jerseyList = {}
local selectedBallSkin = "ClassicBall"
local ballSkinList = {}
local autoSpin = false
local autoAbilitySpin = false
local desiredStyles = {}
local desiredAbilities = {}
local spinType = "Normal"
local abilitySpinType = "Normal"
local autoApplyJersey = false
local autoApplyBallSkin = false
local fakeSpikeEnabled = false
local protectEnabled = false
local tshAnimationEnabled = false
local hidariAnimationEnabled = false
local kazanaBlueEnabled = false
local kazanaWhiteEnabled = false

local originals = {}
local clones = {}
local seen = {}

local linesEnabled = false
local lineDistance = 50
local lines = {}
local lineColors = {
    Color3.fromRGB(255, 0, 0),
    Color3.fromRGB(0, 255, 0),
    Color3.fromRGB(0, 0, 255),
    Color3.fromRGB(255, 165, 0),
    Color3.fromRGB(128, 0, 128),
    Color3.fromRGB(255, 255, 0),
    Color3.fromRGB(139, 0, 0),
    Color3.fromRGB(0, 100, 0)
}

local changedProperties = {}
local oldQualityLevel
local oldSavedQualityLevel
local antilagConnections = {}

local BallService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService
local Serve = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.GameService.RF.Serve
local EffectsRemote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.Effects
local doMove = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.DoMove
local GameEffectRemote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.GameService.RE.Effect

local TWINHUB = {
    NameTag = "T\u{200B}win Protect",
    Title = "<font color='#FF0000'><b>T\u{200B}win</b></font>",
    NotifConn = nil,
    NotifConn2 = nil,
}

local function installSpikeEffectHook()
    hookNamecall("spikeEffect", function(callNext, self, method, ...)
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" then
                if tshAnimationEnabled and firesignal and LocalPlayer and LocalPlayer.Character then
                    firesignal(EffectsRemote.OnClientEvent, {
                        ["Character"] = LocalPlayer.Character,
                        ["Sound"] = "PowerSpike",
                        ["Effect"] = "SpecialChargeSpikeVFX",
                    })
                elseif hidariAnimationEnabled and firesignal and LocalPlayer and LocalPlayer.Character then
                    firesignal(EffectsRemote.OnClientEvent, {
                        ["Character"] = LocalPlayer.Character,
                        ["Sound"] = "PowerSpike",
                        ["Effect"] = "HidariSpikeVFX",
                    })
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
end

if getrawmetatable and setreadonly and getnamecallmethod then
    installSpikeEffectHook()
end

local function updateNametag()
    local player = LocalPlayer
    if player and player.Character then
        local nameTag = player.Character:FindFirstChild("Nametag")
        if nameTag then
            local label = nameTag:FindFirstChild("PlayerName")
            if label and label:IsA("TextLabel") then
                label.Text = TWINHUB.NameTag
            end
        end
    end
end

local function updateTitle()
    local player = LocalPlayer
    if player then
        player:SetAttribute("User_Title", TWINHUB.Title)
    end
end

local function processNotification(notification)
    if not notification then return end
    local player = LocalPlayer
    if not player then return end
    task.wait(0.2)
    local textLabel = notification:FindFirstChild("TextLabel")
    if not textLabel then
        for _, child in ipairs(notification:GetDescendants()) do
            if child:IsA("TextLabel") then
                textLabel = child
                break
            end
        end
    end
    if not textLabel then return end
    local text = textLabel.Text or ""
    if string.find(text, player.Name) then
        textLabel.Text = string.gsub(text, player.Name, TWINHUB.NameTag)
    end
end

local function setupNotifications()
    if TWINHUB.NotifConn then 
        TWINHUB.NotifConn:Disconnect() 
        TWINHUB.NotifConn = nil 
    end
    if TWINHUB.NotifConn2 then 
        TWINHUB.NotifConn2:Disconnect() 
        TWINHUB.NotifConn2 = nil 
    end
    local player = LocalPlayer
    if not player then return end
    local gui = player.PlayerGui:FindFirstChild("Interface")
    if gui then
        gui = gui:FindFirstChild("Persistent")
        if gui then
            gui = gui:FindFirstChild("Notifications")
        end
    end
    if not gui then return end
    for _, child in ipairs(gui:GetChildren()) do
        processNotification(child)
    end
    TWINHUB.NotifConn = gui.ChildAdded:Connect(function(child)
        task.wait(0.2)
        processNotification(child)
    end)
    TWINHUB.NotifConn2 = gui.DescendantAdded:Connect(function(child)
        if child:IsA("TextLabel") then
            task.wait(0.1)
            local player = LocalPlayer
            if not player then return end
            local text = child.Text or ""
            if string.find(text, player.Name) then
                child.Text = string.gsub(text, player.Name, TWINHUB.NameTag)
            end
        end
    end)
end

local function protectPlayerCard()
    if not protectEnabled then return end
    local playerName = string.upper(LocalPlayer.Name)
    local flashFrame = LocalPlayer.PlayerGui:FindFirstChild("Interface")
    if flashFrame then
        flashFrame = flashFrame:FindFirstChild("Persistent")
        if flashFrame then
            flashFrame = flashFrame:FindFirstChild("FlashPlayerCardFrame")
        end
    end
    if not flashFrame then return end
    local username = flashFrame:FindFirstChild("Username", true)
    if username and username:IsA("TextLabel") then
        local currentText = string.upper(username.Text or "")
        if string.find(currentText, playerName) then
            username.Text = TWINHUB.NameTag
        end
    end
end

local function fireCardRemote()
    if hasFiredCard or isProcessing then return end
    local Remote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PlayerCardService.RE.OnFlashCard
    if Remote and firesignal then
        isProcessing = true
        hasFiredCard = true
        pcall(firesignal, Remote.OnClientEvent, {
            ["PlayerCardItemId"] = selectedCard,
            ["Context"] = {
                ["Custom"] = {},
                ["PlacementId"] = "ScoredPoint",
            },
            ["Player"] = LocalPlayer,
        })
        task.wait(0.3)
        hasFiredCard = false
        isProcessing = false
    end
end

local function changePlayerCard()
    if not playerCardEnabled then return end
    if isProcessing then return end
    local flashFrame = LocalPlayer.PlayerGui.Interface.Persistent:FindFirstChild("FlashPlayerCardFrame")
    if not flashFrame then return end
    local username = flashFrame:FindFirstChild("Username", true)
    if username and username:IsA("TextLabel") then
        local currentText = string.upper(username.Text or "")
        local playerName = string.upper(LocalPlayer.Name)
        if string.find(currentText, playerName) then
            flashFrame:Destroy()
            task.wait(0.1)
            fireCardRemote()
        end
    end
end

local function enablePlayerCard()
    if cardConnection then return end
    cardConnection = LocalPlayer.PlayerGui.Interface.Persistent.ChildAdded:Connect(function(child)
        if child.Name == "FlashPlayerCardFrame" then
            task.wait(0.1)
            changePlayerCard()
        end
    end)
end

local function disablePlayerCard()
    if cardConnection then
        cardConnection:Disconnect()
        cardConnection = nil
    end
end

_G.PlayerCard = {
    Enable = enablePlayerCard,
    Disable = disablePlayerCard,
    SetCard = function(cardName)
        selectedCard = cardName
    end,
    GetCard = function()
        return selectedCard
    end
}

local function toggleProtection(state)
    protectEnabled = state
    if state then
        updateNametag()
        updateTitle()
        setupNotifications()
        protectPlayerCard()
    else
        if TWINHUB.NotifConn then TWINHUB.NotifConn:Disconnect() TWINHUB.NotifConn = nil end
        if TWINHUB.NotifConn2 then TWINHUB.NotifConn2:Disconnect() TWINHUB.NotifConn2 = nil end
        if LocalPlayer.Character then
            local char = LocalPlayer.Character
            local nameTag = char:FindFirstChild("Nametag")
            if nameTag then
                local label = nameTag:FindFirstChild("PlayerName")
                if label and label:IsA("TextLabel") then
                    label.Text = LocalPlayer.Name
                end
            end
        end
        local player = LocalPlayer
        if player then
            player:SetAttribute("User_Title", "")
        end
    end
end

track(LocalPlayer.CharacterAdded:Connect(function(character)
    if not protectEnabled then return end
    local tag = character:WaitForChild("Nametag", 10)
    if not tag or not protectEnabled or LocalPlayer.Character ~= character then return end
    tag:WaitForChild("PlayerName", 5)
    if not protectEnabled or LocalPlayer.Character ~= character then return end
    updateNametag()
    task.wait(0.5)
    if protectEnabled and LocalPlayer.Character == character then
        updateNametag()
    end
end))

local function findFirstPart(model)
    if model.PrimaryPart then
        return model.PrimaryPart
    end
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant.Name ~= MARK and descendant.Name ~= MARK2 then
            return descendant
        end
    end
    return nil
end

local function ballModels()
    local found = CollectionService:GetTagged("Ball")
    if found[1] then
        return found
    end
    local list = {}
    for _, model in ipairs(Workspace:GetChildren()) do
        if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
            list[#list + 1] = model
        end
    end
    return list
end

local function getBallId()
    for _, model in ipairs(ballModels()) do
        local id = model.Name:match("^CLIENT_BALL_(%d+)$")
        if id then
            return tonumber(id)
        end
    end
    return nil
end

local function reachableBall(params, character, reach)
    if not character then return nil end
    local closest, shortest = nil, reach or hitboxReach
    for _, model in ipairs(params.FilterDescendantsInstances) do
        if model:IsA("Model") then
            local driver = model.PrimaryPart or findFirstPart(model)
            if driver then
                for _, piece in ipairs(character:GetChildren()) do
                    if piece:IsA("BasePart") then
                        local gap = (piece.Position - driver.Position).Magnitude
                        if gap <= shortest then
                            closest, shortest = driver, gap
                        end
                    end
                end
            end
        end
    end
    return closest
end

local function installHitboxHook()
    if hitboxHooked then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("hitbox", function(callNext, self, method, ...)
        if self == Workspace and method == "GetPartsInPart" then
            local spiking = SpikeReach.expiry > os.clock()
            if hitboxEnabled or spiking then
                local probe, params = ...
                if typeof(probe) == "Instance" and typeof(params) == "OverlapParams"
                    and params.FilterType == Enum.RaycastFilterType.Include then
                    local results = callNext(self, method, probe, params)
                    if type(results) == "table" and not results[1] then
                        local driver = reachableBall(params, LocalPlayer.Character, spiking and SpikeReach.reach or hitboxReach)
                        if driver then
                            results[1] = driver
                        end
                    end
                    return results
                end
            end
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        hitboxHooked = true
    end
end

local function adornHolder()
    local camera = Workspace.CurrentCamera or Camera
    local folder = camera:FindFirstChild(MARK)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = MARK
        folder.Parent = camera
    end
    return folder
end

local function installHitboxFollow()
    if hitboxFollow then return end
    hitboxFollow = track(RunService.RenderStepped:Connect(function()
        for driver, shell in pairs(hitboxBoxes) do
            if driver.Parent and shell.Parent then
                shell.CFrame = driver.CFrame
            end
        end
    end))
end

local function updateHitboxes(scale)
    if not hitboxEnabled then return end
    hitboxReach = scale or hitboxReach
    installHitboxHook()
    installHitboxFollow()
    local folder = adornHolder()
    local live = {}
    for _, model in ipairs(ballModels()) do
        local driver = model.PrimaryPart or findFirstPart(model)
        if driver then
            live[driver] = true
            local shell = hitboxBoxes[driver]
            if not shell or not shell.Parent then
                shell = Instance.new("Part")
                shell.Name = MARK
                shell.Shape = Enum.PartType.Ball
                shell.Material = Enum.Material.ForceField
                shell.Anchored = true
                shell.CanCollide = false
                shell.CanTouch = false
                shell.CanQuery = false
                shell.CastShadow = false
                shell.Massless = true
                shell.Reflectance = 0
                shell.Parent = folder
                hitboxBoxes[driver] = shell
            end
            shell.Size = Vector3.new(2, 2, 2) * hitboxReach
            shell.CFrame = driver.CFrame
            shell.Color = hitboxColor
            shell.Transparency = hitboxTransparency
        end
    end
    for driver, shell in pairs(hitboxBoxes) do
        if not live[driver] then
            if shell.Parent then
                shell:Destroy()
            end
            hitboxBoxes[driver] = nil
        end
    end
end

local function removeHitboxes()
    for driver, shell in pairs(hitboxBoxes) do
        if shell.Parent then
            shell:Destroy()
        end
        hitboxBoxes[driver] = nil
    end
    local camera = Workspace.CurrentCamera or Camera
    local folder = camera:FindFirstChild(MARK)
    if folder then
        folder:Destroy()
    end
end

track(Workspace.ChildAdded:Connect(function(child)
    if child:IsA("Model") and child.Name:match("^CLIENT_BALL_%d+$") then
        for _ = 1, 40 do
            if findFirstPart(child) then
                break
            end
            task.wait(0.05)
        end
        if hitboxEnabled and child.Parent then
            updateHitboxes(hitboxScale)
        end
    end
end))

if hitboxEnabled then
    updateHitboxes(hitboxScale)
end

local function removeLine(player)
    local data = lines[player]
    if data then
        if data.beam then data.beam:Destroy() end
        if data.target and data.target.Parent then data.target:Destroy() end
        if data.attachment and data.attachment.Parent then data.attachment:Destroy() end
        lines[player] = nil
    end
end

local function updateLine(player, index)
    if not linesEnabled then
        removeLine(player)
        return
    end
    local character = player.Character
    if not character or not character:FindFirstChild("Head") or not character:FindFirstChild("HumanoidRootPart") then
        removeLine(player)
        return
    end
    local head = character.Head
    local rootPart = character.HumanoidRootPart
    if not lines[player] then
        local attachment = Instance.new("Attachment", head)
        local target = Instance.new("Part")
        target.Anchored = true
        target.CanCollide = false
        target.Transparency = 1
        target.Size = Vector3.new(0.1, 0.1, 0.1)
        target.Parent = Workspace
        local targetAttachment = Instance.new("Attachment", target)
        local beam = Instance.new("Beam")
        beam.Attachment0 = attachment
        beam.Attachment1 = targetAttachment
        beam.Width0 = 0.25
        beam.Width1 = 0.25
        beam.FaceCamera = true
        beam.LightEmission = 1
        beam.Transparency = NumberSequence.new(0.3)
        beam.Color = ColorSequence.new(lineColors[(index - 1) % #lineColors + 1])
        beam.Parent = head
        lines[player] = { beam = beam, target = target, attachment = attachment }
    end
    local data = lines[player]
    data.target.Position = head.Position + rootPart.CFrame.LookVector * lineDistance
end

track(RunService.RenderStepped:Connect(function()
    if linesEnabled then
        for index, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Team ~= LocalPlayer.Team then
                updateLine(player, index)
            else
                removeLine(player)
            end
        end
    else
        for player in pairs(lines) do
            removeLine(player)
        end
    end
end))

track(Players.PlayerRemoving:Connect(removeLine))

_G.Lines = {
    SetEnabled = function(value)
        linesEnabled = value
        if not value then
            for player in pairs(lines) do
                removeLine(player)
            end
        end
    end,
    SetDistance = function(value)
        lineDistance = value
    end,
    IsEnabled = function()
        return linesEnabled
    end,
    GetDistance = function()
        return lineDistance
    end
}

local function isOnGround()
    local character = LocalPlayer.Character
    if not character then return false end
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return false end
    local humanoid = character:FindFirstChild("Humanoid")
    if not humanoid then return false end
    if humanoid.FloorMaterial == Enum.Material.Air then return false end
    local state = humanoid:GetState()
    return state ~= Enum.HumanoidStateType.Freefall and state ~= Enum.HumanoidStateType.Jumping
end

local function getNearestBall()
    local nearestBall = nil
    local nearestDistance = math.huge
    local character = LocalPlayer.Character
    if not character then return nil, nil end
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return nil, nil end
    for _, model in ipairs(Workspace:GetChildren()) do
        if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
            for _, part in ipairs(model:GetDescendants()) do
                if part:IsA("BasePart") then
                    local distance = (part.Position - rootPart.Position).Magnitude
                    if distance < nearestDistance then
                        nearestDistance = distance
                        nearestBall = part
                    end
                    break
                end
            end
        end
    end
    return nearestBall, nearestDistance
end

local function ballDrift(part)
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if reached then
        local found, controller = pcall(Knit.GetController, "BallController")
        if found and type(controller) == "table" and type(controller.ActiveBalls) == "table" then
            for _, record in pairs(controller.ActiveBalls) do
                local model = record.Ball
                if model and model.Parent and model:IsAncestorOf(part) and typeof(record.Velocity) == "Vector3" then
                    return record.Velocity
                end
            end
        end
    end
    local now = os.clock()
    local spot, when = Receive.spot, Receive.when
    local same = Receive.part == part
    Receive.part, Receive.spot, Receive.when = part, part.Position, now
    if same and spot and now > when then
        return (part.Position - spot) / (now - when)
    end
    return Vector3.zero
end

local function autoReceive()
    if not autoReceiveEnabled then return end
    if not isOnGround() then return end
    local character = LocalPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return end

    local now = os.clock()
    if now - Receive.stamp < Receive.gap then return end

    local ball = getNearestBall()
    if not ball then return end

    local offset = ball.Position - rootPart.Position
    local drift = ballDrift(ball) - rootPart.AssemblyLinearVelocity
    local pull = Vector3.new(0, -Workspace.Gravity, 0)

    local closest = offset.Magnitude
    for step = 1, 12 do
        local moment = step / 12 * Receive.lead
        local reach = (offset + drift * moment + pull * (0.5 * moment * moment)).Magnitude
        if reach < closest then
            closest = reach
        end
    end

    if closest > Receive.range then return end

    local loaded, handlers = pcall(require, game:GetService("ReplicatedFirst").Controllers.GameController.Handlers)
    if loaded and type(handlers) == "table" and handlers.States then
        local states = handlers.States
        if states.IsBusy:get() or states.IsServing:get() then
            return
        end
    end

    if firesignal then
        firesignal(doMove.OnClientEvent, "Set", false, false)
        Receive.stamp = now
    end
end

track(RunService.Heartbeat:Connect(autoReceive))

track(LocalPlayer.CharacterAdded:Connect(function()
    Receive.stamp = 0
    Receive.part = nil
end))


local function enableRedirectSpike()
    redirectSpikeEnabled = true
    if redirectSpikeInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("redirectSpike", function(callNext, self, method, ...)
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" and redirectSpikeEnabled then
                local dir = Camera.CFrame.LookVector
                data.LookVector = dir
                data.Direction = dir
                if data.MoveDirection then
                    data.MoveDirection = dir
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        redirectSpikeInstalled = true
    end
end

local function disableRedirectSpike()
    redirectSpikeEnabled = false
end

local AutoCorner = {
    enabled = false,
    side = "Auto",
    reach = "All",
}

local function enableSanjuTilt()
    sanjuTiltEnabled = true
    if sanjuTiltInstalled then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("sanjuTilt", function(callNext, self, method, ...)
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" and sanjuTiltEnabled then
                if data.TiltDirection and data.LookVector then
                    local tiltDir = data.TiltDirection
                    if math.abs(tiltDir.X) > 0.01 or math.abs(tiltDir.Z) > 0.01 then
                        local lookVec = data.LookVector
                        local bend = Vector3.new(tiltDir.X, 0, tiltDir.Z)
                        data.LookVector = Vector3.new(
                            lookVec.X + bend.X * 0.3,
                            lookVec.Y,
                            lookVec.Z + bend.Z * 0.3
                        ).Unit
                        data.TiltDirection = Vector3.new(
                            tiltDir.X * 1.35,
                            tiltDir.Y,
                            tiltDir.Z * 1.35
                        )
                    end
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        sanjuTiltInstalled = true
    end
end

local function disableSanjuTilt()
    sanjuTiltEnabled = false
end

AutoCorner.physics = function()
    local reached, module = pcall(require, ReplicatedStorage.Common.Physics)
    return reached and module or nil
end

AutoCorner.bounds = function()
    local physics = AutoCorner.physics()
    if physics and physics._getCourtlines then
        local found, lines = pcall(physics._getCourtlines)
        if found and lines and lines:IsA("BasePart") then
            return lines.Position, lines.Size * 0.5, lines.Position.Y
        end
    end
    local map = Workspace:FindFirstChild("Map")
    local court = map and map:FindFirstChild("Court")
    if court then
        return court.Position, court.Size * 0.5 - Vector3.new(1, 0, 1), court.Position.Y + court.Size.Y * 0.5
    end
    return nil
end

AutoCorner.trackBall = function(ball, before, elapsed)
    if elapsed <= 0 then return end
    local drift = ball.Position - before
    AutoCorner.drift = drift / elapsed
end

AutoCorner.origin = function()
    local ball = getNearestBall()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not ball then
        return root and root.Position or Vector3.zero
    end

    local drift = AutoCorner.drift
    if not root or typeof(drift) ~= "Vector3" or drift.Magnitude < 1 then
        return ball.Position
    end

    local gap = ball.Position - root.Position
    local closing = drift - root.AssemblyLinearVelocity
    local speed = closing:Dot(closing)
    if speed < 1 then
        return ball.Position
    end

    local reach = math.clamp(-gap:Dot(closing) / speed, 0, 0.45)
    return ball.Position + drift * reach
end

local function cornerPoint()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local centre, half, surfaceY = AutoCorner.bounds()
    if not root or not centre then return nil end

    local halfX = math.max(half.X - 2, 1)
    local halfZ = math.max(half.Z - 2, 1)

    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    local netZ = net and net.Position.Z or centre.Z

    local index = LocalPlayer.Team and LocalPlayer.Team:GetAttribute("Index")
    local sign
    if index == 1 then
        sign = 1
    elseif index == 2 then
        sign = -1
    else
        sign = (root.Position.Z < netZ) and 1 or -1
    end

    local deepZ = centre.Z + sign * halfZ
    local leftX = centre.X + sign * halfX
    local rightX = centre.X - sign * halfX

    local pivot = AutoCorner.origin()
    local attackLine = half.Z / 3
    local standoff = math.abs(root.Position.Z - netZ)
    local hugging = 1 - math.clamp(standoff / attackLine, 0, 1)
    AutoCorner.lean = hugging

    local shortZ = centre.Z + sign * halfZ * 0.3
    local reach = AutoCorner.reach
    local wantsNear = reach == "Nearest" or (reach ~= "Back" and hugging > 0)

    local side = AutoCorner.side
    if side == "Left" then
        return Vector3.new(leftX, surfaceY, wantsNear and shortZ or deepZ)
    elseif side == "Right" then
        return Vector3.new(rightX, surfaceY, wantsNear and shortZ or deepZ)
    end

    local corners = {}
    if reach ~= "Nearest" then
        corners[#corners + 1] = { at = Vector3.new(leftX, surfaceY, deepZ), reward = 0 }
        corners[#corners + 1] = { at = Vector3.new(rightX, surfaceY, deepZ), reward = 0 }
    end
    if wantsNear then
        corners[#corners + 1] = { at = Vector3.new(leftX, surfaceY, shortZ), reward = 0.45 * hugging }
        corners[#corners + 1] = { at = Vector3.new(rightX, surfaceY, shortZ), reward = 0.45 * hugging }
    end

    local eye = Workspace.CurrentCamera or Camera
    local heading = eye and eye.CFrame.LookVector or root.CFrame.LookVector
    heading = Vector3.new(heading.X, 0, heading.Z)
    if heading.Magnitude < 0.01 then
        return corners[1].at
    end
    heading = heading.Unit

    local physics = AutoCorner.physics()
    local bounds = physics and physics._getCourtlines and physics._getCourtlines()

    local guards = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and (not LocalPlayer.Team or player.Team ~= LocalPlayer.Team) then
            local guardRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if guardRoot then
                guards[#guards + 1] = Vector3.new(guardRoot.Position.X, surfaceY, guardRoot.Position.Z)
            end
        end
    end

    local aligned = {}
    for _, corner in ipairs(corners) do
        local legal = true
        if bounds and physics.isPositionInCourt then
            local ok, inside = pcall(physics.isPositionInCourt, corner.at, bounds, 0, nil)
            legal = not ok or inside
        end
        if legal then
            local line = Vector3.new(corner.at.X - pivot.X, 0, corner.at.Z - pivot.Z)
            if line.Magnitude > 0.01 then
                local dot = line.Unit:Dot(heading)
                aligned[#aligned + 1] = { spot = corner.at, dot = dot, reward = corner.reward }
            end
        end
    end
    if #aligned == 0 then return corners[1].at end

    local pick
    for _, entry in ipairs(aligned) do
        if not pick or entry.dot > pick.dot then pick = entry end
    end
    local wanted = pick.spot.X >= centre.X

    local best, bestScore
    for _, entry in ipairs(aligned) do
        if (entry.spot.X >= centre.X) == wanted then
            local nearest = 60
            for _, guard in ipairs(guards) do
                local gap = (guard - entry.spot).Magnitude
                if gap < nearest then nearest = gap end
            end
            local score = math.min(nearest, 45) / 45 + entry.reward
            if not bestScore or score > bestScore then
                bestScore = score
                best = entry.spot
            end
        end
    end
    return best or pick.spot
end

AutoCorner.facing = function()
    local spot = cornerPoint()
    if not spot then return nil end
    local pivot = AutoCorner.origin()
    local flat = Vector3.new(spot.X - pivot.X, 0, spot.Z - pivot.Z)

    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root then
        local map = Workspace:FindFirstChild("Map")
        local collide = map and map:FindFirstChild("BallCollideOnly")
        local net = collide and collide:FindFirstChild("Net")
        local netZ = net and net.Position.Z
        if netZ then
            local ownSide = (root.Position.Z > netZ) and 1 or -1
            if flat.Z * ownSide >= 0 then
                flat = Vector3.new(spot.X - root.Position.X, 0, spot.Z - root.Position.Z)
            end
            if flat.Z * ownSide >= 0 then
                flat = Vector3.new(flat.X, 0, -ownSide * math.max(math.abs(flat.Z), 1))
            end
        end
    end

    if flat.Magnitude < 0.01 then return nil end
    return flat.Unit
end

AutoCorner.installAim = function()
    if AutoCorner.aimed then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("autoCornerAim", function(callNext, self, method, ...)
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = (...)
            if AutoCorner.enabled and type(data) == "table" and (data.Move == "Spike" or data.Move == "ServeSpike") then
                local steer = AutoCorner.steer
                if typeof(steer) == "Vector3" then
                    local flat = Vector3.new(steer.X, 0, steer.Z)
                    if flat.Magnitude > 0.01 then
                        flat = flat.Unit
                        local aim = (flat - Vector3.new(0, 0.35, 0)).Unit
                        data.LookVector = aim
                        data.Direction = aim
                    end
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        AutoCorner.aimed = true
    end
end

local function enableMaxCharge()
    maxChargeEnabled = true
    if maxChargeHookActive then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("maxCharge", function(callNext, self, method, ...)
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = (...)
            if type(data) == "table" and data.Move == "Spike" and maxChargeEnabled then
                data.Charge = 1.0
                data.SpecialCharge = 1.0
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        maxChargeHookActive = true
    end
end

local function disableMaxCharge()
    maxChargeEnabled = false
end

local Hush = {
    active = false,
    links = {},
    damped = {},
    paused = {},
    loud = {
        [Enum.AnimationPriority.Action] = true,
        [Enum.AnimationPriority.Action2] = true,
        [Enum.AnimationPriority.Action3] = true,
        [Enum.AnimationPriority.Action4] = true,
    },
}

Hush.gag = function(signal)
    if type(getconnections) ~= "function" then return end
    local listed, cons = pcall(getconnections, signal)
    if not listed or type(cons) ~= "table" then return end
    for _, con in ipairs(cons) do
        pcall(function()
            if con.Enabled ~= false then
                con:Disable()
                Hush.paused[#Hush.paused + 1] = con
            end
        end)
    end
end

Hush.quiet = function(inst)
    if not inst:IsA("Sound") then return end
    Hush.damped[#Hush.damped + 1] = { inst = inst, level = inst.Volume }
    pcall(function()
        inst.Volume = 0
        inst:Stop()
    end)
end

Hush.start = function()
    if Hush.active then return end
    Hush.active = true

    Hush.gag(EffectsRemote.OnClientEvent)
    Hush.gag(GameEffectRemote.OnClientEvent)

    Hush.animUntil = os.clock() + 0.2
    local character = LocalPlayer.Character
    local animator = character and character:FindFirstChildWhichIsA("Animator", true)
    if animator then
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            if Hush.loud[track.Priority] then
                pcall(track.Stop, track, 0)
            end
        end
        Hush.links[#Hush.links + 1] = animator.AnimationPlayed:Connect(function(track)
            if not Hush.active or os.clock() > Hush.animUntil then return end
            if Hush.loud[track.Priority] then
                pcall(track.Stop, track, 0)
            end
        end)
    end

    for _, root in ipairs({ Workspace, game:GetService("SoundService"), character }) do
        if root then
            Hush.links[#Hush.links + 1] = root.DescendantAdded:Connect(function(inst)
                if Hush.active then
                    Hush.quiet(inst)
                end
            end)
        end
    end
end

Hush.stop = function()
    if not Hush.active then return end
    Hush.active = false
    for _, link in ipairs(Hush.links) do
        pcall(function() link:Disconnect() end)
    end
    Hush.links = {}
    for _, con in ipairs(Hush.paused) do
        pcall(function() con:Enable() end)
    end
    Hush.paused = {}
    for _, record in ipairs(Hush.damped) do
        if record.inst.Parent then
            pcall(function() record.inst.Volume = record.level end)
        end
    end
    Hush.damped = {}
end

local function enemyAim()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local centre, half, surfaceY = AutoCorner.bounds()
    if not centre then return nil end

    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    local netZ = net and net.Position.Z or centre.Z
    local netTop = net and (net.Position.Y + net.Size.Y * 0.5) or surfaceY

    local index = LocalPlayer.Team and LocalPlayer.Team:GetAttribute("Index")
    local sign
    if index == 1 then
        sign = 1
    elseif index == 2 then
        sign = -1
    else
        sign = (root.Position.Z < netZ) and 1 or -1
    end

    local ball = getNearestBall()
    local origin = ball and ball.Position or (root.Position + Vector3.new(0, 6, 0))
    local headroom = origin.Y - netTop
    local standoff = math.max(math.abs(netZ - origin.Z), 2)
    local drop = math.clamp(0.45 * headroom / standoff, -0.05, 0.30)

    local halfZ = math.max(half.Z - 2, 1)
    local target = Vector3.new(centre.X + (origin.X - centre.X) * 0.25, surfaceY, centre.Z + sign * halfZ * 0.55)

    local flat = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
    if flat.Magnitude < 0.01 then return nil end
    return (flat.Unit - Vector3.new(0, drop, 0)).Unit
end

local Silent = { steer = nil, expiry = 0, hooked = false }

Silent.install = function()
    if Silent.hooked then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("silentSpike", function(callNext, self, method, ...)
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = (...)
            local steer = Silent.steer
            if steer ~= nil then
                if os.clock() >= Silent.expiry then
                    Silent.steer = nil
                    Silent.expiry = 0
                elseif type(data) == "table" and typeof(steer) == "Vector3" then
                    if data.Move == "Spike" or data.Move == "ServeSpike" then
                        data.LookVector = steer
                        data.Direction = steer
                        local ground = Vector3.new(steer.X, 0, steer.Z)
                        if typeof(data.TiltDirection) == "Vector3" and ground.Magnitude > 0.01 then
                            local power = Vector3.new(data.TiltDirection.X, 0, data.TiltDirection.Z).Magnitude
                            if power > 0.05 then
                                local lean = ground.Unit * power
                                data.TiltDirection = Vector3.new(lean.X, data.TiltDirection.Y, lean.Z)
                            end
                        end
                        -- one shot: the next spike the player throws must not be steered
                        Silent.steer = nil
                        Silent.expiry = 0
                    end
                end
            end
            return callNext(self, method, data)
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        Silent.hooked = true
    end
end

local function fireNewSpike()
    if not newSilentSpikeEnabled then return end
    if not firesignal then return end
    local newRemote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.DoMove
    Hush.start()
    installHitboxHook()
    SpikeReach.expiry = os.clock() + 0.3
    local dir = enemyAim() or Camera.CFrame.LookVector
    local expiry = os.clock() + 0.8
    Silent.steer = dir
    Silent.expiry = expiry
    Silent.install()
    firesignal(newRemote.OnClientEvent, "Spike", false, false, dir)
    task.spawn(function()
        task.wait(0.3)
        Hush.stop()
    end)
    task.delay(0.8, function()
        if Silent.expiry == expiry then
            Silent.steer = nil
            Silent.expiry = 0
        end
    end)
end

local function createNewSpikeButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    newSpikeButton = Instance.new("TextButton")
    newSpikeButton.Size = UDim2.new(0, 50, 0, 50)
    newSpikeButton.Position = UDim2.new(0.5, -25, 0.85, -25)
    newSpikeButton.BackgroundColor3 = Color3.fromRGB(255, 165, 0)
    newSpikeButton.Text = "Spike"
    newSpikeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    newSpikeButton.TextScaled = true
    newSpikeButton.Font = Fonts.Bold
    newSpikeButton.Parent = screenGui
    newSpikeButton.BackgroundTransparency = 0.2
    newSpikeButton.BorderSizePixel = 0
    newSpikeButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = newSpikeButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    newSpikeButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = newSpikeButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    newSpikeButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            newSpikeButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    newSpikeButton.MouseButton1Click:Connect(function()
        fireNewSpike()
    end)
    newSpikeButton.Visible = false
    return newSpikeButton
end

newSpikeButton = createNewSpikeButton()

local function enableDesync()
    if desyncConnection then return end
    local doMove = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.DoMove
    desyncConnection = UserInputService.JumpRequest:Connect(function()
        if desyncEnabled then
            task.wait(0.03)
            if firesignal then
                firesignal(doMove.OnClientEvent, "Spike", false, false)
            end
        end
    end)
    desyncEnabled = true
end

local function disableDesync()
    if desyncConnection then
        desyncConnection:Disconnect()
        desyncConnection = nil
    end
    desyncEnabled = false
end

track(UserInputService.JumpRequest:Connect(function()
    if not kazanaBlueEnabled and not kazanaWhiteEnabled then
        return
    end
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then
        return
    end
    if os.clock() - (seen.__kazanaAt or 0) < 0.35 then
        return
    end
    seen.__kazanaAt = os.clock()

    local white = kazanaWhiteEnabled
    local effectFolder = ReplicatedStorage.Assets:FindFirstChild("Effects")
    local module = effectFolder and effectFolder:FindFirstChild(white and "KazanaWhite" or "KazanaBlue")
    if not module then
        return
    end

    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        require(module)(character)
        require(ReplicatedStorage.Tools.Sound).fromName(white and "Kazana_White" or "Kazana_Blue")({})
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
end))

local function playDashEffect(direction)
    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        local Effect = require(ReplicatedStorage.Content.Effect)
        Effect:Play("KuraiDashFX")({
            Player = LocalPlayer,
            Direction = direction,
        })
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
end

local function akariDash()
    if not akariDashEnabled then return end
    local character = LocalPlayer.Character
    if not character then return end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local direction, distance = nil, 10
    local ball = getNearestBall()
    if ball then
        local flat = Vector3.new(ball.Position.X - hrp.Position.X, 0, ball.Position.Z - hrp.Position.Z)
        if flat.Magnitude > 0.01 then
            direction = flat.Unit
            distance = math.clamp(flat.Magnitude - 1, 0, 16)
        end
    end
    if not direction then
        local forward = Camera.CFrame.LookVector
        direction = Vector3.new(forward.X, 0, forward.Z).Unit
    end
    playDashEffect(direction)
    local tween = game:GetService("TweenService"):Create(hrp, TweenInfo.new(0.2, Enum.EasingStyle.Linear), {
        CFrame = CFrame.new(hrp.Position + (direction * distance)) * CFrame.Angles(0, math.rad(hrp.Orientation.Y), 0)
    })
    tween:Play()
end

local function createDashButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    dashButton = Instance.new("TextButton")
    dashButton.Size = UDim2.new(0, 50, 0, 50)
    dashButton.Position = UDim2.new(0.15, -25, 0.8, -25)
    dashButton.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
    dashButton.Text = "⚡"
    dashButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    dashButton.TextScaled = true
    dashButton.Font = Fonts.Bold
    dashButton.Parent = screenGui
    dashButton.BackgroundTransparency = 0.2
    dashButton.BorderSizePixel = 0
    dashButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = dashButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    dashButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = dashButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    dashButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            dashButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    dashButton.MouseButton1Click:Connect(akariDash)
    dashButton.Visible = false
    return dashButton
end

createDashButton()

local function stopBall()
    if not BallService then return end
    local ballId = getBallId()
    if not ballId then return end
    local lookVector = Vector3.new(0, -1, 0)
    local Interact = BallService.RF.Interact
    if Interact then
        Interact:InvokeServer({
            ["Charge"] = 1,
            ["Move"] = "Block",
            ["SpecialCharge"] = 0,
            ["TiltDirection"] = Vector3.new(-0.1260179579257965, 1, 0.992027997970581),
            ["LookVector"] = lookVector,
            ["MoveDirection"] = Vector3.new(0, 0, 0),
            ["ClientCanRunSpecial"] = false,
            ["From"] = "Client",
            ["BallId"] = ballId,
            ["Timestamp"] = tick(),
            ["CustomClient"] = {},
        })
    end
end

local function createStopBallButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    stopBallButton = Instance.new("TextButton")
    stopBallButton.Size = UDim2.new(0, 50, 0, 50)
    stopBallButton.Position = UDim2.new(0.35, -25, 0.8, -25)
    stopBallButton.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
    stopBallButton.Text = "Stop"
    stopBallButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    stopBallButton.TextScaled = true
    stopBallButton.Font = Fonts.Bold
    stopBallButton.Parent = screenGui
    stopBallButton.BackgroundTransparency = 0.2
    stopBallButton.BorderSizePixel = 0
    stopBallButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = stopBallButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    stopBallButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = stopBallButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    stopBallButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            stopBallButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    stopBallButton.MouseButton1Click:Connect(function()
        stopBall()
    end)
    stopBallButton.Visible = stopBallVisible
    return stopBallButton
end

local AutoCounter = (function()
    local ReplicatedFirst = game:GetService("ReplicatedFirst")

    local state = {
        enabled = false,
        move = "Auto",
        netRange = 9,
        lateral = 14,
        reach = 16,
        delay = 0.05,
        cooldown = 0.5,
        autoJump = true,
    }

    local handlers = nil
    local controller = nil
    local firing = false
    local lastFire = 0

    local function elevate(fn)
        local restore = getthreadidentity and getthreadidentity()
        if setthreadidentity then
            pcall(setthreadidentity, 2)
        end
        local ok = pcall(fn)
        if setthreadidentity and restore then
            pcall(setthreadidentity, restore)
        end
        return ok
    end

    local function bind()
        if handlers and controller then return true end
        elevate(function()
            handlers = require(ReplicatedFirst.Controllers.GameController.Handlers)
            controller = require(ReplicatedStorage.Packages.Knit).GetController("GameController")
        end)
        return handlers ~= nil and controller ~= nil
    end

    local function getNet()
        local tagged = CollectionService:GetTagged("Net")[1]
        if tagged and tagged:IsA("BasePart") then
            return tagged
        end
        local map = Workspace:FindFirstChild("Map")
        local collide = map and map:FindFirstChild("BallCollideOnly")
        return collide and collide:FindFirstChild("Net")
    end

    local function ownSide(root, netZ)
        local team = LocalPlayer.Team
        local index = team and team:GetAttribute("Index")
        if index == 1 then return -1 end
        if index == 2 then return 1 end
        return (root.Position.Z >= netZ) and 1 or -1
    end

    local function findThreat(root, net)
        local netZ = net.Position.Z
        local netTop = net.Position.Y + net.Size.Y * 0.5
        local side = ownSide(root, netZ)

        local myGap = (root.Position.Z - netZ) * side
        if myGap < 0 or myGap > state.netRange then return nil end

        local ball = getNearestBall()
        if not ball then return nil end
        if ball.Position.Y < netTop - 3 then return nil end
        if math.abs(ball.Position.Z - netZ) > state.netRange + 6 then return nil end
        if math.abs(ball.Position.X - root.Position.X) > state.lateral then return nil end

        local myTeam = LocalPlayer.Team
        for _, player in ipairs(Players:GetPlayers()) do
            local hostile = player ~= LocalPlayer and (myTeam == nil or player.Team ~= myTeam)
            if hostile then
                local character = player.Character
                local enemyRoot = character and character:FindFirstChild("HumanoidRootPart")
                if enemyRoot and character:GetAttribute("Jumping") then
                    local enemyGap = (enemyRoot.Position.Z - netZ) * side
                    if enemyGap < 0 and -enemyGap <= state.netRange + 4
                        and (ball.Position - enemyRoot.Position).Magnitude <= state.reach
                        and math.abs(enemyRoot.Position.X - root.Position.X) <= state.lateral then
                        return ball, netZ, side
                    end
                end
            end
        end
        return nil
    end

    local function pickMove(ball, netZ, side)
        if state.move ~= "Auto" then return state.move end
        if (ball.Position.Z - netZ) * side > 0 then return "Spike" end
        return "Block"
    end

    local function fire(move)
        if not bind() then return end
        local states = handlers.States
        if states.IsBusy:get() or states.IsStunned:get() or states.IsServing:get() then return end
        if not states.IsPlaying:get() then return end
        if ReplicatedStorage:GetAttribute("ServedByTeam") then return end

        firing = true
        task.spawn(function()
            if state.autoJump and not states.IsJumping:get() then
                elevate(function() controller:PerformJump() end)
            end
            if state.delay > 0 then
                task.wait(state.delay)
            end
            elevate(function()
                controller:DoMove({
                    ActionName = move,
                    IsAerial = true,
                    InputState = Enum.UserInputState.Begin,
                    Metadata = {},
                })
            end)
            lastFire = os.clock()
            firing = false
        end)
    end

    local function step()
        if Library.Unloaded then return end
        if not state.enabled or firing then return end
        if os.clock() - lastFire < state.cooldown then return end
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local net = getNet()
        if not net then return end
        local ball, netZ, side = findThreat(root, net)
        if not ball then return end
        fire(pickMove(ball, netZ, side))
    end

    track(RunService.Heartbeat:Connect(step))

    return { state = state }
end)()

local function getNearestTeammate()
    local nearest = nil
    local shortestDistance = math.huge
    local playerRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not playerRoot then return nil end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Team == LocalPlayer.Team then
            local character = player.Character
            if character then
                local rootPart = character:FindFirstChild("HumanoidRootPart")
                if rootPart then
                    local distance = (rootPart.Position - playerRoot.Position).Magnitude
                    if distance < shortestDistance then
                        shortestDistance = distance
                        nearest = player
                    end
                end
            end
        end
    end
    return nearest
end

local function aim()
    if not BallService then return end
    local ballId = getBallId()
    if not ballId then return end
    local nearestTeammate = getNearestTeammate()
    if not nearestTeammate then return end
    local targetRoot = nearestTeammate.Character:FindFirstChild("HumanoidRootPart")
    local playerRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not targetRoot or not playerRoot then return end
    local direction = (targetRoot.Position - playerRoot.Position).Unit
    local tiltDir = Vector3.new(direction.X, 1, direction.Z)
    local lookVec = Vector3.new(direction.X, 0, direction.Z)
    if lookVec.Magnitude > 0 then
        lookVec = lookVec.Unit
    else
        lookVec = Vector3.new(0.17569558322429657, 9.214759444375886e-08, -0.9844445586204529)
    end
    local Interact = BallService.RF.Interact
    if Interact then
        Interact:InvokeServer({
            ["Charge"] = 1,
            ["Move"] = "JumpSet",
            ["SpecialCharge"] = 0.9999996364706223,
            ["TiltDirection"] = tiltDir,
            ["LookVector"] = lookVec,
            ["MoveDirection"] = Vector3.new(0, 0, 0),
            ["ClientCanRunSpecial"] = false,
            ["From"] = "Client",
            ["Timestamp"] = tick(),
            ["BallId"] = ballId,
            ["CustomClient"] = {},
        })
    end
end

local function createAimButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    aimButton = Instance.new("TextButton")
    aimButton.Size = UDim2.new(0, 50, 0, 50)
    aimButton.Position = UDim2.new(0.65, -25, 0.8, -25)
    aimButton.BackgroundColor3 = Color3.fromRGB(50, 150, 255)
    aimButton.Text = "Aim"
    aimButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    aimButton.TextScaled = true
    aimButton.Font = Fonts.Bold
    aimButton.Parent = screenGui
    aimButton.BackgroundTransparency = 0.2
    aimButton.BorderSizePixel = 0
    aimButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = aimButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    aimButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = aimButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    aimButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            aimButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    aimButton.MouseButton1Click:Connect(function()
        aim()
    end)
    aimButton.Visible = aimVisible
    return aimButton
end

track(RunService.RenderStepped:Connect(function()
    if not airMovement then
        if bodyVelocity then
            bodyVelocity:Destroy()
            bodyVelocity = nil
        end
        return
    end

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then
        return
    end

    if not bodyVelocity or bodyVelocity.Parent ~= root then
        if bodyVelocity then
            bodyVelocity:Destroy()
        end
        bodyVelocity = Instance.new("BodyVelocity")
        bodyVelocity.Name = MARK
        bodyVelocity.MaxForce = Vector3.zero
        bodyVelocity.Velocity = Vector3.zero
        bodyVelocity.P = 12500
        bodyVelocity.Parent = root
    end

    local direction = humanoid.MoveDirection
    if direction.Magnitude == 0 then
        if seen.__controls == nil then
            local reached, controls = pcall(function()
                return require(LocalPlayer.PlayerScripts.PlayerModule):GetControls()
            end)
            seen.__controls = (reached and controls) or false
        end
        if seen.__controls then
            local read, raw = pcall(seen.__controls.GetMoveVector, seen.__controls)
            if read and typeof(raw) == "Vector3" and raw.Magnitude > 0 then
                local camera = Workspace.CurrentCamera
                if camera then
                    raw = camera.CFrame:VectorToWorldSpace(raw)
                end
                direction = Vector3.new(raw.X, 0, raw.Z)
            end
        end
    end

    if humanoid.FloorMaterial == Enum.Material.Air and direction.Magnitude > 0 then
        bodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
        bodyVelocity.Velocity = direction.Unit * airMovementSpeed
    else
        bodyVelocity.MaxForce = Vector3.zero
        bodyVelocity.Velocity = Vector3.zero
    end
end))
local function isEnemy(player)
    if player == LocalPlayer then return false end
    if not player.Team or not LocalPlayer.Team then return false end
    return player.Team ~= LocalPlayer.Team
end

local function applyESP(player)
    if not player.Character or espHighlights[player] then return end
    local tone = Color3.fromRGB(255, 72, 72)
    local highlight = Instance.new("Highlight")
    highlight.Name = MARK
    highlight.Adornee = player.Character
    highlight.FillColor = tone
    highlight.FillTransparency = 0.72
    highlight.OutlineTransparency = 0
    highlight.OutlineColor = tone
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent = player.Character
    espHighlights[player] = highlight
end

local function removeESP(player)
    if espHighlights[player] then
        espHighlights[player]:Destroy()
        espHighlights[player] = nil
    end
end

local function cleanupConnections(player)
    if espConnections[player] then
        for _, connection in pairs(espConnections[player]) do
            connection:Disconnect()
        end
        espConnections[player] = nil
    end
    removeESP(player)
end

local function setupESP(player)
    if player == LocalPlayer then return end
    local function onCharacterAdded(character)
        cleanupConnections(player)
        local humanoid = character:WaitForChild("Humanoid", 3)
        local head = character:FindFirstChild("Head")
        if not humanoid or not head then return end
        local stateConnection = humanoid.StateChanged:Connect(function(_, newState)
            if not espJumpEnabled or not isEnemy(player) then
                removeESP(player)
                return
            end
            if newState == Enum.HumanoidStateType.Jumping or newState == Enum.HumanoidStateType.Freefall then
                applyESP(player)
            elseif newState == Enum.HumanoidStateType.Landed or newState == Enum.HumanoidStateType.Running then
                removeESP(player)
            end
        end)
        local heartbeatConnection = RunService.Heartbeat:Connect(function()
            if not espJumpEnabled or not player.Character or not isEnemy(player) then
                removeESP(player)
                return
            end
            local state = humanoid:GetState()
            if state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall then
                applyESP(player)
            else
                removeESP(player)
            end
        end)
        espConnections[player] = { track(stateConnection), track(heartbeatConnection) }
    end
    if player.Character then
        onCharacterAdded(player.Character)
    end
    track(player.CharacterAdded:Connect(onCharacterAdded))
end

for _, player in ipairs(Players:GetPlayers()) do
    setupESP(player)
end
track(Players.PlayerAdded:Connect(setupESP))

local function enableMaxServe()
    maxServeEnabled = true
    if maxServeHookActive then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local hooked = hookNamecall("maxServe", function(callNext, self, method, ...)
        if self == Serve and method == "InvokeServer" and maxServeEnabled then
            local args = {...}
            args[2] = 5
            return callNext(self, method, unpack(args))
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        maxServeHookActive = true
    end
end

local function disableMaxServe()
    maxServeEnabled = false
end

local function leadFeetSlam()
    if not leadFeetEnabled then return end
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then return end
    local root = character.PrimaryPart
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return end

    local tuning = { Acceleration = -10000, TerminalVelocity = -300, Duration = 2 }
    local controller = nil

    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        local ability = require(ReplicatedStorage.Content.Ability.LeadFeet)
        if type(ability) == "table" and type(ability.Metadata) == "table" then
            tuning = ability.Metadata
        end
        controller = require(ReplicatedStorage.Packages.Knit).GetController("GameController")
        if controller then
            controller.IsBusy:set(false)
        end
        require(ReplicatedStorage.Content.Effect):Play("LeadFeetFX")({ Player = LocalPlayer })
        require(game:GetService("ReplicatedFirst").Controllers.GameController.Actions.Move.Jump).stop()
        if controller then
            controller.IsBusy:set(true)
        end
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end

    if leadFeetLink then
        leadFeetLink:Disconnect()
        leadFeetLink = nil
    end

    local expiry = os.clock() + (tuning.Duration or 2)
    leadFeetLink = RunService.Heartbeat:Connect(function(delta)
        if not root.Parent or humanoid.FloorMaterial ~= Enum.Material.Air or os.clock() >= expiry then
            if controller then
                controller.IsBusy:set(false)
            end
            if leadFeetLink then
                leadFeetLink:Disconnect()
                leadFeetLink = nil
            end
            return
        end
        local velocity = root.AssemblyLinearVelocity
        local drop = math.max(velocity.Y + (tuning.Acceleration or -10000) * delta, tuning.TerminalVelocity or -300)
        root.AssemblyLinearVelocity = Vector3.new(velocity.X, drop, velocity.Z)
    end)
end

local function createLeadFeetButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    screenGui.ResetOnSpawn = false
    leadFeetButton = Instance.new("TextButton")
    leadFeetButton.Size = UDim2.new(0, 50, 0, 50)
    leadFeetButton.Position = UDim2.new(0.25, -25, 0.8, -25)
    leadFeetButton.BackgroundColor3 = Color3.fromRGB(0, 255, 200)
    leadFeetButton.Text = "LF"
    leadFeetButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    leadFeetButton.TextScaled = true
    leadFeetButton.Font = Fonts.Bold
    leadFeetButton.Parent = screenGui
    leadFeetButton.BackgroundTransparency = 0.2
    leadFeetButton.BorderSizePixel = 0
    leadFeetButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = leadFeetButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    leadFeetButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = leadFeetButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    leadFeetButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            leadFeetButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    leadFeetButton.MouseButton1Click:Connect(leadFeetSlam)
    leadFeetButton.Visible = false
    return leadFeetButton
end

createLeadFeetButton()

local function loadJerseys()
    jerseyList = {
        "BlueOnesieJersey", "ClassicJersey", "CursedTournamentTop100Jersey", "CursedTournamentTop1Jersey", "CursedTournamentTop1KJersey", "DragonTuxedoJersey", "NeonJersey", "PajamasJersey", "PastelJersey", "PinkOnesieJersey", "PirateJersey", "RainbowJersey", "RefJersey", "SkeletonJersey", "SkeletonJerseySeason19", "SparkleTimeJersey", "T1TournamentJersey", "TournamentJersey", "TournamentTop100BeachJersey", "TournamentTop10BeachJersey", "TournamentTop1BeachJersey", "TuxedoJersey", "VampireJersey"
    }
    return jerseyList
end

loadJerseys()

local function loadBallSkins()
    ballSkinList = {
        "2026ChocolateEggBall", "2026EasterEggBall", "AcornBall", "AlienBall", "AngelHeadBall", "AngelicBall", "AngryEmojiBall", "AnimeVolleyBall", "ArrowBall", "AuroraBall", "BananaBall", "Basketball", "BeachBall", "BeachGlobeBall", "BlackBall", "BlueAndYellowBall", "BooBall", "BrainBall", "BronzeCannonBall", "BronzeCloverBall", "BronzeCoconutBall", "BronzeEggBall", "BronzeFestivalBall", "BronzeHeartBall", "BronzeOrnamentBall", "BronzeRibcageBall", "BronzeSeashellBall", "BunnyBall", "BunnyEggBall", "CakeBall", "CameraBall", "CandleBall", "CauldronBall", "CelestialOrbBall", "ChocolateBunnyHeadBall", "ChocolateCoveredBall", "ChocolateCoveredNerdBall", "ChocolateEggBall", "ChocolateHeartBall", "ChristmasLightsBall", "ClassicBall", "CloverBall", "ClownBall", "CoalBall", "CoconutBall", "CoralReefBall", "CrabBall", "CrackedBall", "CrackedEasterEggBall", "CraftyBall", "CryoFlareBall", "CursedKrakenEyeBall", "CuteKittyBall", "DarkBatBall", "DecoratedEasterEggBall", "DemonBall", "DevilBall", "DevilHeadBall", "DiamondAcornBall", "DiamondBall", "DiamondCannonBall", "DiamondCloverBall", "DiamondCoconutBall", "DiamondEggBall", "DiamondEyeBall", "DiamondFestivalBall", "DiamondHeartBall", "DiamondRibcageBall", "DiamondSantaBall", "DiamondSeashellBall", "DiamondSnowGlobeBall", "DiamondSnowmanBall", "DiscoBall", "EasterEggBall", "ElectrifiedBall", "EvilEyeBall", "FestivalBall", "FlameBall", "FlowerBall", "FlowerBlossomBall", "FourLeafCloverBall", "Frostball", "GalaxyBall", "GamerBall", "GhostBall", "GiftBall", "GingerbreadBall", "GodBall", "GoldCannonBall", "GoldCoconutBall", "GoldCoinBall", "GoldFestivalBall", "GoldHeartBall", "GoldRibcageBall", "GoldSeashellBall", "GoldenBall", "GoldenClockBall", "GoldenCloverBall", "GoldenDiamondBall", "GoldenEggBall", "GoldenPearlBall", "GoldenSkullBall", "GoldenSnowmanBall", "GoldenStarBall", "GoldenSunEggBall", "GradientBall", "HackerBall", "HamburgerBall", "HauntedBall", "HeadBall", "HeartBall", "HologramBall", "HolyHellBall", "HorseshoeBall", "HourglassBall", "IceCreamBall", "JellyfishBall", "KarasunoBall", "KareemBall", "KoiBall", "Level150Ball", "Level50Ball", "LifebuoyBall", "MagicCrystalBall", "MangoBall", "MechBall", "MoneyBall", "MonkeyBall", "MoonBall", "MoonFireBall", "NebulaBall", "NerdBall", "NewYearsDragonBall", "NinjaBall", "OrnamentBall", "OvergrownCrystalBall", "PaintSplatterBall", "PartyHatBall", "PartySunglassesBall", "PastelSwirlEggBall", "PearlBall", "PhantomBall", "PhoenixBall", "PhonkBall", "PinataBall", "PineappleBall", "PinkBall", "PinkBlossomBall", "PinkFlamingoBall", "PinkSummerHatBall", "PirateHatBall", "PixelBall", "PolyhedralBall", "PotOfGoldBall", "PotionBall", "PumpkinBall", "PurplePhoenixBall", "RainbowBall", "RainbowPrismBall", "RattlingJawBall", "ReaperBall", "RedDragonBall", "RedEyeBall", "RedGreenAndWhiteBall", "ReindeerBall", "RigBall", "RippedBall", "RubberDuckyBall", "SaturnBall", "ScarecrowBall", "ShellBall", "ShinyBunnyEggBall", "ShinyChocolateEggBall", "SilverBall", "SilverCannonBall", "SilverCloverBall", "SilverCoconutBall", "SilverEggBall", "SilverFestivalBall", "SilverHeartBall", "SilverLanternBall", "SilverMikageHeadBall", "SilverRibbonBall", "SilverRibcageBall", "SilverSeashellBall", "SilverTurkeyBall", "SlimeBall", "SnowGlobeBall", "Snowball", "SnowmanBall", "SoccerBall", "SoulBall", "SpikyBall", "SpiritBall", "StainedGlassBall", "SubspaceBall", "SummerHatBall", "SunBall", "SunglassesBall", "SuperSunBall", "TennisBall", "TigerBall", "TimeBall", "TitaniumBall", "TranslucentTurkeyBall", "TrollFaceBall", "TurkeyBall", "TuxedoBall", "UltraFastModeBall", "VIPBall", "ValentineCardBall", "WaterBall", "WhiteEggBall", "WingedBall", "WizardHatBall"
    }
    return ballSkinList
end

loadBallSkins()

local function applyJersey(id)
    local character = LocalPlayer.Character
    if not character or not character:FindFirstChild("UpperTorso") then
        return false
    end

    local jerseyFolder = ReplicatedStorage:FindFirstChild("Assets")
    jerseyFolder = jerseyFolder and jerseyFolder:FindFirstChild("Jersey")
    if not jerseyFolder then
        return false
    end

    if not seen.__jerseyHook then
        seen.__jerseyChar = character
        seen.__jerseyHook = track(LocalPlayer.CharacterAdded:Connect(function(character2)
            local oldChar = seen.__jerseyChar
            if oldChar and oldChar ~= character2 then
                originals[oldChar] = nil
            end
            seen.__jerseyChar = character2
            pickedTeam = nil
            if character2:WaitForChild("UpperTorso", 10) and autoApplyJersey then
                task.wait(1)
                applyJersey(selectedJersey)
            end
        end))
    end

    local function clearWorn()
        for _, child in ipairs(character:GetChildren()) do
            if child.Name == "JerseyFront" or child.Name == "JerseyBack"
                or child.Name == "_jerseyInstances"
                or child:IsA("Clothing") or child:IsA("ShirtGraphic") then
                child:Destroy()
            end
        end
    end

    if not autoApplyJersey then
        local backup = originals[character]
        if backup then
            clearWorn()
            for _, saved in ipairs(backup) do
                local restored = saved:Clone()
                if restored:IsA("SurfaceGui") then
                    restored.Adornee = character:FindFirstChild("UpperTorso")
                end
                restored.Parent = character
            end
            originals[character] = nil
        end
        pickedTeam = nil
        return true
    end

    if not originals[character] then
        local backup = {}
        for _, child in ipairs(character:GetChildren()) do
            if child.Name == "JerseyFront" or child.Name == "JerseyBack"
                or child:IsA("Clothing") or child:IsA("ShirtGraphic") then
                table.insert(backup, child:Clone())
            end
        end
        originals[character] = backup
    end

    local function resolveTeam()
        local worn = character:FindFirstChildOfClass("Shirt")
        if not worn then
            return nil
        end
        for _, asset in ipairs(jerseyFolder:GetChildren()) do
            for _, team in ipairs(asset:GetChildren()) do
                local shirt = team:FindFirstChild("Shirt")
                if shirt and shirt:IsA("Shirt") and shirt.ShirtTemplate == worn.ShirtTemplate then
                    return team.Name
                end
            end
        end
        return nil
    end

    local loaded, Jersey = pcall(require, ReplicatedStorage.Tools.Jersey)
    if not loaded or type(Jersey) ~= "table" or not Jersey.set then
        return false
    end

    pickedTeam = pickedTeam or resolveTeam()

    local applied, err = pcall(Jersey.set, {
        Player = LocalPlayer,
        Character = character,
        Id = id or selectedJersey,
        TeamName = pickedTeam,
    })
    if not applied then
        warn("[TWINHUB] jersey apply failed: " .. tostring(err))
        return false
    end

    pickedTeam = pickedTeam or resolveTeam()
    return true
end

local function sweep()
    local ballFolder = ReplicatedStorage:FindFirstChild("Assets")
    ballFolder = ballFolder and ballFolder:FindFirstChild("Ball")
    if not ballFolder then
        return
    end

    local function strip(model)
        local holder = clones[model]
        if holder then
            holder:Destroy()
            clones[model] = nil
        end
        local saved = originals[model]
        if saved then
            for piece, record in pairs(saved) do
                if piece.Parent then
                    pcall(function()
                        piece[record.field] = record.value
                    end)
                end
            end
            originals[model] = nil
        end
    end

    local function skin(model)
        local driver = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
        local source = ballFolder:FindFirstChild(selectedBallSkin)
        if not driver or not source then
            return
        end

        strip(model)

        local saved = {}
        local function stash(piece, field, value)
            saved[piece] = { field = field, value = piece[field] }
            piece[field] = value
        end
        for _, piece in ipairs(model:GetDescendants()) do
            if piece:IsA("BasePart") then
                if piece.Name ~= MARK then
                    stash(piece, "Transparency", 1)
                end
            elseif piece:IsA("Decal") or piece:IsA("Texture") then
                stash(piece, "Transparency", 1)
            elseif piece:IsA("Trail") or piece:IsA("ParticleEmitter") or piece:IsA("Beam") or piece:IsA("Light") or piece:IsA("Smoke") or piece:IsA("Fire") or piece:IsA("Sparkles") then
                stash(piece, "Enabled", false)
            end
        end
        originals[model] = saved

        local holder = source:Clone()
        holder.Name = MARK2
        holder.Parent = model
        local pieces = {}
        if holder:IsA("BasePart") then
            pieces[#pieces + 1] = holder
        end
        for _, candidate in ipairs(holder:GetDescendants()) do
            if candidate:IsA("BasePart") then
                pieces[#pieces + 1] = candidate
            end
        end

        local anchor = holder:IsA("Model") and holder.PrimaryPart or nil
        if not anchor then
            local bestScore
            for _, candidate in ipairs(pieces) do
                if candidate:IsA("BasePart") then
                    local vol = candidate.Size.X * candidate.Size.Y * candidate.Size.Z
                    local roundish = math.abs(candidate.Size.X - candidate.Size.Y) < 0.5 and math.abs(candidate.Size.Y - candidate.Size.Z) < 0.5
                    local score = vol
                    if candidate:IsA("Part") and candidate.Shape == Enum.PartType.Ball then
                        score = score * 6
                    elseif roundish then
                        score = score * 3
                    end
                    if not bestScore or score > bestScore then
                        bestScore = score
                        anchor = candidate
                    end
                end
            end
        end
        if anchor then
            local offset = holder:GetPivot():ToObjectSpace(anchor.CFrame)
            holder:PivotTo(driver.CFrame * offset:Inverse())
        else
            holder:PivotTo(driver.CFrame)
        end

        for _, part in ipairs(pieces) do
            part.Anchored = false
            part.CanCollide = false
            part.CanQuery = false
            part.CanTouch = false
            part.Massless = true
            local weld = Instance.new("WeldConstraint")
            weld.Part0 = driver
            weld.Part1 = part
            weld.Parent = part
        end

        clones[model] = holder
    end

    local tracked = {}
    for model in pairs(clones) do
        table.insert(tracked, model)
    end
    for _, model in ipairs(tracked) do
        strip(model)
    end

    if not autoApplyBallSkin then
        return
    end

    for _, model in ipairs(Workspace:GetChildren()) do
        if model:IsA("Model") and model.Name:match("^CLIENT_BALL_") then
            skin(model)
        end
    end

    if not seen.__ballHook then
        seen.__ballHook = Workspace.ChildAdded:Connect(function(child)
            if not autoApplyBallSkin or not child:IsA("Model") or not child.Name:match("^CLIENT_BALL_") then
                return
            end
            task.spawn(function()
                for _ = 1, 40 do
                    if child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart") then
                        break
                    end
                    task.wait(0.05)
                end
                if autoApplyBallSkin and child.Parent then
                    sweep()
                end
            end)
        end)
    end
end

local Kisuki = { enabled = false, hooked = false, charge = 1 }

Kisuki.effect = function(strong)
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then return end
    local assets = ReplicatedStorage:FindFirstChild("Assets")
    local effects = assets and assets:FindFirstChild("Effects")
    local module = effects and effects:FindFirstChild("SuperDive")
    if not module then return end

    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        task.spawn(require(module), character, { IsStrong = strong })
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
end

Kisuki.install = function()
    if Kisuki.hooked then return end
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if not reached then return end
    local found, controller = pcall(Knit.GetController, "GameController")
    if not found or type(controller) ~= "table" or type(controller.Dive) ~= "function" then return end

    local passthrough = controller.Dive
    controller.Dive = function(self, params, ...)
        if not Kisuki.enabled then
            return passthrough(self, params, ...)
        end

        local blend = math.clamp(Kisuki.charge, 0, 1)
        local styled, special = pcall(require, ReplicatedStorage.Content.Style.Kimiro.Special)
        local tuning = styled and type(special) == "table" and special.Metadata
        if type(tuning) == "table" then
            params = type(params) == "table" and params or {}
            params.MaxForce = tuning.MaxForce
            params.TimeScale = tuning.TimeScale
            params.StretchSpeedFactor = tuning.StretchSpeedFactor
            params.EasingStyle = tuning.EasingStyle
            params.Debounce = tuning.Debounce
            if not params.Target and typeof(tuning.Power) == "NumberRange" then
                local character = LocalPlayer.Character
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                local heading = humanoid and humanoid.MoveDirection or Vector3.zero
                if heading.Magnitude < 0.5 and character then
                    heading = character:GetPivot().LookVector
                end
                heading = Vector3.new(heading.X, 0, heading.Z)
                if heading.Magnitude > 0.01 then
                    local reach = tuning.Power.Min + (tuning.Power.Max - tuning.Power.Min) * blend
                    params.Target = heading.Unit * reach
                end
            end
        end

        local outcome = passthrough(self, params, ...)
        if outcome ~= nil then
            Kisuki.effect(blend >= 0.5)
        end
        return outcome
    end
    Kisuki.hooked = true
end

local Vault = { real = nil, want = {} }

Vault.mark = function(kind, on)
    Vault.want[kind] = on or nil
    if on then
        Vault.wear()
    end

    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if not reached then return end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Inventory then return end

    local held, current = pcall(function()
        return inventory.Inventory:get()
    end)
    if not held or type(current) ~= "table" then return end

    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = type(genv.TWINHUB_SESSION) == "table" and genv.TWINHUB_SESSION or nil

    if not Vault.real then
        local carried = session and session.vault or nil
        if carried and carried.inventory then
            Vault.real = carried.inventory
            Vault.realTitle = carried.title
            Vault.realEquipped = carried.equipped or {}
        else
            local snapshot = {}
            for id, count in pairs(current) do
                snapshot[id] = count
            end
            Vault.real = snapshot
            Vault.realTitle = LocalPlayer:GetAttribute("User_Title")
            local heldWorn, worn = pcall(function()
                return inventory.Equipped:get()
            end)
            local realEquipped = {}
            if heldWorn and type(worn) == "table" then
                for slot, value in pairs(worn) do
                    realEquipped[slot] = value
                end
            end
            Vault.realEquipped = realEquipped
            if session then
                session.vault = {
                    inventory = Vault.real,
                    title = Vault.realTitle,
                    equipped = Vault.realEquipped,
                }
            end
        end
    end

    local wanted = false
    for _ in pairs(Vault.want) do
        wanted = true
        break
    end
    if not wanted then
        pcall(function()
            inventory.Inventory:set(Vault.real)
        end)
        Vault.real = nil
        if session then
            session.vault = nil
        end
        return
    end

    local catalogued, Item = pcall(require, ReplicatedStorage.Content.Item)
    local entities = ReplicatedStorage.Content.Item:FindFirstChild("Entities")
    if not catalogued or not entities then return end

    local stocked = {}
    for id, count in pairs(Vault.real) do
        stocked[id] = count
    end
    for _, child in ipairs(entities:GetChildren()) do
        if child:IsA("ModuleScript") and not stocked[child.Name] then
            local read, entry = pcall(require, child)
            if read and type(entry) == "table" and entry.Type then
                for kindName in pairs(Vault.want) do
                    if entry.Type == Item.Type[kindName] then
                        stocked[child.Name] = 1
                        break
                    end
                end
            end
        end
    end
    pcall(function()
        inventory.Inventory:set(stocked)
    end)
end

Vault.typeOf = function(id)
    local module = ReplicatedStorage.Content.Item:FindFirstChild("Entities")
    module = module and module:FindFirstChild(id)
    if not module then return nil end
    local read, entry = pcall(require, module)
    if read and type(entry) == "table" and entry.Type then
        return entry.Type, entry
    end
    return nil
end

Vault.paint = function(kind, id, entry)
    local real = Vault.realEquipped or {}
    if kind == "Title" then
        pcall(function()
            local text = id and ((entry and entry.DisplayName) or id) or Vault.realTitle
            LocalPlayer:SetAttribute("User_Title", text)
        end)
    elseif kind == "ScoreEffect" then
        selectedEffect = id or real.ScoreEffect or "SupernovaScoreEffect"
    elseif kind == "Ball" then
        selectedBallSkin = id or real.Ball or "ClassicBall"
        task.spawn(function()
            pcall(sweep)
        end)
    elseif kind == "Jersey" then
        selectedJersey = id or real.Jersey or "DragonTuxedoJersey"
        pickedTeam = nil
        task.spawn(function()
            pcall(applyJersey, selectedJersey)
        end)
    elseif kind == "PlayerCard" then
        selectedCard = id or real.PlayerCard or "UltimateChampionPlayerCard"
        task.spawn(function()
            pcall(fireCardRemote)
        end)
    end
end

Vault.setSlot = function(kind, id)
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if not reached then return end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Equipped then return end
    local held, worn = pcall(function()
        return inventory.Equipped:get()
    end)
    if not held or type(worn) ~= "table" then return end
    local dressed = {}
    for slot, value in pairs(worn) do
        dressed[slot] = value
    end
    dressed[kind] = id
    pcall(function()
        inventory.Equipped:set(dressed)
    end)
end

Vault.currentSlot = function(kind)
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if not reached then return nil end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Equipped then return nil end
    local held, worn = pcall(function()
        return inventory.Equipped:get()
    end)
    if held and type(worn) == "table" then
        return worn[kind]
    end
    return nil
end

Vault.dress = function(id)
    local kind, entry = Vault.typeOf(id)
    if not kind then return false end
    if kind == "Title" or kind == "ScoreEffect" or kind == "Ball" or kind == "Jersey" or kind == "PlayerCard" then
        Vault.paint(kind, id, entry)
    elseif kind ~= "ProfileArt" then
        return false
    end
    Vault.setSlot(kind, id)
    return true
end

Vault.revert = function(kind)
    local realId = Vault.realEquipped and Vault.realEquipped[kind] or nil
    Vault.paint(kind, nil)
    Vault.setSlot(kind, realId)
end

Vault.wear = function()
    if Vault.worn then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local located, remote = pcall(function()
        return ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.InventoryService.RF.Equip
    end)
    if not located or not remote then return end

    local hooked = hookNamecall("vaultEquip", function(callNext, self, method, ...)
        if self == remote and method == "InvokeServer" then
            local id = (...)
            if type(id) == "string" and Vault.real then
                local kind, entry = Vault.typeOf(id)
                if not Vault.real[id] then
                    if kind and Vault.currentSlot(kind) == id then
                        Vault.revert(kind)
                        return true
                    end
                    Vault.dress(id)
                    return true
                elseif kind then
                    Vault.paint(kind, id, entry)
                end
            end
        end
        return callNext(self, method, ...)
    end)
    if hooked then
        Vault.worn = true
    end
end

local Landing = {
    enabled = false,
    marker = nil,
    label = nil,
    tracked = nil,
    last = nil,
    stamp = 0,
    drift = Vector3.zero,
}

Landing.clear = function()
    if Landing.marker then
        Landing.marker:Destroy()
        Landing.marker = nil
        Landing.label = nil
    end
    Landing.tracked = nil
    Landing.last = nil
    Landing.drift = Vector3.zero
end

Landing.build = function()
    local disc = Instance.new("Part")
    disc.Name = MARK
    disc.Shape = Enum.PartType.Cylinder
    disc.Size = Vector3.new(0.2, 7, 7)
    disc.Anchored = true
    disc.CanCollide = false
    disc.CanQuery = false
    disc.CanTouch = false
    disc.Material = Enum.Material.Neon
    disc.Transparency = 0.35
    disc.CastShadow = false
    disc.Parent = Camera

    local board = Instance.new("BillboardGui")
    board.Size = UDim2.new(0, 90, 0, 30)
    board.StudsOffset = Vector3.new(0, 4, 0)
    board.AlwaysOnTop = true
    board.Parent = disc

    local text = Instance.new("TextLabel")
    text.Size = UDim2.fromScale(1, 1)
    text.BackgroundTransparency = 1
    text.TextScaled = true
    text.Font = Fonts.Bold
    text.TextStrokeTransparency = 0
    text.Parent = board

    Landing.marker = disc
    Landing.label = text
end

Landing.gravity = function()
    local pulled, value = pcall(function()
        local Game = require(ReplicatedStorage.Configuration.Game)
        local State = require(ReplicatedStorage.Common.State)
        return State.get(ReplicatedStorage, State.Id.Modifier, "BallGravity", Game.Physics.Gravity)
    end)
    if pulled and type(value) == "number" and value > 0 then
        return value
    end
    return 17
end

Landing.velocity = function(part)
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if reached then
        local found, controller = pcall(Knit.GetController, "BallController")
        if found and type(controller) == "table" and type(controller.ActiveBalls) == "table" then
            for _, record in pairs(controller.ActiveBalls) do
                local model = record.Ball
                if model and model.Parent and model:IsAncestorOf(part) and typeof(record.Velocity) == "Vector3" then
                    return record.Velocity
                end
            end
        end
    end
    return Landing.drift
end

Landing.solve = function(pos, vel, gravity, floorY)
    local drop = pos.Y - floorY
    if drop < 0 then return nil end
    local disc = vel.Y * vel.Y + 2 * gravity * drop
    if disc < 0 then return nil end
    local flight = (vel.Y + math.sqrt(disc)) / gravity
    if flight ~= flight or flight <= 0 or flight > 15 then return nil end
    return flight
end

Landing.netHit = function(pos, vel, gravity, flight)
    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    if not net then return false end
    local netZ = net.Position.Z
    local gap = netZ - pos.Z
    if math.abs(vel.Z) < 0.01 then return false end
    local moment = gap / vel.Z
    if moment <= 0 or moment >= flight then return false end
    local height = pos.Y + vel.Y * moment - 0.5 * gravity * moment * moment
    local across = pos.X + vel.X * moment
    local top = net.Position.Y + net.Size.Y * 0.5
    local base = net.Position.Y - net.Size.Y * 0.5
    if height > top or height < base then return false end
    return math.abs(across - net.Position.X) <= net.Size.X * 0.5
end

Landing.predict = function(ball)
    local reached, module = pcall(require, ReplicatedStorage.Common.Physics)
    if not reached then return nil end

    local gravity = Landing.gravity()
    local pos = ball.Position
    local vel = Landing.velocity(ball)
    if typeof(vel) ~= "Vector3" then return nil end

    local floorY = module.LastFloorHeight
    if not floorY then
        local found, height = pcall(module.calculateFloorHeight, pos, true)
        floorY = found and height or nil
    end
    if not floorY then return nil end

    local flight = Landing.solve(pos, vel, gravity, floorY)
    if not flight then return nil end

    local spot = Vector3.new(pos.X + vel.X * flight, floorY, pos.Z + vel.Z * flight)
    local probed, ground = pcall(module.calculateFloorHeight, Vector3.new(spot.X, pos.Y, spot.Z), true)
    if probed and type(ground) == "number" and math.abs(ground - floorY) > 0.05 then
        local refined = Landing.solve(pos, vel, gravity, ground)
        if refined then
            flight = refined
            spot = Vector3.new(pos.X + vel.X * flight, ground, pos.Z + vel.Z * flight)
        end
    end

    return spot, module, flight, Landing.netHit(pos, vel, gravity, flight)
end

track(RunService.RenderStepped:Connect(function()
    if not Landing.enabled then
        if Landing.marker then Landing.clear() end
        return
    end

    local ball = getNearestBall()
    if not ball then
        if Landing.marker then Landing.marker.Transparency = 1 end
        Landing.last = nil
        return
    end

    local now = os.clock()
    if Landing.tracked == ball and Landing.last and now > Landing.stamp then
        Landing.drift = (ball.Position - Landing.last) / (now - Landing.stamp)
    end
    Landing.tracked = ball
    Landing.last = ball.Position
    Landing.stamp = now

    local spot, physics, flight, netted = Landing.predict(ball)
    if not spot then
        if Landing.marker then Landing.marker.Transparency = 1 end
        return
    end

    if not Landing.marker then Landing.build() end
    local bounds = physics._getCourtlines and physics._getCourtlines()
    local inside = true
    if bounds and physics.isPositionInCourt then
        local ok, verdict = pcall(physics.isPositionInCourt, spot, nil, ball.Size.X * 0.5, nil)
        inside = not ok or verdict
    end

    local tone, verdictText
    if netted then
        tone = Color3.fromRGB(250, 180, 40)
        verdictText = "NET"
    elseif inside then
        tone = Color3.fromRGB(60, 220, 90)
        verdictText = "IN"
    else
        tone = Color3.fromRGB(235, 60, 60)
        verdictText = "OUT"
    end

    local urgency = math.clamp(1 - flight / 2, 0, 1)
    local span = 6 + urgency * 3
    Landing.marker.Size = Vector3.new(0.2, span, span)
    Landing.marker.Transparency = 0.35 - urgency * 0.15
    Landing.marker.Color = tone
    Landing.marker.CFrame = CFrame.new(spot + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
    Landing.label.Text = verdictText .. "  " .. string.format("%.1fs", flight)
    Landing.label.TextColor3 = tone
end))

local effectList = {}
local function loadEffects()
    effectList = {
        "2026ScoreEffect", "AtomicExplosionScoreEffect", "AuroraScoreEffect", "BallPortalScoreEffect", "BananaSlipScoreEffect", "BeachSpiralScoreEffect", "BeachSplashScoreEffect", "BeatOfMadnessScoreEffect", "BinaryScoreEffect", "BlackHoleScoreEffect", "BloodMoonScoreEffect", "BlueHeartScoreEffect", "BotFaceEmojiScoreEffect", "BubbleScoreEffect", "BunnyHopScoreEffect", "CandyCaneScoreEffect", "CandyCrunchScoreEffect", "CannonBallRainScoreEffect", "CauldronSplashScoreEffect", "ChickScoreEffect", "ChocolateBeamScoreEffect", "ChocolateEggHatchingScoreEffect", "ChocolateSpiralScoreEffect", "ChocolateSplashScoreEffect", "CloudburstScoreEffect", "ColonThreeScoreEffect", "ColorfulFireScoreEffect", "CombiningHeartsScoreEffect", "ConfettiBurstScoreEffect", "CookieSplashScoreEffect", "CoolBunnyScoreEffect", "CoralScoreEffect", "CosmicSpiralScoreEffect", "CrabBeamScoreEffect", "CrabScurryScoreEffect", "CryoFlareScoreEffect", "CursedCrateScoreEffect", "CursedScoreEffect", "CyberWaveScoreEffect", "DarkStarScoreEffect", "DiamondScoreEffect", "DivineStrikeScoreEffect", "DynamiteScoreEffect", "EasterBeamScoreEffect", "EasterEggBasketScoreEffect", "EasterSwirlScoreEffect", "EggHatchScoreEffect", "EggMeteorScoreEffect", "EggRainScoreEffect", "ElectricScoreEffect", "EverybodyDanceScoreEffect", "FallingAcornScoreEffect", "FallingAnchorScoreEffect", "FallingAnvilScoreEffect", "FallingPianoScoreEffect", "FishExplosionScoreEffect", "FistSlamScoreEffect", "FlameScoreEffect", "FlamethrowerScoreEffect", "FloppyFishScoreEffect", "FountainScoreEffect", "FourLeafCloverSpiralScoreEffect", "GenieLampScoreEffect", "GhostVortexScoreEffect", "GiantEggDropScoreEffect", "GiantPlayerScoreEffect", "GiantSoccerKickScoreEffect", "GiantTongueScoreEffect", "GlowStickDanceScoreEffect", "GobbleStormScoreEffect", "GoldCoinPopScoreEffect", "GoldScoreEffect", "GoldenConfettiBurstScoreEffect", "GoldenEggPopScoreEffect", "GoldenWaveScoreEffect", "GravyWaveScoreEffect", "GreenEnergyScoreEffect", "GroundCrackScoreEffect", "HakkaScoreEffect", "HeartBeamScoreEffect", "HeartBubbleScoreEffect", "HeartScoreEffect", "HoneyScoreEffect", "IceCreamScoreEffect", "IceScoreEffect", "JohnDoeScoreEffect", "KittySpiralScoreEffect", "KrakenPullScoreEffect", "LaughingScoreEffect", "LavaSplashScoreEffect", "LeafExplosionScoreEffect", "Level100ScoreEffect", "Level200ScoreEffect", "LightShowScoreEffect", "LightningStrikeScoreEffect", "LuckyCloverScoreEffect", "LuckyStrikeScoreEffect", "MagicBurstScoreEffect", "MegaSunbeamScoreEffect", "MetaBlastScoreEffect", "MeteorScoreEffect", "MoneyExplosionScoreEffect", "MoonlightBeamScoreEffect", "MusicNoteStormScoreEffect", "NewYearsWrathScoreEffect", "NinjaStarScoreEffect", "NorthStarScoreEffect", "NukeScoreEffect", "OceanicSpiralScoreEffect", "PalmTreeHammockScoreEffect", "PastelRainbowScoreEffect", "PastelSwirlScoreEffect", "PineappleScoreEffect", "PinkCosmicSpiralScoreEffect", "PinkHeartScoreEffect", "PixelExplosionScoreEffect", "PlayerBubbleScoreEffect", "PlushieScoreEffect", "PotExplosionScoreEffect", "PotionSplashScoreEffect", "PumpkinPieBurstScoreEffect", "PumpkinSmashScoreEffect", "RainbowScoreEffect", "RainbowStarScoreEffect", "RainbowStrikeScoreEffect", "RandomFavoriteScoreEffect", "RankedWinsScoreEffect", "RedDragonScoreEffect", "RosePetalScoreEffect", "SantasWrathScoreEffect", "SeaCreatureExplosionScoreEffect", "Season0ProScoreEffect", "Season10ProScoreEffect", "Season11ProScoreEffect", "Season12ProScoreEffect", "Season13ProScoreEffect", "Season14ProScoreEffect", "Season15ProScoreEffect", "Season16ProScoreEffect", "Season17ProScoreEffect", "Season18ProScoreEffect", "Season19ProScoreEffect", "Season1ProScoreEffect", "Season2ProScoreEffect", "Season3ProScoreEffect", "Season4ProScoreEffect", "Season5ProScoreEffect", "Season6ProScoreEffect", "Season7ProScoreEffect", "Season8ProScoreEffect", "Season9ProScoreEffect", "ShockwaveBlastScoreEffect", "SixSeven2ScoreEffect", "SixSevenScoreEffect", "SkeletonGrabScoreEffect", "SkullScoreEffect", "SlimeSplashScoreEffect", "SnowTornadoScoreEffect", "SpellCasterScoreEffect", "SpiderInfestationScoreEffect", "SpiritExplosionScoreEffect", "SpringSunScoreEffect", "StPatricksBurstScoreEffect", "StormyWaveScoreEffect", "StrobeLightScoreEffect", "SupernovaScoreEffect", "TapDancerScoreEffect", "ThunderstormScoreEffect", "TimeStopperEasterScoreEffect", "TimeStopperScoreEffect", "TongueScoreEffect", "TrampolineScoreEffect", "TreasureChestScoreEffect", "TsunamiScoreEffect", "VioletBeamScoreEffect", "WaterSplashScoreEffect", "WatermelonSmashScoreEffect", "WhirlpoolScoreEffect", "WindBurstScoreEffect", "WolfEmojiScoreEffect", "XDScoreEffect", "XylophoneScoreEffect"
    }
    table.sort(effectList)
    return effectList
end

effectList = loadEffects()

local cardList = {}
local function loadCards()
    cardList = {}
    local ItemEntities = ReplicatedStorage.Content.Item.Entities
    if ItemEntities then
        for _, child in ipairs(ItemEntities:GetChildren()) do
            if child:IsA("ModuleScript") then
                local name = child.Name
                if string.match(name, "Card") or string.match(name, "PlayerCard") then
                    table.insert(cardList, name)
                end
            end
        end
    end
    table.sort(cardList)
    if #cardList == 0 then
        table.insert(cardList, "ContentCreatorPlayerCard")
    end
    return cardList
end

cardList = loadCards()

local function enableHitEffect()
    if hitConnection then return end
    hasFired = false
    isLocalHit = false
    local lastHitTime = 0
    local Remote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.HitGround
    Remote.OnClientEvent:Connect(function(...)
        local args = {...}
        local myName = LocalPlayer.Name
        for _, val in pairs(args) do
            if tostring(val) == myName then
                isLocalHit = true
                break
            end
        end
    end)
    local function fireHitRemote(hitPos)
        if hasFired then return end
        if not isLocalHit then return end
        if not hitEffectEnabled then return end
        if os.clock() - lastHitTime <= 0.5 then return end
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if root and root.AssemblyLinearVelocity.Magnitude > 50 then return end
        lastHitTime = os.clock()
        hasFired = true
        local myUsername = LocalPlayer.Name
        local targetObject = workspace:FindFirstChild(myUsername) or workspace:FindFirstChild("uwuwuwiiwuw6")
        local effectId = selectedEffect
        local hardHit = true
        if effectId == "GroundHit1" or effectId == "GroundHit2" then
            hardHit = effectId == "GroundHit2"
            effectId = nil
        end
        if firesignal then
            firesignal(Remote.OnClientEvent, table.unpack({
                hitPos,
                hardHit,
                false,
                5,
                effectId,
                targetObject,
                Vector3.new(-0.000002088591600113432, 1, -0.000004710930170404026)
            }, 1, 7))
        end
        task.wait(0.5)
        hasFired = false
        isLocalHit = false
    end
    hitConnection = workspace.ChildAdded:Connect(function(child)
        if child.Name == "HitIndicator" then
            if child.Color == Color3.fromRGB(0, 255, 0) then
                fireHitRemote(child.Position)
            end
        end
    end)
    hitConnection2 = workspace.DescendantAdded:Connect(function(child)
        if child.Name == "HitIndicator" and child:IsA("BasePart") then
            if child.Color == Color3.fromRGB(0, 255, 0) then
                fireHitRemote(child.Position)
            end
        end
    end)
    hitRemovedConnection = workspace.DescendantRemoving:Connect(function(child)
        if child.Name == "HitIndicator" then
            hasFired = false
            isLocalHit = false
        end
    end)
end

local function setupCharacter(character)
    local humanoid = character:WaitForChild("Humanoid")
    local rootPart = character:WaitForChild("HumanoidRootPart")
    
    if shiftLockConnection then
        shiftLockConnection:Disconnect()
        shiftLockConnection = nil
    end

    shiftLockConnection = humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
        if humanoid.Jump and (autoShiftLockEnabled or AutoCorner.enabled) then
            task.defer(function()
                local tracked = AutoCorner.enabled and getNearestBall()
                local before = tracked and tracked.Position
                local stamp = os.clock()
                task.wait(0.03)
                if tracked and before and tracked.Parent then
                    AutoCorner.trackBall(tracked, before, os.clock() - stamp)
                end
                local lookVector = AutoCorner.enabled and AutoCorner.facing()
                if not lookVector and autoShiftLockEnabled then
                    lookVector = Vector3.new(Camera.CFrame.LookVector.X, 0, Camera.CFrame.LookVector.Z)
                end
                if lookVector and lookVector.Magnitude > 0 then
                    AutoCorner.steer = lookVector
                    if autoShiftLockEnabled or AutoCorner.enabled then
                        rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + lookVector.Unit)
                        humanoid.AutoRotate = false
                    end
                end
            end)
        else
            humanoid.AutoRotate = false
        end
    end)
end

local function toggleShiftLock(state)
    autoShiftLockEnabled = state
    if not state then
        local char = LocalPlayer.Character
        if char then
            local humanoid = char:FindFirstChild("Humanoid")
            if humanoid then
                humanoid.AutoRotate = false
            end
        end
    end
end

if LocalPlayer.Character then
    setupCharacter(LocalPlayer.Character)
end
track(LocalPlayer.CharacterAdded:Connect(setupCharacter))

local function doFakeSpike()
    if not fakeSpikeEnabled then return end
    local char = LocalPlayer.Character
    if not char then return end
    
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end

    if _AC and _AC.PlayAnimation then
        hum.Jump = true
        _AC:PlayAnimation("SpikeJump")

        task.delay(0.28, function()
            _AC:PlayAnimation("Spike")
        end)
    end
end

track(UserInputService.JumpRequest:Connect(function()
    if fakeSpikeEnabled then
        doFakeSpike()
    end
end))

local function startAutoSpin()
    coroutine.wrap(function()
        while autoSpin do
            local currentStyle = LocalPlayer.PlayerGui.Interface.Lobby.Styles.TopPanel.DisplayName.Text
            for _, style in ipairs(desiredStyles) do
                if currentStyle == style then
                    autoSpin = false
                    return
                end
            end
            local args = { [1] = (spinType == "Lucky") }
            local StyleService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.StyleService
            if StyleService then
                local RF = StyleService:FindFirstChild("RF")
                if RF then
                    local Roll = RF:FindFirstChild("Roll")
                    if Roll then
                        Roll:InvokeServer(unpack(args))
                    end
                end
            end
            task.wait(0)
        end
    end)()
end

local function startAutoAbilitySpin()
    coroutine.wrap(function()
        while autoAbilitySpin do
            local currentAbility = LocalPlayer.PlayerGui.Interface.Lobby.Abilities.TopPanel.DisplayName.Text
            for _, ability in ipairs(desiredAbilities) do
                if currentAbility == ability then
                    autoAbilitySpin = false
                    return
                end
            end
            local args = { [1] = (abilitySpinType == "Lucky") }
            local AbilityService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.AbilityService
            if AbilityService then
                local RF = AbilityService:FindFirstChild("RF")
                if RF then
                    local Roll = RF:FindFirstChild("Roll")
                    if Roll then
                        Roll:InvokeServer(unpack(args))
                    end
                end
            end
            task.wait(0)
        end
    end)()
end

local function enableAntiLag()
    local function safeGet(instance, propertyName)
        local reached, value = pcall(function()
            return instance[propertyName]
        end)
        if reached then
            return value
        end
        return nil
    end

    local function safeSet(instance, propertyName, value)
        instance[propertyName] = value
    end

    local function rememberProperty(instance, propertyName)
        if not instance then return end
        local data = changedProperties[instance]
        if not data then
            data = {}
            changedProperties[instance] = data
        end
        if data[propertyName] == nil then
            local current = safeGet(instance, propertyName)
            if current == nil then return false end
            data[propertyName] = current
        end
        return true
    end

    local function rememberAndSet(instance, propertyName, value)
        if not instance then return end
        if not rememberProperty(instance, propertyName) then return end
        safeSet(instance, propertyName, value)
    end

    local function shouldSkip(instance)
        if not instance then return true end
        local character = LocalPlayer.Character
        if character and instance:IsDescendantOf(character) then
            return true
        end
        return false
    end

    local function optimizeInstance(instance)
        if shouldSkip(instance) then return end
        
        if instance:IsA("BasePart") then
            rememberAndSet(instance, "Material", Enum.Material.SmoothPlastic)
            rememberAndSet(instance, "Reflectance", 0)
            rememberAndSet(instance, "CastShadow", false)
            if instance:IsA("MeshPart") then
                rememberAndSet(instance, "RenderFidelity", Enum.RenderFidelity.Performance)
                rememberAndSet(instance, "TextureID", "")
            end
        elseif instance:IsA("Decal") or instance:IsA("Texture") then
            rememberAndSet(instance, "Transparency", 1)
        elseif instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam") or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles") then
            rememberAndSet(instance, "Enabled", false)
        elseif instance:IsA("PointLight") or instance:IsA("SpotLight") or instance:IsA("SurfaceLight") then
            rememberAndSet(instance, "Enabled", false)
        elseif instance:IsA("SpecialMesh") then
            rememberAndSet(instance, "TextureId", "")
        elseif instance:IsA("SurfaceAppearance") then
            rememberAndSet(instance, "ColorMap", "")
            rememberAndSet(instance, "MetalnessMap", "")
            rememberAndSet(instance, "NormalMap", "")
            rememberAndSet(instance, "RoughnessMap", "")
        end
    end

    local function optimizeLighting()
        rememberAndSet(Lighting, "Technology", Enum.Technology.Compatibility)
        rememberAndSet(Lighting, "GlobalShadows", false)
        rememberAndSet(Lighting, "FogEnd", 1e9)
        rememberAndSet(Lighting, "ShadowSoftness", 0)
        
        for _, effect in ipairs(Lighting:GetChildren()) do
            if effect:IsA("PostEffect") then
                rememberAndSet(effect, "Enabled", false)
            elseif effect:IsA("Atmosphere") then
                rememberAndSet(effect, "Density", 0)
                rememberAndSet(effect, "Haze", 0)
                rememberAndSet(effect, "Glare", 0)
            elseif effect:IsA("Sky") then
                rememberAndSet(effect, "CelestialBodiesShown", false)
                rememberAndSet(effect, "StarCount", 0)
            end
        end
    end

    local function optimizeTerrain()
        local terrain = workspace:FindFirstChildOfClass("Terrain")
        if not terrain then return end
        
        rememberAndSet(terrain, "Decoration", false)
        rememberAndSet(terrain, "WaterWaveSize", 0)
        rememberAndSet(terrain, "WaterWaveSpeed", 0)
        rememberAndSet(terrain, "WaterReflectance", 0)
        rememberAndSet(terrain, "WaterTransparency", 1)
    end

    local function setLowestQuality()
        local rendering = settings().Rendering
        if oldQualityLevel == nil then
            oldQualityLevel = rendering.QualityLevel
        end
        rendering.QualityLevel = Enum.QualityLevel.Level01
        
        local userGameSettings = UserSettings():GetService("UserGameSettings")
        if oldSavedQualityLevel == nil then
            oldSavedQualityLevel = userGameSettings.SavedQualityLevel
        end
        userGameSettings.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
    end

    setLowestQuality()
    optimizeLighting()
    optimizeTerrain()
    
    for _, instance in ipairs(workspace:GetDescendants()) do
        optimizeInstance(instance)
    end
    
    local conn = workspace.DescendantAdded:Connect(function(instance)
        optimizeInstance(instance)
    end)
    table.insert(antilagConnections, conn)
end

local function disableAntiLag()
    for instance, props in pairs(changedProperties) do
        for prop, value in pairs(props) do
            instance[prop] = value
        end
    end
    changedProperties = {}
    
    if oldQualityLevel ~= nil then
        settings().Rendering.QualityLevel = oldQualityLevel
        oldQualityLevel = nil
    end
    
    if oldSavedQualityLevel ~= nil then
        UserSettings():GetService("UserGameSettings").SavedQualityLevel = oldSavedQualityLevel
        oldSavedQualityLevel = nil
    end
    
    for _, conn in ipairs(antilagConnections) do
        conn:Disconnect()
    end
    antilagConnections = {}
end

local Window = Library:CreateWindow({
    Title = "Twin Hub",
    Footer = "Volleyball Legends",
    Icon = 76037421850699,
    NotifySide = "Right",
})

local Tabs = {
    Main = Window:AddTab("Main", "user", Color3.fromRGB(208, 240, 64), "Ferramentas principais e automações"),
    Character = Window:AddTab("Character", "user", Color3.fromRGB(109, 190, 254), "Ajustes do personagem"),
    Visuals = Window:AddTab("Visuals", "eye", Color3.fromRGB(124, 96, 224), "Efeitos e visual do jogo"),
    Misc = Window:AddTab("Misc", "settings", Color3.fromRGB(80, 224, 160), "Opções diversas"),
    GameJoin = Window:AddTab("Game Join", "gamepad-2", Color3.fromRGB(224, 176, 80), "Entrada e seleção de partidas"),
    ["UI Settings"] = Window:AddTab("UI Settings", "settings", Color3.fromRGB(120, 120, 120), "Tema e configurações da interface"),
}

local UI = {}

UI.LeftGroupBox = Tabs.Main:AddLeftGroupbox("Spike Settings", "crosshair")

UI.LeftGroupBox:AddToggle("redirectspike", {
    Text = "Redirect Spike",
    Tooltip = "Redirect spike to camera direction",
    Default = false,
    Callback = function(Value)
        if Value then
            enableRedirectSpike()
        else
            disableRedirectSpike()
        end
    end,
})

UI.LeftGroupBox:AddToggle("autocorner", {
    Text = "Auto Corner",
    Tooltip = "Aims to the corner sides of the enemy's goal",
    Default = false,
    Callback = function(Value)
        AutoCorner.enabled = Value
        if Value then
            AutoCorner.installAim()
        end
    end,
})

UI.LeftGroupBox:AddDropdown("autocornerside", {
    Values = {"Auto", "Left", "Right"},
    Default = "Auto",
    Text = "Corner Side",
    Callback = function(Value)
        AutoCorner.side = Value
    end,
})

UI.LeftGroupBox:AddDropdown("autocornerreach", {
    Values = {"All", "Back", "Nearest"},
    Default = "All",
    Text = "Corner Depth",
    Callback = function(Value)
        AutoCorner.reach = Value
    end,
})

UI.LeftGroupBox:AddLabel("Auto Corner bind"):AddKeyPicker("autocornerbind", {
    Default = "C",
    Mode = "Press",
    Text = "Auto Corner",
    Callback = function()
        local toggle = Toggles.autocorner
        if toggle then
            toggle:SetValue(not toggle.Value)
        end
    end,
})

UI.LeftGroupBox:AddToggle("newspike", {
    Text = "Silent Spike",
    Tooltip = "Spike with no animation or sound",
    Default = false,
    Callback = function(Value)
        newSilentSpikeEnabled = Value
        if newSpikeButton then
            newSpikeButton.Visible = Value
        end
    end,
})

UI.LeftGroupBox:AddLabel("Silent Spike bind"):AddKeyPicker("newspikebind", {
    Default = "R",
    Mode = "Press",
    Text = "Silent Spike",
    Callback = function()
        fireNewSpike()
    end,
})

UI.LeftGroupBox:AddToggle("sanju", {
    Text = "Sanju Tilt",
    Tooltip = "Sanju tilt effect",
    Default = false,
    Callback = function(Value)
        if Value then
            enableSanjuTilt()
        else
            disableSanjuTilt()
        end
    end,
})

UI.LeftGroupBox:AddToggle("maxcharge", {
    Text = "Max Charge Special",
    Tooltip = "Max charge your special",
    Default = false,
    Callback = function(Value)
        if Value then
            enableMaxCharge()
        else
            disableMaxCharge()
        end
    end,
})

UI.LeftGroupBox:AddToggle("fakespike", {
    Text = "Fake Spike",
    Tooltip = "Auto fake spike when jumping",
    Default = false,
    Callback = function(Value)
        fakeSpikeEnabled = Value
    end,
})

UI.LeftGroupBox:AddToggle("autocounter", {
    Text = "Auto Counter",
    Tooltip = "Counters an enemy spike when both of you are at the net",
    Default = false,
    Callback = function(Value)
        AutoCounter.state.enabled = Value
    end,
})

UI.LeftGroupBox:AddDropdown("autocountermove", {
    Values = {"Auto", "Block", "Spike"},
    Default = "Auto",
    Text = "Counter Move",
    Tooltip = "Auto: block while the ball is still on their half, spike once it crosses",
    Callback = function(Value)
        AutoCounter.state.move = Value
    end,
})

UI.LeftGroupBox:AddSlider("autocounternetrange", {
    Text = "Counter Net Range",
    Default = 9,
    Min = 3,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        AutoCounter.state.netRange = Value
    end,
})

UI.LeftGroupBox:AddSlider("autocounterlateral", {
    Text = "Counter Width",
    Default = 14,
    Min = 4,
    Max = 30,
    Rounding = 1,
    Callback = function(Value)
        AutoCounter.state.lateral = Value
    end,
})

UI.LeftGroupBox:AddSlider("autocounterdelay", {
    Text = "Counter Delay",
    Default = 0.05,
    Min = 0,
    Max = 0.5,
    Rounding = 2,
    Callback = function(Value)
        AutoCounter.state.delay = Value
    end,
})

UI.LeftGroupBox:AddToggle("autocounterjump", {
    Text = "Counter Auto Jump",
    Tooltip = "Jump before the counter, the block hitbox dies the moment you land",
    Default = true,
    Callback = function(Value)
        AutoCounter.state.autoJump = Value
    end,
})

UI.LeftGroupBox:AddLabel("Auto Counter bind"):AddKeyPicker("autocounterbind", {
    Default = "N",
    Mode = "Press",
    Text = "Auto Counter",
    Callback = function()
        local toggle = Toggles.autocounter
        if toggle then
            toggle:SetValue(not toggle.Value)
        end
    end,
})

UI.HitboxGroup = Tabs.Main:AddRightGroupbox("Hitbox Settings", "box")

UI.HitboxGroup:AddToggle("hitboxenable", {
    Text = "Enable Hitbox",
    Tooltip = "Turn Hitbox ON/OFF",
    Default = false,
    Callback = function(Value)
        hitboxEnabled = Value
        if Value then
            updateHitboxes(hitboxScale)
        else
            removeHitboxes()
        end
    end,
})

UI.HitboxGroup:AddSlider("hitboxsize", {
    Text = "Hitbox Size",
    Tooltip = "Reach in studs, the server refuses anything past 20",
    Default = 5,
    Min = 0,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        hitboxScale = Value
        if hitboxEnabled then
            updateHitboxes(Value)
        end
    end,
})

UI.HitboxGroup:AddDropdown("hitboxcolor", {
    Values = {"Invisible", "White", "Green", "Blue", "Red", "Yellow", "Purple", "Orange", "Pink"},
    Default = "Blue",
    Text = "Hitbox Color",
    Callback = function(Value)
        local colors = {
            Invisible = Color3.fromRGB(255, 255, 255),
            White = Color3.fromRGB(255, 255, 255),
            Green = Color3.fromRGB(0, 255, 0),
            Blue = Color3.fromRGB(0, 0, 255),
            Red = Color3.fromRGB(255, 0, 0),
            Yellow = Color3.fromRGB(255, 255, 0),
            Purple = Color3.fromRGB(128, 0, 128),
            Orange = Color3.fromRGB(255, 165, 0),
            Pink = Color3.fromRGB(255, 105, 180)
        }
        local transparencies = {
            Invisible = 1,
            White = 0.3,
            Green = 0.3,
            Blue = 0.3,
            Red = 0.3,
            Yellow = 0.3,
            Purple = 0.3,
            Orange = 0.3,
            Pink = 0.3
        }
        hitboxColor = colors[Value] or Color3.fromRGB(0, 0, 255)
        hitboxTransparency = transparencies[Value] or 0.3
        if hitboxEnabled then
            updateHitboxes(hitboxScale)
        end
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Remove Hitboxes",
    Func = function()
        removeHitboxes()
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Show Stop Ball",
    Func = function()
        stopBallVisible = not stopBallVisible
        if stopBallButton then
            stopBallButton.Visible = stopBallVisible
        else
            stopBallButton = createStopBallButton()
        end
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Show Aim",
    Func = function()
        aimVisible = not aimVisible
        if aimButton then
            aimButton.Visible = aimVisible
        else
            aimButton = createAimButton()
        end
    end,
})

UI.PerfGroup = Tabs.Main:AddLeftGroupbox("Performance", "gauge")

UI.PerfGroup:AddToggle("antilag", {
    Text = "Anti-Lag",
    Tooltip = "Reduce graphics for better performance",
    Default = false,
    Callback = function(Value)
        if Value then
            enableAntiLag()
        else
            disableAntiLag()
        end
    end,
})

UI.MoveGroup = Tabs.Main:AddRightGroupbox("Movement", "move")

UI.MoveGroup:AddToggle("desync", {
    Text = "Desync",
    Tooltip = "Desync movement",
    Default = false,
    Callback = function(Value)
        if Value then
            enableDesync()
        else
            disableDesync()
        end
    end,
})

UI.MoveGroup:AddToggle("autoreceive", {
    Text = "Auto Receive",
    Tooltip = "Auto receive the ball",
    Default = false,
    Callback = function(Value)
        autoReceiveEnabled = Value
    end,
})

UI.MoveGroup:AddSlider("autoreceiverange", {
    Text = "Receive Range",
    Default = 10,
    Min = 3,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        Receive.range = Value
    end,
})

UI.MoveGroup:AddSlider("autoreceivelead", {
    Text = "Receive Lead",
    Default = 0.35,
    Min = 0,
    Max = 1,
    Rounding = 2,
    Callback = function(Value)
        Receive.lead = Value
    end,
})

UI.MoveGroup:AddLabel("Auto Receive bind"):AddKeyPicker("autoreceivebind", {
    Default = "X",
    Mode = "Press",
    Text = "Auto Receive",
    Callback = function()
        local toggle = Toggles.autoreceive
        if toggle then
            toggle:SetValue(not toggle.Value)
        end
    end,
})

UI.MoveGroup:AddToggle("kisukidive", {
    Text = "Kisuki Dive",
    Tooltip = "Kisuki super dive",
    Default = false,
    Callback = function(Value)
        Kisuki.enabled = Value
        if Value then
            Kisuki.install()
        end
    end,
})

UI.MoveGroup:AddSlider("kisukicharge", {
    Text = "Dive Charge",
    Tooltip = "Lerps Kimiro's real 19.5-45 power range, past 0.5 the FX go strong",
    Default = 1,
    Min = 0,
    Max = 1,
    Rounding = 2,
    Callback = function(Value)
        Kisuki.charge = Value
    end,
})

UI.MoveGroup:AddToggle("akaridash", {
    Text = "Akari Dash",
    Tooltip = "Dash into the ball",
    Default = false,
    Callback = function(Value)
        akariDashEnabled = Value
        if dashButton then
            dashButton.Visible = Value
        end
    end,
})

UI.MoveGroup:AddLabel("Akari Dash bind"):AddKeyPicker("akaridashbind", {
    Default = "F",
    Mode = "Press",
    Text = "Akari Dash",
    Callback = function()
        akariDash()
    end,
})

UI.MoveGroup:AddToggle("leadfeet", {
    Text = "Lead Feet",
    Tooltip = "Slams you down at the ability's own -10000 acceleration",
    Default = false,
    Callback = function(Value)
        leadFeetEnabled = Value
        if leadFeetButton then
            leadFeetButton.Visible = Value
        end
    end,
})

UI.MoveGroup:AddLabel("Lead Feet bind"):AddKeyPicker("leadfeetbind", {
    Default = "G",
    Mode = "Press",
    Text = "Lead Feet",
    Callback = function()
        leadFeetSlam()
    end,
})

UI.MaxServeGroup = Tabs.Main:AddLeftGroupbox("Max Serve", "server")

UI.MaxServeGroup:AddToggle("maxserve", {
    Text = "Max Serve",
    Tooltip = "Max serve power",
    Default = false,
    Callback = function(Value)
        if Value then
            enableMaxServe()
        else
            disableMaxServe()
        end
    end,
})

UI.MaxServeGroup:AddToggle("esp", {
    Text = "Jump ESP",
    Tooltip = "Highlight enemies while they are jumping",
    Default = false,
    Callback = function(Value)
        espJumpEnabled = Value
        if not Value then
            for player in pairs(espHighlights) do
                removeESP(player)
            end
        end
    end,
})

UI.DataGroup = Tabs.Main:AddRightGroupbox("Data", "database")

UI.DataGroup:AddButton({
    Text = "Data Rollback",
    Func = function()
        local Remote = game:GetService("ReplicatedStorage")
            :WaitForChild("Packages")
            :WaitForChild("_Index")
            :WaitForChild("sleitnick_knit@1.7.0")
            :WaitForChild("knit")
            :WaitForChild("Services")
            :WaitForChild("SettingsService")
            :WaitForChild("RF")
            :WaitForChild("UpdateKeybind")
        Remote:InvokeServer("MouseButton1", true, "Spike\xE2\x80\x8B\x8F")
        game:GetService("TeleportService"):Teleport(game.PlaceId)
    end,
})

UI.CharAttrGroup = Tabs.Character:AddLeftGroupbox("Attributes", "sliders-horizontal")

UI.CharAttrGroup:AddInput("divespeed", {
    Default = "",
    Numeric = true,
    Finished = true,
    Text = "Dive Speed",
    Placeholder = "0.95",
    Callback = function(Value)
        local num = tonumber(Value)
        if num then
            LocalPlayer:SetAttribute("Multiplier_DiveSpeed", num)
        end
    end,
})

UI.CharAttrGroup:AddInput("jumppower", {
    Default = "",
    Numeric = true,
    Finished = true,
    Text = "Jump Power",
    Placeholder = "1.1",
    Callback = function(Value)
        local num = tonumber(Value)
        if num then
            LocalPlayer:SetAttribute("Multiplier_JumpPower", num)
        end
    end,
})

UI.CharAttrGroup:AddInput("speed", {
    Default = "",
    Numeric = true,
    Finished = true,
    Text = "Speed",
    Placeholder = "0.85",
    Callback = function(Value)
        local num = tonumber(Value)
        if num then
            LocalPlayer:SetAttribute("Multiplier_Speed", num)
        end
    end,
})

UI.CharMoveGroup = Tabs.Character:AddRightGroupbox("Movement", "move")

UI.CharMoveGroup:AddToggle("airmove", {
    Text = "Air Movement",
    Tooltip = "Move in the air",
    Default = false,
    Callback = function(Value)
        airMovement = Value
        if not Value and bodyVelocity then
            bodyVelocity:Destroy()
            bodyVelocity = nil
        end
    end,
})

UI.CharMoveGroup:AddSlider("airspeed", {
    Text = "Air Movement Speed",
    Default = 16,
    Min = 0,
    Max = 100,
    Rounding = 0,
    Callback = function(Value)
        airMovementSpeed = Value
    end,
})

UI.CharMoveGroup:AddToggle("autoshiftlock", {
    Text = "Auto Shift Lock",
    Tooltip = "Auto rotate to camera when jumping",
    Default = false,
    Callback = function(Value)
        toggleShiftLock(Value)
    end,
})

UI.CharMoveGroup:AddToggle("characterlines", {
    Text = "Character Enemy/Team Line",
    Tooltip = "Show colored beams to enemies",
    Default = false,
    Callback = function(Value)
        linesEnabled = Value
        if not Value then
            for player in pairs(lines) do
                removeLine(player)
            end
        end
    end,
})

UI.CharMoveGroup:AddSlider("linedistance", {
    Text = "Line Distance",
    Default = 50,
    Min = 10,
    Max = 200,
    Rounding = 1,
    Callback = function(Value)
        lineDistance = Value
    end,
})

Tabs.Visuals:AddRightGroupbox("Ball Prediction", "target"):AddToggle("ballmarker", {
    Text = "Landing Marker",
    Tooltip = "Predict where the ball land and say if it's out or not",
    Default = false,
    Callback = function(Value)
        Landing.enabled = Value
        if not Value then
            Landing.clear()
        end
    end,
})

-- VISUAL APPLY (dropdown selects, button applies on demand)
local VisualApply = {}

function VisualApply.pick(list, wanted)
    if table.find(list, wanted) then
        return wanted
    end
    return list[1]
end

selectedEffect = VisualApply.pick(effectList, selectedEffect)
selectedCard = VisualApply.pick(cardList, selectedCard)
selectedBallSkin = VisualApply.pick(ballSkinList, selectedBallSkin)

function VisualApply.score()
    hitEffectEnabled = true
    pcall(enableHitEffect)
    Vault.mark("ScoreEffect", true)
    Vault.setSlot("ScoreEffect", selectedEffect)
    Library:Notify("Score effect applied: " .. selectedEffect)
end

function VisualApply.card()
    playerCardEnabled = true
    pcall(enablePlayerCard)
    Vault.mark("PlayerCard", true)
    Vault.setSlot("PlayerCard", selectedCard)
    task.spawn(function()
        pcall(fireCardRemote)
    end)
    Library:Notify("Player card applied: " .. selectedCard)
end

function VisualApply.ball()
    autoApplyBallSkin = true
    Vault.mark("Ball", true)
    Vault.setSlot("Ball", selectedBallSkin)
    task.spawn(function()
        pcall(sweep)
    end)
    Library:Notify("Ball applied: " .. selectedBallSkin)
end

function VisualApply.jersey()
    pickedTeam = nil
    task.spawn(function()
        pcall(applyJersey, selectedJersey)
    end)
    Library:Notify("Jersey applied: " .. selectedJersey)
end

UI.VisualScoreGroup = Tabs.Visuals:AddLeftGroupbox("Score Effect", "sparkles")

UI.VisualScoreGroup:AddDropdown("effectselect", {
    Values = effectList,
    Default = selectedEffect,
    Text = "Select Score Effect",
    Callback = function(Value)
        selectedEffect = Value
    end,
})

UI.VisualScoreGroup:AddButton({
    Text = "Apply Score Effect",
    Func = VisualApply.score,
})

UI.VisualProtectGroup = Tabs.Visuals:AddRightGroupbox("Protection", "shield")

UI.VisualProtectGroup:AddToggle("protect", {
    Text = "Protect",
    Tooltip = "Enable/Disable all protection features",
    Default = false,
    Callback = function(Value)
        toggleProtection(Value)
    end,
})

UI.VisualProtectGroup:AddToggle("tshanimation", {
    Text = "TSH Animation",
    Tooltip = "PowerSpike + SpecialChargeSpikeVFX on spike",
    Default = false,
    Callback = function(Value)
        tshAnimationEnabled = Value
    end,
})

UI.VisualProtectGroup:AddToggle("hidarianimation", {
    Text = "Hidari Animation",
    Tooltip = "PowerSpike + HidariSpikeVFX on spike",
    Default = false,
    Callback = function(Value)
        hidariAnimationEnabled = Value
    end,
})

UI.VisualProtectGroup:AddToggle("kazanabluejump", {
    Text = "Kazana Blue Jump",
    Tooltip = "Fires KazanaBlue on jump",
    Default = false,
    Callback = function(Value)
        kazanaBlueEnabled = Value
    end,
})

UI.VisualProtectGroup:AddToggle("kazanawhitejump", {
    Text = "Kazana White Jump",
    Tooltip = "Fires KazanaWhite on jump",
    Default = false,
    Callback = function(Value)
        kazanaWhiteEnabled = Value
    end,
})

UI.PlayerCardGroup = Tabs.Visuals:AddLeftGroupbox("Player Card", "id-card")

UI.PlayerCardGroup:AddDropdown("cardselect", {
    Values = cardList,
    Default = selectedCard,
    Text = "Select Player Card",
    Callback = function(Value)
        selectedCard = Value
    end,
})

UI.PlayerCardGroup:AddButton({
    Text = "Apply Player Card",
    Func = VisualApply.card,
})

Tabs.Visuals:AddRightGroupbox("Title Changer", "tag"):AddToggle("titleunlock", {
    Text = "Title Changer",
    Tooltip = "Change title",
    Default = false,
    Callback = function(Value)
        Vault.mark("Title", Value)
    end,
})

-- BALL SKIN UI
UI.BallSkinGroup = Tabs.Visuals:AddLeftGroupbox("Ball Changer", "circle")

UI.BallSkinGroup:AddDropdown("ballselect", {
    Values = ballSkinList,
    Default = selectedBallSkin,
    Text = "Select Ball",
    Callback = function(Value)
        selectedBallSkin = Value
    end,
})

UI.BallSkinGroup:AddButton({
    Text = "Apply Ball",
    Func = VisualApply.ball,
})

-- JERSEY UI (FIXED - AUTO APPLY ENABLED BY DEFAULT)
UI.JerseyGroup = Tabs.Visuals:AddRightGroupbox("Jersey Changer", "shirt")

UI.JerseyGroup:AddToggle("autoapplyjersey", {
    Text = "Auto Apply Jersey",
    Tooltip = "Automatically apply selected jersey",
    Default = false,
    Callback = function(Value)
        autoApplyJersey = Value
        applyJersey(selectedJersey)
    end,
})

UI.JerseyGroup:AddDropdown("jerseyselect", {
    Values = #jerseyList > 0 and jerseyList or {"No Jerseys Found"},
    Default = #jerseyList > 0 and jerseyList[1] or "No Jerseys Found",
    Text = "Select Jersey",
    Callback = function(Value)
        selectedJersey = Value
        pickedTeam = nil
        if autoApplyJersey then
            applyJersey(selectedJersey)
        end
    end,
})

UI.JerseyGroup:AddButton({
    Text = "Apply Jersey",
    Func = VisualApply.jersey,
})

UI.MiscStyleGroup = Tabs.Misc:AddLeftGroupbox("Auto Style Spin", "refresh-cw")

UI.MiscStyleGroup:AddToggle("autostyle", {
    Text = "Auto Style Spin",
    Tooltip = "Auto spin until target style obtained",
    Default = false,
    Callback = function(Value)
        autoSpin = Value
        if Value then
            startAutoSpin()
        end
    end,
})

UI.MiscStyleGroup:AddDropdown("spintype", {
    Values = {"Normal", "Lucky"},
    Default = "Normal",
    Text = "Spin Type",
    Callback = function(Value)
        spinType = Value
    end,
})

UI.MiscStyleGroup:AddInput("targetstyle", {
    Default = "",
    Text = "Target Style (Type manually)",
    Placeholder = "Sanju",
    Callback = function(Value)
        desiredStyles = {Value}
    end,
})

UI.MiscStyleGroup:AddDropdown("stylelist", {
    Values = {
        "Ronin", "Hidari", "Jinko", "Timeskip Hinto", "Timeskip Kyamo",
        "Akuto", "Taichou", "Sanju", "Mikage", "Kazana", "Timeskip Okazu",
        "Kisuki", "Bakuri", "Kyamo", "Okazu", "Hirakumi",
        "Kozai", "Azmei", "Uchikai", "Yokai", "Yogan",
        "Sazuroku", "Kyoshin", "Yomosuke", "Oyatsu", "Tsuchiro",
        "Imaezi", "Tonkura", "Ninyoku", "Hinto", "Hakochi", "Yakisukai", "Sagumi", "Koshoti"
    },
    Default = "Ronin",
    Text = "Style List (Select to auto-fill)",
    Callback = function(Value)
        Options.targetstyle:SetValue(Value)
        desiredStyles = {Value}
    end,
})

UI.MiscAbilityGroup = Tabs.Misc:AddRightGroupbox("Auto Ability Spin", "zap")

UI.MiscAbilityGroup:AddToggle("autoabilityspin", {
    Text = "Auto Ability Spin",
    Tooltip = "Auto spin until target ability obtained",
    Default = false,
    Callback = function(Value)
        autoAbilitySpin = Value
        if Value then
            startAutoAbilitySpin()
        end
    end,
})

UI.MiscAbilityGroup:AddDropdown("abilityspintype", {
    Values = {"Normal", "Lucky"},
    Default = "Normal",
    Text = "Ability Spin Type",
    Callback = function(Value)
        abilitySpinType = Value
    end,
})

UI.MiscAbilityGroup:AddInput("targetability", {
    Default = "",
    Text = "Target Ability (Type manually)",
    Placeholder = "Shield Breaker",
    Callback = function(Value)
        desiredAbilities = {Value}
    end,
})

UI.MiscAbilityGroup:AddDropdown("abilitylist", {
    Values = {
        "Shield Breaker", "Magnetic Pull", "Lead Feet", "Extra Touch", "Godly",
        "Redirection Jump", "Curve Spike", "Divine Strength", "Legendary",
        "Steel Block", "Zero Gravity Set", "Rare", "Boom Jump", "Moonball",
        "Common", "Super Sprint", "Team Spirit", "Rolling Thunder"
    },
    Default = "Shield Breaker",
    Text = "Ability List (Select to auto-fill)",
    Callback = function(Value)
        Options.targetability:SetValue(Value)
        desiredAbilities = {Value}
    end,
})

UI.MiscShopGroup = Tabs.Misc:AddLeftGroupbox("Shop", "shopping-bag")

UI.MiscShopGroup:AddButton({
    Text = "Buy Emote",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                Open:InvokeServer("Emote1")
            end
        end
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Effect",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                Open:InvokeServer("ScoreEffect1")
            end
        end
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Extreme Ball",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                Open:InvokeServer("Extreme")
            end
        end
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Medium Ball",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                Open:InvokeServer("Medium")
            end
        end
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Basic Ball",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                Open:InvokeServer("Basic")
            end
        end
    end,
})

UI.MiscClaimGroup = Tabs.Misc:AddRightGroupbox("Claim Rewards", "gift")

UI.MiscClaimGroup:AddButton({
    Text = "Claim Level Rewards",
    Func = function()
        local LevelService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.LevelService
        if LevelService then
            local RF = LevelService:FindFirstChild("RF")
            if RF then
                local ClaimLevelRewards = RF:FindFirstChild("ClaimLevelRewards")
                if ClaimLevelRewards then
                    ClaimLevelRewards:InvokeServer()
                end
            end
        end
    end,
})

UI.MiscClaimGroup:AddButton({
    Text = "Claim Quest Rewards",
    Func = function()
        local QuestService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.QuestService
        if QuestService then
            local RF = QuestService:FindFirstChild("RF")
            if RF then
                local ClaimAll = RF:FindFirstChild("ClaimAll")
                if ClaimAll then
                    ClaimAll:InvokeServer(true)
                end
            end
        end
    end,
})

UI.MiscClaimGroup:AddButton({
    Text = "Redeem All Codes",
    Func = function()
        local function fetchNewCodes()
            local success, data = pcall(function()
                return httpGet("https://beebom.com/haikyuu-legends-codes/")
            end)
            if not success or not data then
                return {}
            end
            local newCodes = {}
            local processed = {}
            for line in string.gmatch(data, "[^\n]+") do
                if string.find(line, "(NEW)") then
                    local code = string.match(line, "(%u+[%u%d_]+)")
                    if code and not processed[code] then
                        processed[code] = true
                        table.insert(newCodes, code)
                    end
                end
                if #newCodes >= 3 then
                    break
                end
            end
            return newCodes
        end
        local newCodes = fetchNewCodes()
        if #newCodes > 0 then
            for i, code in pairs(newCodes) do
                local CodeService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.CodeService
                if CodeService then
                    local RF = CodeService:FindFirstChild("RF")
                    if RF then
                        local Redeem = RF:FindFirstChild("Redeem")
                        if Redeem then
                            Redeem:InvokeServer(code)
                        end
                    end
                end
                task.wait(0.01)
            end
        end
    end,
})

UI.GameJoinGroup = Tabs.GameJoin:AddLeftGroupbox("Game Modes", "gamepad-2")

UI.GameJoinGroup:AddButton({
    Text = "Chaos Mode",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("ChaosMode")
            end
        end
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "1v1 Mini Map",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("OnesMini")
            end
        end
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "2v2 Ranked",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("Twos")
            end
        end
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "3v3 Ranked",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("Threes")
            end
        end
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "4v4 Ranked",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("Fours")
            end
        end
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "6v6 Ranked",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("Sixes")
            end
        end
    end,
})

UI.GameJoinGroup:AddButton({
    Text = "Training",
    Func = function()
        local PartyService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService.RF
        if PartyService then
            local RequestTeleport = PartyService:FindFirstChild("RequestTeleport")
            if RequestTeleport then 
                RequestTeleport:InvokeServer("Training")
            end
        end
    end,
})

local MenuGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu", "wrench")

MenuGroup:AddToggle("KeybindMenuOpen", {
    Default = Library.KeybindFrame.Visible,
    Text = "Open Keybind Menu",
    Callback = function(value)
        Library.KeybindFrame.Visible = value
    end,
})

MenuGroup:AddDropdown("NotificationSide", {
    Values = { "Left", "Right" },
    Default = "Right",
    Text = "Notification Side",
    Callback = function(Value)
        Library:SetNotifySide(Value)
    end,
})

MenuGroup:AddDropdown("DPIDropdown", {
    Values = { "50%", "75%", "100%", "125%", "150%", "175%", "200%" },
    Default = "100%",
    Text = "DPI Scale",
    Callback = function(Value)
        Value = Value:gsub("%%", "")
        local DPI = tonumber(Value)
        Library:SetDPIScale(DPI)
    end,
})

MenuGroup:AddSlider("UICornerSlider", {
    Text = "Corner Radius",
    Default = Library.CornerRadius,
    Min = 0,
    Max = 20,
    Rounding = 0,
    Callback = function(value)
        Window:SetCornerRadius(value)
    end
})

MenuGroup:AddDivider()
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Menu keybind" })

MenuGroup:AddButton("Unload", function()
    Library:Unload()
end)

Library.ToggleKeybind = Options.MenuKeybind

Library:SetConfigFolder("TWINHUB")
Library:BuildConfigSection(Tabs["UI Settings"])
Library:LoadAutoloadConfig()
-- Botão Flutuante TWINHUB
task.spawn(function()
    local WinShell = Library.Window.Instance
    local WinRoot = Library.Root

    for _, desc in ipairs(WinShell:GetDescendants()) do
        if desc:IsA("TextButton") and desc.Text == "-" then
            desc.Visible = false
        end
    end

    local FloatBtn = Instance.new("TextButton")
    FloatBtn.Name = "TWINHUB_FloatBtn"
    FloatBtn.Size = UDim2.fromOffset(56, 56)
    FloatBtn.Position = UDim2.new(0, 20, 0.5, -28)
    
    FloatBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    FloatBtn.Text = "T"
    FloatBtn.TextColor3 = Color3.fromRGB(219, 219, 219)
    FloatBtn.Font = Library.Fonts.Bold
    FloatBtn.TextSize = 24
    FloatBtn.AutoButtonColor = false
    FloatBtn.BorderSizePixel = 0
    FloatBtn.Visible = false
    FloatBtn.ZIndex = 999
    FloatBtn.Parent = WinRoot

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = FloatBtn

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(219, 219, 219)
    stroke.Thickness = 1
    stroke.Parent = FloatBtn

    -- Logo da bola flutuante (PNG embutido em base64, gravado no disco e carregado via getcustomasset)
    do
        local LOGO_B64 = [[
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
AAAASUVORK5CYII=
]]

        local function decodeBase64(data)
            data = data:gsub("[^%w%+/=]", "")
            local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
            local map = {}
            for i = 1, 64 do
                map[alphabet:byte(i)] = i - 1
            end
            local parts, count = {}, 0
            for i = 1, #data, 4 do
                local a, b, c, d = data:byte(i, i + 3)
                local v = (map[a] or 0) * 262144 + (map[b] or 0) * 4096
                    + ((c and c ~= 61) and map[c] or 0) * 64
                    + ((d and d ~= 61) and map[d] or 0)
                local chunk = string.char(math.floor(v / 65536) % 256)
                if c and c ~= 61 then
                    chunk = chunk .. string.char(math.floor(v / 256) % 256)
                end
                if d and d ~= 61 then
                    chunk = chunk .. string.char(v % 256)
                end
                count = count + 1
                parts[count] = chunk
            end
            return table.concat(parts)
        end

        pcall(function()
            local write = rawget(_G, "writefile") or writefile
            local asset = rawget(_G, "getcustomasset") or getcustomasset or rawget(_G, "getsynasset") or getsynasset
            local isFolder = rawget(_G, "isfolder") or isfolder
            local makeFolder = rawget(_G, "makefolder") or makefolder
            if type(write) ~= "function" or type(asset) ~= "function" then
                return
            end
            if type(isFolder) == "function" and type(makeFolder) == "function" and not isFolder("TWINHUB") then
                pcall(makeFolder, "TWINHUB")
            end
            local path = "TWINHUB/logo.png"
            write(path, decodeBase64(LOGO_B64))
            local content = asset(path)
            if type(content) ~= "string" or content == "" then
                return
            end
            local logo = Instance.new("ImageLabel")
            logo.Name = "Logo"
            logo.BackgroundTransparency = 1
            logo.BorderSizePixel = 0
            logo.Size = UDim2.fromScale(1, 1)
            logo.Image = content
            logo.ScaleType = Enum.ScaleType.Crop
            logo.ZIndex = 1000
            logo.Parent = FloatBtn
            local logoCorner = Instance.new("UICorner")
            logoCorner.CornerRadius = UDim.new(1, 0)
            logoCorner.Parent = logo
            -- Mesmo logo no cabecalho da janela (ao lado do titulo)
            pcall(function()
                for _, desc in ipairs(WinShell:GetDescendants()) do
                    if desc:IsA("ImageLabel") and desc.Size == UDim2.fromOffset(26, 26) and desc.Position == UDim2.fromOffset(18, 15) then
                        desc.Image = content
                        desc.ScaleType = Enum.ScaleType.Crop
                        break
                    end
                end
            end)
            FloatBtn.Text = ""
        end)
    end

    WinShell:GetPropertyChangedSignal("Visible"):Connect(function()
        FloatBtn.Visible = not WinShell.Visible
    end)

    local dragging, dragStart, startPos = false, nil, nil
    FloatBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = FloatBtn.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    
    FloatBtn.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            FloatBtn.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    
    FloatBtn.MouseButton1Click:Connect(function()
        WinShell.Visible = true
        WinShell.Position = UDim2.fromScale(0.5, 0.5)
        WinShell.Size = UDim2.fromOffset(820, 540)
        if Library.Window.SetMinimized then
            Library.Window:SetMinimized(false)
        end
    end)
end)
