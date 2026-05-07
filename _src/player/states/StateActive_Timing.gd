class_name StateActive_Timing
extends InteractionState

var _elapsed: float = 0.0


func enter() -> void:
	print("[Active_Timing] enter")
	_elapsed = 0.0


func physics_update(delta: float) -> StringName:
	var ray := player.get_node(^"CameraPivot/InteractionRayCast") as RayCast3D
	if not ray.is_colliding():
		return InteractionStateMachine.STATE_IDLE
	_elapsed += delta
	var collider := ray.get_collider()
	if collider != null and collider.has_method(&"on_interact_timing"):
		var done: bool = collider.on_interact_timing(player, _elapsed, delta)
		if done:
			return InteractionStateMachine.STATE_IDLE
	if Input.is_action_just_released(&"interact"):
		return InteractionStateMachine.STATE_HOVER
	return &""


func exit() -> void:
	_elapsed = 0.0
