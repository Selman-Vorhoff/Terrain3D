extends SceneTree
## Barge Game addition. On D3D12 a pool texture array may not have more than 4096
## subresources (layers x mip levels), and the pool allocates its whole capacity at the
## first insert. A capacity over the limit must be refused before anything is allocated,
## and one at the limit must work. Runs only with the D3D12 driver:
##   tools/terrain3d_fork/test.py --windowed --driver d3d12 pool_d3d12_limit
## Elsewhere it skips and passes.
## expect-error: over the D3D12 limit of 4096

const RS := 64 # 7 mip levels when the colour map has mipmaps

var _fail := 0
var _started := false


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
	img.fill(Color(1.0, 0.0, 0.0))
	r.set_height_map(img)
	var colour := Image.create_empty(RS, RS, true, Image.FORMAT_RGBA8)
	colour.fill(Color.WHITE)
	r.set_color_map(colour)
	return r


func _run() -> void:
	if _started:
		return
	_started = true
	if RenderingServer.get_current_rendering_driver_name() != "d3d12":
		print("SKIP: needs the D3D12 driver (got %s)" % RenderingServer.get_current_rendering_driver_name())
		print("RESULT PASS (0 failed)")
		quit(0)
		return
	var mips := 0
	var n := RS
	while n > 1:
		n >>= 1
		mips += 1
	var levels := mips + 1
	var at_limit := 4096 / levels
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.make_current()
	for case in [[at_limit + 1, false], [at_limit, true]]:
		var t := Terrain3D.new()
		root.add_child(t)
		t.set_camera(cam)
		await process_frame
		t.change_region_size(RS)
		t.material.max_regions = 1024
		t.data.enable_streaming(case[0])
		var err: int = t.data.add_region(_make_region(Vector2i(0, 0)))
		ok((err == OK) == case[1], "capacity %d (x %d levels = %d subresources): add %s"
				% [case[0], levels, case[0] * levels, "works" if case[1] else "refused"])
		var stats: Dictionary = t.data.get_streaming_stats()
		if case[1]:
			ok(stats["bytes_resident"] > 0 and stats["bytes_allocated"] == stats["bytes_resident"] * case[0],
					"stats report allocated and resident bytes (%s / %s)" % [stats["bytes_allocated"], stats["bytes_resident"]])
		else:
			ok(not t.data.has_region(Vector2i(0, 0)), "nothing resident after the refusal")
		t.free()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
