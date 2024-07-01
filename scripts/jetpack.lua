local Jetpack = {}

---@class jetpack_struct
---@field status jetpack_status
---@field character LuaEntity
---@field unit_number uint
---@field force_name string
---@field player_index uint
---@field velocity {x:number, y:number}
---@field speed float
---@field smoke_timer float
---@field flame_timer float
---@field altitude float
---@field sound LuaEntity?
---@field thrust float
---@field character_type string
---@field orientation float?
---@field last_selected_angle float?
---@field animation_shadow uint64?
---@field animation_base uint64?
---@field animation_mask uint64?
---@field animation_flame uint64?

---@class fuel_struct
---@field name string
---@field energy float
---@field thrust float

--TODO: interaction with vehicles?

Jetpack.on_character_swapped_event = "on_character_swapped"
--{new_unit_number = uint, old_unit_number = uint, new_character = luaEntity, old_character = luaEntity}

Jetpack.name_event = "jetpack"
Jetpack.name_character_suffix = "-jetpack"
Jetpack.name_jetpack_shadow = "jetpack-animation-shadow"
Jetpack.name_jetpack_sound = "jetpack-sound"
Jetpack.name_animation_base = "jetpack-animation"
Jetpack.name_animation_mask = "jetpack-animation-mask"
Jetpack.name_animation_flame = "jetpack-animation-flame"
Jetpack.drag = 0.01
Jetpack.brake = 0.001
Jetpack.printed_thrust_multiplier = 1000
Jetpack.thrust_multiplier_before_move = 0.001
Jetpack.shadow_base_offset = { x = 1, y = 0.1 }
Jetpack.altitude_target = 3
Jetpack.altitude_base_increase = 0.01
Jetpack.altitude_percentage_increase = 0.05
Jetpack.altitude_decrease = 0.2
Jetpack.altitude_decrease_falling = Jetpack.altitude_decrease * 2
Jetpack.falling_orientation_spin = 1 / 12
Jetpack.fuel_use_base = 25000
Jetpack.fuel_use_thrust = 50000
Jetpack.jump_base_thrust = 0.15 -- excluding suit thrust
Jetpack.jump_thrust_multiplier = 5 -- multiplies suit thrust
Jetpack.landing_collision_snap_radius = 3
Jetpack.toggle_cooldown = 15
Jetpack.damage_cooldown = 90
Jetpack.last_selected_angle_timeout = 3000

---@type {[string]: "bounce"|"stop"}
Jetpack.no_jetpacking_tiles = {
  ["out-of-map"] = "bounce",
  ["interior-divider"] = "bounce",
  ["se-spaceship-floor"] = "stop",
}

---@type string[]
Jetpack.bounce_entities = {
  "se-spaceship-wall",
  "se-spaceship-rocket-engine",
  "se-spaceship-ion-engine",
  "se-spaceship-antimatter-engine",
  "se-spaceship-clamp",
}

---@enum jetpack_status
Jetpack.statuses = {
  walking = 1,
  spacewalking = 2,
  rising = 3,
  stopping = 4,
  falling = 5, -- After damage
  flying = 6,
}

---@type {[string]: {thrust: number}}
Jetpack.jetpack_equipment = {
  ["jetpack-0"] = { thrust = 0.5 },
}
---@type {[string]: {thrust: integer}}
Jetpack.jetpack_armor = {
  ["se-thruster-suit"] = { thrust = 1 },
  ["se-thruster-suit-2"] = { thrust = 2 },
  ["se-thruster-suit-3"] = { thrust = 3 },
  ["se-thruster-suit-4"] = { thrust = 4 },
}
---@type {[string]: {thrust: float}}
local default_fuels = { -- sorted by preference
  { fuel_name = "rocket-fuel", thrust = 1.2 },
  { fuel_name = "advanced-fuel", thrust = 1.1 }, -- K2
  { fuel_name = "nuclear-fuel", thrust = 1.1 },
  { fuel_name = "rocket-booster", thrust = 1.1 }, -- Angel's petrochem
  { fuel_name = "fuel", thrust = 1 }, -- K2
  { fuel_name = "processed-fuel", thrust = 1 },
  { fuel_name = "bio-fuel", thrust = 0.9 }, -- K2
  { fuel_name = "solid-fuel", thrust = 0.5 },
  { fuel_name = "steam-cell", thrust = 0.7 },
}
---@type {[string]: true}
Jetpack.space_tiles = {
  ["se-space"] = true,
}

-- SPACEWALK
Jetpack.spacewalk_jump_base_thrust = 0.08
Jetpack.spacewalk_base_thrust = 0.07
Jetpack.spacewalk_thrust_multiplier = 0.5
Jetpack.spacewalk_no_drag_threshold = 0.5

-- Global var to temporary keep track of newly added jetpacks without messing up the current iteration through global.jetpacks
Jetpack.jetpacks_to_add = {}

---@param character LuaEntity
---@return true?
function Jetpack.on_space_tile(character)
  local tile = character.surface.get_tile(character.position.x, character.position.y)
  return Jetpack.space_tiles[tile.name]
end

---@param character LuaEntity
---@return jetpack_struct
function Jetpack.from_character(character)
  return global.jetpacks[character.unit_number]
end

---@param jetpack jetpack_struct
---@return boolean
function Jetpack.is_moving(jetpack)
  return jetpack.speed > 0.001
end

---@param jetpack jetpack_struct?
---@return jetpack_status
local function get_jetpack_status(jetpack)
  if not jetpack then
    return Jetpack.statuses.walking
  else
    return jetpack.status
  end
end

---@param character LuaEntity
---@param message Any
local function character_print(character, message)
  if character.player then
    character.player.print(message)
  end
