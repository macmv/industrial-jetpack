local data_util = require("data_util")

local extra_jetpack_prototypes = {
  ["jetpack-0"] = {
    tier = 0,
    grid_width = 2,
    grid_height = 2,
    power = "100kW",
    ingredients = {
      { "iron-piston", 4 },
      { "pipe", 10 },
      { "iron-rivet", 8 },
      { "iron-gear-wheel", 10 },
    },
    science_packs = {
      { "automation-science-pack", 1 },
      { "logistic-science-pack", 1 },
    },
    prerequisites = {
      "heavy-armor",
      "ir-iron-milestone",
      "ir-steambot",
    },
  },
}

for name, jep in pairs(extra_jetpack_prototypes) do
  local jetpack_equipment = table.deepcopy(data.raw["battery-equipment"]["battery-equipment"])
  jetpack_equipment.name = name
  jetpack_equipment.movement_bonus = 0
  jetpack_equipment.energy_source = {
    type = "void",
    usage_priority = "tertiary",
  }
  --jetpack_equipment.energy_consumption = "1kW"
  jetpack_equipment.sprite = {
    filename = "__industrial-jetpack__/graphics/equipment/" .. name .. ".png",
    width = 128,
    height = 128,
    priority = "medium",
  }
  --jetpack_equipment.background_color = { r = 0.2, g = 0.3, b = 0.6, a = 1 }
  jetpack_equipment.shape = { width = jep.grid_width, height = jep.grid_width, type = "full" }
  jetpack_equipment.categories = { "armor-jetpack" }

  local jetpack_item = table.deepcopy(data.raw["item"]["battery-equipment"])
  jetpack_item.name = name
  jetpack_item.icon = "__industrial-jetpack__/graphics/icons/" .. name .. ".png"
  jetpack_item.icon_size = 64
  jetpack_item.placed_as_equipment_result = name

  local jetpack_recipe = table.deepcopy(data.raw["recipe"]["battery-equipment"])
  jetpack_recipe.name = name
  jetpack_recipe.icon = icon_path
  jetpack_recipe.icon_size = 32
  jetpack_recipe.enabled = false
  jetpack_recipe.result = name
  jetpack_recipe.ingredients = jep.ingredients
  jetpack_recipe.energy_required = 5
  jetpack_recipe.category = "crafting"

  local jetpack_tech = {
    type = "technology",
    name = name,
    effects = { { type = "unlock-recipe", recipe = name } },
    icons = data_util.technology_icon_constant_equipment(
      "__industrial-jetpack__/graphics/technology/" .. name .. ".png",
      256
    ),
    order = "e-g",
    prerequisites = jep.prerequisites,
    unit = {
      count = 50,
      time = 30,
      ingredients = jep.science_packs,
    },
  }

  data:extend({
    jetpack_equipment,
    jetpack_item,
    jetpack_recipe,
    jetpack_tech,
  })
end
