extends Node2D

# tilemap layers
@export var ground_layer_path: NodePath = NodePath("Ground")
@export var walls_layer_path: NodePath = NodePath("Walls")
@onready var ground: TileMapLayer = get_node_or_null(ground_layer_path) as TileMapLayer
@onready var walls: TileMapLayer = get_node_or_null(walls_layer_path) as TileMapLayer

# remote players
@export var remote_player_scene: PackedScene

# enemy spawning
@export var enemy_scene: PackedScene
@export var enemy_spawn_tiles: Array[Vector2i] = [Vector2i(6, 6)]
@export var enemy_respawn_seconds: float = 3.0

var enemies_by_tile: Dictionary = {} # Vector2i -> Enemy
var enemies_by_id: Dictionary = {}   # int -> Enemy

var remote_by_identity: Dictionary = {} # String -> Node (RemotePlayer)

# STDB poll
@export var poll_seconds: float = 0.30
var _poll_left: float = 0.0


func _enter_tree() -> void:
	ground = get_node_or_null(ground_layer_path) as TileMapLayer
	walls = get_node_or_null(walls_layer_path) as TileMapLayer
	assert(ground != null, "ground_layer_path must point to a TileMapLayer (e.g. 'Ground').")
	assert(walls != null, "walls_layer_path must point to a TileMapLayer (e.g. 'Walls').")


func _ready() -> void:
	spawn_initial_enemies()

	# connect STDB SQL results
	if SpacetimeClient.sql_result.is_connected(_on_sql_result) == false:
		SpacetimeClient.sql_result.connect(_on_sql_result)


func _process(delta: float) -> void:
	_poll_left -= delta
	if _poll_left > 0.0:
		return
	_poll_left = poll_seconds

	# pull online players
	var q := "SELECT identity, x, y, facing_x, facing_y, online FROM player;"
	SpacetimeClient.sql(q)


# --- Coordinate helpers ---
func tile_to_world(t: Vector2i) -> Vector2:
	return ground.map_to_local(t)

func world_to_tile(p: Vector2) -> Vector2i:
	assert(ground != null, "Ground layer is null. Check ground_layer_path on World.")
	return ground.local_to_map(p)

# --- Collision ---
func is_blocked(tile: Vector2i) -> bool:
	return walls.get_cell_source_id(tile) != -1

func can_step(from_tile: Vector2i, dir: Vector2i) -> bool:
	if dir == Vector2i.ZERO:
		return false

	var to_tile := from_tile + dir
	if is_blocked(to_tile):
		return false

	# prevent corner cutting
	if dir.x != 0 and dir.y != 0:
		var side_a := from_tile + Vector2i(dir.x, 0)
		var side_b := from_tile + Vector2i(0, dir.y)
		if is_blocked(side_a) or is_blocked(side_b):
			return false

	return true


# --- Pathing ---
func get_path_tiles(from_tile: Vector2i, to_tile: Vector2i) -> Array[Vector2i]:
	if from_tile == to_tile:
		return []
	if is_blocked(to_tile):
		return []

	var dirs: Array[Vector2i] = [
		Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1),
		Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1),
	]

	var open: Array[Vector2i] = [from_tile]
	var came_from: Dictionary = {}
	var g_score: Dictionary = { from_tile: 0 }

	while open.size() > 0:
		var current: Vector2i = open[0]
		var current_f: int = int(g_score[current]) + _heuristic_octile(current, to_tile)

		for t in open:
			var f: int = int(g_score[t]) + _heuristic_octile(t, to_tile)
			if f < current_f:
				current = t
				current_f = f

		if current == to_tile:
			return _reconstruct_path(came_from, current, from_tile)

		open.erase(current)

		var current_g: int = int(g_score[current])

		for d in dirs:
			if not can_step(current, d):
				continue

			var neighbor: Vector2i = current + d
			var step_cost: int = 14 if (d.x != 0 and d.y != 0) else 10
			var tentative_g: int = current_g + step_cost

			if not g_score.has(neighbor) or tentative_g < int(g_score[neighbor]):
				came_from[neighbor] = current
				g_score[neighbor] = tentative_g
				if not open.has(neighbor):
					open.append(neighbor)

	return []

