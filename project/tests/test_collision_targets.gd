extends SceneTree
## Barge Game addition. Several dynamic collision targets (BARGE_CHANGES entry 6):
## separate and overlapping targets, radius in metres at 0.25 m vertex spacing, a target
## freed, a target teleported, the last target removed (stock single target again), a
## stationary target gaining a newly streamed region and losing an evicted one, and a
## neighbour region filling the border samples of shapes next to it. Logs shape counts
## and update times.
## Exits with the number of failed checks (0 = pass).
## expect-error: Collision target is null
## expect-error: Collision target radius must be above 0 m
## expect-error: m limit
## expect-error: Cannot find clipmap target or active camera
## The world background blend check needs material uniforms, which only a real renderer
## has: tools/terrain3d_fork/test.py --windowed collision_targets

const RS := 128 # vertices per region side
const SPACING := 0.25 # m per vertex: 32 m regions
const SHAPE := 16 # vertices per shape side: 4 m
const RADIUS_M := 8.0
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


func _frames(n: int = 3) -> void:
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


## World position (y = 0) of a region's corner plus an offset in metres.
func _at(loc: Vector2i, dx: float = 0.0, dz: float = 0.0) -> Vector3:
	return Vector3(loc.x * REGION_M + dx, 0.0, loc.y * REGION_M + dz)


func _ray(p: Vector3) -> float:
	var space := _t.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 500.0, p + Vector3.DOWN * 500.0))
	return hit.position.y if hit else NAN