end

-- Get first availaible fuel from inventory.
-- Does not consume any fuel.
---@param character LuaEntity
---@return fuel_struct?
local function get_fuel_from_inventory(character)
  local inventory = character.get_main_inventory()
  if not inventory then
    return nil
  end

  for _, compatible_fuel in pairs(default_fuels) do
    local fuel_name = compatible_fuel.fuel_name
    if game.item_prototypes[fuel_name] then
      local count = inventory.get_item_count(fuel_name)
      if count > 0 then
        return { name = fuel_name, energy = game.item_prototypes[fuel_name].fuel_value, thrust = compatible_fuel.thrust }
      end
    end
  end
end

-- Get first availaible fuel, either fuel currently in use by the character, or fuel from inventory.
-- Does not consume any fuel.
---@param character LuaEntity
---@return fuel_struct?
local function get_fuel(character)
  local current_fuel = global.current_fuel_by_character[character.unit_number]
  if current_fuel and current_fuel.energy > 0 then
    return current_fuel
  else
    return get_fuel_from_inventory(character)
  end
end

-- Take inventory fuel matching name and set it as currently used fuel by character.
---@param character LuaEntity
---@param fuel fuel_struct
---@return boolean
local function use_inventory_fuel(character, fuel)
  local inventory = character.get_main_inventory() --[[@as LuaInventory]]
  local fuel_removed = inventory.remove({ name = fuel.name, count = 1 })
  if fuel_removed == 0 then
    return false
  end
  local item_prod_stats = character.force.item_production_statistics
  global.current_fuel_by_character[character.unit_number] = fuel
  item_prod_stats.on_flow(fuel.name, -1)

  local burnt_result = game.item_prototypes[fuel.name].burnt_result
  if burnt_result then
    inventory.insert({ name = burnt_result.name })
    item_prod_stats.on_flow(burnt_result.name, 1)
  end
  return true
end

---@param jetpack jetpack_struct
local function spend_fuel_energy(jetpack)
  local fuel_consumption_rate = Settings.get_setting_global("jetpack-fuel-consumption") / 100
  local character = jetpack.character
  local current_fuel = global.current_fuel_by_character[character.unit_number]

  if not current_fuel or current_fuel.energy <= 0 then
    local stopping = true
    local fuel = get_fuel_from_inventory(character)
    if fuel then
      local thrust = Jetpack.get_current_thrust(character, fuel)
      jetpack.thrust = thrust
      if jetpack.thrust > 0 then
        use_inventory_fuel(character, fuel)
        current_fuel = fuel
        stopping = false
      end
    end
    if stopping then
      jetpack.status = Jetpack.statuses.stopping
      character_print(character, { "jetpack.ran_out_of_fuel" })
      return
    end
  end

  current_fuel.energy = current_fuel.energy - Jetpack.fuel_use_base * fuel_consumption_rate

  if character.walking_state.walking and jetpack.status ~= Jetpack.statuses.spacewalking then -- Thrusting in a direction
    current_fuel.energy = current_fuel.energy - Jetpack.fuel_use_thrust * fuel_consumption_rate
  end
end

---@type table<string, true>
local energy_shield_set = nil
local function populate_energy_shield_set()
  energy_shield_set = {}
  for energy_shield_name, _energy_shield_prototype in
    pairs(game.get_filtered_equipment_prototypes({ { filter = "type", type = "energy-shield-equipment" } }))
  do
    if not string.find(energy_shield_name, "armour", 1, true) then
      energy_shield_set[energy_shield_name] = true
    end
  end
  log("energy_shield_set: " .. serpent.line(energy_shield_set))
end

---@param equipment_name string
---@return true?
local function is_energy_shield(equipment_name)
  if not energy_shield_set then
    populate_energy_shield_set()
  end
  return energy_shield_set[equipment_name]
end

---@param jetpack jetpack_struct
---@param tick uint
local function damage_shields(jetpack, tick)
  if tick % 5 == 0 and jetpack.character.grid and jetpack.character.grid.shield > 0 then
    local shield_reduction =
      math.min(1, jetpack.speed / 10 * Settings.get_setting_global("jetpack-speed-reduces-shields") / 100)
    if shield_reduction > 0 then
      for _, eq in pairs(jetpack.character.grid.equipment) do
        if is_energy_shield(eq.name) then
          eq.shield = math.max(0, eq.shield - (eq.max_shield + 9 * eq.shield) / 10 * shield_reduction)
        end
      end
    end
  end
end

-- Instantly swap to walking state
---@param jetpack jetpack_struct
---@return LuaEntity?
function Jetpack.land_and_start_walking(jetpack)
  local surface = jetpack.character.surface
  local land_character
  if Jetpack.character_is_flying_version(jetpack.character.name) then
    local non_colliding = surface.find_non_colliding_position(
      util.replace(jetpack.character.name, Jetpack.name_character_suffix, ""), -- name
      jetpack.character.position, -- center
      Jetpack.landing_collision_snap_radius, --radius
      0.1, -- precision
      false --force_to_tile_center
    )
    if non_colliding then
      jetpack.character.teleport(non_colliding)
    end
    land_character = Jetpack.swap_to_land_character(jetpack.character)
  else
    land_character = jetpack.character
  end

  if land_character then
    local landing_tile = surface.get_tile(land_character.position.x, land_character.position.y)
    global.jetpacks[jetpack.unit_number] = nil

    if Jetpack.space_tiles[landing_tile.name] then -- Start spacewalking, keep the jetpack object around
      jetpack.status = Jetpack.statuses.spacewalking
      jetpack.character = land_character
      jetpack.unit_number = land_character.unit_number
      jetpack.character_type = "land"
      jetpack.orientation = nil

      Jetpack.jetpacks_to_add[jetpack.unit_number] = jetpack
    else
      JetpackGraphicsSound.create_land_effects(land_character, landing_tile.name)
    end
  end

  JetpackGraphicsSound.cleanup(jetpack)

  return land_character