func _heuristic_octile(a: Vector2i, b: Vector2i) -> int:
	var dx: int = absi(a.x - b.x)
	var dy: int = absi(a.y - b.y)
	var min_d: int = min(dx, dy)
	var max_d: int = max(dx, dy)
	return 14 * min_d + 10 * (max_d - min_d)

func _reconstruct_path(came_from: Dictionary, current: Vector2i, start: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	while current != start:
		path.append(current)
		current = came_from[current]
	path.reverse()
	return path


# --- Enemies ---
func register_enemy(e: Enemy) -> void:
	enemies_by_tile[e.tile_pos] = e
	enemies_by_id[e.get_instance_id()] = e

func unregister_enemy(e: Enemy) -> void:
	if enemies_by_tile.get(e.tile_pos) == e:
		enemies_by_tile.erase(e.tile_pos)
	enemies_by_id.erase(e.get_instance_id())

func get_enemy_at(tile: Vector2i) -> Enemy:
	return enemies_by_tile.get(tile, null)

func get_enemy_by_id(id: int) -> Enemy:
	return enemies_by_id.get(id, null)

func spawn_enemy_at(tile: Vector2i) -> Enemy:
	if enemy_scene == null:
		push_error("World.enemy_scene is not set.")
		return null

	if is_blocked(tile) or enemies_by_tile.has(tile):
		return null

	var e := enemy_scene.instantiate() as Enemy
	add_child(e)
	e.set_tile(self, tile)
	register_enemy(e)
	return e

func spawn_initial_enemies() -> void:
	for t in enemy_spawn_tiles:
		spawn_enemy_at(t)

func kill_enemy(e: Enemy) -> void:
	if e == null:
		return
	var death_tile := e.tile_pos
	unregister_enemy(e)
	e.queue_free()
	_respawn_enemy_later(death_tile)

func _respawn_enemy_later(tile: Vector2i) -> void:
	await get_tree().create_timer(enemy_respawn_seconds).timeout

	var spawn_tile := tile
	if is_blocked(spawn_tile) or enemies_by_tile.has(spawn_tile):
		spawn_tile = _find_nearby_open_tile(tile)

	spawn_enemy_at(spawn_tile)

func _find_nearby_open_tile(origin: Vector2i) -> Vector2i:
	for r in range(1, 10):
		for y in range(origin.y - r, origin.y + r + 1):
			for x in range(origin.x - r, origin.x + r + 1):
				var t := Vector2i(x, y)
				if not is_blocked(t) and not enemies_by_tile.has(t):
					return t
	return origin

func get_best_approach_tile(from_tile: Vector2i, enemy_tile: Vector2i) -> Vector2i:
	var candidates: Array[Vector2i] = [
		enemy_tile + Vector2i(1, 0),
		enemy_tile + Vector2i(-1, 0),
		enemy_tile + Vector2i(0, 1),
		enemy_tile + Vector2i(0, -1),
		enemy_tile + Vector2i(1, 1),
		enemy_tile + Vector2i(1, -1),
		enemy_tile + Vector2i(-1, 1),
		enemy_tile + Vector2i(-1, -1),
	]

	var best_tile: Vector2i = from_tile
	var best_len: int = 999999

	for t in candidates:
		if is_blocked(t): continue
		if enemies_by_tile.has(t): continue

		var path: Array[Vector2i] = get_path_tiles(from_tile, t)
		if path.size() == 0: continue

		if path.size() < best_len:
			best_len = path.size()
			best_tile = t

	return best_tile


# --- STDB Remote Players (poll via SQL) ---
func _on_sql_result(query: String, payload: Variant) -> void:
	# Normalize payload into: rows = Array where each element is a row Array
	var rows: Array = []

	# Case A: payload is a dict: { schema, rows, stats, ... }
	if typeof(payload) == TYPE_DICTIONARY:
		var d: Dictionary = payload as Dictionary
		if d.has("rows") and typeof(d["rows"]) == TYPE_ARRAY:
			rows = d["rows"] as Array
		elif d.has("result") and typeof(d["result"]) == TYPE_ARRAY:
			# Some wrappers might use "result"
			rows = d["result"] as Array

	# Case B: payload is an array (often a wrapper or mixed contents)
	elif typeof(payload) == TYPE_ARRAY:
		var a: Array = payload as Array
		if a.is_empty():
			return

		# Common shapes:
		# 1) [ {schema, rows, ...} ]
		# 2) [ [row,row,...], {schema/stats...} ]
		# 3) [ [row,row,...] ]
		# 4) [ row, row, row, {schema/stats...} ]  <-- this is what your logs show

		var first: Variant = a[0]

		if typeof(first) == TYPE_DICTIONARY:
			var d0: Dictionary = first as Dictionary
			if d0.has("rows") and typeof(d0["rows"]) == TYPE_ARRAY:
				rows = d0["rows"] as Array
		elif typeof(first) == TYPE_ARRAY:
			# If the first element is itself an array of rows, use it directly.
			# Example: payload[0] == [ [row...], [row...], ... ]
			# We still need to detect if it's a single row vs list-of-rows:
			var maybe_rows: Array = first as Array
			if maybe_rows.size() > 0 and typeof(maybe_rows[0]) == TYPE_ARRAY:
				rows = maybe_rows
			else:
				# It's a single row; treat payload as list-of-rows and filter later.
				rows = a
		else:
			# Unknown wrapper; treat as list and filter later.
			rows = a

	# If payload is something unexpected, bail
	else:
		return

	# Filter out non-row elements (like the schema/stats Dictionary)
	var normalized_rows: Array = []
	for item in rows:
		if typeof(item) == TYPE_ARRAY:
			normalized_rows.append(item)
		elif typeof(item) == TYPE_DICTIONARY:
			# Sometimes the array contains a dict that itself has "rows"
			var dd: Dictionary = item as Dictionary
			if dd.has("rows") and typeof(dd["rows"]) == TYPE_ARRAY:
				var inner: Array = dd["rows"] as Array
				for inner_item in inner:
					if typeof(inner_item) == TYPE_ARRAY:
						normalized_rows.append(inner_item)

	rows = normalized_rows

	# Debug (keep short)
	# print("[CLIENT] SQL normalized rows = %d" % rows.size())
	# print("[CLIENT] My identity: %s" % SpacetimeClient.identity)

	var seen: Dictionary = {} # identity -> true

	for i in range(rows.size()):
		var r: Variant = rows[i]
		if typeof(r) != TYPE_ARRAY:
			continue

		var row_array: Array = r as Array
		# Expected: identity, x, y, facing_x, facing_y, online
		if row_array.size() < 6:
			continue

		var ident_raw: Variant = row_array[0]
		var ident: String = ""

		# Your identity sometimes shows up wrapped like ["0x..."] in the logs
		if typeof(ident_raw) == TYPE_ARRAY:
			var ident_arr: Array = ident_raw as Array
			if ident_arr.size() > 0:
				ident = str(ident_arr[0])
		else:
			ident = str(ident_raw)

		if ident == "" or ident == "null":
			continue
		
		var my_id := _norm_identity(SpacetimeClient.identity)
		ident = _norm_identity(ident)
		# skip self
		if ident == my_id:
			continue

		var online: bool = bool(row_array[5])
		if not online:
			continue

		seen[ident] = true

		var x: int = int(row_array[1])
		var y: int = int(row_array[2])
		var fx: int = int(row_array[3])
		var fy: int = int(row_array[4])
		ident = _norm_identity(ident)
		_upsert_remote_player(ident, Vector2i(x, y), Vector2i(fx, fy))

	# cleanup remotes not seen this tick
	var to_remove: Array[String] = []
	for k in remote_by_identity.keys():
		var idstr: String = str(k)
		if not seen.has(idstr):
			to_remove.append(idstr)

	for idstr in to_remove:
		var node: Node = remote_by_identity.get(idstr, null) as Node
		if node != null:
			node.queue_free()
		remote_by_identity.erase(idstr)

func _type_to_string(type: int) -> String:
	match type:
		TYPE_NIL: return "NIL"
		TYPE_BOOL: return "BOOL"
		TYPE_INT: return "INT"
		TYPE_FLOAT: return "FLOAT"
		TYPE_STRING: return "STRING"
		TYPE_VECTOR2: return "VECTOR2"
		TYPE_VECTOR2I: return "VECTOR2I"
		TYPE_RECT2: return "RECT2"
		TYPE_RECT2I: return "RECT2I"
		TYPE_VECTOR3: return "VECTOR3"
		TYPE_VECTOR3I: return "VECTOR3I"
		TYPE_TRANSFORM2D: return "TRANSFORM2D"
		TYPE_VECTOR4: return "VECTOR4"
		TYPE_VECTOR4I: return "VECTOR4I"
		TYPE_PLANE: return "PLANE"
		TYPE_QUATERNION: return "QUATERNION"
		TYPE_AABB: return "AABB"
		TYPE_BASIS: return "BASIS"
		TYPE_TRANSFORM3D: return "TRANSFORM3D"
		TYPE_PROJECTION: return "PROJECTION"
		TYPE_COLOR: return "COLOR"
		TYPE_STRING_NAME: return "STRING_NAME"
		TYPE_NODE_PATH: return "NODE_PATH"
		TYPE_RID: return "RID"
		TYPE_OBJECT: return "OBJECT"
		TYPE_CALLABLE: return "CALLABLE"
		TYPE_SIGNAL: return "SIGNAL"
		TYPE_DICTIONARY: return "DICTIONARY"
		TYPE_ARRAY: return "ARRAY"
		TYPE_PACKED_BYTE_ARRAY: return "PACKED_BYTE_ARRAY"
		TYPE_PACKED_INT32_ARRAY: return "PACKED_INT32_ARRAY"
		TYPE_PACKED_INT64_ARRAY: return "PACKED_INT64_ARRAY"
		TYPE_PACKED_FLOAT32_ARRAY: return "PACKED_FLOAT32_ARRAY"
		TYPE_PACKED_FLOAT64_ARRAY: return "PACKED_FLOAT64_ARRAY"
		TYPE_PACKED_STRING_ARRAY: return "PACKED_STRING_ARRAY"
		TYPE_PACKED_VECTOR2_ARRAY: return "PACKED_VECTOR2_ARRAY"
		TYPE_PACKED_VECTOR3_ARRAY: return "PACKED_VECTOR3_ARRAY"
		TYPE_PACKED_COLOR_ARRAY: return "PACKED_COLOR_ARRAY"
		_: return "UNKNOWN(%d)" % type

func _upsert_remote_player(ident: String, pos: Vector2i, face: Vector2i) -> void:
	if remote_player_scene == null:
		print("[CLIENT] ERROR: remote_player_scene is null! Cannot spawn remote player.")
		return

	var rp = remote_by_identity.get(ident, null)
	if rp == null:
		print("[CLIENT] Spawning new remote player: identity=%s, pos=(%d, %d)" % [ident, pos.x, pos.y])
		rp = remote_player_scene.instantiate()
		add_child(rp)
		remote_by_identity[ident] = rp
		# Set the world reference for the remote player
		if rp.has_method("set_world"):
			rp.set_world(self)
	else:
		print("[CLIENT] Updating remote player: identity=%s, pos=(%d, %d), facing=(%d, %d)" % 
			[ident, pos.x, pos.y, face.x, face.y])

	# Support either "apply_state" or "set_state" style.
	if rp.has_method("apply_state"):
		rp.apply_state(pos, face)
	elif rp.has_method("set_state"):
		rp.set_state(pos, face)
	else:
		# fallback: just teleport
		rp.global_position = tile_to_world(pos)
		
func _norm_identity(s: String) -> String:
	var t := s.strip_edges().to_lower()
	if t.begins_with("0x"):
		t = t.substr(2)
	return t
