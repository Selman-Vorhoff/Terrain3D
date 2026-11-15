extends SceneTree
## Barge Game addition. The C# wrappers in addons/terrain_3d/csharp/ call the native classes
## by name. Every name in their GDExtensionMethodName, GDExtensionPropertyName and
## GDExtensionSignalName blocks must exist on that class, so a wrapper for a fork method
## (entries 3, 4, 6) cannot carry a typo or point at a method that is not bound.
## Exits with the number of failed checks (0 = pass).

const DIR := "res://addons/terrain_3d/csharp/"

var _fail := 0


func ok(c: bool, m: String) -> void:
	if not c:
		print("FAIL " + m)
		_fail += 1


func _initialize() -> void:
	var name_re := RegEx.create_from_string("StringName\\s+(\\w+)\\s*=\\s*\"([^\"]+)\"")
	var block_re := RegEx.create_from_string("class GDExtension(Method|Property|Signal)Name")
	var checked := 0
	for file in DirAccess.get_files_at(DIR):
		if not file.ends_with(".cs"):
			continue
		var cls := file.get_basename()
		if not ClassDB.class_exists(cls):
			ok(false, "%s: no native class %s" % [file, cls])
			continue
		var kind := ""
		for line in FileAccess.get_file_as_string(DIR + file).split("\n"):
			var block := block_re.search(line)
			if block:
				kind = block.get_string(1)
				continue
			var m := name_re.search(line)
			if m == null or kind == "":
				continue
			var native := m.get_string(2)
			var found := false
			match kind:
				"Method":
					found = ClassDB.class_has_method(cls, native)
				"Property":
					found = native in ClassDB.class_get_property_list(cls).map(func(p: Dictionary) -> String: return p.name)
				"Signal":
					found = ClassDB.class_has_signal(cls, native)
			ok(found, "%s: %s %s ('%s') not found on %s" % [file, kind.to_lower(), m.get_string(1), native, cls])
			checked += 1
	print("PASS checked %d wrapper names" % checked)
	ok(checked > 300, "expected the full wrapper set, checked only %d" % checked)
	for n in ["add_collision_target", "remove_collision_target", "clear_collision_targets", "get_collision_targets"]:
		ok(ClassDB.class_has_method("Terrain3D", n), "Terrain3D.%s bound" % n)
	print("RESULT %s (%d failed)" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
