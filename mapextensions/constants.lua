
--- When starting to read or write a map/sav file, set maximum length to 128 MB
local MAP_MEMORY_SIZE = 128 * 1000 * 1000

--- Max 100 MB
local CUSTOM_SECTION_SIZE = 100 * 1000 * 1000

--- Claim a section id not used by the game
local CUSTOM_SECTION_ID = 1337

--- No compression for now, let the game compress
local CUSTOM_SECTION_ZIP_COMPRESSION = nil

return {
  MAP_MEMORY_SIZE = MAP_MEMORY_SIZE,
  CUSTOM_SECTION_SIZE = CUSTOM_SECTION_SIZE,
  CUSTOM_SECTION_ID = CUSTOM_SECTION_ID,
  CUSTOM_SECTION_ZIP_COMPRESSION = CUSTOM_SECTION_ZIP_COMPRESSION,
}