extends CharacterBody2D

# --- Player HP ---
@export var max_hp: int = 10
var hp: int = 10

# --- Movement ---
@export var move_cooldown: float = 0.30
@onready var sprite: AnimatedSprite2D = $Sprite

var cooldown_left: float = 0.0
var _stepped_this_frame: bool = false

var tile_pos: Vector2i
var facing: Vector2i = Vector2i.DOWN
var walk_target: Vector2i

# Smoothing
var is_moving: bool = false
var move_t: float = 0.0
var start_world: Vector2 = Vector2.ZERO
var target_world: Vector2 = Vector2.ZERO

# Click-to-move queue
var walk_queue: Array[Vector2i] = []

@onready var world := get_parent()

# --- Combat: Pokémon move slots (attack1/attack2/attack3) ---
enum Slot { A1, A2, A3 }

class Move:
	var name: String
	var range_tiles: int
	var cooldown: float
	var damage: int
	func _init(_name: String, _range: int, _cooldown: float, _damage: int) -> void:
		name = _name
		range_tiles = _range
		cooldown = _cooldown
		damage = _damage

var moves: Dictionary = {
	Slot.A1: Move.new("Tackle", 1, 0.6, 1),
	Slot.A2: Move.new("Ember", 3, 0.9, 1),
	Slot.A3: Move.new("Vine Whip", 2, 0.8, 1),
}

@export var acquire_radius: int = 8

var target_enemy_id: int = 0
var active_slot: int = -1
var is_auto_casting: bool = false
var attack_timer: float = 0.0


func _ready() -> void:
	hp = max_hp
	tile_pos = world.world_to_tile(global_position)
	global_position = world.tile_to_world(tile_pos)

	# Mark yourself online and publish initial position to STDB.
	SpacetimeClient.call_set_online(true)
	SpacetimeClient.call_set_pos(tile_pos, facing)


func _exit_tree() -> void:
	# Best-effort offline flag
	SpacetimeClient.call_set_online(false)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var clicked_tile: Vector2i = world.world_to_tile(get_global_mouse_position())

		# Click enemy => select target (and approach if a slot is active)
		var clicked_enemy: Enemy = world.get_enemy_at(clicked_tile)
		if clicked_enemy != null:
			target_enemy_id = clicked_enemy.get_instance_id()

			# If we already have a move selected, start/continue auto-cast and move into range
			if active_slot != -1:
				is_auto_casting = true
				_ensure_in_range_and_path()
			return

		# Click ground => cancels combat and moves
		_clear_combat()
		walk_target = clicked_tile
		walk_queue = world.get_path_tiles(tile_pos, walk_target)


func _process(delta: float) -> void:
	_stepped_this_frame = false

	# Smooth movement in progress
	if is_moving:
		_update_move(delta)
		return

	# Read input once
	var manual_dir: Vector2i = _read_dir8()

	# Attack keys select slot and initiate auto-cast
	if Input.is_action_just_pressed("attack1"):
		_start_auto_cast(Slot.A1)
	if Input.is_action_just_pressed("attack2"):
		_start_auto_cast(Slot.A2)
	if Input.is_action_just_pressed("attack3"):
		_start_auto_cast(Slot.A3)

	# Manual movement cancels combat intent
	if manual_dir != Vector2i.ZERO:
		_clear_combat()
		walk_queue.clear()
		_try_step(delta, manual_dir)
	else:
		# Otherwise follow auto-walk queue
		if walk_queue.size() > 0:
			var next_tile: Vector2i = walk_queue[0]
			var dir: Vector2i = next_tile - tile_pos
			dir.x = clampi(dir.x, -1, 1)
			dir.y = clampi(dir.y, -1, 1)
			_try_step(delta, dir)

	# Auto-cast update (runs when not smoothing)
	_update_auto_cast(delta)

	# If idle
	if not _stepped_this_frame and manual_dir == Vector2i.ZERO and walk_queue.size() == 0 and not is_auto_casting:
		_play_anim(false)


