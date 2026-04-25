-- Vehicle Hub | Fixed Version
-- Fixed: No duplicate UI elements on spawn
-- Fixed: Gun and Missile are separate toggle switches that save per vehicle
-- Fixed: Removed auto-select for weapons

local SCRIPT_URL = "https://raw.githubusercontent.com/YOUR_NAME/YOUR_REPO/main/vehicle_hub.lua"

local RS, Players, Http, Run =
    game:GetService("ReplicatedStorage"),
    game:GetService("Players"),
    game:GetService("HttpService"),
    game:GetService("RunService")

local P = Players.LocalPlayer

local knit = nil
pcall(function()
    local pkg = RS.Packages._Index:FindFirstChild("sleitnick_knit@1.5.1")
    if pkg then knit = pkg.knit.Services.VehicleService end
end)

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local DEFAULT_CONFIG = {
    Speed              = 400,
    HoverHeight        = 50,
    HoverForwardOffset = 30,
    HoverLateralOffset = 0,
    HoverSnapDist      = 30,
    PatrolStopDist     = 200,
    HoverMaxSpeed      = 150,
    HoverGain          = 2.5,
    HoverDamp          = 0.35,
    HoverSmooth        = 0.08,
    Deadzone           = 2.0,
    LookSmoothness     = 0.3,
    FireRate           = 0.1,
    MissileRate        = 0.6,
    MissileSpeed       = 5000,
    MissileLead        = 0.3,
    AvoidDist          = 80,
    AvoidStrength      = 1.0,
}
local CONFIG = {}
for k, v in pairs(DEFAULT_CONFIG) do CONFIG[k] = v end

local spawnCoords = {
    Vector3.new( 2669.02,  651.91,  -623.42),
    Vector3.new( 1362.56,  678.43,  -960.20),
    Vector3.new( 1089.36,  631.47, -1947.38),
    Vector3.new(  -14.62, 1232.61, -1012.30),
    Vector3.new(-1044.81,  611.31, -1206.94),
    Vector3.new( -981.76,  861.38, -2392.76),
}

local UUID_FILE      = "vehicle_uuids.json"
local SETTINGS_FILE  = "vehicle_settings.json"
local WEAPONS_FILE   = "vehicle_weapons.json"

local savedUUIDs   = {}
local savedWeapons = {}

pcall(function()
    if isfile(UUID_FILE) then savedUUIDs = Http:JSONDecode(readfile(UUID_FILE)) end
end)
pcall(function()
    if isfile(SETTINGS_FILE) then
        local loaded = Http:JSONDecode(readfile(SETTINGS_FILE))
        for k, v in pairs(loaded) do
            if DEFAULT_CONFIG[k] ~= nil then CONFIG[k] = v end
        end
    end
end)
pcall(function()
    if isfile(WEAPONS_FILE) then savedWeapons = Http:JSONDecode(readfile(WEAPONS_FILE)) end
end)

local function saveUUIDs()
    pcall(writefile, UUID_FILE, Http:JSONEncode(savedUUIDs))
end
local function saveSettings()
    local t = {}
    for k, v in pairs(CONFIG) do t[k] = v end
    pcall(writefile, SETTINGS_FILE, Http:JSONEncode(t))
end
local function saveWeapons()
    pcall(writefile, WEAPONS_FILE, Http:JSONEncode(savedWeapons))
end

-- Weapon settings for current vehicle
local useGun = true
local useMissile = false

local function getWeaponsForVehicle(name)
    local data = savedWeapons[name]
    if data then
        return data.gun or true, data.missile or false
    end
    return true, false  -- default: gun on, missile off
end

local function setWeaponsForVehicle(name, gun, missile)
    savedWeapons[name] = { gun = gun, missile = missile }
    saveWeapons()
    useGun = gun
    useMissile = missile
end

local spawnedVehicle, lastSpawnedUUID, autofarmEnabled, autofarmConn = nil, nil, false, nil
local selectedTarget, state, stateStart, lastRetarget, patrolIdx = nil, "patrol", tick(), tick(), 1
local pendingKey, pendingLabel, lastShot, lastMissileShot, cachedFireRemote = nil, nil, 0, 0, nil
local avoidEnabled = true

local smoothedHoverPos = Vector3.zero
local hoverPosInitialized = false

local lockCache, lastLockCheck = false, 0
local LOCK_TTL = 0.15
local _lockStack = {}

