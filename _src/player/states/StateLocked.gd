class_name StateLocked
extends InteractionState


func enter() -> void:
	print("[Locked] input locked")


func physics_update(_delta: float) -> StringName:
	if not GameManager.is_input_locked():
		return InteractionStateMachine.STATE_IDLE
	return &""