end

---@param jetpack jetpack_struct
local function movement_collision_bounce(jetpack)
  local character = jetpack.character
  local tiles =
    jetpack.character.surface.find_tiles_filtered({ area = Util.position_to_area(jetpack.character.position, 1.49) })
  local best_vector
  local best_distance = math.huge
  for _, tile in pairs(tiles) do
    if not Jetpack.no_jetpacking_tiles[tile.name] then
      local v = Util.vectors_delta(jetpack.character.position, Util.tile_to_position(tile.position))
      local d = Util.vector_length(v)
      if d < best_distance then
        best_distance = d
        best_vector = v
      end
    end
  end
  jetpack.speed = 0.05
  if best_vector then
    jetpack.velocity = Util.vector_set_length(best_vector, jetpack.speed)
    local new_position =
      { x = character.position.x + jetpack.velocity.x * 4, y = character.position.y + jetpack.velocity.y * 4 }
    character.teleport(new_position)
  else
    local x_part = jetpack.character.position.x % 1 - 0.5
    local y_part = jetpack.character.position.y % 1 - 0.5
    jetpack.velocity = { x = x_part, y = y_part }
    jetpack.velocity = Util.vector_set_length(jetpack.velocity, jetpack.speed)
  end
end

---@param jetpack jetpack_struct
---@param tick uint
---@param disallow_thrust true?
local function movement_tick(jetpack, tick, disallow_thrust)
  local spacewalking = jetpack.status == Jetpack.statuses.spacewalking
  local character = jetpack.character

  -- drag
  if spacewalking then
    if jetpack.speed > Jetpack.spacewalk_no_drag_threshold then
      local m = 1 - Jetpack.drag * (jetpack.speed - Jetpack.spacewalk_no_drag_threshold) / jetpack.speed -- reduction
      jetpack.velocity.x = jetpack.velocity.x * m
      jetpack.velocity.y = jetpack.velocity.y * m
      jetpack.speed = jetpack.speed * m
    end
  else
    jetpack.velocity.x = jetpack.velocity.x * (1 - Jetpack.drag)
    jetpack.velocity.y = jetpack.velocity.y * (1 - Jetpack.drag)
    jetpack.speed = jetpack.speed * (1 - Jetpack.drag)
    damage_shields(jetpack, tick)
  end

  local walking_state = character.walking_state
  if walking_state.walking and not disallow_thrust then -- Player is pressing a direction
    local direction_vector = util.direction_to_vector(walking_state.direction)
    local thrust
    if spacewalking then
      thrust = Jetpack.spacewalk_base_thrust
      JetpackGraphicsSound.create_spacewalking_smoke(character)
    else
      thrust = jetpack.thrust -- get from equipment + fuel
    end
    thrust = thrust * Jetpack.thrust_multiplier_before_move
    local thrust_vector = { x = direction_vector.x * thrust, y = direction_vector.y * thrust }
    jetpack.velocity.x = jetpack.velocity.x + thrust_vector.x
    jetpack.velocity.y = jetpack.velocity.y + thrust_vector.y
    jetpack.speed = util.vector_length(jetpack.velocity)
  elseif not spacewalking then -- Not pressing a direction, slow down (except when spacewalking)
    local new_speed = jetpack.speed - Jetpack.brake
    if new_speed < 0.001 then
      jetpack.velocity.x = 0
      jetpack.velocity.y = 0
      jetpack.speed = 0
    else
      jetpack.velocity.x = jetpack.velocity.x * new_speed / jetpack.speed
      jetpack.velocity.y = jetpack.velocity.y * new_speed / jetpack.speed
      jetpack.speed = new_speed
    end
  end

  local new_position = { x = character.position.x + jetpack.velocity.x, y = character.position.y + jetpack.velocity.y }

  local target_tile = jetpack.character.surface.get_tile(new_position.x, new_position.y)
  if target_tile then
    local tile_effect = Jetpack.no_jetpacking_tiles[target_tile.name]
    if tile_effect == "bounce" then
      movement_collision_bounce(jetpack)
    elseif tile_effect == "stop" then
      local bounce_entity = character.surface.find_entities_filtered({
        name = Jetpack.bounce_entities,
        position = util.tile_to_position(target_tile.position),
        limit = 1,
      })
      if #bounce_entity == 1 then -- actually, bounce
        movement_collision_bounce(jetpack)
      else
        -- Instant stop
        character.teleport(new_position)
        Jetpack.land_and_start_walking(jetpack)
      end
    elseif Jetpack.is_moving(jetpack) then
      character.teleport(new_position)
      -- End of spacewalking
      -- We do this here instead of on_player_changed_position because a character could be moving without a player attached.
      -- e.g. remote view in SE
      if spacewalking and not Jetpack.space_tiles[target_tile.name] then
        global.jetpacks[jetpack.unit_number] = nil -- "walking"
        JetpackGraphicsSound.create_land_effects(jetpack.character, target_tile.name)
      end
    end
  else
    jetpack.velocity.x = jetpack.velocity.x / 2
    jetpack.velocity.y = jetpack.velocity.y / 2
    jetpack.speed = jetpack.speed / 2
  end
end

