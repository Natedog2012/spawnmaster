local mq = require('mq')
require('ImGui')

local Icons = require('mq.ICONS')

local OpenEditor, OpenSpawnViewer = false, true
local npc_list = {}  -- Persistent watchlist of spawn queries per zone
local tracked_spawns = {}
local alerted_spawn = {}
local alert_on = {}
local input_npc_name = ""
local file_path = mq.luaDir .. "/spawnmaster/npc_watchlist_by_zone.json"
local lockWindow = false

-- MacroQuest command to reopen the editor
mq.bind('/sm_edit', function()
    OpenEditor = true
end)

mq.bind('/sm_lock', function()
    lockWindow = not lockWindow
end)

-- MacroQuest command to reopen the spawn viewer
mq.bind('/showspawns', function()
    OpenSpawnViewer = true
end)

-- Manual JSON Stringifier
local function table_to_json(tbl)
    local json = "{\n"
    for zone, queries in pairs(tbl) do
        json = json .. string.format('    "%s": [', zone)
        local items = {}
        for _, v in ipairs(queries) do
            local alert_state = (alert_on[zone] and alert_on[zone][v]) and true or false
            table.insert(items, string.format('{"query": "%s", "alert": %s}', v, tostring(alert_state)))
        end
        json = json .. table.concat(items, ", ")
        json = json .. "],\n"
    end
    json = json .. "}"
    return json
end

-- Manual JSON Parser (supports both old and new format)
local function json_to_table(json)
    local tbl = {}
    alert_on = {}
    for zone, entry_list_str in json:gmatch('"([^"]+)": %[(.-)%]') do
        local queries = {}
        alert_on[zone] = {}
        local has_new_format = false
        for query_obj in entry_list_str:gmatch('{.-}') do
            has_new_format = true
            local query = query_obj:match('"query"%s*:%s*"([^"]+)"')
            local alert_state = query_obj:match('"alert"%s*:%s*true')
            if query then
                table.insert(queries, query)
                alert_on[zone][query] = (alert_state ~= nil)
            end
        end
        if not has_new_format then
            for query in entry_list_str:gmatch('"([^"]+)"') do
                table.insert(queries, query)
                alert_on[zone][query] = false
            end
        end
        tbl[zone] = queries
    end
    return tbl
end

-- 🔹 Save the watchlist to a JSON file
local function save_npc_list()
    local file = io.open(file_path, "w")
    if file then
        file:write(table_to_json(npc_list))
        file:close()
    end
end

