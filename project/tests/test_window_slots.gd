extends SceneTree
## Barge Game addition. GPU slots follow the region window: resident regions outside the
## window are CPU data only (no slot, no texture layer), regions entering the window take a
## slot and upload their maps, regions leaving give it back. A window holding more resident
## regions than slots leaves the rest data only, reported, until a slot comes free.
## GPU layer contents are read back only with a real renderer:
##   tools/terrain3d_fork/test.py --windowed window_slots
## Exits with the number of failed checks (0 = pass).
## expect-error: Slot pool exhausted

const RS := 64
const CAPACITY := 4

var _fail := 0
var _started := false
var _gpu := false
var _t: Terrain3D


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	process_frame.connect(_run)


func _make_region(loc: Vector2i, height: float) -> Terrain3DRegion:
	var r := Terrain3DRegion.new()
	r.set_location(loc)
	r.set_region_size(RS)
	r.set_vertex_spacing(1.0)
	var img := Image.create_empty(RS, RS, false, Image.FORMAT_RF)
	img.fill(Color(height, 0.0, 0.0))
	r.set_height_map(img)
	return r


func _centre(loc: Vector2i) -> Vector3:
	return Vector3((loc.x + 0.5) * RS, 0.0, (loc.y + 0.5) * RS)


func _gpu_height(loc: Vector2i) -> float:
	var slot: int = _t.data.get_region_id(loc)
	if slot < 0:
		return NAN
	var img: Image = RenderingServer.texture_2d_layer_get(_t.data.get_height_maps_rid(), slot)
	return img.get_pixel(RS / 2, RS / 2).r if img and not img.is_empty() else NAN


func _stats() -> Dictionary:
	return _t.data.get_streaming_stats()


func _run() -> void:
	if _started:
		return
	_started = true
	_gpu = DisplayServer.get_name() != "headless"
	if not _gpu:
		print("NOTE: headless, GPU layer readback checks skipped")
	var cam := Camera3D.new()
	root.add_child(cam)
	_t = Terrain3D.new()
	root.add_child(_t)
	_t.set_camera(cam)
	await process_frame
	_t.change_region_size(RS)
	var d: Terrain3DData = _t.data
	d.enable_streaming(CAPACITY)

	# Three regions far outside the default window: resident, data only.
	var far: Array[Vector2i] = [Vector2i(500, 500), Vector2i(501, 500), Vector2i(500, 501)]
	for i in far.size():
		ok(d.add_region(_make_region(far[i], 10.0 + i)) == OK, "add %s outside the window" % far[i])
	ok(int(_stats()["slots_used"]) == 0, "no slot used for regions outside the window")
	ok(int(_stats()["regions_resident"]) == 3, "three resident")
	for i in far.size():
		ok(d.has_region(far[i]) and d.get_region_id(far[i]) == -1, "%s resident without a slot" % far[i])
		ok(is_equal_approx(d.get_height(_centre(far[i])), 10.0 + i), "%s answers get_height" % far[i])
		ok(not d.get_normal(_centre(far[i])).is_zero_approx() and not is_nan(d.get_normal(_centre(far[i])).y),
				"%s answers get_normal" % far[i])

	# Edit a data-only region; the edit must reach the GPU when the window arrives.
	d.set_height(_centre(far[0]), 77.0)
	d.update_maps()
	ok(is_equal_approx(d.get_height(_centre(far[0])), 77.0), "data-only region edited on the CPU")

	# Window over them: they take slots and upload.
	var uploads_before := int(_stats()["uploads"])
	d.set_region_window_origin(Vector2i(490, 490))
	ok(int(_stats()["slots_used"]) == 3, "window arrives: three slots used")
	ok(int(_stats()["uploads"]) == uploads_before + 3, "three uploads when the window arrives")
	for loc in far:
		ok(d.get_region_id(loc) >= 0 and d.get_region_map()[d.get_region_map_index(loc)] == d.get_region_id(loc) + 1,
				"%s drawn: slot and map entry" % loc)
	if _gpu:
		ok(is_equal_approx(_gpu_height(far[0]), 77.0), "GPU layer holds the edit made while data only (%s)" % _gpu_height(far[0]))
		ok(is_equal_approx(_gpu_height(far[1]), 11.0), "GPU layer of %s right" % far[1])

	# More regions in the window than slots: the extra stays data only, reported.
	ok(d.add_region(_make_region(Vector2i(502, 500), 20.0)) == OK, "fourth region inside the window")
	ok(d.add_region(_make_region(Vector2i(503, 500), 21.0)) == OK, "fifth region inside the window, pool full")
	ok(int(_stats()["slots_used"]) == CAPACITY, "all %d slots used" % CAPACITY)
	ok(int(_stats()["regions_undrawn"]) == 1, "one region undrawn")
	ok(d.get_region_id(Vector2i(503, 500)) == -1 and is_equal_approx(d.get_height(_centre(Vector2i(503, 500))), 21.0),
			"the undrawn region answers queries")

	# Window away: every slot returns; the regions stay resident.
	d.set_region_window_origin(Vector2i(-16, -16))
	ok(int(_stats()["slots_used"]) == 0 and d.get_free_slot_count() == CAPACITY, "window leaves: every slot free")
	ok(int(_stats()["regions_undrawn"]) == 0, "nothing undrawn outside the window")
	ok(int(_stats()["regions_resident"]) == 5, "all five still resident")
	var map_entries := 0
	for v in d.get_region_map():
		map_entries += 1 if v != 0 else 0
	ok(map_entries == 0, "region map empty")

	# Back again: four drawn, one undrawn; evicting a drawn one hands its slot over.
	d.set_region_window_origin(Vector2i(490, 490))
	ok(int(_stats()["slots_used"]) == CAPACITY and int(_stats()["regions_undrawn"]) == 1, "back: four drawn, one undrawn")
	var undrawn := Vector2i(-1, -1)
	for loc in [Vector2i(500, 500), Vector2i(501, 500), Vector2i(500, 501), Vector2i(502, 500), Vector2i(503, 500)]:
		if d.get_region_id(loc) == -1:
			undrawn = loc
	ok(undrawn != Vector2i(-1, -1), "found the undrawn region %s" % undrawn)
	var victim := Vector2i(501, 500) if undrawn != Vector2i(501, 500) else Vector2i(500, 501)
	d.evict_region(victim)
	ok(d.get_region_id(undrawn) >= 0, "evicting %s hands its slot to %s" % [victim, undrawn])
	ok(int(_stats()["regions_undrawn"]) == 0, "nothing undrawn")
	if _gpu:
		ok(is_equal_approx(_gpu_height(undrawn), d.get_height(_centre(undrawn))), "GPU layer of %s uploaded on hand-over" % undrawn)

	# Replacing a data-only region keeps it data only and updates its data.
	d.set_region_window_origin(Vector2i(-16, -16))
	ok(d.add_region(_make_region(Vector2i(500, 500), 5.0)) == OK, "replace a data-only region")
	ok(d.get_region_id(Vector2i(500, 500)) == -1 and is_equal_approx(d.get_height(_centre(Vector2i(500, 500))), 5.0),
			"replacement outside the window stays data only with the new data")

	_t.free()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
