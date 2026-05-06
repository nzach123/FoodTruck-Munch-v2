extends Node

enum GamePhase { TUTORIAL, PLAYING, END_OF_DAY }

var phase: GamePhase = GamePhase.PLAYING

func is_input_locked() -> bool:
	return phase != GamePhase.PLAYING

func _ready() -> void:
	pass
