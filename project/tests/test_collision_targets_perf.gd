extends SceneTree
## Barge Game addition. Cost of several dynamic collision targets at the game's planned
## scale: 0.25 m vertex spacing, 1024-vertex (256 m) regions, the barge plus six players,
## 48 m radius each, 8 m shapes. Logs the time to fill every target, one target crossing a
## shape line, a far region arriving and one arriving under a target, plus shape counts.
## Checks only that every target stands on ground; the times are for the log
## (the plan's "shape counts and refresh time logged").
## Exits with the number of failed checks (0 = pass).

const RS := 1024
const SPACING := 0.25
const SHAPE := 32 # 8 m
const RADIUS_M := 48.0
const REGION_M := RS * SPACING

var _fail := 0
var _started := false
var _t: Terrain3D


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	process_frame.connect(_run)


func _frames(n: int = 2) -> void:
	for i in n:
		await physics_frame
		await process_frame


func _region(loc: Vector2i, h: float) -> Terrain3DRegion:
	var r := Terrain3DRegion.new()
	r.set_region_size(RS)
	r.set_vertex_spacing(SPACING)
	r.set_location(loc)
	var img := Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	img.fill(Color(h, 0.0, 0.0))
	r.set_height_map(img)
	return r


func _ray(p: Vector3) -> float:
	var space := _t.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 500.0, p + Vector3.DOWN * 500.0))
	return hit.position.y if hit else NAN


func _node_at(p: Vector3) -> Node3D:
	var n := Node3D.new()
	root.add_child(n)
	n.global_position = p
	return n


func _stats() -> Dictionary:
	return _t.collision.get_stats()


func _run() -> void:
	if _started:
		return
	_started = true
	var cam := Camera3D.new()
	root.add_child(cam)
	_t = Terrain3D.new()
	root.add_child(_t)
	_t.collision_mode = 1
	_t.collision_shape_size = SHAPE
	_t.set_camera(cam)
	print("PERF shape size %d vertices, world background %d" % [_t.collision_shape_size, _t.material.world_background])
	await _frames()
	_t.change_region_size(RS)
	_t.vertex_spacing = SPACING
	var d: Terrain3DData = _t.data
	d.enable_streaming(16)
	var base := Vector2i(100, 100)
	for z in 2:
		for x in 3:
			d.add_region(_region(base + Vector2i(x, z), 5.0))
	await _frames()

	# The barge and six players spread over 3 x 2 regions (768 m x 512 m).
	var origin := Vector3(base.x * REGION_M, 0.0, base.y * REGION_M)
	var spots := [Vector3(128, 0, 128), Vector3(300, 0, 140), Vector3(140, 0, 380), Vector3(400, 0, 400),
			Vector3(620, 0, 120), Vector3(640, 0, 300), Vector3(520, 0, 450)]
	var targets: Array[Node3D] = []
	var t0 := Time.get_ticks_usec()
	for s: Vector3 in spots:
		var n := _node_at(origin + s)
		targets.append(n)
		_t.add_collision_target(n, RADIUS_M)
	_t.collision.update()
	var fill_usec := Time.get_ticks_usec() - t0
	await _frames()
	var st := _stats()
	print("PERF fill 7 targets: %d us, %d shapes active, %d total, %d fills" % [fill_usec, st["shapes_active"], st["shapes_total"], st["fills"]])
	for n in targets:
		ok(is_equal_approx(_ray(n.global_position + Vector3(0.3, 0, 0.3)), 5.0), "ground under %s" % n.global_position)

	# One target crosses one shape line (a player walking).
	var fills_before := int(_stats()["fills"])
	targets[1].global_position += Vector3(SHAPE * SPACING, 0, 0)
	t0 = Time.get_ticks_usec()
	_t.collision.update()
	var step_usec := Time.get_ticks_usec() - t0
	print("PERF one target steps one shape: %d us, %d fills" % [step_usec, int(_stats()["fills"]) - fills_before])

	# Nothing moved: the per-frame cost.
	t0 = Time.get_ticks_usec()
	for i in 100:
		_t.collision.update()
	print("PERF idle update: %.1f us" % ((Time.get_ticks_usec() - t0) / 100.0))

	# A far region arrives (no target near it).
	fills_before = int(_stats()["fills"])
	t0 = Time.get_ticks_usec()
	d.add_region(_region(Vector2i(300, 300), 5.0))
	var far_usec := Time.get_ticks_usec() - t0
	print("PERF far region add incl. collision flush: %d us, %d fills" % [far_usec, int(_stats()["fills"]) - fills_before])

	# A region under a target is replaced (new data streamed in).
	fills_before = int(_stats()["fills"])
	t0 = Time.get_ticks_usec()
	d.add_region(_region(base, 7.0))
	var near_usec := Time.get_ticks_usec() - t0
	await _frames()
	print("PERF region under a target replaced incl. collision flush: %d us, %d fills" % [near_usec, int(_stats()["fills"]) - fills_before])
	ok(is_equal_approx(_ray(targets[0].global_position + Vector3(0.3, 0, 0.3)), 7.0), "replaced region's ground in collision")

	print("STATS %s" % _stats())
	_t.free()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
