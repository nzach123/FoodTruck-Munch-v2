extends Resource
class_name OrderResult

enum Quality { PERFECT, SLOPPY, MISS }

@export var result_quality: Quality
@export var payment_multiplier: float
@export var tip_multiplier: float
