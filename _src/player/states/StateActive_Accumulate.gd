class_name StateActive_Accumulate
extends InteractionState

var _accumulated: float = 0.0


func enter() -> void:
	print("[Active_Accumulate] enter")
	_accumulated = 0.0


func physics_update(delta: float) -> StringName:
	var ray := player.get_node(^"CameraPivot/InteractionRayCast") as RayCast3D
	if not ray.is_colliding():
		return InteractionStateMachine.STATE_IDLE
	if not Input.is_action_pressed(&"interact"):
		return InteractionStateMachine.STATE_HOVER
	var collider := ray.get_collider()
	if collider != null and collider.has_method(&"on_interact_accumulate"):
		_accumulated += delta
		collider.on_interact_accumulate(player, _accumulated, delta)
	return &""


func exit() -> void:
	_accumulated = 0.0
