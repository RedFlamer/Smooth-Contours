function ManageSpawnedUnits:spawn_unit(unit_id, align_obj_name, unit)
	local align_obj = self._unit:get_object(Idstring(align_obj_name))
	local spawn_unit = nil
	if type_name(unit) == "string" then
		if Network:is_server() or self.allow_client_spawn then
			local spawn_pos = align_obj:position()
			local spawn_rot = align_obj:rotation()
			spawn_unit = safe_spawn_unit(Idstring(unit), spawn_pos, spawn_rot)
			spawn_unit:unit_data().parent_unit = self._unit
		end
	else
		spawn_unit = unit
	end

	if not spawn_unit then
		return
	end

	self._unit:link(Idstring(align_obj_name), spawn_unit, spawn_unit:orientation_object():name())

	local contour_ext = self._unit:contour()
	if contour_ext then
		contour_ext:add_child_unit(spawn_unit)
	end

	local unit_entry = {
		align_obj_name = align_obj_name,
		unit = spawn_unit
	}
	self._spawned_units[unit_id] = unit_entry

	if Network:is_server() and not self.local_only then
		managers.network:session():send_to_peers_synched("sync_unit_spawn", self._unit, spawn_unit, align_obj_name, unit_id, "spawn_manager")
	end
end