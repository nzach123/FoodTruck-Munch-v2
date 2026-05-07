class_name InteractionStateMachine
extends Node

const STATE_IDLE             := &"Idle"
const STATE_HOVER            := &"Hover"
const STATE_ACTIVE_INSTANT   := &"Active_Instant"
const STATE_ACTIVE_DISCRETE  := &"Active_Discrete"
const STATE_ACTIVE_ACCUMULATE := &"Active_Accumulate"
const STATE_ACTIVE_TIMING    := &"Active_Timing"
const STATE_LOCKED           := &"Locked"

var _current: InteractionState = null
var _current_name: StringName = &""


func _ready() -> void:
	var player := get_parent() as CharacterBody3D
	for child in get_children():
		if child is InteractionState:
			child.player = player
	call_deferred(&"_enter", STATE_IDLE)


func _physics_process(delta: float) -> void:
	if GameManager.is_input_locked():
		return
	if _current == null:
		return
	var next: StringName = _current.physics_update(delta)
	if next != &"" and next != _current_name:
		_enter(next)


func _enter(state_name: StringName) -> void:
	var node := get_node_or_null(NodePath(state_name)) as InteractionState
	if node == null:
		push_error("InteractionStateMachine: no child named '%s'" % state_name)
		return
	if _current != null:
		_current.exit()
	_current_name = state_name
	_current = node
	_current.enter()


func request(state_name: StringName) -> void:
	if state_name != _current_name:
		_enter(state_name)


func current_state() -> StringName:
	return _current_name
