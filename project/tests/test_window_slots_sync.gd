extends SceneTree
## Barge Game addition. Regressions from the Codex review of GPU slots following the window
## (Review 78, follow-up): changes made while a region is data only still reach collision
## and the height range after the window reaches it; set_height keeps the height range in
## step; instancer meshes exist only while a region holds a slot, through global rebuilds
## and eviction; upload stats count every upload.
## Instancer counts need a real renderer:
##   tools/terrain3d_fork/test.py --windowed window_slots_sync
## Exits with the number of failed checks (0 = pass).

const RS := 64
const LOC := Vector2i(500, 500)
const POS := Vector3(500 * RS + 20.0, 0.0, 500 * RS + 20.0)

var _fail := 0
var _started := false
var _t: Terrain3D


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	process_frame.connect(_run)


func _frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func _height_image(h: float) -> Image:
	var img := Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	img.fill(Color(h, 0.0, 0.0))
	return img


func _ray_height() -> float:
	var space := _t.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(POS + Vector3.UP * 5000.0, POS + Vector3.DOWN * 5000.0))
	return hit.position.y if hit else NAN


func _run() -> void:
	if _started:
		return
	_started = true
	var windowed := DisplayServer.get_name() != "headless"
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.position = POS + Vector3.UP * 50.0
	var target := Node3D.new()
	root.add_child(target)
	target.position = POS
	_t = Terrain3D.new()
	_t.collision_mode = 1 # Dynamic / Game
	_t.collision_radius = 16
	_t.collision_shape_size = 8
	root.add_child(_t)
	_t.set_camera(cam)
	_t.set_collision_target(target)
	await _frames()
	_t.change_region_size(RS)
	var d: Terrain3DData = _t.data
	d.enable_streaming(4)
	var r := Terrain3DRegion.new()
	r.set_region_size(RS)
	r.set_location(LOC)
	r.set_height_map(_height_image(10.0))
	r.set_instances({0: {Vector2i(0, 0): [Array([Transform3D.IDENTITY], TYPE_TRANSFORM3D, &"", null), PackedColorArray([Color.WHITE]), true]}})
	ok(d.add_region(r) == OK, "add %s outside the window" % LOC)
	await _frames()
	ok(d.get_region_id(LOC) == -1, "data only")
	ok(is_equal_approx(_ray_height(), 10.0), "collision under the data-only region (%s)" % _ray_height())

	# (1) A new image while data only, then the window arrives, then update_maps(): the
	# attach must not swallow the collision refresh.
	r.set_height_map(_height_image(70.0))
	d.set_region_window_origin(Vector2i(490, 490))
	d.update_maps()
	await _frames()
	ok(d.get_region_id(LOC) >= 0, "window arrived: slot taken")
	ok(is_equal_approx(_ray_height(), 70.0), "collision follows the image replaced while data only (%s)" % _ray_height())
	ok(is_equal_approx(r.get_height_range().y, 70.0), "region height range follows it (%s)" % r.get_height_range())

	# (3) set_height raises the height range (mesher AABBs) as well as the data.
	d.set_height(POS, 150.0)
	d.update_maps()
	ok(r.get_height_range().y >= 150.0, "region height range after set_height (%s)" % r.get_height_range())
	ok(d.get_height_range().y >= 150.0, "master height range after set_height (%s)" % d.get_height_range())

	# (2) Instancer meshes only while the region holds a slot.
	var ma: Terrain3DMeshAsset = _t.assets.get_mesh_asset(0)
	await _frames()
	if windowed:
		ok(ma.get_instance_count() == 1, "one instance while drawn (%d)" % ma.get_instance_count())
	d.set_region_window_origin(Vector2i(-16, -16))
	await _frames()
	ok(ma.get_instance_count() == 0, "no instances after the window left (%d)" % ma.get_instance_count())
	_t.instancer.update_mmis(-1, Vector2i(2147483647, 2147483647), true)
	await _frames()
	ok(ma.get_instance_count() == 0, "a global instancer rebuild creates none for a data-only region (%d)" % ma.get_instance_count())
	d.set_region_window_origin(Vector2i(490, 490))
	await _frames()
	if windowed:
		ok(ma.get_instance_count() == 1, "instance back when the window returns (%d)" % ma.get_instance_count())
	d.evict_region(LOC)
	await _frames()
	ok(ma.get_instance_count() == 0, "eviction leaves no instances (%d)" % ma.get_instance_count())

	# (4) Every upload is counted, so the mean is per upload.
	var stats: Dictionary = d.get_streaming_stats()
	ok(int(stats["uploads"]) >= 3, "uploads counted: attach, edit, re-attach (%d)" % stats["uploads"])
	ok(float(stats["upload_usec_mean"]) <= float(stats["upload_usec_max"]) + 0.001,
			"mean %s within max %s" % [stats["upload_usec_mean"], stats["upload_usec_max"]])

	_t.free()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
