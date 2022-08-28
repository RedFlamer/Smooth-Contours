local idstr_material = Idstring("material")
local idstr_contour_color = Idstring("contour_color")
local idstr_contour_opacity = Idstring("contour_opacity")

local tmp_vec1 = Vector3()

Hooks:PreHook(ContourExt, "init", "smooth_contours_init", function(self)
	self._occlusion_state = true
end)

Hooks:PostHook(ContourExt, "init", "smooth_contours_init", function(self)
	if self._contour_list and not next(self._contour_list) then
		self._contour_list = nil -- why define this as an empty table when every function checks it's not nil to figure out if there's a contour active...
	end
end)

-- parent unit handles everything through it's contour extension now
function ContourExt:apply_to_linked()
end

local add_orig = ContourExt.add
function ContourExt:add(...)
	local setup = add_orig(self, ...)
	if setup and setup.fadeout_t then
		setup.fadeout_start_t = math.lerp(TimerManager:game():time(), setup.fadeout_t, 0.8)
	end

	return setup
end

function ContourExt:_remove(index, sync)
	local setup = self._contour_list and self._contour_list[index]
	if not setup then
		return
	end

	local contour_type = setup.type
	local data = self._types[setup.type]
	if setup.ref_c and setup.ref_c > 1 then
		setup.ref_c = setup.ref_c - 1

		return
	end

	if #self._contour_list == 1 then
		self:_set_occlusion_state(true)

		if data.material_swap_required then
			self._unit:base():set_material_state(true)
			self._unit:base():set_allow_invisible(true)
		else
			self:_upd_opacity(0)
		end

		if data.damage_bonus then
			self._unit:character_damage():on_marked_state(false)
		end
	end

	self._last_opacity = nil

	table.remove(self._contour_list, index)

	if #self._contour_list == 0 then
		self:_clear()
	elseif index == 1 then
		self:_apply_top_preset()
	end

	if sync then
		local u_id = self._unit:id()

		if u_id == -1 then
			u_id = managers.enemy:get_corpse_unit_data_from_key(self._unit:key()).u_id
		end

		managers.network:session():send_to_peers_synched("sync_contour_state", self._unit, u_id, table.index_of(ContourExt.indexed_types, contour_type), false, 1)
	end

	if data.trigger_marked_event then
		local should_trigger_unmarked_event = true

		for _, setup in ipairs(self._contour_list or {}) do
			if self._types[setup.type].trigger_marked_event then
				should_trigger_unmarked_event = false

				break
			end
		end

		if should_trigger_unmarked_event and self._unit:unit_data().mission_element then
			self._unit:unit_data().mission_element:event("unmarked", self._unit)
		end
	end
end

function ContourExt:update(unit, t, dt)
	self._materials = nil -- lod changes seem to break the material cache, so i'm just refreshing it every frame

	local index = 1
	while self._contour_list and index <= #self._contour_list do
		local setup = self._contour_list[index]
		if setup.fadeout_t and setup.fadeout_t < t then
			self:_remove(index)
			self:_chk_update_state()
		else
			local data = self._types[setup.type]
			local is_current = index == 1
			local opacity = nil
			if data.ray_check and unit:movement() and is_current then
				local turn_on = nil
				local cam_pos = managers.viewport:get_current_camera_position()
				if cam_pos then
					turn_on = mvector3.distance_sq(cam_pos, unit:movement():m_com()) > 16000000 or unit:raycast("ray", unit:movement():m_com(), cam_pos, "slot_mask", self._slotmask_world_geometry, "report")
				end

				local target_opacity = turn_on and 1 or 0
				if self._last_opacity ~= target_opacity then
					opacity = math.step(self._last_opacity or 0, target_opacity, dt / data.persistence)
				end
			end

			if setup.flash_t then
				if setup.flash_t < t then
					setup.flash_t = t + setup.flash_frequency
					setup.flash_on = not setup.flash_on
				end

				if is_current then
					opacity = (setup.flash_t - t) / setup.flash_frequency
					opacity = setup.flash_on and opacity or 1 - opacity
				end
			elseif setup.fadeout_start_t and is_current then
				opacity = (t - setup.fadeout_start_t) / (setup.fadeout_t - setup.fadeout_start_t)
				opacity = 1 - math.max(opacity, 0)
			end

			if opacity then
				self:_upd_opacity(opacity)
			end

			index = index + 1
		end
	end
