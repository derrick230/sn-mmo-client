extends Node2D
class_name Enemy

@export var max_hp: int = 3
var hp: int = 3

var tile_pos: Vector2i

func _ready() -> void:
	hp = max_hp

func set_tile(world: Node, t: Vector2i) -> void:
	tile_pos = t
	global_position = world.tile_to_world(tile_pos)

func apply_damage(amount: int) -> bool:
	hp -= amount
	if hp <= 0:
		hp = 0
		return true # dead
	return false
