-- !! Replace this with your raw GitHub URL !!
-- Example: https://raw.githubusercontent.com/YourName/YourRepo/main/vehicle_hub.lua
local SCRIPT_URL = "https://raw.githubusercontent.com/sjndn71-netizen/Autofarmaiplane/refs/heads/main/vehicle_hub.lua?token=GHSAT0AAAAAADZAXPS2DG4RYZIJJTGFI5MU2PIF37A"

local RS, Players, Http, Run = game:GetService("ReplicatedStorage"), game:GetService("Players"), game:GetService("HttpService"), game:GetService("RunService")
local P = Players.LocalPlayer
local knit = RS.Packages._Index:FindFirstChild("sleitnick_knit@1.5.1").knit.Services.VehicleService
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local DEFAULT_CONFIG = { Speed = 400, HoverHeight = 50, HoverForwardOffset = 30, HoverLateralOffset = 0, HoverSnapDist = 30, PatrolStopDist = 200, HoverMaxSpeed = 150, HoverGain = 2.5, Deadzone = 2.0, LookSmoothness = 0.3, FireRate = 0.1, MissileRate = 0.6 }
local CONFIG = {}
for k, v in pairs(DEFAULT_CONFIG) do CONFIG[k] = v end

local spawnCoords = { Vector3.new(2669.02, 651.91, -623.42), Vector3.new(1362.56, 678.43, -960.20), Vector3.new(1089.36, 631.47, -1947.38), Vector3.new(-14.62, 1232.61, -1012.30), Vector3.new(-1044.81, 611.31, -1206.94), Vector3.new(-981.76, 861.38, -2392.76) }

local UUID_FILE, SETTINGS_FILE = "vehicle_uuids.json", "vehicle_settings.json"
local savedUUIDs = {}
pcall(function() if isfile(UUID_FILE) then savedUUIDs = Http:JSONDecode(readfile(UUID_FILE)) end end)
pcall(function() if isfile(SETTINGS_FILE) then local loaded = Http:JSONDecode(readfile(SETTINGS_FILE)) for k, v in pairs(loaded) do if DEFAULT_CONFIG[k] ~= nil then CONFIG[k] = v end end end end)
local function saveUUIDs() pcall(writefile, UUID_FILE, Http:JSONEncode(savedUUIDs)) end
local function saveSettings() pcall(writefile, SETTINGS_FILE, Http:JSONEncode(CONFIG)) end

local spawnedVehicle, lastSpawnedUUID, autofarmEnabled, autofarmConn, selectedTarget, state, stateStart, lastRetarget, patrolIdx, pendingKey, pendingLabel, lastShot, lastMissileShot, cachedFireRemote = nil, nil, false, nil, nil, "patrol", tick(), tick(), 1, nil, nil, 0, 0, nil
local lockCache, lastLockCheck = false, 0
local LOCK_TTL = 0.05
local function isTargetLocked()
    local now = tick()
    if now - lastLockCheck < LOCK_TTL then return lockCache end
    lastLockCheck = now
    local stack = { { obj = P.PlayerGui, d = 0 } }
    while #stack > 0 do
        local e = table.remove(stack)
        local obj, depth = e.obj, e.d
        if depth <= 8 then
            if obj:IsA("Frame") and obj.Visible then
                local bc = obj.BorderColor3
                if bc.G > 0.55 and bc.R < 0.35 and bc.B < 0.35 then lockCache = true; return true end
                local bg = obj.BackgroundColor3
                if bg.G > 0.55 and bg.R < 0.35 and bg.B < 0.35 and obj.BackgroundTransparency < 0.95 then lockCache = true; return true end
            end
            if depth < 8 then for _, child in ipairs(obj:GetChildren()) do table.insert(stack, { obj = child, d = depth + 1 }) end end
        end
    end
    lockCache = false; return false
end