local function isTargetLocked()
    local now = tick()
    if now - lastLockCheck < LOCK_TTL then return lockCache end
    lastLockCheck = now
    local stackTop = 1
    _lockStack[1] = {obj = P.PlayerGui, d = 0}
    local found = false
    while stackTop > 0 do
        local e = _lockStack[stackTop]; stackTop = stackTop - 1
        local obj, depth = e.obj, e.d
        if depth <= 8 then
            if obj:IsA("Frame") and obj.Visible then
                local bc = obj.BorderColor3
                if bc.G > 0.55 and bc.R < 0.35 and bc.B < 0.35 then found = true; break end
                local bg = obj.BackgroundColor3
                if bg.G > 0.55 and bg.R < 0.35 and bg.B < 0.35 and obj.BackgroundTransparency < 0.95 then
                    found = true; break
                end
            end
            if depth < 8 then
                for _, child in ipairs(obj:GetChildren()) do
                    stackTop = stackTop + 1
                    local slot = _lockStack[stackTop]
                    if slot then slot.obj = child; slot.d = depth + 1
                    else _lockStack[stackTop] = {obj = child, d = depth + 1} end
                end
            end
        end
    end
    lockCache = found
    return found
end

local vehiclesFolder = workspace:WaitForChild("Vehicles", 10)
local myPartCache, myPartConn = nil, nil

local function invalidateMyPart()
    myPartCache = nil
    if myPartConn then myPartConn:Disconnect(); myPartConn = nil end
end

local function getMyPlaneRoot()
    if myPartCache and myPartCache.Parent then return myPartCache end
    if not spawnedVehicle or not vehiclesFolder then invalidateMyPart(); return nil end
    local model = vehiclesFolder:FindFirstChild(spawnedVehicle)
    if not model then invalidateMyPart(); return nil end
    myPartCache = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
    if myPartCache and not myPartConn then
        myPartConn = model.AncestryChanged:Connect(function() invalidateMyPart() end)
    end
    return myPartCache
end

local hrpCache = nil
if P.Character then hrpCache = P.Character:FindFirstChild("HumanoidRootPart") end

local function getFireRemote()
    if cachedFireRemote and cachedFireRemote.Parent then return cachedFireRemote end
    cachedFireRemote = nil
    if not spawnedVehicle or not vehiclesFolder then return nil end
    local vModel = vehiclesFolder:FindFirstChild(spawnedVehicle)
    if vModel then cachedFireRemote = vModel:FindFirstChild("Fire", true) end
    return cachedFireRemote
end

local function waitForFireRemote()
    task.spawn(function()
        for _ = 1, 10 do
            if cachedFireRemote and cachedFireRemote.Parent then return end
            getFireRemote()
            if cachedFireRemote then return end
            task.wait(0.5)
        end
    end)
end

local function getMissileAimPos(origin, target)
    local pos = target.Position
    local vel = Vector3.zero
    pcall(function() vel = target.AssemblyLinearVelocity end)
    local lead = CONFIG.MissileLead
    if lead <= 0 then return pos end
    local t1 = (pos - origin).Magnitude / math.max(CONFIG.MissileSpeed, 1)
    local p1 = pos + vel * (t1 * lead)
    local t2 = (p1 - origin).Magnitude / math.max(CONFIG.MissileSpeed, 1)
    return pos + vel * (t2 * lead)
end

local function scanF35s()
    if not vehiclesFolder then return nil, {} end
    local ref = hrpCache and hrpCache.Position or Vector3.zero
    local closest, closestDist, all = nil, math.huge, {}
    for _, v in ipairs(vehiclesFolder:GetChildren()) do
        if v.Name == "F35" then
            local body = v:FindFirstChild("VehicleObject")
                and v.VehicleObject:FindFirstChild("StealthF35")
                and v.VehicleObject.StealthF35:FindFirstChild("BodyMesh")
            if body then
                table.insert(all, body)
                local d = (body.Position - ref).Magnitude
                if d < closestDist then closest, closestDist = body, d end
            end
        end
    end
    return closest, all
end

local function orientTowardTarget(part, targetPos, dt)
    local cf = part.CFrame
    local dir = (targetPos - cf.Position).Unit
    local up = math.abs(dir.Y) > 0.99 and Vector3.xAxis or Vector3.yAxis
    part.CFrame = cf:Lerp(CFrame.lookAt(cf.Position, targetPos, up),
        math.clamp(CONFIG.LookSmoothness * dt * 60, 0, 1))
