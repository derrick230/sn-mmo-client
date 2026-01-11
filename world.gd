extends Node2D

# --- Tilemap layers ---
@export var ground_layer_path: NodePath = NodePath("Ground")
@export var walls_layer_path: NodePath = NodePath("Walls")

@onready var ground: TileMapLayer = get_node_or_null(ground_layer_path) as TileMapLayer
@onready var walls: TileMapLayer = get_node_or_null(walls_layer_path) as TileMapLayer

# --- Enemies / Spawning ---
@export var enemy_scene: PackedScene
@export var enemy_spawn_tiles: Array[Vector2i] = [Vector2i(6, 6)]
@export var enemy_respawn_seconds: float = 3.0

# Player.gd expects these to exist (it iterates enemies_by_id / checks enemies_by_tile)
var enemies_by_tile: Dictionary = {} # Vector2i -> Enemy
var enemies_by_id: Dictionary = {}   # int -> Enemy


func _enter_tree() -> void:
	# Runs before _ready, so Player._ready can safely call world_to_tile()
	ground = get_node_or_null(ground_layer_path) as TileMapLayer
	walls = get_node_or_null(walls_layer_path) as TileMapLayer
	assert(ground != null, "ground_layer_path must point to a TileMapLayer (e.g. 'Ground').")
	assert(walls != null, "walls_layer_path must point to a TileMapLayer (e.g. 'Walls').")


func _ready() -> void:
	assert(ground != null, "ground_layer_path must point to a TileMapLayer.")
	assert(walls != null, "walls_layer_path must point to a TileMapLayer.")
	spawn_initial_enemies()


# ---------------- Coordinate helpers ----------------

func tile_to_world(t: Vector2i) -> Vector2:
	# Use ONE layer for conversions (ground is fine)
	return ground.map_to_local(t)

func world_to_tile(p: Vector2) -> Vector2i:
	assert(ground != null, "Ground layer is null. Check ground_layer_path on the runtime World instance.")
	return ground.local_to_map(p)


# ---------------- Collision ----------------

func is_blocked(tile: Vector2i) -> bool:
	assert(walls != null, "Walls layer is null. Check walls_layer_path on the runtime World instance.")
	# On TileMapLayer you do not pass a layer index
	return walls.get_cell_source_id(tile) != -1


func can_step(from_tile: Vector2i, dir: Vector2i) -> bool:
	if dir == Vector2i.ZERO:
		return false

	var to_tile: Vector2i = from_tile + dir

	# destination must be open
	if is_blocked(to_tile):
		return false

	# Diagonal corner cutting rule
	if dir.x != 0 and dir.y != 0:
		var side_a: Vector2i = from_tile + Vector2i(dir.x, 0)
		var side_b: Vector2i = from_tile + Vector2i(0, dir.y)
		if is_blocked(side_a) or is_blocked(side_b):
			return false

	return true


# ---------------- Pathfinding (A*) ----------------

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
	var came_from: Dictionary = {} # Vector2i -> Vector2i
	var g_score: Dictionary = { from_tile: 0 } # Vector2i -> int

	while open.size() > 0:
		var current: Vector2i = open[0]
		var current_f: int = int(g_score[current]) + _heuristic_octile(current, to_tile)

		for t: Vector2i in open:
			var f: int = int(g_score[t]) + _heuristic_octile(t, to_tile)
			if f < current_f:
				current = t
				current_f = f

		if current == to_tile:
			return _reconstruct_path(came_from, current, from_tile)

		open.erase(current)

		var current_g: int = int(g_score[current])

		for d: Vector2i in dirs:
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


# ---------------- Enemy registry / API used by Player ----------------

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


# ---------------- Spawning / death / respawn ----------------

func spawn_enemy_at(tile: Vector2i) -> Enemy:
	if enemy_scene == null:
		push_error("World.enemy_scene is not set.")
		return null

	# Don't spawn into walls or occupied tiles
	if is_blocked(tile) or enemies_by_tile.has(tile):
		return null

	var e: Enemy = enemy_scene.instantiate() as Enemy
	add_child(e)
	e.set_tile(self, tile) # your Enemy script should set tile_pos + position
	register_enemy(e)
	return e


func spawn_initial_enemies() -> void:
	for t: Vector2i in enemy_spawn_tiles:
		spawn_enemy_at(t)


func kill_enemy(e: Enemy) -> void:
	if e == null:
		return

	var death_tile: Vector2i = e.tile_pos
	unregister_enemy(e)
	e.queue_free()
	_respawn_enemy_later(death_tile)


func _respawn_enemy_later(tile: Vector2i) -> void:
	await get_tree().create_timer(enemy_respawn_seconds).timeout

	var spawn_tile: Vector2i = tile
	if is_blocked(spawn_tile) or enemies_by_tile.has(spawn_tile):
		spawn_tile = _find_nearby_open_tile(tile)

	spawn_enemy_at(spawn_tile)


func _find_nearby_open_tile(origin: Vector2i) -> Vector2i:
	for r: int in range(1, 10):
		for y: int in range(origin.y - r, origin.y + r + 1):
			for x: int in range(origin.x - r, origin.x + r + 1):
				var t: Vector2i = Vector2i(x, y)
				if not is_blocked(t) and not enemies_by_tile.has(t):
					return t
	return origin


# ---------------- Helper used by Player for melee approach ----------------

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

	for t: Vector2i in candidates:
		if is_blocked(t):
			continue
		if enemies_by_tile.has(t):
			continue

		var path: Array[Vector2i] = get_path_tiles(from_tile, t)
		if path.size() == 0:
			continue

		if path.size() < best_len:
			best_len = path.size()
			best_tile = t

	return best_tile
