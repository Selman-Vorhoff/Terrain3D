extends SceneTree
## Barge Game addition. Regressions from the Codex review of the slot pool (Review 78, S):
## changed resident regions reach the GPU layers, replacement clears old instances, the
## pool keeps its layer size after the last eviction, collision over an evicted neighbour
## refreshes, max_regions and the material cannot drop below the pool, and the map
## getters list resident regions.
## GPU layer contents are read back only with a real renderer:
##   tools/terrain3d_fork/test.py --windowed slot_pool_edits
## Headless (dummy renderer) those checks skip and the rest run.
## Exits with the number of failed checks (0 = pass).
## expect-error: streaming pool is 64 px
## expect-error: is below the streaming slot capacity
## expect-error: The material cannot be replaced while streaming

const RS := 64
const CAPACITY := 8

var _fail := 0
var _started := false
var _t: Terrain3D
var _gpu := false


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	process_frame.connect(_run)


func _make_region(loc: Vector2i, height: float, size: int = RS, colour := Color.WHITE, control := 0) -> Terrain3DRegion:
	var r := Terrain3DRegion.new()
	r.set_location(loc)
	r.set_region_size(size)
	r.set_vertex_spacing(1.0)
	var img := Image.create_empty(size, size, false, Image.FORMAT_RF)
	img.fill(Color(height, 0.0, 0.0))
	r.set_height_map(img)
	var ctl := Image.create_empty(size, size, false, Image.FORMAT_RF)
	ctl.fill(Color(Terrain3DUtil.as_float(Terrain3DUtil.enc_base(control)), 0.0, 0.0)) # base texture id only (bit 2 would be a hole)
	r.set_control_map(ctl)
	var col := Image.create_empty(size, size, true, Image.FORMAT_RGBA8)
	col.fill(colour)
	r.set_color_map(col)
	return r


func _centre(loc: Vector2i) -> Vector3:
	return Vector3((loc.x + 0.5) * RS, 0.0, (loc.y + 0.5) * RS)


# Reads one texel of a pool layer back from the GPU (real renderer only).
func _layer_texel(rid: RID, slot: int) -> Color:
	var img: Image = RenderingServer.texture_2d_layer_get(rid, slot)
	if img == null or img.is_empty():
		return Color(NAN, NAN, NAN, NAN)
	if img.is_compressed():
		img.decompress()
	return img.get_pixel(RS / 2, RS / 2)


func _gpu_height(loc: Vector2i) -> float:
	return _layer_texel(_t.data.get_height_maps_rid(), _t.data.get_region_id(loc)).r


func _ray_height(x: float, z: float) -> float:
	var space := _t.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, 5000.0, z), Vector3(x, -5000.0, z)))
	return hit.position.y if hit else NAN


func _frames(n: int) -> void:
	for i in n:
		await physics_frame
		await process_frame


