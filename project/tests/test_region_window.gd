extends SceneTree
## Barge Game addition. Headless test for the movable region window
## (Terrain3DData.set_region_window_origin) and regions far from the origin:
##   godot --headless --path project --script res://tests/test_region_window.gd
## Exits with the number of failed checks (0 = pass).
## expect-error: The region window can only move while streaming
## expect-error: out of bounds. Max:
## expect-error: is beyond +-
## expect-error: Region window origin

const CAPACITY := 64
const RS := 64
const MAP := 32
const EMPTY := Vector2i(2147483647, 2147483647)

var _fail := 0
var _started := false
var _t: Terrain3D
var _resident := {} # Vector2i -> height


func ok(c: bool, m: String) -> void:
	if not c:
		print("FAIL " + m)
		_fail += 1
	elif OS.is_stdout_verbose():
		print("PASS " + m)


func _initialize() -> void:
	process_frame.connect(_run)


func _sig(loc: Vector2i) -> float:
	# Distinct per location, small enough to stay exact in a float
	return float(posmod(loc.x * 7 + loc.y * 13, 997)) + 0.5


func _make_region(loc: Vector2i, height: float) -> Terrain3DRegion:
	var r := Terrain3DRegion.new()
	r.set_location(loc)
	r.set_region_size(RS)
	r.set_vertex_spacing(1.0)
	var img := Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	img.fill(Color(height, 0.0, 0.0))
	# A slope inside each region, so normals are not trivially straight up
	for x in RS:
		img.set_pixel(x, 5, Color(height + x * 0.25, 0.0, 0.0))
	r.set_height_map(img)
	return r


func _add(loc: Vector2i) -> void:
	ok(_t.data.add_region(_make_region(loc, _sig(loc))) == OK, "add %s" % loc)
	_resident[loc] = _sig(loc)


func _in_window(loc: Vector2i, origin: Vector2i) -> bool:
	var rel := loc - origin
	return rel.x >= 0 and rel.y >= 0 and rel.x < MAP and rel.y < MAP


func _expected_index(loc: Vector2i) -> int:
	return posmod(loc.y + MAP / 2, MAP) * MAP + posmod(loc.x + MAP / 2, MAP)


# The map holds exactly the resident regions inside the window, each at its wraparound
# entry, with slot + 1. Only regions inside the window hold a slot (GPU layer); the ones
# outside are data only (id -1) but still resident. Every data query is the same as
# without any window.
func _check_map(label: String) -> void:
	var d: Terrain3DData = _t.data
	var origin: Vector2i = d.get_region_window_origin()
	var map: PackedInt32Array = d.get_region_map()
	var shader_locs: Array = d.get_shader_region_locations()
	var expected_entries := 0
	for loc: Vector2i in _resident:
		var slot: int = d.get_region_id(loc)
		var inside := _in_window(loc, origin)
		ok(d.has_region(loc), "%s: %s resident" % [label, loc])
		ok((slot >= 0) == inside, "%s: %s holds a slot only inside the window (slot %d, inside %s)" % [label, loc, slot, inside])
		ok(d.is_in_region_window(loc) == inside, "%s: is_in_region_window %s == %s" % [label, loc, inside])
		var idx: int = d.get_region_map_index(loc)
		if inside:
			expected_entries += 1
			ok(idx == _expected_index(loc), "%s: map index of %s is %d, expected %d" % [label, loc, idx, _expected_index(loc)])
			ok(idx >= 0 and map[idx] == slot + 1, "%s: map entry for %s holds slot %d" % [label, loc, slot])
			ok(slot >= 0 and shader_locs[slot] == loc, "%s: shader table slot %d holds %s" % [label, slot, loc])
		else:
			ok(idx == -1, "%s: %s outside window has index -1 (got %d)" % [label, loc, idx])
			ok(not shader_locs.has(loc), "%s: %s outside the window is not in the shader table" % [label, loc])
	var nonzero := 0
	for i in map.size():
		if map[i] != 0:
			nonzero += 1
			var loc: Vector2i = shader_locs[map[i] - 1]
			ok(loc != EMPTY and _in_window(loc, origin) and _expected_index(loc) == i,
					"%s: entry %d points at %s inside the window" % [label, i, loc])
	ok(nonzero == expected_entries, "%s: %d map entries, expected %d" % [label, nonzero, expected_entries])
	var stats: Dictionary = d.get_streaming_stats()
	ok(int(stats["slots_used"]) == expected_entries, "%s: %d slots used for %d regions in the window" % [label, stats["slots_used"], expected_entries])
	ok(int(stats["regions_resident"]) == _resident.size(), "%s: %d resident" % [label, stats["regions_resident"]])


