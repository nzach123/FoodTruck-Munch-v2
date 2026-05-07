class_name InteractionState
extends Node

var player: CharacterBody3D


func enter() -> void:
	pass


## Return the next state name to transition to, or &"" to stay.
func physics_update(_delta: float) -> StringName:
	return &""


func exit() -> void:
	pass
