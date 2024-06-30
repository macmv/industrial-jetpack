local JetpackGraphicsSound = {}

---@param jetpack jetpack_struct
function JetpackGraphicsSound.update_graphics(jetpack)
  if jetpack.character_type == "land" then
    return
  end

  if not jetpack.orientation then
    jetpack.orientation = jetpack.character.orientation
  end

  if
    jetpack.character.shooting_state
    and jetpack.character.shooting_state.state ~= defines.shooting.not_shooting
    and jetpack.character.shooting_state.position
  then
    jetpack.orientation = util.lerp_angles(
      jetpack.orientation,
      util.orientation_from_to(jetpack.character.position, jetpack.character.shooting_state.position),
      0.1
    )
    jetpack.orientation = util.step_angles(jetpack.orientation, jetpack.character.orientation, 1 / 256)
    jetpack.last_selected_angle = nil
  elseif jetpack.character.walking_state and jetpack.character.walking_state.walking == false then
    if jetpack.character.player and jetpack.character.player.selected then
      local selected_angle =
        util.orientation_from_to(jetpack.character.position, jetpack.character.player.selected.position)
      jetpack.last_selected_angle = selected_angle
    end
    if jetpack.last_selected_angle then
      jetpack.character.direction = util.orientation_to_direction(jetpack.last_selected_angle)
      jetpack.orientation = util.step_angles(jetpack.orientation, jetpack.last_selected_angle, 1 / 64)
    else
      jetpack.orientation = util.step_angles(jetpack.orientation, jetpack.character.orientation, 1 / 64)
    end
  else
    jetpack.last_selected_angle = nil
    jetpack.orientation = util.step_angles(jetpack.orientation, jetpack.character.orientation, 1 / 64)
  end

  local frame = math.floor(jetpack.orientation * 32 + 0.5)

  if (not jetpack.animation_shadow) or not rendering.is_valid(jetpack.animation_shadow) then
    jetpack.animation_shadow = rendering.draw_animation({
      animation = Jetpack.name_jetpack_shadow,
      surface = jetpack.character.surface,
      target = jetpack.character,
      target_offset = {
        x = Jetpack.shadow_base_offset.x + jetpack.altitude,
        y = Jetpack.shadow_base_offset.y + jetpack.altitude,
      },
      animation_speed = 0,
      animation_offset = frame,
    })
  else
    rendering.set_target(
      jetpack.animation_shadow,
      jetpack.character,
      { x = Jetpack.shadow_base_offset.x + jetpack.altitude, y = Jetpack.shadow_base_offset.y + jetpack.altitude }
    )
    rendering.set_animation_offset(jetpack.animation_shadow, frame)
  end

  if (not jetpack.animation_base) or not rendering.is_valid(jetpack.animation_base) then
    jetpack.animation_base = rendering.draw_animation({
      animation = Jetpack.name_animation_base,
      surface = jetpack.character.surface,
      target = jetpack.character,
      animation_speed = 0,
      animation_offset = frame,
    })
  else
    rendering.set_animation_offset(jetpack.animation_base, frame)
  end

  if (not jetpack.animation_mask) or not rendering.is_valid(jetpack.animation_mask) then
    jetpack.animation_mask = rendering.draw_animation({
      animation = Jetpack.name_animation_mask,
      surface = jetpack.character.surface,
      target = jetpack.character,
      animation_speed = 0,
      animation_offset = frame,
      tint = jetpack.character.player and jetpack.character.player.color or jetpack.character.color,
    })
  else
    rendering.set_animation_offset(jetpack.animation_mask, frame)
  end

  if (not jetpack.animation_flame) or not rendering.is_valid(jetpack.animation_flame) then
    jetpack.animation_flame = rendering.draw_animation({
      animation = Jetpack.name_animation_flame,
      surface = jetpack.character.surface,
      target = jetpack.character,
      animation_speed = 0,
      animation_offset = frame,
    })
  else
    rendering.set_animation_offset(jetpack.animation_flame, frame)
  end
end

---@param jetpack jetpack_struct
---@param tick uint
function JetpackGraphicsSound.update_sound(jetpack, tick)
  if jetpack.character_type == "land" then
    return
  end
  if not (jetpack.sound and jetpack.sound.valid) then
    jetpack.sound = jetpack.character.surface.create_entity({
      name = Jetpack.name_jetpack_sound,
      target = jetpack.character,
      speed = 0,
      position = util.vectors_add(jetpack.character.position, { x = 0, y = 1 }),
      force = jetpack.character.force,
    })
  elseif tick % 60 == 0 or Jetpack.is_moving(jetpack) then
    jetpack.sound.teleport(util.vectors_add(jetpack.character.position, { x = 0, y = 1 }))
  end
