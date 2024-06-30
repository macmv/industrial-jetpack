-- runtime cache of settings

local Settings = {}

local function reset()
  Settings.player_settings = {}
  Settings.global_settings = {}
end
reset()

local function on_runtime_mod_setting_changed(event)
  reset()
end
script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)

function Settings.get_setting_player(player_index, setting_name)
  if not Settings.player_settings[player_index] then
    Settings.player_settings[player_index] = {}
  end
  if not Settings.player_settings[player_index][setting_name] then
    Settings.player_settings[player_index][setting_name] =
      settings.get_player_settings(player_index)[setting_name].value
  end
  return Settings.player_settings[player_index][setting_name]
end

function Settings.get_setting_global(setting_name)
  if not Settings.global_settings[setting_name] then
    Settings.global_settings[setting_name] = settings.global[setting_name].value
  end
  return Settings.global_settings[setting_name]
end

return Settings