---@param jetpack jetpack_struct
---@param tick uint
local function on_tick_flying(jetpack, tick)
  spend_fuel_energy(jetpack)
  movement_tick(jetpack, tick)
  if jetpack.character.valid then -- Could have instantly landed in movement_tick
    JetpackGraphicsSound.update_graphics(jetpack)
    JetpackGraphicsSound.update_sound(jetpack, tick)
    JetpackGraphicsSound.create_smoke(jetpack)
  end
end

local function on_tick_spacewalking(jetpack, tick)
  movement_tick(jetpack, tick)
end

---@param jetpack jetpack_struct
---@param tick uint
local function on_tick_rising(jetpack, tick)
  if jetpack.altitude < Jetpack.altitude_target then
    local difference = Jetpack.altitude_target - jetpack.altitude
    local change =
      math.min(difference, difference * Jetpack.altitude_percentage_increase + Jetpack.altitude_base_increase)
    jetpack.altitude = jetpack.altitude + change
    jetpack.character.teleport({ x = jetpack.character.position.x, y = jetpack.character.position.y - change })
  else
    jetpack.status = Jetpack.statuses.flying
  end

  on_tick_flying(jetpack, tick)
end

---@param jetpack jetpack_struct
---@param tick uint
local function on_tick_stopping(jetpack, tick)
  if jetpack.altitude > 0 then
    jetpack.altitude = math.max(0, jetpack.altitude - Jetpack.altitude_decrease)
    jetpack.character.teleport({
      x = jetpack.character.position.x,
      y = jetpack.character.position.y + Jetpack.altitude_decrease,
    })
    movement_tick(jetpack, tick)
    if jetpack.character.valid then -- Could have instantly landed in movement_tick
      JetpackGraphicsSound.update_graphics(jetpack)
      JetpackGraphicsSound.update_sound(jetpack, tick)
    end
  else -- Reached the floor
    Jetpack.land_and_start_walking(jetpack)
  end
end

---@param jetpack jetpack_struct
---@param tick uint
local function on_tick_falling(jetpack, tick)
  if jetpack.altitude > 0 then
    jetpack.altitude = math.max(0, jetpack.altitude - Jetpack.altitude_decrease_falling)
    jetpack.character.teleport({
      x = jetpack.character.position.x,
      y = jetpack.character.position.y + Jetpack.altitude_decrease,
    })
    jetpack.orientation = jetpack.orientation + Jetpack.falling_orientation_spin -- Spin
    movement_tick(jetpack, tick, true) -- Momentum, but disallow thrust
    if jetpack.character.valid then -- Could have instantly landed in movement_tick
      JetpackGraphicsSound.update_graphics(jetpack)
      JetpackGraphicsSound.update_sound(jetpack, tick)
    end
  else -- Reached the floor
    local landing_tile_name =
      jetpack.character.surface.get_tile(jetpack.character.position.x, jetpack.character.position.y).name
    if not Jetpack.space_tiles[landing_tile_name] then
      jetpack.character.surface.create_entity({
        name = "small-scorchmark-tintable",
        position = jetpack.character.position,
      })
      JetpackGraphicsSound.create_land_effects(jetpack.character, landing_tile_name, 4, 1.8) -- Some extra dust circles
    end
    Jetpack.land_and_start_walking(jetpack)
  end
end

---@type {jetpack_status: fun(jetpack_struct, uint)}
local on_tick_actions = {
  [Jetpack.statuses.flying] = on_tick_flying,
  [Jetpack.statuses.spacewalking] = on_tick_spacewalking,
  [Jetpack.statuses.rising] = on_tick_rising,
  [Jetpack.statuses.stopping] = on_tick_stopping,
  [Jetpack.statuses.falling] = on_tick_falling,
}

---@param jetpack jetpack_struct
---@param tick uint
local function on_tick_jetpack(jetpack, tick)
  -- Character died or was destroyed
  if not (jetpack.character and jetpack.character.valid) then
    global.jetpacks[jetpack.unit_number] = nil
    return JetpackGraphicsSound.cleanup(jetpack)
  end

  local action = on_tick_actions[jetpack.status]
  if action then
    action(jetpack, tick)
  end -- else is "walking", do nothing
end

local function on_tick(event)
  for _unit_number, jetpack in pairs(global.jetpacks) do
    on_tick_jetpack(jetpack, event.tick)
  end

  for unit_number, jetpack in pairs(Jetpack.jetpacks_to_add) do
    global.jetpacks[unit_number] = jetpack
    Jetpack.jetpacks_to_add[unit_number] = nil
  end

  -- Re-attach personal construction bots after character swap
  for k, robot_collection in pairs(global.robot_collections) do
    if not (robot_collection.character and robot_collection.character.valid) then
      global.robot_collections[k] = nil
    elseif
      robot_collection.character.logistic_cell
      and robot_collection.character.logistic_cell.valid
      and robot_collection.character.logistic_cell.logistic_network
      and robot_collection.character.logistic_cell.logistic_network.valid
    then
      for _, robot in pairs(robot_collection.robots) do
        if robot.valid and robot.surface == robot_collection.character.surface then
          robot.logistic_network = robot_collection.character.logistic_cell.logistic_network
        end
      end
      global.robot_collections[k] = nil
    end
  end
end
script.on_event(defines.events.on_tick, on_tick)