# Data queries at sample points in every resident region (and some empty ones).
func _sample_queries() -> Array:
	var d: Terrain3DData = _t.data
	var out: Array = []
	var locs: Array = _resident.keys()
	locs.sort()
	locs.append(Vector2i(5, 5)) # empty
	locs.append(Vector2i(-301, 299)) # empty, far
	for loc: Vector2i in locs:
		for p: Vector2 in [Vector2(0.37, 0.61), Vector2(10.2, 5.5), Vector2(33.3, 5.9), Vector2(63.4, 63.4)]:
			var pos := Vector3(loc.x * RS + p.x, 0.0, loc.y * RS + p.y)
			out.append([loc, p, str(d.get_height(pos)), str(d.get_normal(pos)), d.has_regionp(pos),
					d.get_control(pos), d.has_region(loc)]) # not get_region_idp: that is the window-dependent GPU layer
	return out


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
	_t = Terrain3D.new()
	_t.collision_mode = 1 # Dynamic / Game
	_t.collision_radius = 32
	root.add_child(_t)
	_t.set_collision_target(target)
	await process_frame
	_t.change_region_size(RS)
	var d: Terrain3DData = _t.data

	# Classic mode keeps stock behaviour: the window cannot move, and locations outside
	# the stock window are refused.
	d.set_region_window_origin(Vector2i(100, 100))
	ok(d.get_region_window_origin() == Vector2i(-16, -16), "classic window stays at (-16, -16)")
	ok(d.add_region_blank(Vector2i(20, 0)) == null, "classic add outside -16..15 refused")
	ok(d.get_region_map_index(Vector2i(-16, -16)) == 0 and d.get_region_map_index(Vector2i(15, 15)) == 1023,
			"default window uses the stock map layout")

	d.enable_streaming(CAPACITY)
	# Regions near the origin, far away, and a wraparound pair (same map entry, 32 apart).
	for loc in [Vector2i(0, 0), Vector2i(-1, 3), Vector2i(300, 300), Vector2i(301, 300), Vector2i(-300, -300),
			Vector2i(300, -1234), Vector2i(332, 300), Vector2i(300, 332), Vector2i(-5000, 4000)]:
		_add(loc)
	_check_map("default window")
	ok(not d.is_in_region_window(Vector2i(300, 300)), "(300, 300) outside the default window")
	ok(is_equal_approx(d.get_height(Vector3(300 * RS + 1.0, 0.0, 300 * RS + 1.0)), _sig(Vector2i(300, 300))),
			"far region answers get_height while outside the window")

	var baseline := _sample_queries()
	var rid_h: RID = d.get_height_maps_rid()
	var rid_c: RID = d.get_control_maps_rid()
	var rid_col: RID = d.get_color_maps_rid()

	# Move the window around, including a jump of 600 regions, and check every position.
	var origins: Array[Vector2i] = [Vector2i(284, 284), Vector2i(290, 290), Vector2i(301, 301), Vector2i(-316, -316),
			Vector2i(284, -1250), Vector2i(-5010, 3990), Vector2i(0, 0), Vector2i(-16, -16)]
	for origin in origins:
		d.set_region_window_origin(origin)
		ok(d.get_region_window_origin() == origin, "window origin %s" % origin)
		_check_map("window %s" % origin)
		ok(str(_sample_queries()) == str(baseline), "window %s: data queries unchanged" % origin)
	ok(d.get_height_maps_rid() == rid_h and d.get_control_maps_rid() == rid_c and d.get_color_maps_rid() == rid_col,
			"texture array RIDs unchanged by window moves")

	# Wraparound pair: (300, 300) and (332, 300) share a map entry; only the one in the
	# window owns it.
	d.set_region_window_origin(Vector2i(290, 290))
	var idx_a: int = d.get_region_map_index(Vector2i(300, 300))
	ok(idx_a == _expected_index(Vector2i(332, 300)), "wraparound pair shares entry %d" % idx_a)
	ok(d.get_region_map()[idx_a] == d.get_region_id(Vector2i(300, 300)) + 1, "entry owned by (300, 300)")
	d.set_region_window_origin(Vector2i(310, 290))
	ok(d.get_region_map()[idx_a] == d.get_region_id(Vector2i(332, 300)) + 1, "after moving, entry owned by (332, 300)")
	# Evicting the region outside the window must not clear the in-window owner's entry.
	ok(d.evict_region(Vector2i(300, 300)) == OK, "evict (300, 300) while outside the window")
	_resident.erase(Vector2i(300, 300))
	ok(d.get_region_map()[idx_a] == d.get_region_id(Vector2i(332, 300)) + 1, "entry of (332, 300) survives the eviction")
	_check_map("after wraparound eviction")
	_add(Vector2i(300, 300))
	ok(d.get_region_map()[idx_a] == d.get_region_id(Vector2i(332, 300)) + 1, "re-adding outside the window leaves the entry")
	_check_map("after re-add outside window")

	# Collision far from the origin works whatever the window.
	target.position = Vector3(300 * RS + 32.0, 0.0, 300 * RS + 32.0)
	for i in 4:
		await physics_frame
	ok(is_equal_approx(_ray_height(300 * RS + 32.0, 300 * RS + 32.0), _sig(Vector2i(300, 300))),
			"collision at (300, 300) with the window elsewhere")
	d.set_region_window_origin(Vector2i(-16, -16))
	await physics_frame
	ok(is_equal_approx(_ray_height(300 * RS + 32.0, 300 * RS + 32.0), _sig(Vector2i(300, 300))),
			"collision unchanged after moving the window")

	# Disk round trip at far locations (wide file names). A fresh directory and heights
	# unique to this run, so leftovers from an earlier run cannot make it pass.
	var run_id := "%d_%d" % [Time.get_unix_time_from_system(), Time.get_ticks_usec()]
	var dir := "user://barge_window_test_" + run_id
	ok(DirAccess.make_dir_recursive_absolute(dir) == OK, "created %s" % dir)
	ok(DirAccess.get_files_at(dir).size() == 0, "test directory starts empty")
	var run_height := 500.0 + float(Time.get_ticks_usec() % 1000) * 0.125
	for loc in [Vector2i(300, -1234), Vector2i(-5000, 4000)]:
		ok(d.add_region(_make_region(loc, run_height)) == OK, "replace %s with this run's height" % loc)
		d.get_region(loc).set_modified(true)
		d.save_region(loc, dir, false)
		var path := dir + "/" + Terrain3DUtil.location_to_filename(loc)
		ok(FileAccess.file_exists(path), "saved %s to %s" % [loc, path.get_file()])
		ok(d.evict_region(loc) == OK, "evict %s before reload" % loc)
		ok(not d.has_region(loc), "%s gone after eviction" % loc)
		d.load_region(loc, dir)
		ok(d.has_region(loc) and is_equal_approx(d.get_height(Vector3(loc.x * RS + 1.0, 0.0, loc.y * RS + 1.0)), run_height),
				"reloaded %s from disk with this run's height %s" % [loc, run_height])
		_resident[loc] = run_height
	_check_map("after disk round trip")
	for f in DirAccess.get_files_at(dir):
		ok(DirAccess.remove_absolute(dir + "/" + f) == OK, "removed %s" % f)
	ok(DirAccess.remove_absolute(dir) == OK, "removed test directory")

	# Limits: +-2^19 regions, compared without overflow; the window's last region must be
	# inside the limit too.
	var limit := 1 << 19
	ok(d.add_region(_make_region(Vector2i(600000, 0), 1.0)) != OK, "location beyond the limit refused")
	ok(d.add_region(_make_region(Vector2i(-2147483648, 0), 1.0)) != OK, "INT32_MIN location refused")
	ok(d.add_region(_make_region(Vector2i(0, -2147483648), 1.0)) != OK, "INT32_MIN location refused (y)")
	for loc in [Vector2i(limit, limit), Vector2i(-limit, -limit)]:
		if d.get_free_slot_count() == 0:
			var any: Vector2i = _resident.keys()[0]
			d.evict_region(any)
			_resident.erase(any)
		_add(loc)
	d.set_region_window_origin(Vector2i(limit - 31, limit - 31))
	ok(d.get_region_window_origin() == Vector2i(limit - 31, limit - 31), "window can reach the last region")
	ok(d.is_in_region_window(Vector2i(limit, limit)), "region at the limit is inside that window")
	d.set_region_window_origin(Vector2i(limit - 30, limit - 30))
	ok(d.get_region_window_origin() == Vector2i(limit - 31, limit - 31), "window past the limit refused")
	d.set_region_window_origin(Vector2i(-limit, -limit))
	ok(d.is_in_region_window(Vector2i(-limit, -limit)), "region at the negative limit is inside the window")
	_check_map("at the limits")
	d.set_region_window_origin(Vector2i(-16, -16))

	_t.free()
	target.free()
	cam.free()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
