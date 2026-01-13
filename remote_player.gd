extends Node2D

@export var move_cooldown: float = 0.30
@onready var sprite: AnimatedSprite2D = $Sprite
var tile_pos: Vector2i = Vector2i.ZERO
var facing: Vector2i = Vector2i.DOWN
var world: Node = null

# Smoothing
var is_moving: bool = false
var move_t: float = 0.0
var start_world: Vector2 = Vector2.ZERO
var target_world: Vector2 = Vector2.ZERO

func set_world(_world: Node) -> void:
	world = _world

func _process(delta: float) -> void:
	# Smooth movement in progress
	if is_moving:
		_update_move(delta)
		return

func apply_state(new_tile: Vector2i, new_facing: Vector2i) -> void:
	var was_moving: bool = (new_tile != tile_pos)
	
	# If position changed, start smooth movement
	if new_tile != tile_pos and world != null:
		is_moving = true
		move_t = 0.0
		start_world = global_position
		target_world = world.tile_to_world(new_tile)
	
	tile_pos = new_tile
	facing = new_facing
	
	# If not moving, update position immediately and play idle
	if not is_moving:
		if world != null:
			global_position = world.tile_to_world(tile_pos)
		_play_anim(false)
	else:
		# Will play walk anim in _update_move
		_play_anim(true)

# matches function in player.gd
func _update_move(delta: float) -> void:
	move_t += delta / move_cooldown
	var t: float = clampf(move_t, 0.0, 1.0)
	_play_anim(true)
	global_position = start_world.lerp(target_world, t)

	if t >= 1.0:
		global_position = target_world
		is_moving = false

# matches function in player.gd
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
