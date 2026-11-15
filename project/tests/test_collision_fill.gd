extends SceneTree
## Barge Game addition. Collision shapes hold exactly the heights the data reports
## (BARGE_CHANGES entry 7: shapes are filled from the region maps in blocks). Random heights
## with holes over regions with gaps, the world background blending towards the ground
## level at region edges, and a border next to a missing region. Every vertex of every
## active shape is read back from the physics server and compared bit for bit with
## Terrain3DData.get_surface_height() at that vertex (the single read). Runs with the world
## background FLAT and NONE, after a region flush (a gap filled, a region replaced),
## through several targets and the stock single target. The blend needs material uniforms,
## so run it windowed too: tools/terrain3d_fork/test.py --windowed collision_fill
## Exits with the number of failed checks (0 = pass).

const RS := 64
const SPACING := 0.5
const SHAPE := 16

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


func _region(loc: Vector2i, rng: RandomNumberGenerator) -> Terrain3DRegion:
	var r := Terrain3DRegion.new()
	r.set_region_size(RS)
	r.set_vertex_spacing(SPACING)
	r.set_location(loc)
	var h := Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	var c := Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	for y in RS:
		for x in RS:
			h.set_pixel(x, y, Color(rng.randf_range(-20.0, 40.0), 0.0, 0.0))
			var hole := rng.randf() < 0.03
			var bits := Terrain3DUtil.enc_base(rng.randi_range(0, 3)) | (4 if hole else 0)
			c.set_pixel(x, y, Color(Terrain3DUtil.as_float(bits), 0.0, 0.0))
	r.set_height_map(h)
	r.set_control_map(c)
	return r


func _same(a: float, b: float) -> bool:
	return (is_nan(a) and is_nan(b)) or a == b


## Compares every vertex of every enabled shape with get_surface_height. Returns
## [vertices compared, mismatches, shapes compared, vertices the blend changed].
func _compare(label: String) -> Array:
	var body: RID = _t.collision.get_rid()
	var d: Terrain3DData = _t.data
	var hs := SHAPE + 1
	var compared := 0
	var wrong := 0
	var shapes := 0
	var blended := 0
	for i in PhysicsServer3D.body_get_shape_count(body):
		# Each comparison runs on a body whose shapes were all placed by the fill under test
		# (fresh build, or a full refill with no shape released); unplaced shapes sit at
		# infinity.
		var origin := PhysicsServer3D.body_get_shape_transform(body, i).origin
		if origin.x > 1.0e20:
			continue
		var data: Dictionary = PhysicsServer3D.shape_get_data(PhysicsServer3D.body_get_shape(body, i))
		var heights: PackedFloat32Array = data["heights"]
		var top_left := Vector2i(roundi(origin.x / SPACING) - SHAPE / 2, roundi(origin.z / SPACING) - SHAPE / 2)
		shapes += 1
		for z in hs:
			for x in hs:
				var got := heights[hs - 1 - z + x * hs]
				var p := Vector3((top_left.x + x) * SPACING, 0.0, (top_left.y + z) * SPACING)
				var want := d.get_surface_height(p)
				compared += 1
				if not is_nan(want) and want != d.get_height(p):
					blended += 1
				if not _same(got, want):
					wrong += 1
					if wrong <= 5:
						print("  %s mismatch at %s: shape %s, data %s" % [label, p, got, want])
	return [compared, wrong, shapes, blended]


func _run() -> void:
	if _started:
		return
	_started = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var cam := Camera3D.new()
	root.add_child(cam)
	_t = Terrain3D.new()
	root.add_child(_t)
	_t.collision_mode = 1
	_t.collision_shape_size = SHAPE
	_t.set_camera(cam)
	await _frames()
	_t.change_region_size(RS)
	_t.vertex_spacing = SPACING
	_t.material.world_background = Terrain3DMaterial.FLAT
	_t.material.set("ground_level", -3.0)
	_t.material.set("region_blend", 0.6)
	var d: Terrain3DData = _t.data
	d.enable_streaming(8)
	# An L of three regions with a gap at (301, 301): edges next to missing regions blend.
	for loc in [Vector2i(300, 300), Vector2i(301, 300), Vector2i(300, 301)]:
		ok(d.add_region(_region(loc, rng)) == OK, "add %s" % loc)
	var region_m := RS * SPACING
	var centre := Vector3(301 * region_m, 0.0, 301 * region_m) # the corner of the gap
	var target := Node3D.new()
	root.add_child(target)
	target.global_position = centre
	_t.add_collision_target(target, 40.0)
	await _frames()

	var r: Array = _compare("FLAT")
	print("FLAT: %d vertices in %d shapes" % [r[0], r[2]])
	ok(r[2] > 20 and r[0] > 20 * 289, "many shapes compared (%d)" % r[2])
	ok(r[1] == 0, "FLAT background: every vertex matches (%d wrong)" % r[1])
	if DisplayServer.get_name() != "headless":
		ok(r[3] > 100, "the blend changed %d vertices (real renderer: material uniforms exist)" % r[3])
	else:
		print("NOTE: headless, no material uniforms, so the blend is inactive; run --windowed for it")

	# The gap fills: the region flush (no full refill) must leave every shape exact,
	# including the blended heights next to the new region and its own new shapes.
	ok(d.add_region(_region(Vector2i(301, 301), rng)) == OK, "fill the gap at (301, 301)")
	await _frames()
	r = _compare("gap filled")
	ok(r[1] == 0 and r[2] > 20, "after the gap filled: every vertex matches (%d wrong of %d, %d shapes)" % [r[1], r[0], r[2]])
	# New data for a resident region (a replacement) refreshes its shapes too.
	ok(d.add_region(_region(Vector2i(300, 300), rng)) == OK, "replace (300, 300)")
	await _frames()
	r = _compare("replaced")
	ok(r[1] == 0, "after the replacement: every vertex matches (%d wrong of %d)" % [r[1], r[0]])

	_t.material.world_background = Terrain3DMaterial.NONE
	_t.collision.update(Vector2i(2147483647, 2147483647), true)
	r = _compare("NONE")
	ok(r[1] == 0 and r[0] > 0, "NONE background: every vertex matches (%d wrong of %d)" % [r[1], r[0]])

	# The stock single target fills through the same block read.
	_t.material.world_background = Terrain3DMaterial.FLAT
	_t.clear_collision_targets()
	_t.set_collision_target(target)
	await _frames()
	r = _compare("stock")
	ok(r[1] == 0 and r[2] > 0, "stock target: every vertex matches (%d wrong of %d)" % [r[1], r[0]])

	_t.free()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
