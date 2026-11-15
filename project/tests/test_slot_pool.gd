extends SceneTree
## Barge Game addition. Headless test for the fixed slot pool (Terrain3DData.enable_streaming):
##   godot --headless --path project --script res://tests/test_slot_pool.gd
## Checks that adding and evicting regions keeps the texture array RIDs and the collision
## body, never leaks a slot, keeps every data query right through random churn, refreshes
## collision in place, and handles exhaustion, replacement and batched inserts.
## Exits with the number of failed checks (0 = pass).
## expect-error: No resident region
## expect-error: Slot pool exhausted
## expect-error: change_region_size is not supported

const CAPACITY := 30
const CYCLES := 500
const RS := 64 # small regions keep the test fast; the pool logic does not depend on size

var _fail := 0
var _started := false
var _t: Terrain3D
var _resident := {} # Vector2i -> expected height


func ok(c: bool, m: String) -> void:
	if not c:
		print("FAIL " + m)
		_fail += 1
	elif OS.is_stdout_verbose():
		print("PASS " + m)


func _initialize() -> void:
	process_frame.connect(_run)


func _sig(loc: Vector2i, version: int = 0) -> float:
	return 10.0 + loc.x * 3.0 + loc.y * 100.0 + version * 0.25


func _make_region(loc: Vector2i, height: float) -> Terrain3DRegion:
	var r := Terrain3DRegion.new()
	r.set_location(loc)
	r.set_region_size(RS)
	r.set_vertex_spacing(1.0)
	var img := Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	img.fill(Color(height, 0.0, 0.0))
	r.set_height_map(img)
	return r


func _center(loc: Vector2i) -> Vector3:
	return Vector3((loc.x + 0.5) * RS, 0.0, (loc.y + 0.5) * RS)


func _check_invariants(label: String) -> void:
	var d: Terrain3DData = _t.data
	ok(d.get_free_slot_count() == CAPACITY - _resident.size(),
			"%s: free slots %d == capacity - resident %d" % [label, d.get_free_slot_count(), CAPACITY - _resident.size()])
	ok(d.get_region_count() == _resident.size(), "%s: region count %d == %d" % [label, d.get_region_count(), _resident.size()])
	var shader_locs: Array = d.get_shader_region_locations()
	ok(shader_locs.size() == CAPACITY, "%s: shader location table has one entry per slot" % label)
	var used := {}
	for loc: Vector2i in _resident:
		var id: int = d.get_region_id(loc)
		ok(id >= 0 and id < CAPACITY, "%s: %s has a slot (%d)" % [label, loc, id])
		ok(not used.has(id), "%s: slot %d used once" % [label, id])
		used[id] = true
		if id >= 0 and id < shader_locs.size():
			ok(shader_locs[id] == loc, "%s: shader table slot %d holds %s" % [label, id, loc])
		ok(d.has_region(loc), "%s: has_region %s" % [label, loc])
		var h: float = d.get_height(_center(loc))
		ok(is_equal_approx(h, _resident[loc]), "%s: height at %s is %s, expected %s" % [label, loc, h, _resident[loc]])
	# Free slots must map to the empty marker in the shader table.
	var empty := 0
	for v: Vector2i in shader_locs:
		if v == Vector2i(2147483647, 2147483647):
			empty += 1
	ok(empty == CAPACITY - _resident.size(), "%s: %d empty shader slots" % [label, empty])


func _ray_height(x: float, z: float) -> float:
	var space := _t.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 5000.0, z), Vector3(x, -5000.0, z))
	var hit := space.intersect_ray(q)
	return hit.position.y if hit else NAN


