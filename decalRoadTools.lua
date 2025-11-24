-- Road Material Painter & Edge Generator
-- Originally written by Stuffi3000
-- Expanded by Sea Land Air
-- bCDDL v1.1

local M = {}
local im = ui_imgui
local ffi = require('ffi')
local toolWindowName = "editor_decalRoadTools"
local logTag = 'editor_decalRoadTools'

-- Shared state and helpers
local decalRoadTypes = {"DecalRoad"}
local decalRoadIds = {}

-- Material Painter state
if not M.selectedTerrainMaterialIdx then
  M.selectedTerrainMaterialIdx = im.IntPtr(0)
end
if not M.edgeMargin then M.edgeMargin = im.FloatPtr(0.02) end
if not M.resampleStep then M.resampleStep = im.FloatPtr(1.0) end

-- Edge Generator state
local savedParams = {}
local roadEdgeWidth = im.FloatPtr(1.0)
local overlap = im.FloatPtr(0.1)
local textureLength = im.IntPtr(5)
local renderPriority = im.IntPtr(10)
local startFade = im.FloatPtr(0.1)
local endFade = im.FloatPtr(0.1)
local materialIndex = im.IntPtr(0)
local materials = {}

local function getRoadMaterials()
  materials = {}
  local allMaterials = scenetree.findClassObjects('Material')
  for _, matName in ipairs(allMaterials) do
    local mat = scenetree.findObject(matName)
    if mat and mat.materialTag0 == 'RoadAndPath' then
      table.insert(materials, matName)
    end
  end
  table.sort(materials)
  
  -- Set default material if available
  local defaultMat = "m_road_asphalt_edge_grass"
  for i, matName in ipairs(materials) do
    if matName == defaultMat then
      materialIndex[0] = i - 1  -- Convert to 0-based index
      savedParams.materialName = defaultMat
      break
    end
  end
  
  return materials
end
local invertEdgePlacement = im.BoolPtr(false)
local randomisePosition = im.BoolPtr(false)
local overObjects = im.BoolPtr(false)
local sideSelection = 0
local settingsPath = "settings/roadedgegenerator_profiles.json"

-- Shared selection helper
local function getSelection()
  local ids = {}
  if editor.selection and editor.selection.object then
    for _, currId in ipairs(editor.selection.object) do
      local obj = scenetree.findObjectById(currId)
      if obj and arrayFindValueIndex(decalRoadTypes, obj.className) then
        table.insert(ids, currId)
      end
    end
  end
  return ids
end

-- Edge Generator helpers
local function calculateVector(point1, point2)
  return {x = point2.x - point1.x, y = point2.y - point1.y, z = point2.z - point1.z}
end

local function vectorLength(vector)
  return math.sqrt(vector.x^2 + vector.y^2 + vector.z^2)
end

local function normalizeVector(vector)
  local length = vectorLength(vector)
  if length == 0 then return {x=0,y=0,z=0} end
  return {x = vector.x / length, y = vector.y / length, z = vector.z / length}
end

local function rotateVector(vector)
  if sideSelection == 0 then
    return {x = -vector.y, y = vector.x, z = vector.z}
  else
    return {x = vector.y, y = -vector.x, z = -vector.z}
  end
end

local function calculateNewPoint(point, directionVector, distance)
  local random_var_x = 0
  local random_var_y = 0
  if savedParams.randomisePosition == true then
    random_var_x = math.random(-0.2, 0.2)
    random_var_y = math.random(-0.2, 0.2)
  end
  local x = (point.x + directionVector.x * distance) + random_var_x
  local y = (point.y + directionVector.y * distance) + random_var_y
  local z = point.z + directionVector.z * distance
  return vec3(x, y, z)
end

local function loadProfiles()
  local profiles = {}
  local ok, f = pcall(function() return io.open(settingsPath, "r") end)
  if ok and f then
    local data = f:read("*a")
    f:close()
    local decoded = jsonDecode(data)
    if decoded and type(decoded) == "table" then
      profiles = decoded
    end
  end
  return profiles
end

local function saveProfiles(profiles)
  local ok, f = pcall(function() return io.open(settingsPath, "w") end)
  if ok and f then
    f:write(jsonEncode(profiles))
    f:close()
  end
end