local vehiclesFolder = workspace:WaitForChild("Vehicles", 10)
local function getMyPlaneRoot()
    if not spawnedVehicle or not vehiclesFolder then return nil end
    local model = vehiclesFolder:FindFirstChild(spawnedVehicle)
    return model and (model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart"))
end
local function getFireRemote()
    if cachedFireRemote and cachedFireRemote.Parent then return cachedFireRemote end
    cachedFireRemote = nil
    if not spawnedVehicle or not vehiclesFolder then return nil end
    local vModel = vehiclesFolder:FindFirstChild(spawnedVehicle)
    if vModel then cachedFireRemote = vModel:FindFirstChild("Fire", true) end
    return cachedFireRemote
end
local function scanF35s()
    if not vehiclesFolder then return nil, {} end
    local hrp = P.Character and P.Character:FindFirstChild("HumanoidRootPart")
    local ref = hrp and hrp.Position or Vector3.zero
    local closest, closestDist = nil, math.huge
    local all = {}
    for _, v in ipairs(vehiclesFolder:GetChildren()) do
        if v.Name == "F35" then
            local vo = v:FindFirstChild("VehicleObject")
            local sf = vo and vo:FindFirstChild("StealthF35")
            local body = sf and sf:FindFirstChild("BodyMesh")
            if body then
                table.insert(all, body)
                local d = (body.Position - ref).Magnitude
                if d < closestDist then closest, closestDist = body, d end
            end
        end
    end
    return closest, all
end
local function getHoverPos(target)
    return target.Position + target.CFrame.LookVector * CONFIG.HoverForwardOffset + target.CFrame.RightVector * CONFIG.HoverLateralOffset + Vector3.new(0, CONFIG.HoverHeight, 0)
end
local function orientTowardTarget(part, targetPos, dt)
    local cf = part.CFrame
    local dir = (targetPos - cf.Position).Unit
    local up = math.abs(dir.Y) > 0.99 and Vector3.xAxis or Vector3.yAxis
    part.CFrame = cf:Lerp(CFrame.lookAt(cf.Position, targetPos, up), math.clamp(CONFIG.LookSmoothness * dt * 60, 0, 1))
end
local function shootAtTarget(myPart, target)
    if not isTargetLocked() then return end
    local now = tick()
    local fireRemote = getFireRemote()
    if not fireRemote then return end
    local origin, targetPos = myPart.Position, target.Position
    if now - lastShot >= CONFIG.FireRate then
        lastShot = now
        fireRemote:FireServer(2, origin, targetPos, target, origin, Vector3.new(0, 1, 0), {})
    end
    if now - lastMissileShot >= CONFIG.MissileRate then
        lastMissileShot = now
        fireRemote:FireServer("Secondary", targetPos, {})
    end
end
local function spawnVehicle(name, uuid)
    spawnedVehicle, lastSpawnedUUID, cachedFireRemote = name, uuid, nil
    knit.RF.Spawn:InvokeServer(uuid)
end

P.CharacterAdded:Connect(function(char)
    char:WaitForChild("HumanoidRootPart", 10)
    task.wait(2)
    if autofarmEnabled and lastSpawnedUUID and spawnedVehicle then
        cachedFireRemote = nil
        knit.RF.Spawn:InvokeServer(lastSpawnedUUID)
        Rayfield:Notify({ Title = "Auto-Respawn", Content = spawnedVehicle .. " respawned after death", Duration = 3 })
    end
end)

local function stopAutofarm() if autofarmConn then autofarmConn:Disconnect(); autofarmConn = nil end end
local function startAutofarm()
    stopAutofarm()
    state, stateStart, lastRetarget, patrolIdx = "patrol", tick(), tick(), 1
    autofarmConn = Run.Heartbeat:Connect(function(dt)
        if not autofarmEnabled then return end
        local now, myPart = tick(), getMyPlaneRoot()
        local hrp = P.Character and P.Character:FindFirstChild("HumanoidRootPart")
        local ref = myPart and myPart.Position or (hrp and hrp.Position) or Vector3.zero
        local target = selectedTarget
        if state == "patrol" then
            local wp = spawnCoords[patrolIdx]
            local toWp = wp - ref
            if myPart then
                if toWp.Magnitude > CONFIG.PatrolStopDist then
                    myPart.AssemblyLinearVelocity = toWp.Unit * CONFIG.Speed
                    orientTowardTarget(myPart, ref + toWp.Unit * 100, dt)
                else
                    patrolIdx = patrolIdx % #spawnCoords + 1
                end
            end
            local found = scanF35s()
            if found then selectedTarget, lastRetarget, state, stateStart = found, now, "approaching", now end
            return
        end
        if not target or not target.Parent then
            local found = scanF35s()
            selectedTarget, lastRetarget = found, now
            if not found then state, stateStart = "patrol", now; return end
            target, state, stateStart = found, "approaching", now
        end
        if state == "approaching" and now - lastRetarget >= 3 then
            local nt = scanF35s()
            if nt then selectedTarget, target = nt, nt end
            lastRetarget = now
        end
        if not myPart then return end
        local hoverPos, distToHover = getHoverPos(target), (getHoverPos(target) - myPart.Position).Magnitude
        orientTowardTarget(myPart, target.Position, dt)
        if state == "approaching" then
            if distToHover > CONFIG.HoverSnapDist then
                myPart.AssemblyLinearVelocity = (hoverPos - myPart.Position).Unit * CONFIG.Speed
            else
                myPart.AssemblyLinearVelocity = Vector3.zero
                state, stateStart = "hovering", now
            end
        elseif state == "hovering" then
            local toHover = hoverPos - myPart.Position
            if toHover.Magnitude > CONFIG.Deadzone then
                myPart.AssemblyLinearVelocity = toHover.Unit * math.min(toHover.Magnitude * CONFIG.HoverGain, CONFIG.HoverMaxSpeed)
            else
                myPart.AssemblyLinearVelocity = Vector3.zero
            end
            shootAtTarget(myPart, target)
            if (target.Position - myPart.Position).Magnitude > CONFIG.HoverHeight * 2.5 then state, stateStart = "approaching", now end
        end
    end)
end

local function getInventory()
    local results, seen = {}, {}
    local fusion = P.PlayerGui:FindFirstChild("Fusion")
    if not fusion then return results end
    local stack = { { obj = fusion, depth = 0 } }
    while #stack > 0 do
        local entry = table.remove(stack)
        local obj, d = entry.obj, entry.depth
        if d <= 10 then
            local attr = obj:GetAttribute("TooltipData")
            if attr then
                local ok, decoded = pcall(Http.JSONDecode, Http, attr)
                if ok and decoded.Name and decoded.Levels then
                    local name = decoded.Name
                    if not seen[name] then
                        seen[name] = true
                        table.insert(results, { name = name, key = name .. "_1", label = name })
                    end
                end
            end
            for _, child in ipairs(obj:GetChildren()) do table.insert(stack, { obj = child, depth = d + 1 }) end
        end
    end
    return results
end

-- ── Self-reload from GitHub ───────────────────────────────────────────────────
-- Destroys the Rayfield window, stops all connections, then re-executes the
-- latest version of the script straight from your GitHub raw URL.
local function reloadFromGitHub()
    Rayfield:Notify({ Title = "Reloading...", Content = "Fetching latest from GitHub", Duration = 2 })
    task.wait(0.5)

    -- Clean up before re-running so nothing leaks
    stopAutofarm()
    pcall(function() Rayfield:Destroy() end)

    task.wait(0.3)

    local ok, result = pcall(function()
        loadstring(game:HttpGet(SCRIPT_URL, true))()
    end)
    if not ok then
        -- Rayfield is gone at this point so just warn via chat
        warn("[VehicleHub] Reload failed: " .. tostring(result))
    end
end

-- ── UI ────────────────────────────────────────────────────────────────────────
local Window = Rayfield:CreateWindow({ Name = "Vehicle Hub" })
local SpawnTab, FarmTab, SettingsTab
local targetBtns = {}
local lastTgtKey  = ""
local lastUIPoll  = 0

local buildTabs

local function rebuildTargets(found)
    table.clear(targetBtns)
    if selectedTarget and not selectedTarget.Parent then selectedTarget = nil end
    for i, body in ipairs(found) do
        local cBody, cIdx = body, i
        targetBtns[#targetBtns + 1] = FarmTab:CreateButton({
            Name = ("F35 #%d  (%.0f, %.0f, %.0f)"):format(i, body.Position.X, body.Position.Y, body.Position.Z),
            Callback = function()
                selectedTarget = cBody
                Rayfield:Notify({ Title = "Target locked", Content = "F35 #" .. cIdx, Duration = 2 })
            end
        })
    end
