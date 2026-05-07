class_name StateIdle
extends InteractionState


func physics_update(_delta: float) -> StringName:
	var ray := player.get_node(^"CameraPivot/InteractionRayCast") as RayCast3D
	if ray.is_colliding() and ray.get_collider() != null:
		return InteractionStateMachine.STATE_HOVER
	return &""
