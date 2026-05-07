extends CharacterBody3D

const SPEED := 3.0
const MOUSE_SENSITIVITY := 0.002

@onready var main_camera: Camera3D = $CameraPivot/MainCamera
@onready var arm_camera: Camera3D = $ArmViewportContainer/ArmViewport/ArmCamera
@onready var arm_viewport: SubViewport = $ArmViewportContainer/ArmViewport
@onready var camera_pivot: Node3D = $CameraPivot
@onready var interaction_raycast: RayCast3D = $CameraPivot/InteractionRayCast


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _process(_delta: float) -> void:
	arm_camera.global_transform = main_camera.global_transform


func _unhandled_input(event: InputEvent) -> void:
	if GameManager.is_input_locked():
		return
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		camera_pivot.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		camera_pivot.rotation.x = clampf(camera_pivot.rotation.x, deg_to_rad(-85.0), deg_to_rad(85.0))


func _physics_process(delta: float) -> void:
	if GameManager.is_input_locked():
		return
	var dir := Vector3.ZERO
	if Input.is_action_pressed(&"move_forward"):
		dir -= transform.basis.z
	if Input.is_action_pressed(&"move_back"):
		dir += transform.basis.z
	if Input.is_action_pressed(&"move_left"):
		dir -= transform.basis.x
	if Input.is_action_pressed(&"move_right"):
		dir += transform.basis.x
	if dir.length_squared() > 0.0:
		dir = dir.normalized()
	velocity.x = dir.x * SPEED
	velocity.z = dir.z * SPEED
	if not is_on_floor():
		velocity.y -= 9.8 * delta
	move_and_slide()
