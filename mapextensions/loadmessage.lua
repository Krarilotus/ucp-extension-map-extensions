local messages = {
  english = 'This save requires the module "%s" (%s). Enable the compatible version and try again.',
  german = 'Dieser Spielstand benötigt das Modul „%s“ (%s). Aktiviere eine kompatible Version und versuche es erneut.',
  french = 'Cette sauvegarde nécessite le module « %s » (%s). Activez une version compatible et réessayez.',
  russian = 'Для этого сохранения нужен модуль «%s» (%s). Включите совместимую версию и повторите попытку.',
  hungarian = 'Ehhez a mentéshez a(z) „%s” modul szükséges (%s). Engedélyezz egy kompatibilis verziót, és próbáld újra.',
  turkish = 'Bu kayıt için “%s” modülü gerekiyor (%s). Uyumlu bir sürümü etkinleştirip tekrar dene.',
  chinese = '此存档需要“%s”模块（%s）。请启用兼容版本后重试。',
  spanish = 'Esta partida guardada requiere el módulo «%s» (%s). Activa una versión compatible y vuelve a intentarlo.',
  persian = 'این ذخیره به ماژول «%s» (%s) نیاز دارد. نسخهٔ سازگار را فعال کنید و دوباره تلاش کنید.',
}

local unreadable = {
  english = 'This save could not be read.',
  german = 'Dieser Spielstand konnte nicht gelesen werden.',
  french = 'Cette sauvegarde n’a pas pu être lue.',
  russian = 'Не удалось прочитать это сохранение.',
  hungarian = 'Ezt a mentést nem sikerült beolvasni.',
  turkish = 'Bu kayıt okunamadı.',
  chinese = '无法读取此存档。',
  spanish = 'No se pudo leer esta partida guardada.',
  persian = 'این ذخیره خوانده نشد.',
}

-- Framework 3.0.7 names only the seven languages of the original release; the
-- other editions show English there.
local function language()
  local name = data.version.getGameLanguage()
  return type(name) == 'string' and name:lower()
end

local function wide(text)
  local result = {}
  for _, value in utf8.codes(text) do
    -- The localized strings and validated module identifiers fit in the BMP.
    result[#result+1] = string.pack('<I2', value)
  end
  return table.concat(result) .. '\0\0'
end

local show
return function(name, version)
  if not show then
    local ffi = modules.cffi:cffi()
    ffi.cdef('int __stdcall MessageBoxW(void *, const void *, const void *, unsigned int);')
    local user = ffi.load('user32')
    show = function(text) user.MessageBoxW(nil, wide(text), wide('Map Extensions'), 0x00040030) end
  end
  if name then
    show((messages[language()] or messages.english):format(name, version))
  else
    show(unreadable[language()] or unreadable.english)
  end
end
