extends Node

# Cross-domain signals
signal order_accepted(customer_id: int, recipe: Recipe)
signal order_completed(result: OrderResult, payment: float, tip: float)
signal order_abandoned(customer_id: int, food_cost: float)
signal balance_changed(new_balance: float, delta: float)
signal strike_added(current_strikes: int)
signal day_ended(summary: DaySummary)
signal save_corrupted()

func _ready() -> void:
	pass
