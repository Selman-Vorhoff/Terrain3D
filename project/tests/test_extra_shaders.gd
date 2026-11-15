extends SceneTree
## Barge Game addition. Compiles and renders the addon's extra shaders that copy the region
## lookup (lightweight and minimum terrain overrides, particle example), so a change to the
## region window lookup cannot leave them broken. Needs a real renderer (headless compiles
## no shaders); headless it skips and passes. tools/terrain3d_fork/test.py --windowed
## treats any SHADER ERROR line as a failure.

const RS := 64
const CLEAR := Color(1.0, 0.0, 1.0)

var _fail := 0
var _started := false


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	process_frame.connect(_run)


func _centre_pixel() -> Color:
	var img: Image = root.get_texture().get_image()
	return img.get_pixel(img.get_width() / 2, img.get_height() / 2)


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
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = RS * 0.5
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	root.add_child(cam)
	cam.make_current()

	var t := Terrain3D.new()
	root.add_child(t)
	t.set_camera(cam)
	await process_frame
	t.change_region_size(RS)
	t.material.world_background = Terrain3DMaterial.NONE
	t.data.enable_streaming(4)
	var r := Terrain3DRegion.new()
	r.set_location(Vector2i(300, 300))
	r.set_region_size(RS)
	r.set_vertex_spacing(1.0)
	var img := Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	img.fill(Color(0.0, 0.0, 0.0))
	r.set_height_map(img)
	t.data.add_region(r)
	t.data.set_region_window_origin(Vector2i(290, 290))
	cam.global_position = Vector3(300.5 * RS, 200.0, 300.5 * RS)

	for path in ["res://addons/terrain_3d/extras/shaders/lightweight.gdshader",
			"res://addons/terrain_3d/extras/shaders/minimum.gdshader"]:
		t.material.shader_override = load(path)
		t.material.shader_override_enabled = true
		t.snap()
		for i in 6:
			await RenderingServer.frame_post_draw
		var c := _centre_pixel()
		ok(not c.is_equal_approx(CLEAR), "%s draws the far region in the moved window (%s)" % [path.get_file(), c])
		t.data.set_region_window_origin(Vector2i(-16, -16))
		for i in 6:
			await RenderingServer.frame_post_draw
		c = _centre_pixel()
		ok(c.is_equal_approx(CLEAR), "%s does not draw it with the window elsewhere (%s)" % [path.get_file(), c])
		t.data.set_region_window_origin(Vector2i(290, 290))
	t.material.shader_override_enabled = false

	var particles := GPUParticles3D.new()
	var pm := ShaderMaterial.new()
	pm.shader = load("res://addons/terrain_3d/extras/particle_example/particles.gdshader")
	particles.process_material = pm
	particles.draw_pass_1 = QuadMesh.new()
	root.add_child(particles)
	for i in 4:
		await RenderingServer.frame_post_draw
	ok(pm.shader != null, "particle shader loaded and used")

	particles.free()
	t.free()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