end

-- create flame and smoke particles based on speed of jetpack
---@param jetpack jetpack_struct
function JetpackGraphicsSound.create_smoke(jetpack)
  jetpack.smoke_timer = jetpack.smoke_timer - jetpack.speed
  jetpack.flame_timer = jetpack.flame_timer - jetpack.speed * 8 - 1

  if jetpack.flame_timer < 0 then
    jetpack.flame_timer = jetpack.flame_timer % 32
    jetpack.character.surface.create_trivial_smoke({
      name = "fire-smoke",
      position = { jetpack.character.position.x, jetpack.character.position.y - 0.2 },
    })
  end
  if jetpack.smoke_timer < 0 then
    jetpack.smoke_timer = jetpack.smoke_timer % 1
    jetpack.character.surface.create_trivial_smoke({
      name = "smoke",
      position = { jetpack.character.position.x, jetpack.character.position.y - 0.7 },
    })
  end
end

---@param character LuaEntity
function JetpackGraphicsSound.create_spacewalking_smoke(character)
  if math.random() < 0.2 then
    character.surface.create_trivial_smoke({
      name = "smoke-fast",
      position = { character.position.x, character.position.y - 0.2 },
    })
  end
end

---@param surface LuaSurface
---@param position MapPosition
---@param nb_particles uint
---@param particle_name string
---@param particle_speed number
local function create_particle_circle(surface, position, nb_particles, particle_name, particle_speed)
  for orientation = 0, 1, 1 / nb_particles do
    local fuzzed_orientation = orientation + math.random() * 0.1
    local vector = util.orientation_to_vector(fuzzed_orientation, particle_speed)
    surface.create_particle({
      name = particle_name,
      position = { position.x + vector.x, position.y + vector.y },
      movement = vector,
      height = 0.2,
      vertical_speed = 0.1,
      frame_speed = 0.4,
    })
  end
end

local NB_DUST_PUFFS = 14
local NB_WATER_DROPLETS = 20
---@param character LuaEntity
---@param landing_tile_name string
---@param particle_mult float?
---@param speed_mult float?
function JetpackGraphicsSound.create_land_effects(character, landing_tile_name, particle_mult, speed_mult)
  local position = character.position
  if not particle_mult then
    particle_mult = 1
  end
  if not speed_mult then
    speed_mult = 1
  end

  if string.find(landing_tile_name, "water", 1, true) then
    -- Water splash
    create_particle_circle(
      character.surface,
      position,
      NB_WATER_DROPLETS * particle_mult,
      "shallow-water-particle",
      0.05 * speed_mult
    )
    character.surface.play_sound({ path = "tile-walking/water-shallow", position = position })
  else
    -- Dust
    local particle_name = landing_tile_name .. "-dust-particle"
    if not game.particle_prototypes[particle_name] then
      particle_name = "sand-1-dust-particle"
    end
    create_particle_circle(character.surface, position, NB_DUST_PUFFS * particle_mult, particle_name, 0.1 * speed_mult)
    local sound_path = "tile-walking/" .. landing_tile_name
    if game.is_valid_sound_path(sound_path) then
      character.surface.play_sound({ path = sound_path, position = position })
    end
  end
end

local NB_SPARKS = 20
local NB_SMOKE = 6
---@param character LuaEntity
function JetpackGraphicsSound.create_damage_effects(character)
  local position = character.position
  local surface = character.surface
  for i = 1, NB_SPARKS, 1 do
    surface.create_entity({
      name = "spark-explosion",
      position = { position.x + (math.random() - 0.5) * 3, position.y + (math.random() - 0.5) * 3 },
    })
  end
  for i = 1, NB_SMOKE, 1 do
    surface.create_trivial_smoke({
      name = "fire-smoke-on-adding-fuel",
      position = { character.position.x + (math.random() - 0.5) * 3, character.position.y + (math.random() - 0.5) * 3 },
    })
  end

  -- Same explosion and noise as robot death
  surface.create_entity({ name = "logistic-robot-explosion", position = { position.x, position.y } })
  surface.play_sound({ path = "jetpack-damage-fall-woosh", position = position })
  surface.play_sound({ path = "jetpack-damage-fall-vox", position = position })
end

---@param jetpack jetpack_struct
function JetpackGraphicsSound.cleanup(jetpack)
  if jetpack.sound and jetpack.sound.valid then
    jetpack.sound.destroy()
  end
end

return JetpackGraphicsSound
