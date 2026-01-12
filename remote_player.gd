extends Node2D

@onready var sprite: AnimatedSprite2D = $Sprite
var tile_pos: Vector2i = Vector2i.ZERO
var facing: Vector2i = Vector2i.DOWN
var world: Node = null

func set_world(_world: Node) -> void:
	world = _world

func apply_state(new_tile: Vector2i, new_facing: Vector2i) -> void:
	tile_pos = new_tile
	facing = new_facing
	if world != null:
		global_position = world.tile_to_world(tile_pos)

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