---@param old LuaEntity
---@param new_name string
---@return LuaEntity?
local function swap_character(old, new_name)
  if not game.entity_prototypes[new_name] then
    return
  end
  local buffer_capacity = 1000
  local position = old.position
  if not Jetpack.character_is_flying_version(new_name) then
    position = old.surface.find_non_colliding_position(new_name, position, 1, 0.25, false) or position
  end
  local new = old.surface.create_entity({
    name = new_name,
    position = position,
    force = old.force,
    direction = old.direction,
  }) --[[@as LuaEntity]]

  local follow_list = global.following_spidertrons[old.unit_number]
  if follow_list then
    for follower_unit_number, follower in pairs(follow_list) do
      if follower and follower.valid then
        local follow_target = follower.follow_target
        if follow_target and follow_target == old then
          local old_follow_offset = follower.follow_offset
          follower.follow_target = new
          follower.follow_offset = old_follow_offset
        else
          follow_list[follower_unit_number] = nil
        end
      end
    end
  end
  global.following_spidertrons[new.unit_number] = follow_list
  global.following_spidertrons[old.unit_number] = nil

  for _, robot in pairs(old.following_robots) do
    robot.combat_robot_owner = new
  end

  new.character_inventory_slots_bonus = old.character_inventory_slots_bonus + buffer_capacity
  old.character_inventory_slots_bonus = old.character_inventory_slots_bonus + buffer_capacity

  -- Save crafting queue
  local vehicle = old.vehicle
  local save_queue = nil
  local crafting_queue_progress = old.crafting_queue_progress
  if old.crafting_queue then
    save_queue = {}
    for i = old.crafting_queue_size, 1, -1 do
      if old.crafting_queue and old.crafting_queue[i] then
        table.insert(save_queue, old.crafting_queue[i])
        old.cancel_crafting(old.crafting_queue[i])
      end
    end
  end

  -- Save personal construction robots
  if old.logistic_cell and old.logistic_cell.logistic_network and #old.logistic_cell.logistic_network.robots > 0 then
    table.insert(global.robot_collections, { character = new, robots = old.logistic_cell.logistic_network.robots })
  end

  new.character_health_bonus = old.character_health_bonus
  new.character_crafting_speed_modifier = old.character_crafting_speed_modifier
  new.character_mining_speed_modifier = old.character_mining_speed_modifier
  new.character_running_speed_modifier = old.character_running_speed_modifier
  new.character_build_distance_bonus = old.character_build_distance_bonus
  new.character_reach_distance_bonus = old.character_reach_distance_bonus
  new.character_resource_reach_distance_bonus = old.character_resource_reach_distance_bonus
  new.character_item_pickup_distance_bonus = old.character_item_pickup_distance_bonus
  new.character_loot_pickup_distance_bonus = old.character_loot_pickup_distance_bonus
  new.character_item_drop_distance_bonus = old.character_item_drop_distance_bonus
  new.character_inventory_slots_bonus = old.character_inventory_slots_bonus
  new.character_trash_slot_count_bonus = old.character_trash_slot_count_bonus
  new.character_maximum_following_robot_count_bonus = old.character_maximum_following_robot_count_bonus
  new.health = old.health
  new.copy_settings(old)
  new.selected_gun_index = old.selected_gun_index

  -- Copy personal logistic requests
  local limit = old.request_slot_count
  local i = 1
  while i <= limit do
    local slot = old.get_personal_logistic_slot(i)
    if slot and slot.name then
      if slot.min then
        if slot.max then
          slot.min = math.min(slot.min, slot.max)
        end
        slot.min = math.max(0, slot.min)
      end
      if slot.max then
        if slot.min then
          slot.max = math.max(slot.min, slot.max)
        end
        slot.max = math.max(0, slot.max)
      end
      new.set_personal_logistic_slot(i, slot)
    end
    i = i + 1
  end
  new.character_personal_logistic_requests_enabled = old.character_personal_logistic_requests_enabled
  new.allow_dispatching_robots = old.allow_dispatching_robots

  local hand_location
  local cursor_ghost
  local cursor_stack_temporary
  local opened_armor
  if old.player then
    hand_location = old.player.hand_location
    cursor_ghost = old.player.cursor_ghost

    -- Set cooldown only if there's no higher cooldown already in place
    if
      not global.player_toggle_cooldown[old.player.index]
      or global.player_toggle_cooldown[old.player.index] < game.tick + Jetpack.toggle_cooldown
    then
      global.player_toggle_cooldown[old.player.index] = game.tick + Jetpack.toggle_cooldown
    end

    -- Handles players holding temporary blueprints e.g. blank upgrade, deconstruction planners, copy paste
    cursor_stack_temporary = old.player.cursor_stack_temporary

    -- Swap character controlled
    local opened_self = old.player.opened_self
    opened_armor = old.player.opened == old.grid
    old.player.set_controller({ type = defines.controllers.character, character = new })
    if opened_self then
      new.player.opened = new
    end
  end

  -- Much faster (and easier) to just transfer armor from one character to the other.
  -- The problem is this changes the inventory size of `old` which causes a slow recalc of the logistic networks with large inventory sizes.
  -- If that issue is ever fixed, change to this code instead of copying everything in the grid.
  -- `buffer` should handle inventory overflow during the swap.

  --[[
  local old_inv_armor_slot = old.get_inventory(defines.inventory.character_armor)[1]
  if old_inv_armor_slot and old_inv_armor_slot.valid_for_read then
    local new_inv_armor = new.get_inventory(defines.inventory.character_armor)
    new.get_inventory(defines.inventory.character_armor)[1].swap_stack(old_inv_armor_slot)
    if opened_armor and player then
      player.opened = new_inv_armor[1]
    end
  end
  ]]

  -- need to stop inventory overflow when armor is swapped
  local old_inv = old.get_inventory(defines.inventory.character_armor)
  if old_inv and old_inv[1] and old_inv[1].valid_for_read then
    local new_inv = new.get_inventory(defines.inventory.character_armor)
    new_inv.insert({ name = old_inv[1].name, count = 1 })
    if opened_armor and new.player then
      new.player.opened = new_inv[1]
    end
  end

  if old.grid then
    for _, old_eq in pairs(old.grid.equipment) do
      local new_eq = new.grid.put({ name = old_eq.name, position = old_eq.position })
      if new_eq and new_eq.valid then
        if old_eq.type == "energy-shield-equipment" then
          new_eq.shield = old_eq.shield
        end
        if old_eq.energy then
          new_eq.energy = old_eq.energy
        end
        if old_eq.burner then
          for i = 1, #old_eq.burner.inventory do
            new_eq.burner.inventory.insert(old_eq.burner.inventory[i])
          end
          for i = 1, #old_eq.burner.burnt_result_inventory do
            new_eq.burner.burnt_result_inventory.insert(old_eq.burner.burnt_result_inventory[i])
          end

          new_eq.burner.currently_burning = old_eq.burner.currently_burning
          new_eq.burner.heat = old_eq.burner.heat
          new_eq.burner.remaining_burning_fuel = old_eq.burner.remaining_burning_fuel
        end
      end
    end
    new.grid.inhibit_movement_bonus = old.grid.inhibit_movement_bonus
  end

  if new.player then
    new.cursor_stack.swap_stack(old.cursor_stack)
    new.player.cursor_stack_temporary = cursor_stack_temporary

    if hand_location then
      new.player.hand_location = hand_location
    end
    if cursor_ghost then
      new.player.cursor_ghost = cursor_ghost
    end
  end

  -- Copy as much as we can for performance gains.
  -- Swap non-fungible items (remotes, blueprints, etc.) to keep quickbar references.
  util.copy_or_swap_entity_inventory(old, new, defines.inventory.character_main)
  util.copy_or_swap_entity_inventory(old, new, defines.inventory.character_trash)
  util.copy_entity_inventory(old, new, defines.inventory.character_guns)
  util.copy_entity_inventory(old, new, defines.inventory.character_ammo)

  if save_queue then
    for i = #save_queue, 1, -1 do
      local cci = save_queue[i]
      if cci then
        cci.silent = true
        new.begin_crafting(cci)
      end
    end
    new.crafting_queue_progress = math.min(1, crafting_queue_progress)
  end
  new.character_inventory_slots_bonus = new.character_inventory_slots_bonus - buffer_capacity -- needs to be before raise_event

  if global.current_fuel_by_character[old.unit_number] then
    global.current_fuel_by_character[new.unit_number] = global.current_fuel_by_character[old.unit_number]
    global.current_fuel_by_character[old.unit_number] = nil
  end

  if old.valid then
    old.destroy()
  end
  if vehicle then
    if not vehicle.get_driver() then
      vehicle.set_driver(new)
    elseif not vehicle.get_passenger() then
      vehicle.set_passenger(new)
    end
  end

  return new
