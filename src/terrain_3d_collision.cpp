// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/height_map_shape3d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/classes/world3d.hpp>

#include <godot_cpp/classes/scene_tree.hpp>

#include "constants.h"
#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_collision.h"
#include "terrain_3d_data.h"
#include "terrain_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

// Calculates shape data from top left position. Assumes descaled and snapped.
Dictionary Terrain3DCollision::_get_shape_data(const Vector2i &p_position, const int p_size) {
	IS_DATA_INIT_MESG("Terrain not initialized", Dictionary());
	const Terrain3DData *data = _terrain->get_data();

	// Get region_loc of top left corner of descaled and grid snapped collision shape position
	Vector2i region_loc = V2I_DIVIDE_FLOOR(p_position, _terrain->get_region_size());
	const Terrain3DRegion *region = data->get_region_ptr(region_loc);
	if (!region || region->is_deleted()) {
		LOG(EXTREME, "Region not found at: ", region_loc, ". Returning blank");
		return Dictionary();
	}

	int hshape_size = p_size + 1; // Calculate last vertex at end
	PackedRealArray map_data = PackedRealArray();
	map_data.resize(hshape_size * hshape_size);
	real_t min_height = FLT_MAX;
	real_t max_height = -FLT_MAX;

	for (int z = 0; z < hshape_size; z++) {
		for (int x = 0; x < hshape_size; x++) {
			// Choose array indexing to match triangulation of heightmapshape with the mesh
			// https://stackoverflow.com/questions/16684856/rotating-a-2d-pixel-array-by-90-degrees
			// Normal array index rotated Y=0 - shape rotation Y=0 (xform below)
			// int index = z * hshape_size + x;
			// Array Index Rotated Y=-90 - must rotate shape Y=+90 (xform below)
			int index = hshape_size - 1 - z + x * hshape_size;
			real_t height = data->get_modified_height(p_position + Vector2i(x, z));
			map_data[index] = height;
			if (!std::isnan(height)) {
				min_height = MIN(min_height, height);
				max_height = MAX(max_height, height);
			}
		}
	}

	// Non rotated shape for normal array index above
	//Transform3D xform = Transform3D(Basis(), global_pos);
	// Rotated shape Y=90 for -90 rotated array index
	Transform3D xform = Transform3D(Basis(V3_UP, Math_PI * .5), v2iv3(p_position + V2I(p_size / 2)));
	Dictionary shape_data;
	shape_data["width"] = hshape_size;
	shape_data["depth"] = hshape_size;
	shape_data["heights"] = map_data;
	shape_data["xform"] = xform;
	shape_data["min_height"] = min_height;
	shape_data["max_height"] = max_height;
	return shape_data;
}

void Terrain3DCollision::_shape_set_disabled(const int p_shape_id, const bool p_disabled) {
	if (is_editor_mode()) {
		CollisionShape3D *shape = _shapes[p_shape_id];
		shape->set_disabled(p_disabled);
		shape->set_visible(!p_disabled);
	} else {
		PS->body_set_shape_disabled(_static_body_rid, p_shape_id, p_disabled);
	}
}

void Terrain3DCollision::_shape_set_transform(const int p_shape_id, const Transform3D &p_xform) {
	if (is_editor_mode()) {
		CollisionShape3D *shape = _shapes[p_shape_id];
		shape->set_transform(p_xform);
	} else {
		PS->body_set_shape_transform(_static_body_rid, p_shape_id, p_xform);
	}
}

Vector3 Terrain3DCollision::_shape_get_position(const int p_shape_id) const {
	if (is_editor_mode()) {
		return _shapes[p_shape_id]->get_global_position();
	} else {
		return PS->body_get_shape_transform(_static_body_rid, p_shape_id).origin;
	}
}

void Terrain3DCollision::_shape_set_data(const int p_shape_id, const Dictionary &p_dict) {
	if (is_editor_mode()) {
		CollisionShape3D *shape = _shapes[p_shape_id];
		Ref<HeightMapShape3D> hshape = shape->get_shape();
		hshape->set_map_data(p_dict["heights"]);
	} else {
		RID shape_rid = PS->body_get_shape(_static_body_rid, p_shape_id);
		PS->shape_set_data(shape_rid, p_dict);
	}
}

void Terrain3DCollision::_reload_physics_material() {
	if (is_editor_mode()) {
		if (_static_body) {
			_static_body->set_physics_material_override(_physics_material);
		}
	} else {
		if (_static_body_rid.is_valid()) {
			if (_physics_material.is_null()) {
				PS->body_set_param(_static_body_rid, PhysicsServer3D::BODY_PARAM_BOUNCE, 0.f);
				PS->body_set_param(_static_body_rid, PhysicsServer3D::BODY_PARAM_FRICTION, 1.f);
			} else {
				real_t computed_bounce = _physics_material->get_bounce() * (_physics_material->is_absorbent() ? -1.f : 1.f);
				real_t computed_friction = _physics_material->get_friction() * (_physics_material->is_rough() ? -1.f : 1.f);
				PS->body_set_param(_static_body_rid, PhysicsServer3D::BODY_PARAM_BOUNCE, computed_bounce);
				PS->body_set_param(_static_body_rid, PhysicsServer3D::BODY_PARAM_FRICTION, computed_friction);
			}
		}
	}
	if (_physics_material.is_valid()) {
		LOG(DEBUG, "Setting PhysicsMaterial bounce: ", _physics_material->get_bounce(), ", friction: ", _physics_material->get_friction());
	}
}