# ---------------- Movement ----------------

func _try_step(delta: float, dir: Vector2i) -> void:
	if cooldown_left > 0.0:
		cooldown_left -= delta
		return
	if dir == Vector2i.ZERO:
		return

	facing = dir

	if _do_step(dir):
		return

	if dir.x != 0 and dir.y != 0:
		if _slide_step(dir):
			return

	# If auto-walking and stuck, repath once
	if walk_queue.size() > 0:
		walk_queue = world.get_path_tiles(tile_pos, walk_target)
		if walk_queue.size() == 0:
			walk_queue.clear()


func _do_step(step_dir: Vector2i) -> bool:
	if step_dir == Vector2i.ZERO:
		return false

	if world.can_step(tile_pos, step_dir):
		tile_pos += step_dir

		# publish to STDB (one call per successful step)
		SpacetimeClient.call_set_pos(tile_pos, facing)

		is_moving = true
		move_t = 0.0
		start_world = global_position
		target_world = world.tile_to_world(tile_pos)

		cooldown_left = move_cooldown

		_stepped_this_frame = true
		_play_anim(true)

		if walk_queue.size() > 0:
			if tile_pos == walk_queue[0]:
				walk_queue.pop_front()
			else:
				walk_queue = world.get_path_tiles(tile_pos, walk_target)

		return true

	return false


func _slide_step(dir: Vector2i) -> bool:
	if dir.x == 0 or dir.y == 0:
		return false

	var try_x_first := true
	if walk_queue.size() > 0:
		var dx: int = walk_target.x - tile_pos.x
		var dy: int = walk_target.y - tile_pos.y
		try_x_first = absi(dx) >= absi(dy)

	if try_x_first:
		if _do_step(Vector2i(dir.x, 0)): return true
		if _do_step(Vector2i(0, dir.y)): return true
	else:
		if _do_step(Vector2i(0, dir.y)): return true
		if _do_step(Vector2i(dir.x, 0)): return true

	return false


func _read_dir8() -> Vector2i:
	var x := int(Input.is_action_pressed("move_right")) - int(Input.is_action_pressed("move_left"))
	var y := int(Input.is_action_pressed("move_down")) - int(Input.is_action_pressed("move_up"))
	return Vector2i(clampi(x, -1, 1), clampi(y, -1, 1))


func _play_anim(moving: bool) -> void:
	if sprite == null:
		return

	var dir := facing
	if dir == Vector2i.ZERO:
		dir = Vector2i.DOWN

	var x: int = sign(dir.x)
	var y: int = sign(dir.y)

	var anim_key := "down"
	var flip := false

	if x == 0 and y < 0: anim_key = "up"
	elif x == 0 and y > 0: anim_key = "down"
	elif x > 0 and y == 0: anim_key = "right"
	elif x < 0 and y == 0: anim_key = "right"; flip = true
	elif x > 0 and y < 0: anim_key = "upright"
	elif x < 0 and y < 0: anim_key = "upright"; flip = true
	elif x > 0 and y > 0: anim_key = "downright"
	elif x < 0 and y > 0: anim_key = "downright"; flip = true

	var anim: String = ("walk_" if moving else "idle_") + anim_key
	sprite.flip_h = flip
	if sprite.animation != anim:
		sprite.play(anim)


func _update_move(delta: float) -> void:
	move_t += delta / move_cooldown
	var t: float = clampf(move_t, 0.0, 1.0)
	_play_anim(true)
	global_position = start_world.lerp(target_world, t)

	if t >= 1.0:
		global_position = target_world
		is_moving = false


# ---------------- Combat ----------------

func _clear_combat() -> void:
	target_enemy_id = 0
	active_slot = -1
	is_auto_casting = false
	attack_timer = 0.0


func _get_target_enemy() -> Enemy:
	if target_enemy_id == 0:
		return null
	return world.get_enemy_by_id(target_enemy_id)


