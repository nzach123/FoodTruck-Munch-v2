class_name StateHover
extends InteractionState

var _last_target: Object = null


func enter() -> void:
	_last_target = null


func physics_update(_delta: float) -> StringName:
	var ray := player.get_node(^"CameraPivot/InteractionRayCast") as RayCast3D
	if not ray.is_colliding():
		return InteractionStateMachine.STATE_IDLE
	var collider := ray.get_collider()
	if collider == null:
		return InteractionStateMachine.STATE_IDLE

	if collider != _last_target:
		_last_target = collider
		print("[Hover] targeting: ", collider.name)

	if Input.is_action_just_pressed(&"interact"):
		var itype: int = collider.get("interaction_type") if "interaction_type" in collider else 0
		match itype:
			0: return InteractionStateMachine.STATE_ACTIVE_INSTANT
			1: return InteractionStateMachine.STATE_ACTIVE_DISCRETE
			2: return InteractionStateMachine.STATE_ACTIVE_ACCUMULATE
			3: return InteractionStateMachine.STATE_ACTIVE_TIMING
		return InteractionStateMachine.STATE_ACTIVE_INSTANT

	return &""


func exit() -> void:
	_last_target = null