end

local avoidParams = RaycastParams.new()
avoidParams.FilterType = Enum.RaycastFilterType.Exclude
local avoidExcludesDirty = true

local function markAvoidDirty() avoidExcludesDirty = true end

local function buildAvoidExcludes()
    if not avoidExcludesDirty then return end
    avoidExcludesDirty = false
    local ex = {}
    if P.Character then table.insert(ex, P.Character) end
    if spawnedVehicle and vehiclesFolder then
        local vm = vehiclesFolder:FindFirstChild(spawnedVehicle)
        if vm then table.insert(ex, vm) end
    end
    avoidParams.FilterDescendantsInstances = ex
end

local lastAvoidTime, cachedAvoidVec = 0, Vector3.zero
local AVOID_RATE = 0.1

local function getAvoidanceVector(myPart, intendedDir)
    if not avoidEnabled or CONFIG.AvoidDist <= 0 then return Vector3.zero end
    local now = tick()
    if now - lastAvoidTime < AVOID_RATE then return cachedAvoidVec end
    lastAvoidTime = now
    buildAvoidExcludes()
    local origin = myPart.Position
    local dist = CONFIG.AvoidDist
    local cf = myPart.CFrame
    local right, up = cf.RightVector, cf.UpVector
    local rays = {
        intendedDir,
        (intendedDir + right * 0.6).Unit,
        (intendedDir - right * 0.6).Unit,
        (intendedDir + up * 0.6).Unit,
        (intendedDir - up * 0.6).Unit,
        right, -right,
    }
    local avoidance = Vector3.zero
    for i, dir in ipairs(rays) do
        local result = workspace:Raycast(origin, dir * dist, avoidParams)
        if result then
            local weight = (dist - result.Distance) / dist
            local strength = i <= 5 and 1.0 or 0.4
            avoidance = avoidance + result.Normal * weight * strength * CONFIG.AvoidStrength
        end
    end
    cachedAvoidVec = avoidance
    return avoidance
end

local function applyMovement(myPart, intendedVelocity)
    if intendedVelocity.Magnitude < 0.01 then
        myPart.AssemblyLinearVelocity = Vector3.zero; return
    end
    local dir = intendedVelocity.Unit
    local avoid = getAvoidanceVector(myPart, dir)
    local final = dir + avoid
    myPart.AssemblyLinearVelocity = final.Magnitude > 0.01
        and final.Unit * intendedVelocity.Magnitude
        or intendedVelocity
end

local function shootAtTarget(myPart, target)
    local now = tick()
    local fireRemote = getFireRemote()
    if not fireRemote then return end
    
    -- Gun firing (only if enabled)
    if useGun and now - lastShot >= CONFIG.FireRate and isTargetLocked() then
        lastShot = now
        fireRemote:FireServer(2, myPart.Position, target.Position,
            target, myPart.Position, Vector3.new(0, 1, 0), {})
    end
    
    -- Missile firing (only if enabled)
    if useMissile and now - lastMissileShot >= CONFIG.MissileRate then
        lastMissileShot = now
        fireRemote:FireServer("Secondary", getMissileAimPos(myPart.Position, target), {})
    end
end

local function spawnVehicle(name, uuid)
    if not knit then
        Rayfield:Notify({Title = "Error", Content = "Knit service unavailable", Duration = 3})
        return false
    end
    local ok, err = pcall(function() knit.RF.Spawn:InvokeServer(uuid) end)
    if not ok then
        Rayfield:Notify({Title = "Spawn Failed", Content = tostring(err), Duration = 5})
        return false
    end
    spawnedVehicle, lastSpawnedUUID, cachedFireRemote = name, uuid, nil
    invalidateMyPart()
    markAvoidDirty()
    hoverPosInitialized = false
    
    -- Load this vehicle's saved weapon settings
    local gun, missile = getWeaponsForVehicle(name)
    useGun = gun
    useMissile = missile
    
    task.wait(0.5)
    if not getMyPlaneRoot() then
        Rayfield:Notify({Title = "Warning", Content = "Vehicle model may be incomplete", Duration = 4})
    end
    waitForFireRemote()
    
    local weaponStatus = ""
    if useGun and useMissile then weaponStatus = "GUN + MISSILE"
    elseif useGun then weaponStatus = "GUN only"
    elseif useMissile then weaponStatus = "MISSILE only"
    else weaponStatus = "NO WEAPONS" end
    
    Rayfield:Notify({Title = name .. " deployed", Content = weaponStatus, Duration = 3})
    return true