end

function ContourExt:_get_materials()
	local materials = {}
	local function add_materials(unit)
		for _, material in ipairs(unit:get_objects_by_type(idstr_material)) do
			if material:variable_exists(idstr_contour_color) and material:variable_exists(idstr_contour_opacity) then
				table.insert(materials, material)
			end
		end
	end
	
	add_materials(self._unit)

	local linked_units = self._unit.spawn_manager and self._unit:spawn_manager() and self._unit:spawn_manager():linked_units()
	if linked_units then
		local spawned_units = self._unit:spawn_manager():spawned_units()
		for unit_id in pairs(linked_units) do
			local unit_desc = spawned_units[unit_id]
			if unit_desc and alive(unit_desc.unit) then
				add_materials(unit_desc.unit)
			end
		end
	end

	return materials
end

function ContourExt:_upd_opacity(opacity, is_retry)
	if opacity == self._last_opacity then
		return
	end

	self._materials = self._materials or self:_get_materials()

	for _, material in ipairs(self._materials) do
		if alive(material) then
			material:set_variable(idstr_contour_opacity, opacity)
		elseif not is_retry then
			self._last_opacity = opacity
			return self:update_materials()
		end
	end

	self._last_opacity = opacity -- set too early in vanilla so retrying the function returns immediately
	self:_upd_color(opacity, is_retry) -- pass is_retry so it doesn't waste time invalidating the cache if it didn't fix itself here
end

function ContourExt:_upd_color(opacity, is_retry)
	if not self._contour_list then
		return
	end

	local contour_color = self._contour_list[1].color or self._types[self._contour_list[1].type].color
	if not contour_color then
		return
	end

	opacity = opacity or 1
	local color = tmp_vec1

	mvector3.set(color, contour_color)
	mvector3.multiply(color, opacity)

	self._materials = self._materials or self:_get_materials()

	for _, material in ipairs(self._materials) do
		if alive(material) then
			material:set_variable(idstr_contour_color, color)
		elseif not is_retry then
			return self:update_materials()
		end
	end
end

Hooks:PreHook(ContourExt, "material_applied", "smooth_contours_material_applied", function(self)
	self:_set_occlusion_state(false)
end)

function ContourExt:_set_occlusion_state(state)
	if self._occlusion_state == state then
		return
	end

	local occ_manager = managers.occlusion
	local occ_func = state and occ_manager.add_occlusion or occ_manager.remove_occlusion
	
	occ_func(occ_manager, self._unit)

	local linked_units = self._unit.spawn_manager and self._unit:spawn_manager() and self._unit:spawn_manager():linked_units()
	if linked_units then
		local spawned_units = self._unit:spawn_manager():spawned_units()
		for unit_id in pairs(linked_units) do
			local unit_desc = spawned_units[unit_id]
			if unit_desc and alive(unit_desc.unit) then
				occ_func(occ_manager, unit_desc.unit)
			end
		end
	end

	self._occlusion_state = state
end

function ContourExt:update_materials()
	if self._contour_list then
		self._materials = nil

		local opacity = self._last_opacity or 1
		self._last_opacity = nil

		self:_upd_opacity(opacity, true) -- opacity also updates colour
	end
end

function ContourExt:add_child_unit(unit)
	if not self._occlusion_state then
		managers.occlusion:remove_occlusion(unit)
	end

	self:update_materials()
end