-- Main actions
local function doPaintMaterials(materialNames, materialIndices)
  local terrainEditor = extensions.editor_terrainEditor
  local terrainBlock = terrainEditor.getTerrainBlock and terrainEditor.getTerrainBlock() or nil
  if terrainBlock and #decalRoadIds > 0 and #materialNames > 0 then
    local painter = require("editor/toolUtilities/terrainPainter")
    local matListIdx = M.selectedTerrainMaterialIdx[0] + 1
    local matName = materialNames[matListIdx]
    local paintMaterialIdx = ((materialIndices[matListIdx] or 1) - 1)
    local paintMargin = M.edgeMargin[0] or 1.0

    for _, decalRoadId in ipairs(decalRoadIds) do
      local road = scenetree.findObjectById(decalRoadId)
      if road then
        local nodes = editor.getNodes(road)
        if #nodes >= 2 then
          local divPoints, binormals, divWidths = {}, {}, {}
          local edgeCount = road.getEdgeCount and road:getEdgeCount() or 0

          if edgeCount and edgeCount >= 2 and road.getLeftEdgePosition and road.getRightEdgePosition and road.getMiddleEdgePosition then
            for ei = 0, edgeCount - 1 do
              local l = road:getLeftEdgePosition(ei)
              local r = road:getRightEdgePosition(ei)
              local m = road:getMiddleEdgePosition(ei)
              local dx, dy = (r.x - l.x), (r.y - l.y)
              local len = math.sqrt(dx * dx + dy * dy)
              if len < 1e-12 then len = 1 end
              local bin = { x = dx / len, y = dy / len, z = 0 }
              table.insert(divPoints, vec3(m.x, m.y, m.z))
              table.insert(binormals, bin)
              table.insert(divWidths, len)
            end
          else
            -- Fallback: resample control nodes
            local function norm2(x, y)
              local l = math.sqrt(x * x + y * y)
              if l == 0 then return 0, 0, 0 end
              return x / l, y / l, l
            end
            local resampleStep = math.max(0.1, (M.resampleStep and M.resampleStep[0]) or 1.0)
            local N = #nodes
            local sPts, sWidths = {}, {}

            for i = 1, N - 1 do
              local p0, p1 = nodes[i].pos, nodes[i + 1].pos
              local w0, w1 = nodes[i].width or 1, (nodes[i + 1].width or nodes[i].width or 1)
              local dx, dy = p1.x - p0.x, p1.y - p0.y
              local _, _, segLen = norm2(dx, dy)
              local nSub = math.max(1, math.ceil(segLen / resampleStep))

              if i == 1 then
                table.insert(sPts, vec3(p0.x, p0.y, p0.z))
                table.insert(sWidths, w0)
              end

              for s = 1, nSub - 1 do
                local t = s / nSub
                local x = p0.x + dx * t
                local y = p0.y + dy * t
                local z = p0.z + (p1.z - p0.z) * t
                local w = w0 + (w1 - w0) * t
                table.insert(sPts, vec3(x, y, z))
                table.insert(sWidths, w)
              end

              table.insert(sPts, vec3(p1.x, p1.y, p1.z))
              table.insert(sWidths, w1)
            end

            local count = #sPts
            for i = 1, count do
              local tdx, tdy
              if i == 1 then
                tdx = sPts[2].x - sPts[1].x
                tdy = sPts[2].y - sPts[1].y
              elseif i == count then
                tdx = sPts[count].x - sPts[count - 1].x
                tdy = sPts[count].y - sPts[count - 1].y
              else
                tdx = sPts[i + 1].x - sPts[i - 1].x
                tdy = sPts[i + 1].y - sPts[i - 1].y
              end
              local tx, ty = norm2(tdx, tdy)
              if tx == 0 and ty == 0 then
                if i > 1 then
                  binormals[i] = binormals[i - 1]
                else
                  binormals[i] = { x = 0, y = 1, z = 0 }
                end
              else
                local binx, biny = -ty, tx
                binormals[i] = { x = binx, y = biny, z = 0 }
              end
              divPoints[i] = sPts[i]
              divWidths[i] = sWidths[i]
            end
          end

          local group = {
            divPoints = divPoints,
            binormals = binormals,
            divWidths = divWidths,
            paintMaterialIdx = paintMaterialIdx,
            paintMargin = paintMargin,
            nodes = nodes,
            paintedDataVals = {},
            paintedDataX = {},
            paintedDataY = {},
            paintedDataBoxXMin = 0,
            paintedDataBoxXMax = 0,
            paintedDataBoxYMin = 0,
            paintedDataBoxYMax = 0
          }
          painter.paint(group)
          log('I', logTag, "Painted material '" .. matName .. "' under road id " .. tostring(decalRoadId))
        end
      end
    end
  end
end