func _run() -> void:
	if _started:
		return
	_started = true
	var cam := Camera3D.new()
	root.add_child(cam)
	var target := Node3D.new()
	root.add_child(target)
	target.position = Vector3(RS * 0.5, 0.0, RS * 0.5) # inside region (0, 0)
	_t = Terrain3D.new()
	_t.collision_mode = 1 # Dynamic / Game
	_t.collision_radius = 32
	root.add_child(_t)
	_t.set_collision_target(target)
	await process_frame
	_t.change_region_size(RS) # needs initialized data
	ok(_t.region_size == RS, "region size %d" % _t.region_size)
	var d: Terrain3DData = _t.data

	d.enable_streaming(CAPACITY)
	ok(d.is_streaming(), "streaming enabled")
	ok(d.get_slot_capacity() == CAPACITY, "capacity %d" % d.get_slot_capacity())

	# Initial 5 x 5 block, batched: inserts with update = false, then one update_maps().
	for y in range(-2, 3):
		for x in range(-2, 3):
			var loc := Vector2i(x, y)
			ok(d.add_region(_make_region(loc, _sig(loc)), false) == OK, "batched add %s" % loc)
			_resident[loc] = _sig(loc)
	d.update_maps()
	_check_invariants("after batch")
	var rid_h: RID = d.get_height_maps_rid()
	var rid_c: RID = d.get_control_maps_rid()
	var rid_col: RID = d.get_color_maps_rid()
	ok(rid_h.is_valid() and rid_c.is_valid() and rid_col.is_valid(), "texture arrays allocated")

	# Collision around the target follows the data.
	for i in 4:
		await physics_frame
	var col_rid: RID = _t.collision.get_rid()
	var h0 := _ray_height(RS * 0.5, RS * 0.5)
	ok(is_equal_approx(h0, _sig(Vector2i.ZERO)), "collision height at (0,0) is %s, expected %s" % [h0, _sig(Vector2i.ZERO)])

	# Replacement keeps the slot and uploads the new maps.
	var slot_before: int = d.get_region_id(Vector2i(1, 1))
	ok(d.add_region(_make_region(Vector2i(1, 1), _sig(Vector2i(1, 1), 1))) == OK, "replace (1,1)")
	_resident[Vector2i(1, 1)] = _sig(Vector2i(1, 1), 1)
	ok(d.get_region_id(Vector2i(1, 1)) == slot_before, "replacement keeps slot %d" % slot_before)
	_check_invariants("after replace")

	# Random churn inside the stock window.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234567
	var version := {}
	for cycle in CYCLES:
		# Every cycle is a real operation: evict a random resident region, or add a random
		# non-resident location. Evict when full, add when empty, otherwise half and half.
		var evict := _resident.size() >= CAPACITY or (not _resident.is_empty() and rng.randf() < 0.5)
		if evict:
			var keys: Array = _resident.keys()
			var loc: Vector2i = keys[rng.randi_range(0, keys.size() - 1)]
			ok(d.evict_region(loc, rng.randf() < 0.7) == OK, "evict %s" % loc)
			_resident.erase(loc)
		else:
			var loc := Vector2i(rng.randi_range(-16, 15), rng.randi_range(-16, 15))
			while _resident.has(loc):
				loc = Vector2i(rng.randi_range(-16, 15), rng.randi_range(-16, 15))
			version[loc] = int(version.get(loc, 0)) + 1
			var h := _sig(loc, version[loc])
			ok(d.add_region(_make_region(loc, h), rng.randf() < 0.7) == OK, "add %s" % loc)
			_resident[loc] = h
		if cycle % 50 == 49:
			d.update_maps()
			_check_invariants("cycle %d" % cycle)
	d.update_maps()
	_check_invariants("after churn")
	ok(d.get_height_maps_rid() == rid_h and d.get_control_maps_rid() == rid_c and d.get_color_maps_rid() == rid_col,
			"texture array RIDs unchanged after %d cycles" % CYCLES)
	var stats: Dictionary = d.get_streaming_stats()
	print("Stats after churn: ", stats)
	ok(int(stats["slots_used"]) == _resident.size(), "stats slots_used")
	ok(int(stats["inserts"]) + int(stats["evictions"]) >= CYCLES, "churn ran %d operations" % (int(stats["inserts"]) + int(stats["evictions"])))

	# Non-resident locations answer "no region".
	for loc in [Vector2i(-16, -16), Vector2i(15, 15), Vector2i(3, -9)]:
		if not _resident.has(loc):
			ok(not d.has_region(loc), "no region at %s" % loc)
			ok(is_nan(d.get_height(_center(loc))), "height NaN at %s" % loc)
	ok(d.evict_region(Vector2i(100, 100)) != OK, "evicting a missing region fails")

	# Collision refresh in place: replace the region under the target.
	if _resident.has(Vector2i.ZERO):
		d.evict_region(Vector2i.ZERO)
		_resident.erase(Vector2i.ZERO)
	await physics_frame
	await physics_frame
	ok(is_nan(_ray_height(RS * 0.5, RS * 0.5)), "no collision after evicting (0,0)")
	if _resident.size() >= CAPACITY:
		var any: Vector2i = _resident.keys()[0]
		d.evict_region(any)
		_resident.erase(any)
	ok(d.add_region(_make_region(Vector2i.ZERO, 777.0)) == OK, "re-add (0,0)")
	_resident[Vector2i.ZERO] = 777.0
	await physics_frame
	await physics_frame
	var h1 := _ray_height(RS * 0.5, RS * 0.5)
	ok(is_equal_approx(h1, 777.0), "collision follows re-added (0,0): %s" % h1)
	ok(_t.collision.get_rid() == col_rid, "collision body not rebuilt")

	# Exhaustion fails cleanly and changes nothing.
	var probe := 0
	while _resident.size() < CAPACITY:
		var loc := Vector2i(-16 + probe % 32, -16 + probe / 32)
		probe += 1
		if not _resident.has(loc):
			d.add_region(_make_region(loc, _sig(loc)))
			_resident[loc] = _sig(loc)
	var extra := Vector2i(15, 15) if not _resident.has(Vector2i(15, 15)) else Vector2i(14, 15)
	ok(d.add_region(_make_region(extra, 1.0)) != OK, "add beyond capacity fails")
	_check_invariants("full pool")

	# Guards: classic-only operations refuse while streaming.
	d.change_region_size(128)
	ok(_t.region_size == RS, "region size unchanged while streaming")

	_t.free()
	target.free()
	cam.free()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