// Barge Game addition. Several collision targets.
//
// With targets registered, dynamic collision fills the union of the circles around them
// (radius in metres, per target) with shapes of _shape_size vertices on the stock shape
// grid. Shapes are created on demand, so the pool grows to the combined area without
// counting overlaps twice; shapes no longer needed are disabled and reused. Each target is
// snapped to the shape grid as stock snaps its one target, so the shape set changes only
// when a target crosses a grid line. With no targets, update() runs the stock code.

int Terrain3DCollision::_shape_count() const {
	if (is_editor_mode()) {
		return int(_shapes.size());
	}
	return _static_body_rid.is_valid() ? PS->body_get_shape_count(_static_body_rid) : 0;
}

// Adds one disabled shape to the body, as build() does, and returns its id.
int Terrain3DCollision::_shape_create() {
	int hshape_size = _shape_size + 1;
	Transform3D xform(Basis(), V3_MAX);
	if (is_editor_mode()) {
		CollisionShape3D *col_shape = memnew(CollisionShape3D);
		_shapes.push_back(col_shape);
		col_shape->set_name("CollisionShape3D");
		col_shape->set_disabled(true);
		col_shape->set_visible(true);
		col_shape->set_enable_debug_fill(false);
		Ref<HeightMapShape3D> hshape;
		hshape.instantiate();
		hshape->set_map_width(hshape_size);
		hshape->set_map_depth(hshape_size);
		col_shape->set_shape(hshape);
		_static_body->add_child(col_shape, true);
		col_shape->set_owner(_static_body);
		col_shape->set_transform(xform);
		return int(_shapes.size()) - 1;
	}
	RID shape_rid = PS->heightmap_shape_create();
	PS->body_add_shape(_static_body_rid, shape_rid, xform, true);
	return PS->body_get_shape_count(_static_body_rid) - 1;
}

// Fills a shape with the cell whose top left vertex is p_cell. False if the cell's region
// is not resident (the shape is left untouched).
bool Terrain3DCollision::_fill_cell(const int p_shape_id, const Vector2i &p_cell) {
	Dictionary shape_data = _get_shape_data(p_cell, _shape_size);
	if (shape_data.is_empty()) {
		return false;
	}
	real_t spacing = _terrain->get_vertex_spacing();
	Transform3D xform = shape_data["xform"];
	xform.scale(Vector3(spacing, 1.f, spacing));
	_shape_set_transform(p_shape_id, xform);
	_shape_set_disabled(p_shape_id, false);
	_shape_set_data(p_shape_id, shape_data);
	_stat_fills++;
	return true;
}

// True if the cell's samples (its vertices plus the far border row and column) read a
// region changed since the last flush.
bool Terrain3DCollision::_cell_touches_dirty(const Vector2i &p_cell) const {
	if (_dirty_regions.is_empty()) {
		return false;
	}
	int region_size = _terrain->get_region_size();
	Vector2i lo = V2I_DIVIDE_FLOOR(p_cell, region_size);
	const Vector2i far_corner = p_cell + Vector2i(int(_shape_size), int(_shape_size));
	Vector2i hi = V2I_DIVIDE_FLOOR(far_corner, region_size);
	for (int y = lo.y; y <= hi.y; y++) {
		for (int x = lo.x; x <= hi.x; x++) {
			if (_dirty_regions.has(Vector2i(x, y))) {
				return true;
			}
		}
	}
	return false;
}

