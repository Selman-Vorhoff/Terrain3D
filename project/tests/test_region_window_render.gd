extends SceneTree
## Barge Game addition. Rendering test for the region window: the shaders must draw a
## resident region exactly when it lies inside the window, at any distance from the origin,
## including the wraparound case. Needs a real renderer (headless compiles no shaders):
##   godot --path project --resolution 640x360 --script res://tests/test_region_window_render.gd
## (tools/terrain3d_fork/test.py --windowed). Headless it skips and passes.
## Exits with the number of failed checks (0 = pass).

const RS := 64
const CLEAR := Color(1.0, 0.0, 1.0) # magenta: nothing drawn

var _fail := 0
var _started := false
var _t: Terrain3D
var _cam: Camera3D


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	process_frame.connect(_run)


func _make_region(loc: Vector2i) -> Terrain3DRegion:
	var r := Terrain3DRegion.new()
	r.set_location(loc)
	r.set_region_size(RS)
	r.set_vertex_spacing(1.0)
	var img := Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	img.fill(Color(0.0, 0.0, 0.0))
	r.set_height_map(img)
	return r


# True if the terrain is drawn at the screen centre with the camera above region loc.
func _drawn_at(loc: Vector2i) -> bool:
	var centre := Vector3((loc.x + 0.5) * RS, 0.0, (loc.y + 0.5) * RS)
	_cam.global_position = centre + Vector3(0.0, 200.0, 0.0)
	_t.snap()
	for i in 6:
		await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	var c: Color = img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	var drawn := not c.is_equal_approx(CLEAR) and c.a > 0.5
	print("  pixel at %s: %s (drawn %s)" % [loc, c, drawn])
	return drawn


func _run() -> void:
	if _started:
		return
	_started = true
	if DisplayServer.get_name() == "headless":
		print("SKIP: needs a real renderer (run with a window)")
		print("RESULT PASS (0 failed)")
		quit(0)
		return

	RenderingServer.set_default_clear_color(CLEAR)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = RS * 0.5
	_cam.far = 1000.0
	_cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	root.add_child(_cam)
	_cam.make_current()
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60.0, 30.0, 0.0)
	root.add_child(light)

	_t = Terrain3D.new()
	root.add_child(_t)
	_t.set_camera(_cam)
	await process_frame
	_t.change_region_size(RS)
	_t.material.world_background = Terrain3DMaterial.NONE # no flat ground outside regions
	var d: Terrain3DData = _t.data
	d.enable_streaming(16)
	for loc in [Vector2i(0, 0), Vector2i(300, 300), Vector2i(332, 300), Vector2i(-300, -300)]:
		ok(d.add_region(_make_region(loc)) == OK, "add %s" % loc)
	for i in 4:
		await RenderingServer.frame_post_draw

	ok(await _drawn_at(Vector2i(0, 0)), "(0, 0) drawn in the default window")
	ok(not await _drawn_at(Vector2i(5, 5)), "empty (5, 5) not drawn")
	ok(not await _drawn_at(Vector2i(300, 300)), "(300, 300) not drawn outside the window")

	d.set_region_window_origin(Vector2i(290, 290))
	ok(await _drawn_at(Vector2i(300, 300)), "(300, 300) drawn once the window covers it")
	ok(not await _drawn_at(Vector2i(332, 300)), "(332, 300) shares its map entry but is outside: not drawn")
	ok(not await _drawn_at(Vector2i(0, 0)), "(0, 0) not drawn after the window moved away")

	d.set_region_window_origin(Vector2i(310, 290))
	ok(await _drawn_at(Vector2i(332, 300)), "(332, 300) drawn after the window moved over it")
	ok(not await _drawn_at(Vector2i(300, 300)), "(300, 300) not drawn after the window moved past it")

	d.set_region_window_origin(Vector2i(-316, -316))
	ok(await _drawn_at(Vector2i(-300, -300)), "(-300, -300) drawn after a 600 region jump")

	d.set_region_window_origin(Vector2i(-16, -16))
	ok(await _drawn_at(Vector2i(0, 0)), "(0, 0) drawn again in the default window")

	_t.free()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