-- 🔹 Load the watchlist from a JSON file
local function load_npc_list()
    local file = io.open(file_path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        npc_list = json_to_table(content) or {}
    end
end

-- 🔹 Update the list of currently spawned entities (Only in the current zone)
local function update_tracked_spawns()
    tracked_spawns = {}
    local current_zone = mq.TLO.Zone.ShortName() or "Unknown"
	
	if not alerted_spawn[current_zone] then
		alerted_spawn[current_zone] = {}
	end

    if npc_list[current_zone] then
        tracked_spawns[current_zone] = {}
        for _, query in ipairs(npc_list[current_zone]) do
			if (not string.find(query, "Chest")) then
				--query = "=" .. query
			else
				query = query .. " object"
			end
            local spawn_count = mq.TLO.SpawnCount(query)()
            if spawn_count and spawn_count > 0 then
                for i = 1, spawn_count do
                    local spawn_name = mq.TLO.NearestSpawn(i, query).CleanName()
                    local spawn_loc = string.format("(%d, %d, %d)", 
                        mq.TLO.NearestSpawn(i, query).X() or 0,
                        mq.TLO.NearestSpawn(i, query).Y() or 0,
                        mq.TLO.NearestSpawn(i, query).Z() or 0)
                    table.insert(tracked_spawns[current_zone], {name = spawn_name, location = spawn_loc})
					
					--Don't beep for corpse~
					if not alert_on[current_zone] then
						alert_on[current_zone] = {}
					end
					if (alert_on[current_zone][query] and not check_found(spawn_name) and not string.find(spawn_name, "`s corpse", 1, true)) then
                            mq.cmd('/beep sounds/achievement.wav')
							--table.insert(alerted_spawn[current_zone], {name = spawn_name})
							-- Adding/Alerting --- TEST
							alerted_spawn[current_zone][spawn_name] = true
							print(string.format("Adding new NPC: %s", spawn_name))
                    end
                end
            end
        end
    end
end

function check_found(target_name)
	--TEST CODE
	local current_zone = mq.TLO.Zone.ShortName() or "Unknown"
	if alerted_spawn[current_zone] and alerted_spawn[current_zone][target_name] then
		return true
	end
	
	return false
end

function clean_found()
	local spawn_count = 0
	local current_zone = mq.TLO.Zone.ShortName() or "Unknown"
    -- Safety check: make sure the table for the current zone exists
    if not alerted_spawn[current_zone] then
		print "Not found in current zone"
        return false 
    end
	
	

    -- Loop through the list of spawns in the current zone
    for npc_name, is_alerted in pairs(alerted_spawn[current_zone]) do
        -- Check if the 'name' key in the current entry matches your target
		--print(string.format("Checking NPC: %s", npc_name))
		spawn_count = mq.TLO.SpawnCount(npc_name)()
        if spawn_count <= 0 then
			print(string.format("Removing missing NPC: %s", npc_name))
			alerted_spawn[current_zone][npc_name] = nil
        end
    end
end

-- 🔹 Draw the Spawn Query Watchlist Editor with improved layout
local function draw_editor()
    if not OpenEditor then return end
    ImGui.SetNextWindowSize(400, 500, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowBgAlpha(0.6)
    OpenEditor = ImGui.Begin("Spawn Query Watchlist Editor", OpenEditor)

    local current_zone = mq.TLO.Zone.ShortName() or "Unknown"
    -- Display a descriptive label on its own
    ImGui.Text("Add spawn query in " .. current_zone)
    -- Set a fixed width for the input field so it doesn't stretch the window
    ImGui.SetNextItemWidth(250)
    input_npc_name = ImGui.InputText("##spawnQuery", input_npc_name, 64)
    ImGui.SameLine()
    if ImGui.Button("Add") and input_npc_name ~= "" then
        if not npc_list[current_zone] then npc_list[current_zone] = {} end
        table.insert(npc_list[current_zone], input_npc_name)
        save_npc_list()  -- Save when adding
        input_npc_name = ""
    end

    -- Display a table of spawn queries being watched
    for zone, queries in pairs(npc_list) do
        if ImGui.CollapsingHeader(zone) then
            if ImGui.BeginTable("WatchlistTable_" .. zone, 3, ImGuiTableFlags.Borders) then
                ImGui.TableSetupColumn("Spawn Query", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn("Remove", ImGuiTableColumnFlags.WidthFixed, 80)
				ImGui.TableSetupColumn("Alert", ImGuiTableColumnFlags.WidthFixed, 80)
                ImGui.TableHeadersRow()
                
                for i, query in ipairs(queries) do
                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    ImGui.Text(query)

                    ImGui.TableSetColumnIndex(1)
                    if ImGui.Button("Remove##" .. zone .. i) then
                        table.remove(npc_list[zone], i)
                        if #npc_list[zone] == 0 then
                            npc_list[zone] = nil
                        end
                        save_npc_list()  -- Save when removing
                    end
					ImGui.TableSetColumnIndex(2)
					if not alert_on[zone] then
						alert_on[zone] = {}
					end
					if (alert_on[zone][query]) then
						if ImGui.Button("Alert Stop##" .. zone .. i) then
							alert_on[zone][query] = nil
							save_npc_list()
						end
					else
						if ImGui.Button("Alert##" .. zone .. i) then
							alert_on[zone][query] = true
							save_npc_list()
						end
					end
                end
                ImGui.EndTable()
            end
        end
    end

    ImGui.End()
end

-- 🔹 Draw the Active Spawn Viewer (Only for the current zone)
local function draw_spawn_viewer()
    if not OpenSpawnViewer then return end

    ImGui.SetNextWindowSize(400, 500, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowBgAlpha(0.0) -- Fully transparent window

    -- Apply NoMove flag if lockWindow is true
    local window_flags = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoResize + ImGuiWindowFlags.AlwaysAutoResize
    if lockWindow then
        window_flags = window_flags + ImGuiWindowFlags.NoMove
    end

    OpenSpawnViewer = ImGui.Begin("Active Spawn Viewer", OpenSpawnViewer, window_flags)

    --if ImGui.Button("Open Spawn Query Editor") then
    --    OpenEditor = true
    --end
	
	if ImGui.Button(Icons.FA_SEARCH .. "##query", 30, 30) then
		OpenEditor = true
	end
	
	if ImGui.IsItemHovered() then
		ImGui.SetTooltip("Add NPC to zone")
	end

    ImGui.SameLine()

	if ImGui.Button((lockWindow and Icons.FA_LOCK or Icons.FA_UNLOCK) .. "##lock", 30, 30) then
		lockWindow = not lockWindow
	end
	
	if ImGui.IsItemHovered() then
		ImGui.SetTooltip(lockWindow and "Unlock Window" or "Lock Window")
	end

    local current_zone = mq.TLO.Zone.ShortName() or "Unknown"
    
    if tracked_spawns[current_zone] and #tracked_spawns[current_zone] > 0 then
        for _, spawn in ipairs(tracked_spawns[current_zone]) do
            ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1)
            local _, clicked = ImGui.Selectable(spawn.name .. " " .. spawn.location)
            ImGui.PopStyleColor()
            if clicked then
                mq.cmd('/target "' .. spawn.name .. '"')
            end
        end
    else
        ImGui.TextColored(1, 0, 0, 1, "Nothing's Up.")
    end

    ImGui.End()
end

-- 🔹 Hook into ImGui rendering
mq.imgui.init("SpawnQueryEditor", draw_editor)
mq.imgui.init("SpawnViewer", draw_spawn_viewer)

-- 🔹 Main loop
local function main()
    load_npc_list()  -- Load the watchlist when the script starts
    while true do
        mq.doevents()
        update_tracked_spawns()
		clean_found()
        mq.delay(5000)
    end
end

-- Run the script (keeping it alive)
main()