func _acquire_target() -> Enemy:
	# 1) Enemy on facing tile
	var fd := Vector2i(sign(facing.x), sign(facing.y))
	if fd != Vector2i.ZERO:
		var e1: Enemy = world.get_enemy_at(tile_pos + fd)
		if e1 != null:
			return e1

	# 2) Any adjacent enemy
	var neighbors := [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	for d in neighbors:
		var e2: Enemy = world.get_enemy_at(tile_pos + d)
		if e2 != null:
			return e2

	# 3) Nearest enemy within radius
	var best: Enemy = null
	var best_d: int = 999999

	for id in world.enemies_by_id.keys():
		var e: Enemy = world.enemies_by_id[id]
		if e == null:
			continue
		var d: int = absi(e.tile_pos.x - tile_pos.x) + absi(e.tile_pos.y - tile_pos.y)
		if d <= acquire_radius and d < best_d:
			best_d = d
			best = e

	return best


func _start_auto_cast(slot: int) -> void:
	active_slot = slot
	is_auto_casting = true

	var enemy: Enemy = _get_target_enemy()
	if enemy == null:
		var acquired: Enemy = _acquire_target()
		if acquired == null:
			is_auto_casting = false
			return
		target_enemy_id = acquired.get_instance_id()
		enemy = acquired

	_ensure_in_range_and_path()
	attack_timer = 0.0


func _ensure_in_range_and_path() -> void:
	var enemy: Enemy = _get_target_enemy()
	if enemy == null:
		_clear_combat()
		return

	var move: Move = moves[active_slot]
	var in_range: bool = _in_range(tile_pos, enemy.tile_pos, move.range_tiles)

	if is_moving:
		return

	if not in_range:
		var goal_tile: Vector2i = _find_reachable_tile_in_range(enemy.tile_pos, move.range_tiles)
		if goal_tile != tile_pos:
			walk_queue = world.get_path_tiles(tile_pos, goal_tile)
			walk_target = enemy.tile_pos


func _in_range(a: Vector2i, b: Vector2i, r: int) -> bool:
	var dx: int = absi(a.x - b.x)
	var dy: int = absi(a.y - b.y)
	return max(dx, dy) <= r and not (dx == 0 and dy == 0)


func _find_reachable_tile_in_range(center: Vector2i, r: int) -> Vector2i:
	if r <= 1:
		return world.get_best_approach_tile(tile_pos, center)

	var best_tile: Vector2i = tile_pos
	var best_len: int = 999999

	for y in range(center.y - r, center.y + r + 1):
		for x in range(center.x - r, center.x + r + 1):
			var t: Vector2i = Vector2i(x, y)
			if not _in_range(t, center, r):
				continue
			if world.is_blocked(t):
				continue
			if world.enemies_by_tile.has(t):
				continue

			var path: Array[Vector2i] = world.get_path_tiles(tile_pos, t)
			if path.size() == 0:
				continue
			if path.size() < best_len:
				best_len = path.size()
				best_tile = t

	return best_tile


func _update_auto_cast(delta: float) -> void:
	if not is_auto_casting or active_slot == -1:
		return

	var enemy: Enemy = _get_target_enemy()
	if enemy == null:
		_clear_combat()
		return

	if walk_queue.size() > 0 or is_moving:
		return

	var move: Move = moves[active_slot]

	if not _in_range(tile_pos, enemy.tile_pos, move.range_tiles):
		_ensure_in_range_and_path()
		return

	var dir: Vector2i = enemy.tile_pos - tile_pos
	facing = Vector2i(sign(dir.x), sign(dir.y))

	attack_timer -= delta
	if attack_timer > 0.0:
		return

	attack_timer = move.cooldown
	_cast_move_on_enemy(move, enemy)


func _cast_move_on_enemy(move: Move, enemy: Enemy) -> void:
	var died: bool = enemy.apply_damage(move.damage)
	print("Cast ", move.name, " for ", move.damage, " (hp=", enemy.hp, ")")

	if died:
		world.kill_enemy(enemy)
		_clear_combat()
