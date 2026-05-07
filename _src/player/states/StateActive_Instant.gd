class_name StateActive_Instant
extends InteractionState


func enter() -> void:
	print("[Active_Instant] enter")
	var ray := player.get_node(^"CameraPivot/InteractionRayCast") as RayCast3D
	if ray.is_colliding():
		var collider := ray.get_collider()
		if collider != null and collider.has_method(&"on_interact"):
			collider.on_interact(player)


func physics_update(_delta: float) -> StringName:
	return InteractionStateMachine.STATE_IDLE