end

---@param old_character LuaEntity
---@return LuaEntity?
function Jetpack.swap_to_land_character(old_character)
  return swap_character(old_character, util.replace(old_character.name, Jetpack.name_character_suffix, ""))
end

---@param old_character LuaEntity
---@return LuaEntity?
function Jetpack.swap_to_flying_character(old_character)
  return swap_character(old_character, old_character.name .. Jetpack.name_character_suffix)
end

---@param event EventData.on_player_placed_equipment|EventData.on_player_removed_equipment|EventData.on_player_armor_inventory_changed
local function on_armor_changed(event)
  local player = game.get_player(event.player_index) --[[@as LuaPlayer]]
  if player.character then
    local character = player.character
    local jetpack = Jetpack.from_character(character)
    if jetpack then
      local fuel = get_fuel(character)
      local thrust = Jetpack.get_current_thrust(character, fuel)
      jetpack.thrust = thrust
      if thrust <= 0 then
        jetpack.status = Jetpack.statuses.stopping
      end
    end
  end
end
script.on_event(defines.events.on_player_placed_equipment, on_armor_changed)
script.on_event(defines.events.on_player_removed_equipment, on_armor_changed)
script.on_event(defines.events.on_player_armor_inventory_changed, on_armor_changed)

---@param character LuaEntity
---@return float
local function get_current_jetpack_equipment_thrust(character)
  local armor_thrust = 0
  -- thruster suits have thrust
  local armor_inv = character.get_inventory(defines.inventory.character_armor)
  if armor_inv and armor_inv[1] and armor_inv[1].valid_for_read then
    local armor = armor_inv[1]
    if Jetpack.jetpack_armor[armor.name] then
      armor_thrust = armor_thrust + Jetpack.jetpack_armor[armor.name].thrust
    end
  end

  local thrust = armor_thrust
  -- jetpack equipment has thrust
  if character.grid then
    for name, count in pairs(character.grid.get_contents()) do
      if Jetpack.jetpack_equipment[name] ~= nil then
        if Settings.get_setting_global("jetpack-thrust-stacks") then
          thrust = thrust + count * (Jetpack.jetpack_equipment[name].thrust or 0)
        else
          local this_thrust = armor_thrust + Jetpack.jetpack_equipment[name].thrust
          if this_thrust > thrust then
            thrust = this_thrust
          end
        end
      end
    end
  end

  return thrust --[[@as float]]
end

