package.path = "./?.lua;./?/init.lua;" .. package.path

local checks, failures = 0, 0
local function eq(got, want, label)
  checks = checks + 1
  if got ~= want then
    failures = failures + 1
    io.stderr:write(("FAIL %s (got %s, want %s)\n"):format(
      label, tostring(got), tostring(want)))
  end
end
local function ok(value, label) eq(not not value, true, label) end

-- Mock love environment
local mockCalls = {}
local origNewImage = function(arg)
  mockCalls[#mockCalls + 1] = { fn="origNewImage", arg=arg }
  if type(arg) == "table" and arg._isImageData then
    return { _isImage=true, w=arg.w, h=arg.h, getDimensions=function(self) return self.w, self.h end, getWidth=function(self) return self.w end, getHeight=function(self) return self.h end }
  end
  error("Could not open file " .. tostring(arg))
end

local origNewImageData = function(w, h)
  mockCalls[#mockCalls + 1] = { fn="origNewImageData", w=w, h=h }
  if type(w) == "number" and type(h) == "number" then
    local pixels = {}
    return {
      _isImageData = true,
      w = w, h = h,
      getDimensions = function() return w, h end,
      getWidth = function() return w end,
      getHeight = function() return h end,
      getPixel = function(_, x, y) return 1, 1, 1, 1 end,
      setPixel = function(_, x, y, r, g, b, a) pixels[y * w + x + 1] = {r, g, b, a} end,
      mapPixel = function(self, fn)
        for y = 0, h - 1 do
          for x = 0, w - 1 do
            self:setPixel(x, y, fn(x, y, 0, 0, 0, 0))
          end
        end
      end,
    }
  end
  error("Invalid imageData args")
end

local origGetInfo = function(path, kind)
  mockCalls[#mockCalls + 1] = { fn="origGetInfo", path=path, kind=kind }
  if path == "existing_file.png" then return { type="file", size=100 } end
  return nil
end

_G.love = {
  graphics = {
    newImage = origNewImage,
  },
  image = {
    newImageData = origNewImageData,
  },
  filesystem = {
    getInfo = origGetInfo,
  },
}

package.loaded["src.render.Assets"] = {
  image = function(path) return _G.love.graphics.newImage(path) end,
  imageData = function(path) return _G.love.image.newImageData(path) end,
  exists = function(path) return _G.love.filesystem.getInfo(path) ~= nil end,
}

for _, modName in ipairs({"cache", "runtime_patches", "picture", "json"}) do
  local full = "mods.CRYSTAL_251.lib." .. modName
  if not package.preload[full] then
    package.preload[full] = function() return require("lib." .. modName) end
  end
end

local Cache = require("mods.CRYSTAL_251.lib.cache")
local Patches = require("mods.CRYSTAL_251.lib.runtime_patches")

-- Stage a test 40x40 dex asset (5x5 tiles = 40x40 pixels)
local raster = string.rep("\0", 40 * 40)
local testDexPath = "crystal_251/generated/dex/chikorita.png"
Cache.stageAsset(testDexPath, {
  raster = raster,
  width = 40,
  height = 40,
  palette = { {255,255,255}, {170,170,170}, {85,85,85}, {0,0,0} },
  presentation = "dex",
})

-- Before bridge: love.graphics.newImage on virtual path throws
local okBefore, errBefore = pcall(love.graphics.newImage, testDexPath)
eq(okBefore, false, "unbridged newImage fails on virtual path")

-- Install asset bridge
Cache.installAssetBridge()

-- After bridge: love.graphics.newImage succeeds and returns 56x56 canvas
local okImg, img = pcall(love.graphics.newImage, testDexPath)
ok(okImg, "bridged newImage succeeds for virtual dex sprite")
ok(type(img) == "table" and img._isImage, "returned object is an Image")
local iw, ih = img:getDimensions()
eq(iw, 56, "dex sprite canvas width is 56 (7 tiles)")
eq(ih, 56, "dex sprite canvas height is 56 (7 tiles)")

-- After bridge: love.image.newImageData succeeds for virtual path
local okData, id = pcall(love.image.newImageData, testDexPath)
ok(okData, "bridged newImageData succeeds for virtual dex sprite")
ok(type(id) == "table" and id._isImageData, "returned object is ImageData")
eq(id:getWidth(), 56, "imageData width is 56")
eq(id:getHeight(), 56, "imageData height is 56")

-- love.filesystem.getInfo returns file info for virtual asset
local info = love.filesystem.getInfo(testDexPath)
ok(info ~= nil and info.type == "file", "bridged getInfo reports virtual file")

-- Non-virtual paths pass through to original handlers
local nonVirtual = love.filesystem.getInfo("existing_file.png")
ok(nonVirtual ~= nil, "non-virtual getInfo passes through")
local okNonVirtual, errNonVirtual = pcall(love.graphics.newImage, "non_existent.png")
eq(okNonVirtual, false, "non-virtual newImage passes through to original")

-- Simulated DexEntryMenu.new pattern:
local def = { id="CHIKORITA", spriteFront=testDexPath }
local path = testDexPath
local okSprite, sprite = false, nil
if path then okSprite, sprite = pcall(love.graphics.newImage, path) end
ok(okSprite and sprite ~= nil, "DexEntryMenu pattern successfully populates sprite")
eq(sprite:getWidth(), 56, "DexEntryMenu sprite has width 56")
eq(sprite:getHeight(), 56, "DexEntryMenu sprite has height 56")

-- Test restoration
Patches.restore()
eq(love.graphics.newImage, origNewImage, "newImage restored after Patches.restore")
eq(love.image.newImageData, origNewImageData, "newImageData restored after Patches.restore")
eq(love.filesystem.getInfo, origGetInfo, "getInfo restored after Patches.restore")

if failures > 0 then
  io.stderr:write(("%d/%d checks failed (Crystal pokedex sprite)\n"):format(failures, checks))
  os.exit(1)
end
print(("%d/%d checks passed (Crystal pokedex sprite)"):format(checks, checks))
