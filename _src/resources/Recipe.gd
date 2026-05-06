extends Resource
class_name Recipe

@export var protein: StringName = &"trompo"
@export var topping_pool_weighted: Dictionary # [StringName, float]
@export var topping_count_range: Vector2i
@export var sauce_count_range: Vector2i