local function createEdge(oldDecalRoad, side)
  local nodes = editor.getNodes(oldDecalRoad)
  local newEdgeNodes = {}
  
  -- Deep copy nodes to prevent modifying original
  for i = 1, #nodes do
    newEdgeNodes[i] = {
      pos = deepcopy(nodes[i].pos),
      width = nodes[i].width
    }
  end
  
  if not roadEdgeWidth then roadEdgeWidth = 1 end
  
  -- Calculate positions
  for i = 1, #newEdgeNodes do
    local decalRoadWidth = newEdgeNodes[i].width
    local vector
    if i < #newEdgeNodes then
      vector = calculateVector(newEdgeNodes[i].pos, newEdgeNodes[i+1].pos)
    else
      vector = calculateVector(newEdgeNodes[i-1].pos, newEdgeNodes[i].pos)
    end
    local normalizedVector = normalizeVector(vector)
    local perpendicularVector = rotateVector(normalizedVector)
    if side == 1 then -- Right side
      perpendicularVector = {
        x = -perpendicularVector.x,
        y = -perpendicularVector.y,
        z = -perpendicularVector.z
      }
    end
    local edgeNodeDistance = (decalRoadWidth/2 + savedParams.roadEdgeWidth/2) - savedParams.overlap
    local newPos = calculateNewPoint(newEdgeNodes[i].pos, perpendicularVector, edgeNodeDistance)
    newEdgeNodes[i].pos = newPos
    newEdgeNodes[i].width = tonumber(savedParams.roadEdgeWidth)
  end
  
  -- Handle node order based on side and inversion
  if (side == 1 and not savedParams.invertEdgePlacement) or (side == 0 and savedParams.invertEdgePlacement) then
    local reversed = {}
    for i = 1, #newEdgeNodes do
      reversed[i] = {
        pos = newEdgeNodes[#newEdgeNodes - i + 1].pos,
        width = newEdgeNodes[#newEdgeNodes - i + 1].width
      }
    end
    newEdgeNodes = reversed
  end
  
  -- Create and configure the edge
  local newDecalRoadId = editor.createRoad(newEdgeNodes, {})
  editor.setFieldValue(newDecalRoadId, "Material", savedParams.materialName)
  editor.setFieldValue(newDecalRoadId, "textureLength", savedParams.textureLength)
  editor.setFieldValue(newDecalRoadId, "renderPriority", savedParams.renderPriority)
  editor.setFieldValue(newDecalRoadId, "startEndFade", tostring(savedParams.startFade .. " " .. savedParams.endFade))
  if savedParams.overObjects == true then
    editor.setFieldValue(newDecalRoadId, "overObjects", 1)
  end
  
  return newDecalRoadId
end

local function doGenerateEdge()
  for _, decalRoadId in ipairs(decalRoadIds) do
    if decalRoadId then
      local oldDecalRoad = scenetree.findObjectById(decalRoadId)
      
      if sideSelection == 2 then -- Both sides
        createEdge(oldDecalRoad, 0) -- Left side
        createEdge(oldDecalRoad, 1) -- Right side
      else
        createEdge(oldDecalRoad, sideSelection)
      end
    end
  end
end

-- UI
local function onEditorGui()
  if not editor.isWindowVisible(toolWindowName) then return end
  if editor.beginWindow(toolWindowName, "Road Painter & Edge Generator") then

    im.Separator()
    im.Spacing()

    -- Road selection (shared between both tools)
    -- Display selected roads with icons
    for i, id in ipairs(decalRoadIds) do
      local obj = scenetree.findObjectById(id)
      local decalRoadName = obj and tostring(obj:getName()) or tostring(id)
      
      -- Icon button for each road
      if editor.uiIconImageButton(editor.icons.check_circle, im.ImVec2(22 * im.uiscale[0], 22 * im.uiscale[0])) then
        editor.selectEditMode(editor.editModes.objectSelect)
        editor.selectObjectById(id)
        editor.fitViewToSelectionSmooth()
      end
      
      im.SameLine()
      im.Text(decalRoadName .. " [" .. id .. "]")
    end
    if im.Button("Get DecalRoad(s) from Selection") then
      decalRoadIds = getSelection()
    end
    if #decalRoadIds > 0 and im.Button("Clear Selected Roads") then
      decalRoadIds = {}
    end

    im.Separator()

    -- Material Painter Section
    im.HeaderText("Material Painter")
    im.Text("Paint a terrain material underneath selected DecalRoad(s).")
    im.Spacing()

    local terrainEditor = extensions.editor_terrainEditor
    local materialNames, materialIndices = {}, {}
    if terrainEditor and terrainEditor.getPaintMaterialProxies then
      local proxies = terrainEditor.getPaintMaterialProxies()
      for i, proxy in ipairs(proxies) do
        table.insert(materialNames, proxy.internalName)
        table.insert(materialIndices, proxy.index or (terrainEditor.getTerrainBlockMaterialIndex and terrainEditor.getTerrainBlockMaterialIndex(proxy.internalName)) or i)
      end
    end

    if #materialNames > 0 then
      local materialNamePtrs = im.ArrayCharPtrByTbl(materialNames)
      im.Combo1("Terrain Material", M.selectedTerrainMaterialIdx, materialNamePtrs)
    else
      im.Text("No terrain materials available.")
    end

    im.InputFloat("Edge Margin (m)", M.edgeMargin, 0.1)
    im.tooltip("Paints this much extra distance to each side of the road (meters). Increase to cover more terrain.")
    im.InputFloat("Resample Step (m)", M.resampleStep, 0.1)
    im.tooltip("Sampling distance along the road when building the paint polygon.")

    im.Spacing()
    if im.Button("Paint Material Under Road") then
      if terrainEditor then doPaintMaterials(materialNames, materialIndices) end
    end

    -- Edge Generator Section
    im.Spacing()
    im.Separator()
    im.Spacing()
    
    im.HeaderText("Edge Generator")
    im.Text("Generate road-edges on the selected DecalRoad(s).")
    im.Spacing()

      -- Profile management
      if not savedParams.profiles then
        savedParams.profiles = loadProfiles()
        savedParams.currentProfile = nil
      end

      im.Text("Parameters:")
      im.InputFloat("Road-edge width", roadEdgeWidth, 1.0)
      im.InputFloat("Overlap/Offset width", overlap, 0.01)
      if im.IsItemHovered() then
        im.BeginTooltip()
        im.TextColored(im.ImVec4(0.0, 1.0, 0.0, 1.0), "[Positive Value]")
        im.Text("Creates an overlap between the DecalRoad and the road-edge")
        im.TextColored(im.ImVec4(1.0, 1.0, 0.0, 1.0), "[Negative Value]")
        im.Text("Creates an offset between the DecalRoad and the road-edge")
        im.EndTooltip()
      end

      local roadMats = getRoadMaterials()
      if #roadMats > 0 then
        local materialNamePtrs = im.ArrayCharPtrByTbl(roadMats)
        if im.Combo1("Material", materialIndex, materialNamePtrs) then
          -- Update saved params when selection changes
          savedParams.materialName = roadMats[materialIndex[0] + 1]
        end
      else
        im.Text("No road materials found. Materials must have tag 'RoadAndPath'.")
      end
      im.tooltip("Select a material to be assigned to the road-edge")
      im.InputInt("Texture Length", textureLength)
      im.InputInt("Render Priority", renderPriority)
      im.InputFloat("Start Fade", startFade, 0.1)
      im.InputFloat("End Fade", endFade, 0.1)

      im.Text("Edge Placement Side:")
      if im.Selectable1("Left", sideSelection == 0) then sideSelection = 0 end
      if im.Selectable1("Right", sideSelection == 1) then sideSelection = 1 end
      if im.Selectable1("Both", sideSelection == 2) then sideSelection = 2 end
      im.tooltip("Side on which to place the edge relative to the road direction")

      im.Checkbox("Invert edge placement", invertEdgePlacement)
      im.tooltip("Invert the edge placement direction (useful for one-sided materials)")
      im.Checkbox("Over Objects", overObjects)
      im.Checkbox("Randomise node placement", randomisePosition)
      im.tooltip("Adds slight randomization to edge positions for a more natural look")

      -- Save current parameters
      savedParams.roadEdgeWidth = roadEdgeWidth[0]
      savedParams.overlap = overlap[0]
      savedParams.startFade = startFade[0]
      savedParams.endFade = endFade[0]
      -- Material name is now handled in the combo callback
      savedParams.textureLength = textureLength[0]
      savedParams.renderPriority = renderPriority[0]
      savedParams.invertEdgePlacement = invertEdgePlacement[0]
      savedParams.overObjects = overObjects[0]
      savedParams.randomisePosition = randomisePosition[0]

      if im.Button("Generate Road-Edge") then
        doGenerateEdge()
      end
  end
  editor.endWindow()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  savedParams.profiles = loadProfiles()
  if not savedParams.profiles then savedParams.profiles = {} end
  editor.registerWindow(toolWindowName, im.ImVec2(760, 600))
  editor.addWindowMenuItem("Road Painter & Edge Generator", onWindowMenuItem)
end

M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui

return M