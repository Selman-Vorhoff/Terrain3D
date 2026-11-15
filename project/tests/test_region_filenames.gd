extends SceneTree
## Barge Game addition. Headless test for region file names at any signed location:
##   godot --headless --path project --script res://tests/test_region_filenames.gd
## Exits with the number of failed checks (0 = pass).

var _fail := 0
var _started := false


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


func _initialize() -> void:
	process_frame.connect(_run)


func _run() -> void:
	if _started:
		return
	_started = true
	_names_unchanged_inside_stock_range()
	_round_trip_any_location()
	_malformed_names_rejected()
	await _stock_folder_loads()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)


# Stock wrote and read every location in -99..99; those names must not change.
func _names_unchanged_inside_stock_range() -> void:
	var expected := {
		Vector2i(0, 0): "terrain3d_00_00.res",
		Vector2i(-1, 2): "terrain3d-01_02.res",
		Vector2i(15, -16): "terrain3d_15-16.res",
		Vector2i(-99, 99): "terrain3d-99_99.res",
		Vector2i(-5, -7): "terrain3d-05-07.res",
	}
	for loc: Vector2i in expected:
		var name: String = Terrain3DUtil.location_to_filename(loc)
		ok(name == expected[loc], "stock name for %s: %s" % [loc, name])
		ok(Terrain3DUtil.filename_to_location(expected[loc]) == loc, "stock name %s reads back" % expected[loc])


func _round_trip_any_location() -> void:
	var locs: Array[Vector2i] = [
		Vector2i(100, 0), Vector2i(0, -100), Vector2i(-100, 100), Vector2i(-1234, 5678),
		Vector2i(99999, -99999), Vector2i(-2147483648, 2147483646),
	]
	for loc in locs:
		var name: String = Terrain3DUtil.location_to_filename(loc)
		var back: Vector2i = Terrain3DUtil.filename_to_location(name)
		ok(back == loc, "round trip %s via %s -> %s" % [loc, name, back])
	ok(Terrain3DUtil.location_to_filename(Vector2i(100, -1234)) == "terrain3d_100-1234.res",
			"wide name format is _100-1234")
	# Names must stay unique: distinct locations never share a file name.
	var seen := {}
	var unique := true
	for x in range(-120, 121, 7):
		for y in range(-120, 121, 11):
			var name: String = Terrain3DUtil.location_to_filename(Vector2i(x, y))
			if seen.has(name):
				unique = false
			seen[name] = true
	ok(unique, "names are unique over -120..120")


func _malformed_names_rejected() -> void:
	var bad: Array[String] = [
		"terrain3d.res", "terrain3d_00.res", "terrain3d00_00.res", "terrain3d_0a_00.res",
		"terrain3d_00_.res", "terrain3d__00_00.res", "terrain3d_00_00_00.res",
		"terrain3d_99999999999_00.res", "terrain3d_2147483647_00.res",
	]
	for name in bad:
		var loc: Vector2i = Terrain3DUtil.filename_to_location(name)
		ok(loc.x == 2147483647, "malformed %s rejected" % name)


# A folder written with stock names (locations inside ±16) loads with the same locations
# and heights.
func _stock_folder_loads() -> void:
	var dir := "user://barge_filename_test"
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + "/" + f)

	var cam := Camera3D.new()
	root.add_child(cam)
	var t := Terrain3D.new()
	root.add_child(t)
	await process_frame
	var locs: Array[Vector2i] = [Vector2i(-16, -16), Vector2i(-1, 2), Vector2i(0, 0), Vector2i(15, 15)]
	for loc in locs:
		t.data.add_region_blank(loc, false)
		var r: Terrain3DRegion = t.data.get_region(loc)
		r.get_height_map().fill(Color(float(loc.x * 100 + loc.y), 0, 0))
		r.set_modified(true)
	t.data.update_maps()
	for loc in locs:
		t.data.save_region(loc, dir, false)
	t.free()

	var t2 := Terrain3D.new()
	root.add_child(t2)
	await process_frame
	t2.data.load_directory(dir)
	ok(t2.data.get_region_count() == locs.size(), "loaded %d regions" % t2.data.get_region_count())
	var rs: int = t2.region_size
	for loc in locs:
		var p := Vector3((loc.x + 0.5) * rs, 0.0, (loc.y + 0.5) * rs)
		var h: float = t2.data.get_height(p)
		ok(t2.data.has_region(loc) and is_equal_approx(h, float(loc.x * 100 + loc.y)),
				"region %s loaded with height %s" % [loc, h])
	t2.free()
	cam.free()