end

P.CharacterAdded:Connect(function(char)
    hrpCache = nil
    invalidateMyPart()
    markAvoidDirty()
    hoverPosInitialized = false
    char:WaitForChild("HumanoidRootPart", 10)
    hrpCache = char:FindFirstChild("HumanoidRootPart")
    task.wait(2)
    if autofarmEnabled and lastSpawnedUUID and spawnedVehicle then
        cachedFireRemote = nil
        knit.RF.Spawn:InvokeServer(lastSpawnedUUID)
        task.wait(0.5)
        waitForFireRemote()
        local gun, missile = getWeaponsForVehicle(spawnedVehicle)
        useGun = gun
        useMissile = missile
        Rayfield:Notify({Title = "Respawned", Content = spawnedVehicle .. " re-deployed", Duration = 3})
    end
end)

local function stopAutofarm()
    if autofarmConn then autofarmConn:Disconnect(); autofarmConn = nil end
end

local function startAutofarm()
    stopAutofarm()
    state, stateStart, lastRetarget, patrolIdx = "patrol", tick(), tick(), 1
    cachedAvoidVec, lastAvoidTime = Vector3.zero, 0
    hoverPosInitialized = false
    local lastPatrolScan = 0

    autofarmConn = Run.Heartbeat:Connect(function(dt)
        if not autofarmEnabled then return end
        local now = tick()

        local cfgSpeed = CONFIG.Speed
        local cfgSnap = CONFIG.HoverSnapDist
        local cfgFwd = CONFIG.HoverForwardOffset
        local cfgLat = CONFIG.HoverLateralOffset
        local cfgH = CONFIG.HoverHeight
        local cfgGain = CONFIG.HoverGain
        local cfgDamp = CONFIG.HoverDamp
        local cfgSmooth = CONFIG.HoverSmooth
        local cfgMaxSpd = CONFIG.HoverMaxSpeed
        local cfgDead = CONFIG.Deadzone

        local myPart = getMyPlaneRoot()
        local ref = myPart and myPart.Position
                     or (hrpCache and hrpCache.Position)
                     or Vector3.zero
        local target = selectedTarget

        if state == "patrol" then
            hoverPosInitialized = false
            local wp = spawnCoords[patrolIdx]
            local toWp = wp - ref
            if myPart then
                if toWp.Magnitude > CONFIG.PatrolStopDist then
                    applyMovement(myPart, toWp.Unit * cfgSpeed)
                    orientTowardTarget(myPart, ref + toWp.Unit * 100, dt)
                else
                    patrolIdx = patrolIdx % #spawnCoords + 1
                end
            end
            if now - lastPatrolScan >= 0.5 then
                lastPatrolScan = now
                local found = scanF35s()
                if found then
                    selectedTarget, lastRetarget, state, stateStart = found, now, "approaching", now
                end
            end
            return
        end

        if not target or not target.Parent then
            local found = scanF35s()
            selectedTarget, lastRetarget = found, now
            if not found then state, stateStart = "patrol", now; return end
            target, state, stateStart = found, "approaching", now
            hoverPosInitialized = false
        end

        if state == "approaching" and now - lastRetarget >= 3 then
            local nt = scanF35s()
            if nt then
                if nt ~= target then hoverPosInitialized = false end
                selectedTarget, target = nt, nt
            end
            lastRetarget = now
        end

        if not myPart then return end

        local tCF = target.CFrame
        local realHoverPos = target.Position
            + tCF.LookVector * cfgFwd
            + tCF.RightVector * cfgLat
            + Vector3.new(0, cfgH, 0)

        if not hoverPosInitialized then
            smoothedHoverPos = realHoverPos
            hoverPosInitialized = true
        else
            local alpha = math.clamp(cfgSmooth * dt * 60, 0, 1)
            smoothedHoverPos = smoothedHoverPos:Lerp(realHoverPos, alpha)
        end

        local distToHover = (smoothedHoverPos - myPart.Position).Magnitude
        orientTowardTarget(myPart, target.Position, dt)

        if state == "approaching" then
            if distToHover > cfgSnap then
                applyMovement(myPart, (smoothedHoverPos - myPart.Position).Unit * cfgSpeed)
            else
                myPart.AssemblyLinearVelocity = Vector3.zero
                state, stateStart = "hovering", now
            end
        elseif state == "hovering" then
            local toHover = smoothedHoverPos - myPart.Position
            if toHover.Magnitude > cfgDead then
                local currentVel = myPart.AssemblyLinearVelocity
                local desired = toHover.Unit * math.min(toHover.Magnitude * cfgGain, cfgMaxSpd)
                local damped = desired - currentVel * cfgDamp
                applyMovement(myPart, damped.Magnitude > 0.01 and damped or toHover.Unit * 0.1)
            else
                myPart.AssemblyLinearVelocity = Vector3.zero
            end
            shootAtTarget(myPart, target)
            if (target.Position - myPart.Position).Magnitude > math.abs(cfgH) * 2.5 then
                state, stateStart = "approaching", now
            end
        end
    end)