---@param character LuaEntity
---@param fuel fuel_struct?
---@return float
function Jetpack.get_current_thrust(character, fuel)
  if not fuel then
    return 0
  end

  local thrust = get_current_jetpack_equipment_thrust(character)

  if thrust == 0 then
    return 0
  end -- No jetpack equipment, no need to go further.

  -- Apply fuel multiplier
  local fuel_thrust_multiplier = fuel.thrust or 1
  thrust = thrust * fuel_thrust_multiplier

  -- Slow down with weight
  local grid_slots = character.grid and (character.grid.width * character.grid.height) or 0
  local weight = #character.get_main_inventory() / 10 + grid_slots
  local final_thrust = Jetpack.printed_thrust_multiplier * thrust / weight

  -- Print thrust
  if character.player and Settings.get_setting_player(character.player.index, "jetpack-print-thrust") then
    if fuel and final_thrust ~= global.last_printed_thrust[character.player.index] then -- Don't print thrust when you have no fuel
      if fuel_thrust_multiplier == 1 then
        character.player.print({ "jetpack.jetpack_acceleration", string.format("%.2f", final_thrust) })
      else
        local fuel_bonus_percentage = string.format("%.f", (fuel_thrust_multiplier - 1) * 100)
        if fuel_thrust_multiplier > 1 then
          fuel_bonus_percentage = "+" .. fuel_bonus_percentage
        end
        local fuel_prototype = game.item_prototypes[fuel.name]
        local fuel_icon = "[img=item/" .. fuel.name .. "]"
        local fuel_localised_name = fuel_prototype and fuel_prototype.localised_name or "Unknown fuel"
        character.player.print({
          "jetpack.jetpack_acceleration_with_fuel_bonus",
          string.format("%.2f", final_thrust),
          fuel_bonus_percentage,
          fuel_icon,
          fuel_localised_name,
        })
      end
      global.last_printed_thrust[character.player.index] = final_thrust
    end
  end

  return final_thrust ^ 0.5 --[[@as float]]
end

function Jetpack.character_is_flying_version(name)
  if string.find(name, Jetpack.name_character_suffix, 1, true) then
    return true
  else
    return false
  end
end

-- Creates a new jetpack object and swaps character if needed.
-- Sometimes character swap is not needed, e.g. from walking to spacewalking.
-- This method always assumes the character starts from walking state.
---@param character LuaEntity
---@param thrust float
---@param default_status jetpack_status
---@return jetpack_struct?
function Jetpack.start_on_character(character, thrust, default_status)
  default_status = default_status or Jetpack.statuses.rising
  local player = character.player
  local force_name = character.force.name

  if not player then
    return
  end
  if character.vehicle or global.disabled_on[character.unit_number] then
    return
  end

  local tile = character.surface.get_tile(character.position.x, character.position.y)
  if Jetpack.no_jetpacking_tiles[tile.name] then
    character_print(character, { "jetpack.cant_fly_inside" })
    return
  end

  local walking_state = character.walking_state
  local new_character
  if default_status == Jetpack.statuses.rising or default_status == Jetpack.statuses.flying then
    if not Jetpack.character_is_flying_version(character.name) then
      new_character = Jetpack.swap_to_flying_character(character)
      if not new_character then
        for _, jetpack in pairs(global.jetpacks) do
          if jetpack.character == character then
            return
          end
        end
        new_character = character
      end
    end
  else
    if Jetpack.character_is_flying_version(character.name) then
      new_character = Jetpack.swap_to_land_character(character)
      if not new_character then
        for _, jetpack in pairs(global.jetpacks) do
          if jetpack.character == character then
            return
          end
        end
        new_character = character
      end
    end
  end
  ---@type jetpack_struct
  local jetpack = {
    status = default_status,
    character = new_character or character,
    unit_number = new_character and new_character.unit_number or character.unit_number,
    force_name = force_name,
    player_index = player.index,
    velocity = { x = 0, y = 0 },
    speed = 0,
    smoke_timer = 0,
    flame_timer = 0,
    altitude = 0,
    thrust = thrust,
    character_type = (default_status == Jetpack.statuses.rising or default_status == Jetpack.statuses.flying) and "fly"
      or "land",
  }
  if walking_state.walking == true then
    local direction_vector = util.direction_to_vector(walking_state.direction)
    if direction_vector then
      local thrust = Jetpack.thrust_multiplier_before_move * jetpack.thrust -- get from equipment + fuel
      local base_thrust = jetpack.status == Jetpack.statuses.spacewalking and Jetpack.spacewalk_jump_base_thrust
        or Jetpack.jump_base_thrust
      jetpack.velocity.x = direction_vector.x * (base_thrust + Jetpack.jump_thrust_multiplier * thrust)
      jetpack.velocity.y = direction_vector.y * (base_thrust + Jetpack.jump_thrust_multiplier * thrust)
      jetpack.speed = base_thrust + Jetpack.jump_thrust_multiplier * thrust
    end
  end
  JetpackGraphicsSound.update_graphics(jetpack)
  JetpackGraphicsSound.update_sound(jetpack, game.tick)
  Jetpack.jetpacks_to_add[jetpack.unit_number] = jetpack
  return jetpack
end

local function on_player_changed_position(event)
  local player = game.get_player(event.player_index) --[[@as LuaPlayer]]
  if player and player.connected and player.character then
    local jetpack = Jetpack.from_character(player.character)
    if
      not jetpack -- "walking"
      and Jetpack.on_space_tile(player.character)
    then
      -- Starting spacewalking
      local character = player.character
      Jetpack.start_on_character(character, 0, Jetpack.statuses.spacewalking)
    end
  end
end
script.on_event(defines.events.on_player_changed_position, on_player_changed_position)

---@param event EventData.on_player_joined_game
local function on_player_joined_game(event)
  local player = game.get_player(event.player_index) --[[@as LuaPlayer]]
  if player and player.connected and player.character then
    if Jetpack.character_is_flying_version(player.character.name) then
      local character = player.character
      local fuel = get_fuel(character)
      local thrust = Jetpack.get_current_thrust(character, fuel)
      local jetpack = Jetpack.start_on_character(character, thrust, Jetpack.statuses.flying)
      if jetpack then
        jetpack.altitude = Jetpack.altitude_target
      end
    end
  end