func _run() -> void:
	if _started:
		return
	_started = true
	_gpu = DisplayServer.get_name() != "headless"
	if not _gpu:
		print("NOTE: headless, GPU layer readback checks skipped")
	var cam := Camera3D.new()
	root.add_child(cam)
	var target := Node3D.new()
	root.add_child(target)
	target.position = Vector3(12.0, 0.0, 12.0)
	_t = Terrain3D.new()
	_t.collision_mode = 1 # Dynamic / Game
	_t.collision_radius = 64
	_t.collision_shape_size = 8
	root.add_child(_t)
	_t.set_camera(cam)
	_t.set_collision_target(target)
	await process_frame
	_t.change_region_size(RS)
	var d: Terrain3DData = _t.data
	d.enable_streaming(CAPACITY)
	var mat_before: Terrain3DMaterial = _t.material

	# --- Changed resident regions reach the GPU (finding S02).
	ok(d.add_region(_make_region(Vector2i(0, 0), 10.0)) == OK, "add (0, 0) at height 10")
	if _gpu:
		ok(is_equal_approx(_gpu_height(Vector2i(0, 0)), 10.0), "GPU layer holds 10")
	d.set_height(_centre(Vector2i(0, 0)), 55.0)
	d.update_maps()
	ok(is_equal_approx(d.get_height(_centre(Vector2i(0, 0))), 55.0), "CPU height 55 after set_height")
	if _gpu:
		ok(is_equal_approx(_gpu_height(Vector2i(0, 0)), 55.0), "GPU layer follows set_height + update_maps (%s)" % _gpu_height(Vector2i(0, 0)))
	var fresh := Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	fresh.fill(Color(70.0, 0.0, 0.0))
	d.get_region(Vector2i(0, 0)).set_height_map(fresh)
	d.update_maps()
	if _gpu:
		ok(is_equal_approx(_gpu_height(Vector2i(0, 0)), 70.0), "GPU layer follows a new height image (%s)" % _gpu_height(Vector2i(0, 0)))
	await _frames(2)
	ok(is_equal_approx(_ray_height(RS * 0.5, RS * 0.5), 70.0), "collision follows the new height image (%s)" % _ray_height(RS * 0.5, RS * 0.5))

	# Replacement and slot reuse carry all three maps.
	var slot0: int = d.get_region_id(Vector2i(0, 0))
	ok(d.add_region(_make_region(Vector2i(0, 0), 20.0, RS, Color(0.0, 0.0, 1.0), 5)) == OK, "replace (0, 0)")
	ok(d.get_region_id(Vector2i(0, 0)) == slot0, "replacement keeps the slot")
	if _gpu:
		ok(is_equal_approx(_gpu_height(Vector2i(0, 0)), 20.0), "GPU height after replacement")
		var c := _layer_texel(d.get_color_maps_rid(), slot0)
		ok(c.b > 0.9 and c.r < 0.1, "GPU colour after replacement (%s)" % c)
		var ctl := _layer_texel(d.get_control_maps_rid(), slot0)
		ok(Terrain3DUtil.get_base(Terrain3DUtil.as_uint(ctl.r)) == 5, "GPU control after replacement (base %d)" % Terrain3DUtil.get_base(Terrain3DUtil.as_uint(ctl.r)))
	d.evict_region(Vector2i(0, 0))
	ok(d.add_region(_make_region(Vector2i(3, 3), 33.0, RS, Color(1.0, 0.0, 0.0), 9)) == OK, "add (3, 3) into the freed slot")
	ok(d.get_region_id(Vector2i(3, 3)) == slot0, "freed slot reused")
	if _gpu:
		ok(is_equal_approx(_gpu_height(Vector2i(3, 3)), 33.0), "GPU height after slot reuse")
		var c2 := _layer_texel(d.get_color_maps_rid(), slot0)
		ok(c2.r > 0.9 and c2.b < 0.1, "GPU colour after slot reuse (%s)" % c2)
		ok(Terrain3DUtil.get_base(Terrain3DUtil.as_uint(_layer_texel(d.get_control_maps_rid(), slot0).r)) == 9, "GPU control after slot reuse")
	d.evict_region(Vector2i(3, 3))

	# --- Collision over an evicted neighbour (finding S04): target (12, 12), radius 64,
	# shape size 8. Shapes near (64, 64) sample region (1, 1)'s border vertex.
	for loc in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		d.add_region(_make_region(loc, 50.0 if loc == Vector2i(1, 1) else 0.0), false)
	d.update_maps()
	await _frames(2)
	var before := _ray_height(63.75, 63.75)
	d.evict_region(Vector2i(1, 1))
	await _frames(2)
	var after := _ray_height(63.75, 63.75)
	_t.collision.update(Vector2i(2147483647, 2147483647), true) # what a forced refresh gives
	await _frames(2)
	var forced := _ray_height(63.75, 63.75)
	ok(not is_equal_approx(before, forced), "the evicted neighbour mattered here (%s vs %s)" % [before, forced])
	ok(is_equal_approx(after, forced) or (is_nan(after) and is_nan(forced)),
			"collision near the evicted neighbour refreshed (%s, forced %s)" % [after, forced])

	# --- The pool keeps its layer size after the last eviction (finding S03).
	for loc in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]:
		d.evict_region(loc, false)
	d.update_maps()
	ok(d.get_region_count() == 0, "pool drained")
	var dir := "user://barge_slot_edits_%d_%d" % [Time.get_unix_time_from_system(), Time.get_ticks_usec()]
	ok(DirAccess.make_dir_recursive_absolute(dir) == OK, "created %s" % dir)
	var big := _make_region(Vector2i(2, 2), 55.0, 128)
	var path := dir + "/" + Terrain3DUtil.location_to_filename(Vector2i(2, 2))
	ok(ResourceSaver.save(big, path) == OK, "saved a 128 px region")
	d.load_region(Vector2i(2, 2), dir)
	ok(not d.has_region(Vector2i(2, 2)), "128 px region refused by a 64 px pool")
	ok(_t.region_size == RS, "terrain region size still %d (%d)" % [RS, _t.region_size])
	ok(d.add_region(_make_region(Vector2i(2, 2), 12.0)) == OK, "a 64 px region still works")
	if _gpu:
		ok(is_equal_approx(_gpu_height(Vector2i(2, 2)), 12.0), "GPU layer right after the refused load")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(dir)

	# --- Map getters list resident regions (finding S07).
	d.add_region(_make_region(Vector2i(-4, 7), 1.0))
	ok(d.get_height_maps().size() == d.get_region_count(), "get_height_maps lists %d resident maps" % d.get_height_maps().size())
	ok(d.get_control_maps().size() == d.get_region_count(), "get_control_maps lists the resident maps")
	ok(d.get_color_maps().size() == d.get_region_count(), "get_color_maps lists the resident maps")
	var locs: Array = d.get_region_locations()
	var listed: float = d.get_height_maps()[locs.find(Vector2i(-4, 7))].get_pixel(0, 0).r
	ok(is_equal_approx(listed, 1.0), "getter order follows get_region_locations")

	# --- max_regions and material replacement (finding S06). Capacity 8 is below the
	# minimum of 64, so use a pool that needs 128.
	var t2 := Terrain3D.new()
	root.add_child(t2)
	t2.set_camera(cam)
	await process_frame
	t2.change_region_size(RS)
	t2.data.enable_streaming(128)
	t2.material.max_regions = 64
	ok(t2.material.max_regions >= 128, "max_regions cannot drop below the slot capacity (%d)" % t2.material.max_regions)
	var other := Terrain3DMaterial.new()
	t2.material = other
	ok(t2.material != other, "material replacement refused while streaming")
	t2.free()
	ok(_t.material == mat_before, "first terrain kept its material")

	_t.free()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