end

local function getInventory()
    local results, seen = {}, {}
    local fusion = P.PlayerGui:FindFirstChild("Fusion")
    if not fusion then return results end
    local stack = {{obj = fusion, depth = 0}}
    while #stack > 0 do
        local entry = table.remove(stack)
        local obj, d = entry.obj, entry.depth
        if d <= 10 then
            local attr = obj:GetAttribute("TooltipData")
            if attr then
                local ok, decoded = pcall(function() return Http:JSONDecode(attr) end)
                if ok and decoded.Name and decoded.Levels then
                    local name = decoded.Name
                    if not seen[name] then
                        seen[name] = true
                        table.insert(results, {name = name, key = name .. "_1", label = name})
                    end
                end
            end
            for _, child in ipairs(obj:GetChildren()) do
                table.insert(stack, {obj = child, depth = d + 1})
            end
        end
    end
    return results
end

local function reloadFromGitHub()
    if SCRIPT_URL:find("YOUR_NAME") then
        Rayfield:Notify({Title = "Update Disabled", Content = "SCRIPT_URL not set", Duration = 4})
        return
    end
    Rayfield:Notify({Title = "Updating", Content = "Fetching latest version from GitHub", Duration = 2})
    task.wait(0.5)
    stopAutofarm()
    pcall(function() Rayfield:Destroy() end)
    task.wait(0.3)
    local ok, err = pcall(function() loadstring(game:HttpGet(SCRIPT_URL, true))() end)
    if not ok then warn("[VehicleHub] Reload failed: " .. tostring(err)) end
end

local Window = Rayfield:CreateWindow({Name = "Vehicle Hub"})
local SpawnTab, FarmTab, SettingsTab
local targetBtns = {}
local lastTgtKey, lastUIPoll = "", 0
local tabsBusy = false
local buildTabs

