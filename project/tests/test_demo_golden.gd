extends SceneTree
## Barge Game addition. Golden test: the demo terrain answers data queries exactly as the
## stock v1.1.0 library did. It guards every fork change against changing worlds that
## stock could already load (all inside the old ±16 region window).
##   godot --headless --path project --script res://tests/test_demo_golden.gd
##   godot --headless --path project --script res://tests/test_demo_golden.gd -- --record
## --record rewrites tests/golden/demo_stock.json; only do that with the stock library.
## Exits with the number of failed checks (0 = pass).

const GOLDEN := "res://tests/golden/demo_stock.json"
const DATA_DIR := "res://demo/data"
const STEP := 7.3 # metres; not a divisor of the region size, so samples hit many offsets

var _fail := 0
var _started := false


func ok(c: bool, m: String) -> void:
	if not c:
		print("FAIL " + m)
		_fail += 1


func _initialize() -> void:
	process_frame.connect(_run)


func _run() -> void:
	if _started:
		return
	_started = true
	var cam := Camera3D.new()
	root.add_child(cam)
	var t := Terrain3D.new()
	root.add_child(t)
	await process_frame
	t.data_directory = DATA_DIR
	await process_frame

	var samples := _sample(t)
	if "--record" in OS.get_cmdline_user_args():
		var f := FileAccess.open(GOLDEN, FileAccess.WRITE)
		f.store_string(JSON.stringify(samples, "\t"))
		f.close()
		print("Recorded %d samples to %s" % [samples["points"].size(), GOLDEN])
	else:
		_compare(samples)
	t.free()
	cam.free()
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)


func _sample(t: Terrain3D) -> Dictionary:
	var locs: Array = []
	for loc: Vector2i in t.data.get_region_locations():
		locs.append([loc.x, loc.y])
	locs.sort()
	var rs: float = t.region_size * t.vertex_spacing
	var points: Array = []
	# One region beyond the data on every side, so "no region" answers are covered too.
	var lo := Vector2i(1 << 30, 1 << 30)
	var hi := -lo
	for l: Array in locs:
		lo = Vector2i(mini(lo.x, l[0]), mini(lo.y, l[1]))
		hi = Vector2i(maxi(hi.x, l[0]), maxi(hi.y, l[1]))
	var x := (lo.x - 1) * rs + 0.37
	while x < (hi.x + 2) * rs:
		var z := (lo.y - 1) * rs + 0.61
		while z < (hi.y + 2) * rs:
			var p := Vector3(x, 0.0, z)
			var h: float = t.data.get_height(p)
			var n: Vector3 = t.data.get_normal(p)
			points.append({
				"p": [x, z],
				"h": h if not is_nan(h) else "nan",
				"n": [n.x, n.y, n.z] if not is_nan(n.x) else "nan",
				"r": t.data.has_regionp(p),
				"c": t.data.get_control(p),
			})
			z += STEP * 17.0
		x += STEP * 13.0
	return {
		"region_size": t.region_size,
		"vertex_spacing": t.vertex_spacing,
		"regions": locs,
		"points": points,
	}


func _compare(samples: Dictionary) -> void:
	var f := FileAccess.open(GOLDEN, FileAccess.READ)
	ok(f != null, "golden file %s exists" % GOLDEN)
	if f == null:
		return
	var golden: Dictionary = JSON.parse_string(f.get_as_text())
	ok(int(golden["region_size"]) == samples["region_size"], "region size %s" % samples["region_size"])
	ok(_same_value(golden["regions"], samples["regions"]), "region list %s" % [samples["regions"]])
	var gp: Array = golden["points"]
	ok(gp.size() == samples["points"].size(), "sample count %d vs golden %d" % [samples["points"].size(), gp.size()])
	var bad := 0
	for i in mini(gp.size(), samples["points"].size()):
		var a: Dictionary = gp[i]
		var b: Dictionary = samples["points"][i]
		var same: bool = _same_value(a["h"], b["h"]) and _same_value(a["n"], b["n"])
		same = same and bool(a["r"]) == bool(b["r"]) and int(a["c"]) == int(b["c"])
		if not same:
			bad += 1
			if bad <= 10:
				ok(false, "sample %d at %s: golden %s, now %s" % [i, b["p"], a, b])
	if bad > 10:
		ok(false, "... %d samples differ in total" % bad)
	print("Compared %d samples, %d differ" % [gp.size(), bad])


# Values come from JSON (floats, arrays of floats, or the string "nan"). Exact JSON text
# must match, or the numbers must be equal within float rounding.
func _same_value(a: Variant, b: Variant) -> bool:
	if str(a) == str(b):
		return true
	if (a is float or a is int) and (b is float or b is int):
		return is_equal_approx(float(a), float(b))
	if a is Array and b is Array and a.size() == b.size():
		for i in a.size():
			if not _same_value(a[i], b[i]):
				return false
		return true
	return false