// p_refill_all: refill every needed shape (update(…, true)).
// p_dirty_only: a region flush; refill the shapes that read a changed region.
void Terrain3DCollision::_update_targets(const bool p_refill_all, const bool p_dirty_only) {
	uint64_t start = Time::get_singleton()->get_ticks_usec();
	real_t spacing = _terrain->get_vertex_spacing();

	// 1. Snap each target; drop freed ones.
	bool changed = p_refill_all || p_dirty_only || _targets_dirty;
	_targets_dirty = false;
	for (int i = int(_targets.size()) - 1; i >= 0; i--) {
		Target &t = _targets[i];
		Node3D *node = t.node.get_target();
		if (node == nullptr) {
			LOG(INFO, "Collision target freed, removing it");
			_targets.erase(_targets.begin() + i);
			changed = true;
			continue;
		}
		Vector2i snapped = node->is_inside_tree() ? _snap_to_grid(node->get_global_position() / spacing) : V2I_MAX;
		if (snapped != t.snapped) {
			t.snapped = snapped;
			changed = true;
		}
	}
	if (_targets.empty()) {
		LOG(INFO, "Last collision target gone, back to the single stock target");
		build();
		return;
	}
	if (!changed) {
		return;
	}

	// 2. The cells needed: every cell whose centre lies within a target's radius of the
	// target's snapped position, as stock tests its one target. At least the four cells
	// around the target are kept, however small the radius.
	std::vector<Vector2i> needed;
	HashSet<Vector2i> needed_set;
	const real_t half = real_t(_shape_size) * 0.5f;
	for (const Target &t : _targets) {
		if (t.snapped == V2I_MAX) {
			continue; // outside the tree: no collision for it until it returns
		}
		real_t radius = MAX(t.radius_m / spacing, real_t(_shape_size) * 0.75f);
		real_t radius_sqr = radius * radius;
		int reach = int(Math::ceil(radius / real_t(_shape_size))) + 1;
		for (int z = -reach; z < reach; z++) {
			for (int x = -reach; x < reach; x++) {
				Vector2 centre_offset(real_t(x * _shape_size) + half, real_t(z * _shape_size) + half);
				if (centre_offset.length_squared() > radius_sqr) {
					continue;
				}
				Vector2i cell = t.snapped + Vector2i(x, z) * int(_shape_size);
				if (!needed_set.has(cell)) {
					needed_set.insert(cell);
					needed.push_back(cell);
				}
			}
		}
	}

	// 3. Release shapes no longer needed.
	std::vector<Vector2i> released;
	for (const KeyValue<Vector2i, int> &kv : _cell_shapes) {
		if (!needed_set.has(kv.key)) {
			released.push_back(kv.key);
		}
	}
	for (const Vector2i &cell : released) {
		int id = _cell_shapes[cell];
		_shape_set_disabled(id, true);
		_free_shapes.push_back(id);
		_cell_shapes.erase(cell);
	}

	// 4. Fill needed cells: refresh active ones that changed, place missing ones. A cell
	// whose region is not resident stays empty and is tried again on the next change.
	for (const Vector2i &cell : needed) {
		int *active = _cell_shapes.getptr(cell);
		if (active != nullptr) {
			if (p_refill_all || (p_dirty_only && _cell_touches_dirty(cell))) {
				if (!_fill_cell(*active, cell)) {
					_shape_set_disabled(*active, true);
					_free_shapes.push_back(*active);
					_cell_shapes.erase(cell);
				}
			}
			continue;
		}
		int id;
		if (!_free_shapes.empty()) {
			id = _free_shapes.back();
			if (!_fill_cell(id, cell)) {
				continue;
			}
			_free_shapes.pop_back();
		} else {
			if (!_terrain->get_data()->has_region(V2I_DIVIDE_FLOOR(cell, _terrain->get_region_size()))) {
				continue;
			}
			id = _shape_create();
			if (!_fill_cell(id, cell)) {
				_free_shapes.push_back(id);
				continue;
			}
		}
		_cell_shapes.insert(cell, id);
	}

	uint64_t usec = Time::get_singleton()->get_ticks_usec() - start;
	_stat_updates++;
	_stat_update_usec_last = usec;
	_stat_update_usec_total += usec;
	_stat_update_usec_max = MAX(_stat_update_usec_max, usec);
	LOG(EXTREME, "Collision targets: ", _targets.size(), ", shapes active: ", _cell_shapes.size(), "/", _shape_count(), ", ", usec, " us");
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DCollision::initialize(Terrain3D *p_terrain) {
	if (p_terrain) {
		_terrain = p_terrain;
	} else {
		return;
	}
	if (!IS_EDITOR && is_editor_mode()) {
		LOG(WARN, "Change collision mode to a non-editor mode for releases");
	}
	build();
}

void Terrain3DCollision::build() {
	IS_DATA_INIT(VOID);
	if (!_terrain->is_inside_world()) {
		LOG(ERROR, "Terrain isn't inside world. Returning.");
		return;
	}

	// Clear collision as the user might change modes in the editor
	destroy();

	// Build only in applicable modes
	if (!is_enabled() || (IS_EDITOR && !is_editor_mode())) {
		return;
	}

	// Create StaticBody3D
	if (is_editor_mode()) {
		LOG(INFO, "Building editor collision");
		_static_body = memnew(StaticBody3D);
		_static_body->set_name("StaticBody3D");
		_static_body->set_as_top_level(true);
		_terrain->add_child(_static_body, true);
		_static_body->set_owner(_terrain);
		_static_body->set_collision_mask(_mask);
		_static_body->set_collision_layer(_layer);
		_static_body->set_collision_priority(_priority);
	} else {
		LOG(INFO, "Building collision with Physics Server");
		_static_body_rid = PS->body_create();
		PS->body_set_mode(_static_body_rid, PhysicsServer3D::BODY_MODE_STATIC);
		PS->body_set_space(_static_body_rid, _terrain->get_world_3d()->get_space());
		PS->body_attach_object_instance_id(_static_body_rid, _terrain->get_instance_id());
		PS->body_set_collision_mask(_static_body_rid, _mask);
		PS->body_set_collision_layer(_static_body_rid, _layer);
		PS->body_set_collision_priority(_static_body_rid, _priority);
	}
	_reload_physics_material();

	// Create CollisionShape3Ds
	int shape_count;
	int hshape_size;
	if (is_dynamic_mode() && _uses_targets()) {
		shape_count = 0; // Barge Game: created on demand by _update_targets()
		hshape_size = _shape_size + 1;
	} else if (is_dynamic_mode()) {
		int grid_width = _radius * 2 / _shape_size;
		grid_width = int_ceil_pow2(grid_width, 4);
		shape_count = grid_width * grid_width;
		hshape_size = _shape_size + 1;
		LOG(DEBUG, "Grid width: ", grid_width);
	} else {
		shape_count = _terrain->get_data()->get_region_count();
		hshape_size = _terrain->get_region_size() + 1;
	}
	// Preallocate memory for push_back()
	if (is_editor_mode()) {
		_shapes.reserve(shape_count);
	}
	LOG(DEBUG, "Shape count: ", shape_count);
	LOG(DEBUG, "Shape size: ", _shape_size, ", hshape_size: ", hshape_size);
	Transform3D xform(Basis(), V3_MAX);
	for (int i = 0; i < shape_count; i++) {
		if (is_editor_mode()) {
			CollisionShape3D *col_shape = memnew(CollisionShape3D);
			_shapes.push_back(col_shape);
			col_shape->set_name("CollisionShape3D");
			col_shape->set_disabled(true);
			col_shape->set_visible(true);
			col_shape->set_enable_debug_fill(false);
			Ref<HeightMapShape3D> hshape;
			hshape.instantiate();
			hshape->set_map_width(hshape_size);
			hshape->set_map_depth(hshape_size);
			col_shape->set_shape(hshape);
			_static_body->add_child(col_shape, true);
			col_shape->set_owner(_static_body);
			col_shape->set_transform(xform);
		} else {
			RID shape_rid = PS->heightmap_shape_create();
			PS->body_add_shape(_static_body_rid, shape_rid, xform, true);
			LOG(DEBUG, "Adding shape: ", i, ", rid: ", shape_rid.get_id(), " pos: ", _shape_get_position(i));
		}
	}

	_initialized = true;
	update();
}

void Terrain3DCollision::update(const Vector2i &p_region_loc, const bool p_rebuild) {
	IS_INIT(VOID);
	if (!_initialized) {
		return;
	}
	if (p_rebuild && !is_dynamic_mode()) {
		build();
		return;
	}
	if (is_dynamic_mode() && _uses_targets()) {
		_update_targets(p_rebuild, false); // Barge Game: several targets
		return;
	}
	int time = Time::get_singleton()->get_ticks_usec();
	real_t spacing = _terrain->get_vertex_spacing();

	if (is_dynamic_mode()) {
		// Snap descaled position to a _shape_size grid (eg. multiples of 16)
		Vector2i snapped_pos = _snap_to_grid(_terrain->get_collision_target_position() / spacing);
		LOG(EXTREME, "Updating collision at ", snapped_pos);

		// Return if target hasn't moved to next grid slot
		if (!p_rebuild && (_last_snapped_pos - snapped_pos).length_squared() == 0) {
			return;
		}

		LOG(EXTREME, "---- 1. Defining area as a radius on a grid ----");
		// Create a 0-N grid, center on snapped_pos
		PackedInt32Array grid;
		int grid_width = _radius * 2 / _shape_size; // 64*2/16 = 8
		grid_width = int_ceil_pow2(grid_width, 4);
		grid.resize(grid_width * grid_width);
		grid.fill(-1);
		Vector2i grid_offset = -V2I(grid_width / 2); // offset # cells to center of grid
		Vector2i grid_corner = snapped_pos + grid_offset * _shape_size; // Top left of grid
		LOG(EXTREME, "New snapped_pos: ", snapped_pos);
		LOG(EXTREME, "grid_corner: ", grid_corner);
		LOG(EXTREME, "radius: ", _radius, ", grid_width: ", grid_width, ", grid_offset: ", grid_offset, ", # cells: ", grid.size());
		LOG(EXTREME, "shape_size: ", _shape_size);

		LOG(EXTREME, "---- 2. Checking existing shapes ----");
		// If shape is within area, skip
		// Else, mark unused

		// Stores index into _shapes array
		TypedArray<int> inactive_shape_ids;

		real_t radius_sqr = real_t(_radius * _radius);
		Vector2i shape_offset = V2I(_shape_size / 2); // offset meters to top left corner of shape
		int shape_count = is_editor_mode() ? _shapes.size() : PS->body_get_shape_count(_static_body_rid);
		for (int i = 0; i < shape_count; i++) {
			Vector3 shape_global_pos = _shape_get_position(i);
			if (p_rebuild || shape_global_pos.x > 1e20f) {
				inactive_shape_ids.push_back(i);
				_shape_set_disabled(i, true);
				LOG(EXTREME, "Shape ", i, " marked inactive (rebuild or out of bounds)");
				continue;
			}

			// Descale global position of shape center
			Vector3 shape_center = shape_global_pos / spacing;
			// Unique key: Top left corner of shape, snapped to grid
			Vector2i shape_pos = _snap_to_grid(v3v2i(shape_center) - shape_offset);
			if (v3v2i(shape_center).distance_squared_to(snapped_pos) <= radius_sqr) {
				// Get index into shape array
				Vector2i grid_loc = (shape_pos - grid_corner) / _shape_size;
				int idx = grid_loc.y * grid_width + grid_loc.x;
				if (idx >= 0 && idx < grid.size()) {
					grid[idx] = i;
					_shape_set_disabled(i, false);
					LOG(EXTREME, "Shape ", i, ": shape_center: ", shape_center, ", shape_pos: ", shape_pos, ", grid_loc: ",
							grid_loc, ", index: ", idx, " active");
					continue;
				}
			}

			inactive_shape_ids.push_back(i);
			_shape_set_disabled(i, true);
			LOG(EXTREME, "Shape ", i, ": shape_center: ", shape_center, ", shape_pos: ", shape_pos,
					" out of bounds, marking inactive");
		}
		LOG(EXTREME, "_inactive_shapes size: ", inactive_shape_ids.size());

		LOG(EXTREME, "---- 3. Review grid cells in area ----");
		// If cell is full, skip
		// Else assign shape and form it

		for (int i = 0; i < grid.size(); i++) {
			Vector2i grid_loc(i % grid_width, i / grid_width);
			if (!p_rebuild && grid[i] >= 0) {
				LOG(EXTREME, "grid[", i, ":", grid_loc, "] already active, skipping");
				continue;
			}

			// Unique key: Top left corner of shape, snapped to grid
			Vector2i shape_pos = grid_corner + grid_loc * _shape_size;
			Vector2i shape_center = shape_pos + shape_offset;
			if (shape_center.distance_squared_to(snapped_pos) > radius_sqr) {
				LOG(EXTREME, "grid[", i, ":", grid_loc, "] shape_pos : ", shape_pos, " out of circle, skipping");
				continue;
			}
			if (inactive_shape_ids.size() == 0) {
				LOG(ERROR, "No more unused shapes! Aborting!");
				break;
			}
			Dictionary shape_data = _get_shape_data(shape_pos, _shape_size);
			if (shape_data.is_empty()) {
				LOG(EXTREME, "grid[", i, ":", grid_loc, "] shape_pos : ", shape_pos, " No region found");
				continue;
			}
			int shape_id = inactive_shape_ids.pop_back();
			Transform3D xform = shape_data["xform"];
			LOG(EXTREME, "grid[", i, ":", grid_loc, "] shape_pos : ", shape_pos, " act ", v3v2i(xform.origin) - shape_offset, " placing shape id ", shape_id);
			xform.scale(Vector3(spacing, 1.f, spacing));
			_shape_set_transform(shape_id, xform);
			_shape_set_disabled(shape_id, false);
			_shape_set_data(shape_id, shape_data);
		}
		_last_snapped_pos = snapped_pos;
		LOG(EXTREME, "Setting _last_snapped_pos: ", _last_snapped_pos);
		LOG(EXTREME, "inactive_shape_ids size: ", inactive_shape_ids.size());

	} else {
		// Full collision
		int shape_count = _terrain->get_data()->get_region_count();
		int region_size = _terrain->get_region_size();
		TypedArray<Vector2i> region_locs = _terrain->get_data()->get_region_locations();
		for (int i = 0; i < region_locs.size(); i++) {
			Vector2i region_loc = region_locs[i];
			if (p_region_loc != V2I_MAX && region_loc != p_region_loc) {
				continue;
			}
			Vector2i shape_pos = region_loc * region_size;
			Dictionary shape_data = _get_shape_data(shape_pos, region_size);
			if (shape_data.is_empty()) {
				LOG(ERROR, "Can't get shape data for ", region_loc);
				continue;
			}
			Transform3D xform = shape_data["xform"];
			xform.scale(Vector3(spacing, 1.f, spacing));
			_shape_set_transform(i, xform);
			_shape_set_disabled(i, false);
			_shape_set_data(i, shape_data);
		}
	}
	LOG(EXTREME, "Collision update time: ", Time::get_singleton()->get_ticks_usec() - time, " us");
}

// Barge Game addition. A streamed region was inserted or evicted. Dynamic collision only
// cares when the region can intersect the area around the collision target; the shapes
// there are refilled by flush_region_changes(). Full collision is rebuilt, which is costly
// and only meant for small streamed worlds. Ported from the collision refresh in upstream
// draft PR #1004's streamer.
void Terrain3DCollision::region_changed(const Vector2i &p_region_loc) {
	if (!_initialized || !is_enabled() || _terrain == nullptr) {
		return;
	}
	if (!is_dynamic_mode()) {
		_region_rebuild_pending = true;
		return;
	}
	if (_uses_targets()) {
		// Several targets: remember the region; the flush refills only shapes that read it
		// and retries needed cells that had no region, so a far region costs lookups only.
		_dirty_regions.insert(p_region_loc);
		_region_refresh_pending = true;
		return;
	}
	// Work in descaled (vertex) units, as update() does.
	real_t spacing = _terrain->get_vertex_spacing();
	Vector3 target = _terrain->get_collision_target_position() / spacing;
	real_t region_size = real_t(_terrain->get_region_size());
	Vector2 lo = Vector2(p_region_loc) * region_size;
	Vector2 hi = lo + Vector2(region_size, region_size);
	Vector2 t = Vector2(target.x, target.z);
	Vector2 nearest = Vector2(CLAMP(t.x, lo.x, hi.x), CLAMP(t.y, lo.y, hi.y));
	// Conservative square bound: shapes are placed around the target snapped to the shape
	// grid (up to one shape away), reach one shape size out and sample one border vertex
	// past their edge. A false positive costs an in-place refresh; a miss leaves stale
	// collision over an evicted region.
	real_t reach = real_t(_radius) + 2.0 * real_t(_shape_size) + 2.0;
	Vector2 d = (nearest - t).abs();
	if (MAX(d.x, d.y) <= reach) {
		_region_refresh_pending = true;
	}
}

void Terrain3DCollision::flush_region_changes() {
	if (_region_rebuild_pending) {
		_region_rebuild_pending = false;
		_region_refresh_pending = false;
		build();
	} else if (_region_refresh_pending) {
		_region_refresh_pending = false;
		if (_initialized && is_dynamic_mode() && _uses_targets()) {
			_update_targets(false, true);
		} else {
			update(V2I_MAX, true);
		}
	}
	_dirty_regions.clear();
}

void Terrain3DCollision::add_target(Node3D *p_node, const real_t p_radius_m) {
	if (p_node == nullptr) {
		LOG(ERROR, "Collision target is null");
		return;
	}
	if (!(p_radius_m > 0.f)) {
		LOG(ERROR, "Collision target radius must be above 0 m, got ", p_radius_m);
		return;
	}
	for (Target &t : _targets) {
		if (t.node.get_target() == p_node) {
			t.radius_m = p_radius_m;
			_targets_dirty = true;
			LOG(INFO, "Collision target ", p_node, " radius now ", p_radius_m, " m");
			return;
		}
	}
	const bool first = !_uses_targets();
	Target t;
	t.node.set_target(p_node);
	t.radius_m = p_radius_m;
	_targets.push_back(t);
	_targets_dirty = true;
	LOG(INFO, "Collision target added: ", p_node, ", radius ", p_radius_m, " m, targets: ", _targets.size());
	if (first && _initialized && is_dynamic_mode()) {
		build(); // leave the stock grid for on-demand shapes
	}
}

void Terrain3DCollision::remove_target(Node3D *p_node) {
	for (int i = 0; i < int(_targets.size()); i++) {
		if (_targets[i].node.get_target() == p_node) {
			_targets.erase(_targets.begin() + i);
			_targets_dirty = true;
			LOG(INFO, "Collision target removed: ", p_node, ", targets: ", _targets.size());
			if (_targets.empty() && _initialized && is_dynamic_mode()) {
				build(); // back to the single stock target
			}
			return;
		}
	}
}

void Terrain3DCollision::clear_targets() {
	if (_targets.empty()) {
		return;
	}
	_targets.clear();
	LOG(INFO, "Collision targets cleared");
	if (_initialized && is_dynamic_mode()) {
		build();
	}
}

TypedArray<Node3D> Terrain3DCollision::get_targets() const {
	TypedArray<Node3D> nodes;
	for (const Target &t : _targets) {
		if (Node3D *node = t.node.get_target()) {
			nodes.push_back(node);
		}
	}
	return nodes;
}

real_t Terrain3DCollision::get_target_radius(Node3D *p_node) const {
	for (const Target &t : _targets) {
		if (t.node.get_target() == p_node) {
			return t.radius_m;
		}
	}
	return 0.f;
}

Dictionary Terrain3DCollision::get_stats() const {
	Dictionary stats;
	stats["targets"] = int64_t(_targets.size());
	stats["shapes_total"] = int64_t(_shape_count());
	stats["shapes_active"] = int64_t(_cell_shapes.size());
	stats["shapes_free"] = int64_t(_free_shapes.size());
	stats["updates"] = int64_t(_stat_updates);
	stats["fills"] = int64_t(_stat_fills);
	stats["update_usec_last"] = int64_t(_stat_update_usec_last);
	stats["update_usec_max"] = int64_t(_stat_update_usec_max);
	stats["update_usec_mean"] = _stat_updates > 0 ? double(_stat_update_usec_total) / double(_stat_updates) : 0.0;
	return stats;
}

void Terrain3DCollision::destroy() {
	_initialized = false;
	_last_snapped_pos = V2I_MAX;
	// Barge Game: the shapes go; the targets stay and are snapped afresh after build()
	_cell_shapes.clear();
	_free_shapes.clear();
	for (Target &t : _targets) {
		t.snapped = V2I_MAX;
	}
	_targets_dirty = true;

	// Physics Server
	if (_static_body_rid.is_valid()) {
		// Shape IDs change as they are freed, so it's not safe to iterate over them while freeing.
		while (PS->body_get_shape_count(_static_body_rid) > 0) {
			RID rid = PS->body_get_shape(_static_body_rid, 0);
			LOG(DEBUG, "Freeing CollisionShape RID ", rid);
			PS->free_rid(rid);
		}

		LOG(DEBUG, "Freeing StaticBody RID");
		PS->free_rid(_static_body_rid);
		_static_body_rid = RID();
	}

	// Scene Tree
	for (int i = 0; i < _shapes.size(); i++) {
		CollisionShape3D *shape = _shapes[i];
		LOG(DEBUG, "Freeing CollisionShape3D ", i, " ", shape->get_name());
		remove_from_tree(shape);
		memdelete_safely(shape);
	}
	_shapes.clear();
	if (_static_body) {
		LOG(DEBUG, "Freeing StaticBody3D");
		remove_from_tree(_static_body);
		memdelete_safely(_static_body);
	}
}

void Terrain3DCollision::set_mode(const CollisionMode p_mode) {
	SET_IF_DIFF(_mode, p_mode);
	LOG(INFO, "Setting collision mode: ", p_mode);
	if (is_enabled()) {
		build();
	} else {
		destroy();
	}
}

void Terrain3DCollision::set_shape_size(const uint16_t p_size) {
	uint16_t size = CLAMP(p_size, 8, 64);
	size = int_round_mult(size, uint16_t(8));
	SET_IF_DIFF(_shape_size, size);
	LOG(INFO, "Setting collision dynamic shape size: ", _shape_size);
	// Ensure size:radius always results in at least one valid shape
	if (_shape_size > _radius - 8) {
		set_radius(_shape_size + 16);
	} else if (is_dynamic_mode()) {
		build();
	}
}

void Terrain3DCollision::set_radius(const uint16_t p_radius) {
	uint16_t radius = CLAMP(p_radius, 16, 256);
	radius = int_ceil_pow2(radius, uint16_t(16));
	SET_IF_DIFF(_radius, radius);
	LOG(INFO, "Setting collision dynamic radius: ", _radius);
	// Ensure size:radius always results in at least one valid shape
	if (_radius < _shape_size + 8) {
		set_shape_size(_radius - 8);
	} else if (_shape_size < 16 && _radius > 128) {
		set_shape_size(16);
	} else if (is_dynamic_mode()) {
		build();
	}
}

void Terrain3DCollision::set_layer(const uint32_t p_layers) {
	SET_IF_DIFF(_layer, p_layers);
	LOG(INFO, "Setting collision layers: ", p_layers);
	if (is_editor_mode()) {
		if (_static_body) {
			_static_body->set_collision_layer(_layer);
		}
	} else {
		if (_static_body_rid.is_valid()) {
			PS->body_set_collision_layer(_static_body_rid, _layer);
		}
	}
}

void Terrain3DCollision::set_mask(const uint32_t p_mask) {
	SET_IF_DIFF(_mask, p_mask);
	LOG(INFO, "Setting collision mask: ", p_mask);
	if (is_editor_mode()) {
		if (_static_body) {
			_static_body->set_collision_mask(_mask);
		}
	} else {
		if (_static_body_rid.is_valid()) {
			PS->body_set_collision_mask(_static_body_rid, _mask);
		}
	}
}

void Terrain3DCollision::set_priority(const real_t p_priority) {
	SET_IF_DIFF(_priority, p_priority);
	LOG(INFO, "Setting collision priority: ", p_priority);
	if (is_editor_mode()) {
		if (_static_body) {
			_static_body->set_collision_priority(_priority);
		}
	} else {
		if (_static_body_rid.is_valid()) {
			PS->body_set_collision_priority(_static_body_rid, _priority);
		}
	}
}

void Terrain3DCollision::set_physics_material(const Ref<PhysicsMaterial> &p_mat) {
	if (_physics_material == p_mat) {
		return;
	}
	if (_physics_material.is_valid()) {
		if (_physics_material->is_connected("changed", callable_mp(this, &Terrain3DCollision::_reload_physics_material))) {
			LOG(DEBUG, "Disconnecting _physics_material::changed signal to _reload_physics_material()");
			_physics_material->disconnect("changed", callable_mp(this, &Terrain3DCollision::_reload_physics_material));
		}
	}
	_physics_material = p_mat;
	LOG(INFO, "Setting physics material: ", p_mat);
	if (_physics_material.is_valid()) {
		LOG(DEBUG, "Connecting _physics_material::changed signal to _reload_physics_material()");
		_physics_material->connect("changed", callable_mp(this, &Terrain3DCollision::_reload_physics_material));
	}
	_reload_physics_material();
}

RID Terrain3DCollision::get_rid() const {
	if (!is_editor_mode()) {
		return _static_body_rid;
	} else {
		if (_static_body) {
			return _static_body->get_rid();
		}
	}
	return RID();
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DCollision::_bind_methods() {
	BIND_ENUM_CONSTANT(DISABLED);
	BIND_ENUM_CONSTANT(DYNAMIC_GAME);
	BIND_ENUM_CONSTANT(DYNAMIC_EDITOR);
	BIND_ENUM_CONSTANT(FULL_GAME);
	BIND_ENUM_CONSTANT(FULL_EDITOR);

	ClassDB::bind_method(D_METHOD("build"), &Terrain3DCollision::build);
	ClassDB::bind_method(D_METHOD("update", "region_location", "rebuild"), &Terrain3DCollision::update, DEFVAL(V2I_MAX), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("destroy"), &Terrain3DCollision::destroy);
	ClassDB::bind_method(D_METHOD("set_mode", "mode"), &Terrain3DCollision::set_mode);
	ClassDB::bind_method(D_METHOD("get_mode"), &Terrain3DCollision::get_mode);
	ClassDB::bind_method(D_METHOD("is_enabled"), &Terrain3DCollision::is_enabled);
	ClassDB::bind_method(D_METHOD("is_editor_mode"), &Terrain3DCollision::is_editor_mode);
	ClassDB::bind_method(D_METHOD("is_dynamic_mode"), &Terrain3DCollision::is_dynamic_mode);

	ClassDB::bind_method(D_METHOD("set_shape_size", "size"), &Terrain3DCollision::set_shape_size);
	ClassDB::bind_method(D_METHOD("get_shape_size"), &Terrain3DCollision::get_shape_size);
	ClassDB::bind_method(D_METHOD("set_radius", "radius"), &Terrain3DCollision::set_radius);
	ClassDB::bind_method(D_METHOD("get_radius"), &Terrain3DCollision::get_radius);
	ClassDB::bind_method(D_METHOD("set_layer", "layers"), &Terrain3DCollision::set_layer);
	ClassDB::bind_method(D_METHOD("get_layer"), &Terrain3DCollision::get_layer);
	ClassDB::bind_method(D_METHOD("set_mask", "mask"), &Terrain3DCollision::set_mask);
	ClassDB::bind_method(D_METHOD("get_mask"), &Terrain3DCollision::get_mask);
	ClassDB::bind_method(D_METHOD("set_priority", "priority"), &Terrain3DCollision::set_priority);
	ClassDB::bind_method(D_METHOD("get_priority"), &Terrain3DCollision::get_priority);
	ClassDB::bind_method(D_METHOD("set_physics_material", "material"), &Terrain3DCollision::set_physics_material);
	ClassDB::bind_method(D_METHOD("get_physics_material"), &Terrain3DCollision::get_physics_material);
	ClassDB::bind_method(D_METHOD("get_rid"), &Terrain3DCollision::get_rid);
	// Barge Game addition: several collision targets
	ClassDB::bind_method(D_METHOD("add_target", "node", "radius_m"), &Terrain3DCollision::add_target);
	ClassDB::bind_method(D_METHOD("remove_target", "node"), &Terrain3DCollision::remove_target);
	ClassDB::bind_method(D_METHOD("clear_targets"), &Terrain3DCollision::clear_targets);
	ClassDB::bind_method(D_METHOD("get_targets"), &Terrain3DCollision::get_targets);
	ClassDB::bind_method(D_METHOD("get_target_radius", "node"), &Terrain3DCollision::get_target_radius);
	ClassDB::bind_method(D_METHOD("get_stats"), &Terrain3DCollision::get_stats);

	ADD_PROPERTY(PropertyInfo(Variant::INT, "mode", PROPERTY_HINT_ENUM, "Disabled,Dynamic / Game,Dynamic / Editor,Full / Game,Full / Editor"), "set_mode", "get_mode");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "shape_size", PROPERTY_HINT_RANGE, "8,64,8"), "set_shape_size", "get_shape_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "radius", PROPERTY_HINT_RANGE, "16,256,16"), "set_radius", "get_radius");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "layer", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_layer", "get_layer");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mask", PROPERTY_HINT_LAYERS_3D_PHYSICS), "set_mask", "get_mask");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "priority", PROPERTY_HINT_RANGE, "0.1,256,.1"), "set_priority", "get_priority");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "physics_material", PROPERTY_HINT_RESOURCE_TYPE, "PhysicsMaterial"), "set_physics_material", "get_physics_material");
}