local function rebuildTargets(found)
    if tabsBusy or not FarmTab then return end
    -- Clear existing buttons safely
    for _, btn in ipairs(targetBtns) do
        pcall(function() btn:Destroy() end)
    end
    table.clear(targetBtns)
    if selectedTarget and not selectedTarget.Parent then selectedTarget = nil end
    for i, body in ipairs(found) do
        local cBody, cIdx = body, i
        local ok, btn = pcall(function()
            return FarmTab:CreateButton({
                Name = ("Target %d   —   %.0f, %.0f, %.0f"):format(
                    i, body.Position.X, body.Position.Y, body.Position.Z),
                Callback = function()
                    selectedTarget = cBody
                    Rayfield:Notify({Title = "Target Acquired",
                        Content = "Locked onto Target " .. cIdx, Duration = 2})
                end,
            })
        end)
        if ok then targetBtns[#targetBtns + 1] = btn end
    end
end

buildTabs = function()
    if tabsBusy then return end
    tabsBusy = true
    
    -- Clean up old tabs properly
    if SpawnTab then pcall(function() SpawnTab:Destroy() end); SpawnTab = nil end
    if FarmTab then pcall(function() FarmTab:Destroy() end); FarmTab = nil end
    if SettingsTab then pcall(function() SettingsTab:Destroy() end); SettingsTab = nil end
    
    task.wait(0.1)

    SpawnTab = Window:CreateTab("Spawner")
    FarmTab = Window:CreateTab("Autofarm")
    SettingsTab = Window:CreateTab("Settings")
    task.wait()

    -- Spawn Tab
    SpawnTab:CreateButton({Name = "Refresh Script", Callback = reloadFromGitHub})
    SpawnTab:CreateInput({
        Name = "Vehicle UUID",
        PlaceholderText = "Select a vehicle below, then paste its UUID here",
        RemoveTextAfterFocusLost = false,
        Callback = function(val)
            val = val:gsub("%s+", "")
            if not pendingKey then
                Rayfield:Notify({Title = "No Vehicle Selected",
                    Content = "Tap a vehicle below before entering a UUID", Duration = 3})
                return
            end
            if #val < 10 then return end
            savedUUIDs[pendingKey] = val
            saveUUIDs()
            local label = pendingLabel or pendingKey
            local name = pendingKey:match("^(.-)_%d+$") or pendingKey
            local ok = spawnVehicle(name, val)
            if ok then
                pendingKey, pendingLabel = nil, nil
                Rayfield:Notify({Title = "Saved",
                    Content = label .. " saved and deployed", Duration = 3})
                -- Refresh UI without full rebuild to avoid duplication
                task.wait(0.5)
                buildTabs()
            end
        end,
    })

    local inv = getInventory()
    for _, item in ipairs(inv) do
        local cKey, cName, cLabel = item.key, item.name, item.label
        SpawnTab:CreateButton({
            Name = (savedUUIDs[cKey] and "[Ready]  " or "[No UUID]  ") .. cLabel,
            Callback = function()
                local id = savedUUIDs[cKey]
                if id then
                    local ok = spawnVehicle(cName, id)
                    if ok then
                        Rayfield:Notify({Title = "Deployed",
                            Content = cLabel .. " is now active", Duration = 2})
                        -- Don't rebuild here to avoid duplication
                    end
                else
                    pendingKey, pendingLabel = cKey, cLabel
                    Rayfield:Notify({Title = "UUID Required",
                        Content = "Paste the UUID for " .. cLabel .. " in the field above",
                        Duration = 5})
                end
            end,
        })
    end

    local savedNames = {}
    for name in pairs(savedUUIDs) do table.insert(savedNames, name) end
    table.sort(savedNames)
    if #savedNames > 0 then
        SpawnTab:CreateLabel("Saved Vehicles")
        for _, name in ipairs(savedNames) do
            local cName = name
            SpawnTab:CreateButton({
                Name = "Remove   " .. cName,
                Callback = function()
                    savedUUIDs[cName] = nil
                    saveUUIDs()
                    Rayfield:Notify({Title = "Removed",
                        Content = cName .. " deleted", Duration = 3})
                    buildTabs()
                end,
            })
        end
    end

    -- Farm Tab
    FarmTab:CreateToggle({
        Name = "Autofarm",
        CurrentValue = autofarmEnabled,
        Callback = function(val)
            autofarmEnabled = val
            if val then
                if not spawnedVehicle then
                    Rayfield:Notify({Title = "No Vehicle Active",
                        Content = "Deploy a vehicle before starting", Duration = 4})
                end
                startAutofarm()
                Rayfield:Notify({Title = "Autofarm", Content = "Now active", Duration = 2})
            else
                stopAutofarm()
                Rayfield:Notify({Title = "Autofarm", Content = "Stopped", Duration = 2})
            end
        end,
    })
    
    FarmTab:CreateToggle({
        Name = "Obstacle Avoidance",
        CurrentValue = avoidEnabled,
        Callback = function(val)
            avoidEnabled = val
            Rayfield:Notify({Title = "Obstacle Avoidance",
                Content = val and "Enabled" or "Disabled", Duration = 2})
        end,
    })

    -- Weapon Toggles (separate, no auto-select)
    local currentVehicleName = spawnedVehicle or "none"
    local currentGun, currentMissile = getWeaponsForVehicle(currentVehicleName)
    
    -- Gun Toggle
    FarmTab:CreateToggle({
        Name = "🔫 GUN",
        CurrentValue = currentGun,
        Callback = function(val)
            if not spawnedVehicle then
                Rayfield:Notify({Title = "No vehicle active", Content = "Spawn a vehicle first", Duration = 3})
                return
            end
            useGun = val
            setWeaponsForVehicle(spawnedVehicle, useGun, useMissile)
            Rayfield:Notify({Title = spawnedVehicle,
                Content = "GUN " .. (val and "ON" or "OFF"), Duration = 2})
        end,
    })
    
    -- Missile Toggle (below Gun)
    FarmTab:CreateToggle({
        Name = "🚀 MISSILE",
        CurrentValue = currentMissile,
        Callback = function(val)
            if not spawnedVehicle then
                Rayfield:Notify({Title = "No vehicle active", Content = "Spawn a vehicle first", Duration = 3})
                return
            end
            useMissile = val
            setWeaponsForVehicle(spawnedVehicle, useGun, useMissile)
            Rayfield:Notify({Title = spawnedVehicle,
                Content = "MISSILE " .. (val and "ON" or "OFF"), Duration = 2})
        end,
    })

    local _, targets = scanF35s()
    rebuildTargets(targets)
    lastTgtKey = ""

    -- Settings Tab
    local sliders = {
        {"Travel Speed", "Speed", 50, 5000, 100, " st/s"},
        {"Snap Distance", "HoverSnapDist", 5, 1000, 10, " st"},
        {"Height Offset", "HoverHeight", -1000, 1000, 10, " st"},
        {"Bullet Fire Rate", "FireRate", 0.05, 2.0, 0.05, " s"},
        {"Missile Fire Rate", "MissileRate", 0.1, 5.0, 0.1, " s"},
        {"Missile Speed", "MissileSpeed", 100, 5000, 100, " st/s"},
        {"Missile Lead (0=homing 1=full)", "MissileLead", 0, 1.0, 0.05, ""},
        {"Hover Smoothness (lower=smoother)", "HoverSmooth", 0.01, 0.5, 0.01, ""},
        {"Hover Damping (higher=less bounce)", "HoverDamp", 0, 1.0, 0.05, ""},
        {"Avoidance Range", "AvoidDist", 20, 1000, 10, " st"},
        {"Avoidance Strength", "AvoidStrength", 0.1, 10.0, 0.1, "x"},
    }
    SettingsTab:CreateLabel("Movement & Combat")
    for _, s in ipairs(sliders) do
        local label, key, mn, mx, inc, suffix = table.unpack(s)
        SettingsTab:CreateSlider({
            Name = label, Range = {mn, mx}, Increment = inc,
            Suffix = suffix, CurrentValue = CONFIG[key],
            Callback = function(v) CONFIG[key] = v; saveSettings() end,
        })
    end

    SettingsTab:CreateLabel("Speed Nudge (+/- 100 st/s)")
    SettingsTab:CreateButton({Name = "Speed +100", Callback = function()
        CONFIG.Speed = math.min(CONFIG.Speed + 100, 5000); saveSettings()
        Rayfield:Notify({Title = "Speed", Content = "Now " .. CONFIG.Speed .. " st/s", Duration = 1})
    end})
    SettingsTab:CreateButton({Name = "Speed -100", Callback = function()
        CONFIG.Speed = math.max(CONFIG.Speed - 100, 50); saveSettings()
        Rayfield:Notify({Title = "Speed", Content = "Now " .. CONFIG.Speed .. " st/s", Duration = 1})
    end})

    SettingsTab:CreateLabel("Position Nudge (+/- 5 st)")
    local NUDGE = 5
    local nudges = {
        {"Increase Height", "HoverHeight", NUDGE},
        {"Decrease Height", "HoverHeight", -NUDGE},
        {"Move Forward", "HoverForwardOffset", -NUDGE},
        {"Move Backward", "HoverForwardOffset", NUDGE},
    }
    for _, n in ipairs(nudges) do
        local label, key, delta = table.unpack(n)
        SettingsTab:CreateButton({
            Name = label,
            Callback = function()
                CONFIG[key] = CONFIG[key] + delta
                saveSettings()
                Rayfield:Notify({Title = key, Content = "Now " .. CONFIG[key] .. " st", Duration = 1})
            end,
        })
    end

    SettingsTab:CreateButton({
        Name = "Reset to Default",
        Callback = function()
            for k, v in pairs(DEFAULT_CONFIG) do CONFIG[k] = v end
            saveSettings()
            Rayfield:Notify({Title = "Settings Reset",
                Content = "All values restored to default", Duration = 4})
        end,
    })

    tabsBusy = false
end

buildTabs()

-- UI Poll - only updates targets, never rebuilds whole UI
Run.Heartbeat:Connect(function()
    local now = tick()
    if now - lastUIPoll < 0.5 then return end
    lastUIPoll = now
    if tabsBusy or not FarmTab then return end
    local _, targets = scanF35s()
    local key = ""
    for _, b in ipairs(targets) do key = key .. tostring(b) .. "," end
    if key ~= lastTgtKey then lastTgtKey = key; rebuildTargets(targets) end
end)