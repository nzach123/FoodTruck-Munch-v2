class_name StateActive_Discrete
extends InteractionState


func enter() -> void:
	print("[Active_Discrete] enter")


func physics_update(_delta: float) -> StringName:
	var ray := player.get_node(^"CameraPivot/InteractionRayCast") as RayCast3D
	if not ray.is_colliding():
		return InteractionStateMachine.STATE_IDLE
	if Input.is_action_just_pressed(&"interact"):
		var collider := ray.get_collider()
		if collider != null and collider.has_method(&"on_interact"):
			collider.on_interact(player)
	if Input.is_action_just_released(&"interact"):
		return InteractionStateMachine.STATE_HOVER
	return &""