end

buildTabs = function()
    table.clear(targetBtns)
    if SpawnTab    then pcall(function() SpawnTab:Destroy()    end) end
    if FarmTab     then pcall(function() FarmTab:Destroy()     end) end
    if SettingsTab then pcall(function() SettingsTab:Destroy() end) end

    SpawnTab    = Window:CreateTab("Spawner")
    FarmTab     = Window:CreateTab("Autofarm")
    SettingsTab = Window:CreateTab("Settings")

    -- ── Spawner ───────────────────────────────────────────────────────────
    SpawnTab:CreateButton({
        Name = "🔄 Reload Script from GitHub",
        Callback = reloadFromGitHub
    })

    SpawnTab:CreateInput({
        Name = "Enter UUID  —  tap a vehicle first",
        PlaceholderText = "Tap a vehicle below, then paste UUID here",
        RemoveTextAfterFocusLost = false,
        Callback = function(val)
            val = val:gsub("%s+", "")
            if not pendingKey then
                Rayfield:Notify({ Title = "Tap a vehicle first", Content = "Select a vehicle below before typing", Duration = 3 })
                return
            end
            if #val < 10 then return end
            savedUUIDs[pendingKey] = val
            saveUUIDs()
            local label = pendingLabel or pendingKey
            local name  = pendingKey:match("^(.-)_%d+$") or pendingKey
            spawnVehicle(name, val)
            pendingKey, pendingLabel = nil, nil
            Rayfield:Notify({ Title = "Saved & Spawned", Content = label .. " UUID saved!", Duration = 3 })
            buildTabs()
        end
    })

    local inv = getInventory()
    for _, item in ipairs(inv) do
        local cKey, cName, cLabel = item.key, item.name, item.label
        SpawnTab:CreateButton({
            Name = (savedUUIDs[cKey] and "✔ " or "✘ ") .. cLabel,
            Callback = function()
                local id = savedUUIDs[cKey]
                if id then
                    spawnVehicle(cName, id)
                    Rayfield:Notify({ Title = "Spawned", Content = cLabel, Duration = 2 })
                else
                    pendingKey, pendingLabel = cKey, cLabel
                    Rayfield:Notify({ Title = "UUID needed", Content = cLabel .. " — paste UUID in the box above", Duration = 5 })
                end
            end
        })
    end

    local savedNames = {}
    for name in pairs(savedUUIDs) do table.insert(savedNames, name) end
    table.sort(savedNames)
    if #savedNames > 0 then
        SpawnTab:CreateLabel("── Saved UUIDs — tap to remove ──")
        for _, name in ipairs(savedNames) do
            local cName = name
            SpawnTab:CreateButton({
                Name = "🗑️ " .. cName,
                Callback = function()
                    savedUUIDs[cName] = nil
                    saveUUIDs()
                    Rayfield:Notify({ Title = "Removed", Content = cName .. " UUID deleted", Duration = 3 })
                    buildTabs()
                end
            })
        end
    end

    -- ── Autofarm ──────────────────────────────────────────────────────────
    FarmTab:CreateToggle({
        Name = "Enable Autofarm",
        CurrentValue = autofarmEnabled,
        Callback = function(val)
            autofarmEnabled = val
            if val then
                if not spawnedVehicle then
                    Rayfield:Notify({ Title = "Warning", Content = "Spawn a vehicle first", Duration = 4 })
                end
                startAutofarm()
                Rayfield:Notify({ Title = "Autofarm", Content = "Running", Duration = 2 })
            else
                stopAutofarm()
                Rayfield:Notify({ Title = "Autofarm", Content = "Stopped", Duration = 2 })
            end
        end
    })

    local _, targets = scanF35s()
    rebuildTargets(targets)
    lastTgtKey = ""

    -- ── Settings ──────────────────────────────────────────────────────────
    local sliders = {
        { "Travel Speed",            "Speed",            50,   1000, 10,   " st/s" },
        { "Snap Distance",           "HoverSnapDist",    5,    300,  5,    " st"   },
        { "Height Offset",           "HoverHeight",      -200, 200,  5,    " st"   },
        { "Bullet Rate (sec/shot)",  "FireRate",         0.05, 2.0,  0.05, " s"    },
        { "Missile Rate (sec/shot)", "MissileRate",      0.1,  5.0,  0.1,  " s"    },
    }
    SettingsTab:CreateLabel("── Movement & Weapons ───────────────")
    for _, s in ipairs(sliders) do
        local label, key, min, max, inc, suffix = table.unpack(s)
        SettingsTab:CreateSlider({
            Name = label, Range = { min, max }, Increment = inc,
            Suffix = suffix, CurrentValue = CONFIG[key],
            Callback = function(v) CONFIG[key] = v; saveSettings() end
        })
    end
    SettingsTab:CreateLabel("── Nudge (5 st per tap) ─────────────")
    local NUDGE = 5
    for _, n in ipairs({
        { "Higher (+5)",       "HoverHeight",        NUDGE  },
        { "Lower (-5)",        "HoverHeight",       -NUDGE  },
        { "More Forward (+5)", "HoverForwardOffset",  NUDGE  },
        { "More Behind (-5)",  "HoverForwardOffset", -NUDGE  },
    }) do
        local label, key, delta = table.unpack(n)
        SettingsTab:CreateButton({ Name = label, Callback = function()
            CONFIG[key] = CONFIG[key] + delta
            saveSettings()
            Rayfield:Notify({ Title = key, Content = "Now " .. CONFIG[key] .. " st", Duration = 1 })
        end })
    end
    SettingsTab:CreateButton({
        Name = "⟳ Reset All Settings to Default",
        Callback = function()
            for k, v in pairs(DEFAULT_CONFIG) do CONFIG[k] = v end
            saveSettings()
            Rayfield:Notify({ Title = "Settings Reset", Content = "All values restored. Reopen Settings tab to see sliders update.", Duration = 4 })
        end
    })
end

buildTabs()

-- ── Background target-list refresh ───────────────────────────────────────────
Run.Heartbeat:Connect(function()
    local now = tick()
    if now - lastUIPoll < 0.5 then return end
    lastUIPoll = now
    if not FarmTab then return end
    local _, targets = scanF35s()
    local key = ""
    for _, b in ipairs(targets) do key = key .. tostring(b) .. "," end
    if key ~= lastTgtKey then
        lastTgtKey = key
        rebuildTargets(targets)
    end
end)