end
script.on_event(defines.events.on_player_joined_game, on_player_joined_game)

---@param event EventData.on_entity_damaged
local function on_character_damaged(event)
  if Settings.get_setting_global("jetpack-fall-on-damage") then
    local jetpack = Jetpack.from_character(event.entity)
    local status = get_jetpack_status(jetpack)
    if
      event.damage_type.name ~= "suffocation"
      and event.damage_type.name ~= "radioactive" -- Don't fall down from SE's suffocation and K2's uranium
      and (
        status == Jetpack.statuses.flying
        or status == Jetpack.statuses.rising
        or status == Jetpack.statuses.stopping
      )
    then
      jetpack.status = Jetpack.statuses.falling
      -- jetpack.altitude_decrease = Jetpack.altitude_decrease * 2 -- Fall twice as fast
      JetpackGraphicsSound.create_damage_effects(jetpack.character)
      local player = event.entity.player
      if player then -- If you detach your character just before getting hit then you avoid the cooldown, sure to be a crucial speedrunning technique lol
        global.player_toggle_cooldown[player.index] = event.tick + Jetpack.damage_cooldown
      end
    end
  end
end
script.on_event(defines.events.on_entity_damaged, on_character_damaged, { { filter = "type", type = "character" } })

---@param jetpack jetpack_struct
function Jetpack.stop_jetpack(jetpack)
  jetpack.status = Jetpack.statuses.stopping
end

---@param character LuaEntity
function Jetpack.toggle(character)
  local jetpack = Jetpack.from_character(character)
  local status = get_jetpack_status(jetpack)

  if
    status == Jetpack.statuses.walking
    or status == Jetpack.statuses.spacewalking
    or status == Jetpack.statuses.stopping
  then
    if character.vehicle or global.disabled_on[character.unit_number] then
      return
    end

    local fuel = get_fuel(character)
    if not fuel then
      if get_current_jetpack_equipment_thrust(character) == 0 then -- Warn about no jetpack before no fuel
        character_print(character, { "jetpack.need_jetpack" })
      else
        character_print(character, { "jetpack.need_fuel" })
      end
      return
    end

    local thrust = Jetpack.get_current_thrust(character, fuel)
    if thrust == 0 then
      character_print(character, { "jetpack.need_jetpack" })
      return
    end

    if status == Jetpack.statuses.walking then
      Jetpack.start_on_character(character, thrust, Jetpack.statuses.rising)
    elseif status == Jetpack.statuses.spacewalking then
      -- Swap jetpack type from spacewalking to flying
      local flying_character = Jetpack.swap_to_flying_character(character)
      if flying_character then
        global.jetpacks[jetpack.unit_number] = nil

        jetpack.character = flying_character
        jetpack.unit_number = flying_character.unit_number
        jetpack.status = Jetpack.statuses.rising
        jetpack.character_type = "fly"
        jetpack.orientation = nil
        jetpack.thrust = thrust

        Jetpack.jetpacks_to_add[jetpack.unit_number] = jetpack
      end
    else -- "stopping"
      jetpack.status = Jetpack.statuses.rising
      jetpack.thrust = thrust
    end
  else -- rising or flying
    jetpack.status = Jetpack.statuses.stopping
  end
end

local function on_jetpack_keypress(event)
  local player = game.get_player(event.player_index) --[[@as LuaPlayer]]
  if player.character then
    if
      not global.player_toggle_cooldown[event.player_index]
      or global.player_toggle_cooldown[event.player_index] < event.tick
    then
      global.player_toggle_cooldown[event.player_index] = event.tick + Jetpack.toggle_cooldown
      Jetpack.toggle(player.character)
    else
      player.play_sound({ path = "utility/cannot_build" })
    end
  end
end
script.on_event("jetpack", on_jetpack_keypress)

-- As far as I can tell, when flying you can only enter vehicles via scripts.
-- For example, ironclad.
---@param event EventData.on_player_driving_changed_state
local function on_player_driving_changed_state(event)
  local player = game.get_player(event.player_index) --[[@as LuaPlayer]]
  if not player or not player.character or not player.character.valid then
    return
  end
  local jetpack = Jetpack.from_character(player.character)
  if not jetpack or not jetpack.character.valid then
    return
  end

  if Jetpack.character_is_flying_version(jetpack.character.name) then
    Jetpack.land_and_start_walking(jetpack)
  end
end
script.on_event(defines.events.on_player_driving_changed_state, on_player_driving_changed_state)

---@param event EventData.on_player_used_spider_remote
function Jetpack.on_player_used_spider_remote(event)
  if event.success then
    local spidertron = event.vehicle
    local target = spidertron.follow_target
    if target and target.type == "character" then
      -- Add the spidertron to the follow list of the player
      local follow_list = global.following_spidertrons[target.unit_number] or {}
      follow_list[spidertron.unit_number] = spidertron
      global.following_spidertrons[target.unit_number] = follow_list
    end
  end
end
script.on_event(defines.events.on_player_used_spider_remote, Jetpack.on_player_used_spider_remote)

local function on_init()
  global.jetpacks = {}
  global.current_fuel_by_character = {}
  global.player_toggle_cooldown = {}
  global.robot_collections = {}
  global.disabled_on = {}
  global.last_printed_thrust = {}
  global.following_spidertrons = {}
end
script.on_init(on_init)

local function on_configuration_changed()
  global.following_spidertrons = global.following_spidertrons or {}
  load_compatible_fuels()
end
script.on_configuration_changed(on_configuration_changed)

return Jetpack