## Cells the rule in Terrain3DCollision::_update_targets() keeps for targets at grid-aligned
## positions (metres), as a set of top-left vertex positions.
func _expected_cells(positions: Array, radius_m: float) -> Dictionary:
	var cells := {}
	var r := maxf(radius_m / SPACING, SHAPE * 0.75)
	var reach := ceili(r / SHAPE) + 1
	for p: Vector3 in positions:
		var snapped := Vector2i(roundi(p.x / SPACING / SHAPE) * SHAPE, roundi(p.z / SPACING / SHAPE) * SHAPE)
		for z in range(-reach, reach):
			for x in range(-reach, reach):
				var c := Vector2(x * SHAPE + SHAPE * 0.5, z * SHAPE + SHAPE * 0.5)
				if c.length_squared() <= r * r:
					cells[snapped + Vector2i(x, z) * SHAPE] = true
	return cells


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
	var a_loc := Vector2i(500, 500)
	var b_loc := Vector2i(520, 500) # 640 m east of a
	var c_loc := Vector2i(540, 500) # not resident at first
	var d_loc := Vector2i(560, 500) # border test with (561, 500)

	var cam := Camera3D.new()
	root.add_child(cam)
	var stock_target := _node_at(_at(a_loc, 16.0, 16.0))
	_t = Terrain3D.new()
	root.add_child(_t) # collision settings need the collision manager, made on entering the tree
	_t.collision_mode = 1 # Dynamic / Game
	_t.collision_shape_size = SHAPE
	_t.collision_radius = 32 # vertices: 8 m
	_t.set_camera(cam)
	_t.set_collision_target(stock_target)
	await _frames()
	_t.change_region_size(RS)
	_t.vertex_spacing = SPACING
	# Heights exactly as stored; the blend towards the ground level is checked on its own below.
	_t.material.world_background = Terrain3DMaterial.NONE
	var d: Terrain3DData = _t.data
	d.enable_streaming(8)
	for loc in [a_loc, b_loc, d_loc]:
		ok(d.add_region(_region(loc, 10.0 + (loc.x - 500))) == OK, "add %s" % loc)
	await _frames()

	# Stock: one target, radius in vertices.
	var a := _at(a_loc, 16.0, 16.0)
	var b := _at(b_loc, 16.0, 16.0)
	ok(is_equal_approx(_ray(a + Vector3(1, 0, 1)), 10.0), "stock target has ground (%s)" % _ray(a + Vector3(1, 0, 1)))
	ok(is_nan(_ray(b)), "stock: nothing at b")
	ok(int(_stats()["targets"]) == 0, "no targets yet")
	ok(_t.collision_shape_size == SHAPE and _t.collision_radius == 32, "collision settings applied")

	# Two separate targets, radius in metres.
	var ta := _node_at(a)
	var tb := _node_at(b)
	_t.add_collision_target(ta, RADIUS_M)
	_t.add_collision_target(tb, RADIUS_M)
	await _frames()
	var single := _expected_cells([a], RADIUS_M).size()
	ok(_t.get_collision_targets().size() == 2, "two targets")
	ok(is_equal_approx(_t.collision.get_target_radius(ta), RADIUS_M), "radius kept in metres")
	ok(int(_stats()["shapes_active"]) == 2 * single, "separate targets: %d shapes (expected %d)" % [_stats()["shapes_active"], 2 * single])
	ok(is_equal_approx(_ray(a + Vector3(1, 0, 1)), 10.0), "ground at a")
	ok(is_equal_approx(_ray(b + Vector3(1, 0, 1)), 30.0), "ground at b (%s)" % _ray(b + Vector3(1, 0, 1)))
	ok(is_equal_approx(_ray(a + Vector3(5, 0, 1)), 10.0), "ground 5 m from a")
	ok(is_nan(_ray(a + Vector3(14, 0, 1))), "no ground 14 m from a (radius 8 m)")
	ok(is_nan(_ray((a + b) * 0.5)), "no ground between the targets")
	ok(is_nan(_ray(stock_target.global_position + Vector3(20, 0, 20))), "the stock target is ignored while targets exist")
	print("STATS separate %s" % _stats())

	# Overlapping targets: the union, no double counting.
	tb.global_position = a + Vector3(4, 0, 0)
	await _frames()
	var union := _expected_cells([a, a + Vector3(4, 0, 0)], RADIUS_M).size()
	ok(int(_stats()["shapes_active"]) == union, "overlapping targets: %d shapes (union %d)" % [_stats()["shapes_active"], union])
	ok(is_nan(_ray(b + Vector3(1, 0, 1))), "b's old ground released")
	var total_before := int(_stats()["shapes_total"])
	tb.global_position = a
	await _frames()
	ok(int(_stats()["shapes_active"]) == single, "same spot: %d shapes (one target's %d)" % [_stats()["shapes_active"], single])

	# Teleport (respawn) far away and back: shapes are reused, the pool does not grow.
	tb.global_position = b
	await _frames()
	ok(is_equal_approx(_ray(b + Vector3(1, 0, 1)), 30.0), "teleported target has ground at once")
	ok(int(_stats()["shapes_total"]) <= maxi(total_before, 2 * single), "pool reused: %d shapes total" % _stats()["shapes_total"])

	# A stationary target over a region that is not resident yet.
	var c := _at(c_loc, 16.0, 16.0)
	var tc := _node_at(c)
	_t.add_collision_target(tc, RADIUS_M)
	await _frames()
	ok(is_nan(_ray(c)), "no ground at c before its region streams in")
	ok(d.add_region(_region(c_loc, 50.0)) == OK, "stream in %s" % c_loc)
	await _frames()
	ok(is_equal_approx(_ray(c + Vector3(1, 0, 1)), 50.0), "c gains ground without moving (%s)" % _ray(c + Vector3(1, 0, 1)))
	d.evict_region(c_loc)
	await _frames()
	ok(is_nan(_ray(c + Vector3(1, 0, 1))), "c loses ground when its region is evicted")
	ok(d.add_region(_region(c_loc, 55.0)) == OK, "stream %s in again" % c_loc)
	await _frames()
	ok(is_equal_approx(_ray(c + Vector3(1, 0, 1)), 55.0), "c has the new ground (%s)" % _ray(c + Vector3(1, 0, 1)))

	# A target on a region border: the neighbour arriving fills the shapes' border samples.
	var edge := _at(d_loc + Vector2i(1, 0), 0.0, 16.0)
	var td := _node_at(edge)
	_t.add_collision_target(td, RADIUS_M)
	await _frames()
	ok(is_equal_approx(_ray(edge + Vector3(-1, 0, 1)), 70.0), "ground west of the border (%s)" % _ray(edge + Vector3(-1, 0, 1)))
	ok(is_nan(_ray(edge + Vector3(1, 0, 1))), "no ground east of the border yet")
	ok(d.add_region(_region(d_loc + Vector2i(1, 0), 90.0)) == OK, "stream in the neighbour")
	await _frames()
	ok(is_equal_approx(_ray(edge + Vector3(1, 0, 1)), 90.0), "ground east of the border (%s)" % _ray(edge + Vector3(1, 0, 1)))
	var seam := _ray(edge + Vector3(-0.1, 0, 1))
	ok(seam > 70.5 and seam < 90.0, "west shape's border samples read the neighbour (%s)" % seam)

	# A target freed: removed, its ground released; the others stay.
	tc.queue_free()
	await _frames()
	ok(_t.get_collision_targets().size() == 3, "freed target dropped (%d left)" % _t.get_collision_targets().size())
	ok(is_nan(_ray(c + Vector3(1, 0, 1))), "freed target's ground released")
	ok(is_equal_approx(_ray(a + Vector3(1, 0, 1)), 10.0), "a still has ground")
	print("STATS four targets %s" % _stats())

	# Removing the last target returns to the stock single target.
	_t.remove_collision_target(ta)
	_t.remove_collision_target(tb)
	_t.clear_collision_targets()
	await _frames()
	ok(_t.get_collision_targets().is_empty() and int(_stats()["targets"]) == 0, "no targets left")
	ok(int(_stats()["shapes_active"]) == 0, "on-demand shapes gone")
	ok(is_equal_approx(_ray(stock_target.global_position + Vector3(1, 0, 1)), 10.0), "stock target has ground again")
	ok(is_nan(_ray(b + Vector3(1, 0, 1))), "nothing at b after the targets left")
	ok(is_nan(_ray(edge + Vector3(1, 0, 1))), "nothing at the border target after it left")

	# Bad input is refused.
	_t.add_collision_target(null, 5.0)
	_t.add_collision_target(ta, 0.0)
	ok(_t.get_collision_targets().is_empty(), "null node and zero radius refused")
	_t.add_collision_target(ta, RADIUS_M)
	_t.add_collision_target(ta, INF)
	_t.add_collision_target(ta, NAN)
	_t.add_collision_target(ta, 1.0e6)
	ok(is_equal_approx(_t.collision.get_target_radius(ta), RADIUS_M), "infinite, NaN and huge radii refused, radius kept")
	await _frames()
	ok(is_equal_approx(_ray(a + Vector3(1, 0, 1)), 10.0), "ground kept after the refused radii")

	# World background blend: a neighbour arriving changes heights near the shared edge
	# (the blend reads residency one region out), so those shapes refill too.
	if DisplayServer.get_name() != "headless":
		_t.material.world_background = Terrain3DMaterial.FLAT
		_t.material.set("region_blend", 1.0)
		var e_loc := Vector2i(580, 500)
		ok(d.add_region(_region(e_loc, 10.0)) == OK, "add %s for the blend check" % e_loc)
		var te := _node_at(_at(e_loc, 26.0, 16.0))
		_t.add_collision_target(te, RADIUS_M)
		await _frames()
		var p := _at(e_loc, 26.3, 16.3)
		var before := _ray(p)
		ok(d.add_region(_region(e_loc + Vector2i(1, 0), 10.0)) == OK, "stream in the eastern neighbour")
		await _frames()
		var after := _ray(p)
		_t.collision.update(Vector2i(2147483647, 2147483647), true)
		var refilled := _ray(p)
		ok(not is_equal_approx(before, refilled), "the neighbour changes the blended height (%s -> %s)" % [before, refilled])
		ok(is_equal_approx(after, refilled), "shapes next to the new neighbour refilled (%s, full refill %s)" % [after, refilled])
		_t.remove_collision_target(te)
		_t.material.world_background = Terrain3DMaterial.NONE
	else:
		print("NOTE: headless, world background blend check skipped (no material uniforms)")
	_t.remove_collision_target(ta)

	# Without any camera, collision still follows its targets.
	cam.free()
	_t.clear_collision_targets()
	var tn := _node_at(a)
	_t.add_collision_target(tn, RADIUS_M)
	await _frames()
	tn.global_position = b
	await _frames(5)
	ok(is_equal_approx(_ray(b + Vector3(1, 0, 1)), 30.0), "no camera: the target moved and has ground (%s)" % _ray(b + Vector3(1, 0, 1)))
	ok(is_nan(_ray(a + Vector3(1, 0, 1))), "no camera: its old ground released")
	# Mode round trips without a camera: processing must resume for dynamic collision.
	for mode in [0, 3]: # Disabled, Full / Game
		_t.collision_mode = mode
		await _frames()
		_t.collision_mode = 1
		tn.global_position = a if tn.global_position == b else b
		await _frames(5)
		var want := 10.0 if tn.global_position == a else 30.0
		ok(is_equal_approx(_ray(tn.global_position + Vector3(1, 0, 1)), want),
				"no camera, mode %d -> dynamic: ground follows the moved target" % mode)
	# Back to the stock collision_target without a camera: it is still followed.
	_t.clear_collision_targets()
	stock_target.global_position = b
	await _frames(5)
	ok(is_equal_approx(_ray(b + Vector3(1, 0, 1)), 30.0), "no camera, stock target: ground follows it (%s)" % _ray(b + Vector3(1, 0, 1)))
	ok(_t.is_physics_processing(), "no camera, stock target: processing stays on")
	# Nothing to follow: processing stops (stock); a camera alone resumes it.
	_t.set_collision_target(null)
	await _frames()
	ok(not _t.is_physics_processing(), "nothing to follow and no camera: processing stops (stock)")
	var cam2 := Camera3D.new()
	root.add_child(cam2)
	_t.set_camera(cam2)
	ok(_t.is_physics_processing(), "a camera alone resumes processing")

	print("STATS final %s" % _stats())
	_t.free()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
