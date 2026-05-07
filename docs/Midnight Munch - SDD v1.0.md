# Midnight Munch — Specification-Driven Development (SDD) v1.0

**Engine:** Godot 4.6 · GDScript only (strict static typing)
**Target:** WebGL2 / HTML5 Compatibility renderer, 60 FPS sustained, ≤16.6 ms frame, ≤50 MB initial download
**Source-of-truth chain:** `Midnight_Munch_-_Master_GDD v3.4.md` → `Midnight Munch - Implementation Roadmap.md` → `Midnight Munch - Technical Implementation Plan.md` → **this SDD**
**Audience:** A downstream code-generation agent. Every decision is explicit; every type is bound; every signal payload is named.

---

## 0. Document Authority & Reading Order

This SDD is the **canonical machine-actionable contract** for the Midnight Munch prototype codebase. It does not relitigate the GDD's mechanical decisions or the Roadmap's sprint order; it binds them to exact Godot 4.6 nodes, scripts, signal payloads, and phase gates.

**Conflict resolution order, highest authority first:**
1. GDD §1 (mechanics) and §11 (cut list).
2. GDD §7 (performance budget).
3. This SDD (architecture, types, code contracts).
4. Technical Implementation Plan (sprint sequencing, task breakdown).

**Forbidden actions for the implementer:**
- Adding a 5th autoload (the cap is 4 — see §3).
- Inserting business logic into `EventBus`.
- Reading `Input.*` from any station script.
- Calling `queue_free()` or `instantiate()` on any node managed by `NodePool` during gameplay.
- Using `GPUParticles3D`, `SDFGI`, `VoxelGI`, `SSAO`, `SSIL`, `SSR`, volumetric fog, HDR glow, or `CompositorEffect` (Compatibility renderer disallows).
- Using `emit_signal("name", …)` (string lookup). All emits must be `.emit(…)`.
- Using untyped variables (`var x = …`) in any script outside trivial loop iterators.

---

## 1. System Analysis (Internalized Constraints)

### 1.1 Hard Constraints (non-negotiable)

| ID | Constraint | Source |
|---|---|---|
| HC-1 | Single gameplay scene `TruckInterior.tscn`; only `MainMenu`, `EndOfDayScreen` (CanvasLayer) outside it | GDD §2.1, Plan §1.1 |
| HC-2 | 4 autoloads max: `EventBus`, `NodePool`, `EconomyManager`, `GameManager` | GDD §4.1 |
| HC-3 | `GameManager.is_input_locked()` is the sole input-lock authority | GDD §4.2 |
| HC-4 | Stations expose only `interaction_type` and `input_action`; FSM owns input | GDD §2.4 |
| HC-5 | `ArmViewport.update_mode = UPDATE_DISABLED` whenever no held item | GDD §2.2, §7 |
| HC-6 | `NodePool.return_node()` resets state, **not** `checkout()` | GDD §4.1 |
| HC-7 | Sloppy quality is sticky in `ActiveOrder` | GDD §3.4 |
| HC-8 | Recipe duplicate-prevention window = last 3 generated orders | GDD §4.6 |
| HC-9 | Save corruption recovery emits `EventBus.save_corrupted` and creates fresh save | GDD §4.7 |
| HC-10 | All audio plays one **physics tick** after visual commit (web latency margin) | Plan §2.1, §6.2 |
| HC-11 | All `.emit()` calls are typed; no `emit_signal()` | GDD §9 |
| HC-12 | Compatibility renderer + WASM threads disabled in web export | Plan §0.1 |

### 1.2 Performance Budget (Compatibility renderer, Chromebook-class)

| System | Budget | Owner |
|---|---|---|
| Main viewport render | 6.0 ms | Baked `LightmapGI` + `MeshInstance3D` truck shell |
| ArmViewport SubViewport render | 2.0 ms | `UPDATE_DISABLED` when idle |
| Physics + raycast | 2.0 ms | Single 3 m raycast on layer 3 only |
| GDScript (FSM + OrderManager + Customer AI) | 3.0 ms | §6 code contracts |
| Audio | 1.0 ms | Reverb/Doppler off; bus split UI/World |
| Headroom | 2.6 ms | — |
| **Total** | **16.6 ms** | |

### 1.3 Cut Priority (frozen, do not improvise alternatives)

1. Sauce stations (drop `Active_Accumulate`).
2. Dynamic queue compaction (cap concurrent at 2, no compaction tween).
3. SubViewport arms (replace with depth-bias single-camera).
4. Tip system (flat payments).
5. Topping SLOPPY granularity (binary pass/fail on ring).

---

## 2. Engine, Project, and Renderer Configuration

### 2.1 Project Settings (exact values)

| Setting | Value | Rationale |
|---|---|---|
| `application/run/main_scene` | `res://scenes/MainMenu.tscn` | Boot path |
| `display/window/size/viewport_width` | `1280` | GDD target window |
| `display/window/size/viewport_height` | `720` | |
| `display/window/stretch/mode` | `canvas_items` | UI scaling |
| `display/window/stretch/aspect` | `keep` | Letterbox preserves layout |
| `physics/common/physics_ticks_per_second` | `60` | Locks deterministic FSM cadence |
| `physics/common/max_physics_steps_per_frame` | `8` | Prevent spiral-of-death on slow web frames |
| `rendering/renderer/rendering_method` | `gl_compatibility` | Required for WebGL2 |
| `rendering/renderer/rendering_method.web` | `gl_compatibility` | Belt-and-suspenders |
| `rendering/anti_aliasing/quality/msaa_3d` | `Disabled` | ArmViewport budget |
| `rendering/anti_aliasing/quality/screen_space_aa` | `Disabled` | Compatibility cost |
| `rendering/textures/canvas_textures/default_texture_filter` | `Linear` | UI sharpness |
| `rendering/lights_and_shadows/directional_shadow/size` | `2048` | Static bake only — runtime cost zero |
| `rendering/environment/glow/upscale_mode` | `Linear` | If glow is enabled it would no-op anyway in Compatibility |
| `gui/timers/incremental_search_max_interval_msec` | `2000` | UX |

### 2.2 Physics Layers (locked)

| Layer # | Name | Used By |
|---|---|---|
| 1 | `world` | TruckShell static body |
| 2 | `npc` | `CustomerNPC` collision (toggled off during compaction) |
| 3 | `interactable` | All `Station` Area3Ds — sole layer the raycast scans |
| 4 | `arm_only` | Held items rendered through `ArmViewport` |

`InteractionRayCast.collision_mask = 0b0100` (decimal 4) — **only** layer 3.
`MainCamera.cull_mask` excludes bit 4. `ArmCamera.cull_mask` includes **only** bit 4.

### 2.3 Input Map (definitive)

| Action | Bindings | Notes |
|---|---|---|
| `interact` | `MOUSE_BUTTON_LEFT`, `KEY_E` | Primary commit |
| `mash` | `MOUSE_BUTTON_LEFT`, `KEY_E` | Same as `interact`; FSM disambiguates by current state |
| `pause` | `KEY_ESCAPE` | |
| `move_forward` | `KEY_W` | |
| `move_back` | `KEY_S` | |
| `move_left` | `KEY_A` | |
| `move_right` | `KEY_D` | |
| `ui_accept` | Default | Modal popups |
| `ui_cancel` | Default | Modal popups |
| `debug_toggle` | `KEY_F3` | Dev-only overlay |

### 2.4 Web Export Preset

```ini
preset.name = "Web"
preset.platform = "Web"
preset.runnable = true
preset.export_path = "export/web/index.html"

# CRITICAL
threads/enabled = false                 # SAB blocked on common hosts
variant/extensions_support = false      # No GDExtension on web
vram_texture_compression/for_mobile = true
html/canvas_resize_policy = 2           # adaptive
html/focus_canvas_on_start = true
progressive_web_app/enabled = false
```

### 2.5 `.gitignore`

```
.godot/
export/
*.import
.DS_Store
```

---

## 3. Static Typing Contract

This is binding for all GDScript files in the project. The downstream code generator must obey it.

### 3.1 Rules

1. **Every `var`, `func` parameter, and `func` return type is annotated.** No implicit types except short loop variables (`for i in range(n)`).
2. **`@export` declarations always typed.** `@export var x: int = 0` not `@export var x = 0`.
3. **Signal definitions always typed.** `signal foo(value: int)` not `signal foo(value)`.
4. **Resource references typed by `class_name`,** never `Resource`. E.g. `func generate(r: Recipe) -> ActiveOrder`.
5. **Dictionaries are typed where contents are homogeneous:** `Dictionary[StringName, int]`. Heterogeneous lookups (rare) use `Dictionary` with a comment.
6. **`StringName` (`&"…"`) for ids and action names; `String` only for human-readable display text.**
7. **No `Variant` returns.** If a function genuinely cannot decide its return type, split it.
8. **No `Object`-typed parameters.** Always narrow to the actual base class.
9. **`null` returns must be explicit:** `-> Node` is non-nullable by convention; if null is possible, return type is left as the base but **callers must null-check**, and the function header includes a `## Returns null if not found.` doc comment.

### 3.2 Class Names (registered globally — `class_name` in each script)

```
EventBus              GameManager           EconomyManager        NodePool
SaveSystem            Player                InteractionStateMachine
State                 IdleState             HoverState
ActiveInstantState    ActiveDiscreteState   ActiveAccumulateState
ActiveTimingState     LockedState
StationBase           CustomerNPC           CustomerSpawner       OrderManager
ActiveOrder           Recipe                IngredientResource
DifficultyEntry       DifficultySchedule    OrderResult           DaySummary
EconomyResource       UpgradeResource       Settings
StrikeTracker         TutorialSequencer     ShrinkingCircleUI
ObjectiveHUD          IngredientPill        BankBalanceHUD
EndOfDayScreen        BellConfirmationPopup PauseMenu             DebugOverlay
```

---

## 4. Autoloads (4-cap)

Load order in Project Settings → Autoload (top to bottom):

1. `EventBus` (`res://autoload/EventBus.gd`)
2. `NodePool` (`res://autoload/NodePool.gd`)
3. `EconomyManager` (`res://autoload/EconomyManager.gd`)
4. `GameManager` (`res://autoload/GameManager.gd`)

**Forbidden additions:** `OrderManager` (scene-level), `SaveSystem` (stateless utility), `Settings` (resource), `StrikeTracker` (scene-level), `TutorialSequencer` (scene-level, freed Day 0+).

---

## 5. Code Contracts — Production-Ready GDScript

All code blocks below are the **exact** target shape of the generated files. Comments mark hot-path constraints.

### 5.1 `autoload/EventBus.gd` — signals only, zero state

```gdscript
class_name EventBusType extends Node
## Signals-only autoload. NEVER add state, helpers, or logic here.
## Rationale: EventBus is an addressing mechanism, not a controller.

@warning_ignore("unused_signal")

signal order_accepted(customer_id: int, recipe: Recipe)
signal order_completed(result: OrderResult, payment: float, tip: float)
signal order_abandoned(customer_id: int, food_cost: float)
signal balance_changed(new_balance: float, delta: float)
signal strike_added(current_strikes: int)
signal day_ended(summary: DaySummary)
signal save_corrupted()

## ----- Local-domain (not cross-domain) signals lifted to bus only when
## a documented architectural reason demands it. None at present.
```

> **Naming**: the autoload is registered as `EventBus`. The `class_name` is `EventBusType` to keep static analysis happy without shadowing the autoload symbol.

### 5.2 `autoload/NodePool.gd` — checkout/return contract

```gdscript
class_name NodePoolType extends Node
## Object-pool autoload. Hot-path: checkout() must NOT allocate or reset.
## Cold-path: return_node() resets state and re-parents to pool root.
## WebGL note: queue_free() during gameplay is forbidden — Godot's web
## build cannot rely on prompt cleanup; pooled nodes outlive their use.

const _POOL_PATHS: Dictionary[StringName, String] = {
    &"customer":      "res://scenes/CustomerNPC.tscn",
    &"tortilla":      "res://scenes/items/Tortilla.tscn",
    &"topping_cilantro": "res://scenes/items/Topping_Cilantro.tscn",
    &"topping_onion":    "res://scenes/items/Topping_Onion.tscn",
    &"sauce_splat_red":  "res://scenes/items/SauceSplat_Red.tscn",
    # ...declare every poolable scene here, by StringName id.
}

const _PREWARM_COUNTS: Dictionary[StringName, int] = {
    &"customer": 12,           # max_concurrent_customers (3) x 4
    &"tortilla": 10,
    &"topping_cilantro": 12,
    &"topping_onion": 12,
    &"sauce_splat_red": 12,
}

var _pools: Dictionary[StringName, Array] = {}
var _scenes: Dictionary[StringName, PackedScene] = {}

func _ready() -> void:
    for id in _POOL_PATHS:
        _scenes[id] = load(_POOL_PATHS[id]) as PackedScene
        _pools[id] = []
    for id in _PREWARM_COUNTS:
        _prewarm(id, _PREWARM_COUNTS[id])

func _prewarm(id: StringName, count: int) -> void:
    var arr: Array = _pools[id]
    for i in count:
        var n: Node = _scenes[id].instantiate()
        _deactivate(n)
        add_child(n)            # pool root holds inactive nodes
        arr.append(n)

## Hot-path. Must not allocate, reset, or call into game logic.
func checkout(id: StringName) -> Node:
    var arr: Array = _pools[id]
    if arr.is_empty():
        if OS.is_debug_build():
            assert(false, "NodePool exhausted for id=%s" % id)
        push_warning("NodePool exhausted for id=%s — falling back to instantiate()" % id)
        return _scenes[id].instantiate()
    var n: Node = arr.pop_back()
    _activate(n)
    return n

## Cold-path. Resets node state. Caller MUST detach from current parent first.
func return_node(n: Node, id: StringName) -> void:
    if n == null:
        push_warning("NodePool.return_node received null")
        return
    if n.get_parent() != null:
        n.get_parent().remove_child(n)
    if n.has_method(&"reset_pooled_state"):
        n.call(&"reset_pooled_state")
    _deactivate(n)
    add_child(n)
    var arr: Array = _pools[id]
    arr.append(n)

func _activate(n: Node) -> void:
    n.set_process(true)
    n.set_physics_process(true)
    if n is Node3D:
        (n as Node3D).visible = true
    if n is CollisionObject3D:
        (n as CollisionObject3D).process_mode = Node.PROCESS_MODE_INHERIT

func _deactivate(n: Node) -> void:
    n.set_process(false)
    n.set_physics_process(false)
    if n is Node3D:
        (n as Node3D).visible = false
    if n is CollisionObject3D:
        (n as CollisionObject3D).process_mode = Node.PROCESS_MODE_DISABLED
```

**Pooled-node contract:** every poolable scene's root script implements:

```gdscript
func reset_pooled_state() -> void:
    # zero out timers, clear references, reset transform, etc.
    pass
```

### 5.3 `autoload/GameManager.gd` — phase + input lock authority

```gdscript
class_name GameManagerType extends Node
## Single source of truth for day phase, the 5-minute timer, and input lock.

enum GamePhase { MAIN_MENU, TUTORIAL, PLAYING, END_OF_DAY, PAUSED }

const DAY_LENGTH_SECONDS: float = 300.0

@export var difficulty_schedule: DifficultySchedule

var phase: GamePhase = GamePhase.MAIN_MENU
var current_day: int = 1
var modal_open: bool = false   # set by BellConfirmationPopup, PauseMenu
var purchased_upgrades: Array[StringName] = []

var _day_timer: SceneTreeTimer
var _day_time_remaining: float = 0.0

func _ready() -> void:
    set_process(false)

## Single source of truth — every FSM state's _physics_process MUST call this
## as its first line. No duplications elsewhere. No wrapper helpers.
func is_input_locked() -> bool:
    return phase != GamePhase.PLAYING or modal_open

func start_day() -> void:
    phase = GamePhase.PLAYING
    _day_time_remaining = DAY_LENGTH_SECONDS
    set_process(true)

func _process(delta: float) -> void:
    if phase != GamePhase.PLAYING:
        return
    _day_time_remaining -= delta
    if _day_time_remaining <= 0.0:
        _day_time_remaining = 0.0
        end_day_normal()

func get_time_remaining() -> float:
    return _day_time_remaining

## Called by the 300 s natural expiry.
func end_day_normal() -> void:
    if phase == GamePhase.END_OF_DAY:
        return
    phase = GamePhase.END_OF_DAY                  # FLIP FIRST
    set_process(false)
    var summary: DaySummary = _build_summary()
    EventBus.day_ended.emit(summary)              # THEN emit

## Called by StrikeTracker on the third strike.
func end_day_immediately() -> void:
    end_day_normal()

func advance_to_next_day() -> void:
    current_day += 1
    SaveSystem.save(_collect_save_state())
    get_tree().reload_current_scene()

func get_current_difficulty() -> DifficultyEntry:
    var idx: int = clampi(current_day, 0, difficulty_schedule.entries.size() - 1)
    return difficulty_schedule.entries[idx]

func get_upgrade_value(effect_key: StringName) -> float:
    var total: float = 0.0
    # Iterate purchased upgrades; sum effect_value for matching effect_key.
    # (Real impl reads UpgradeResource.tres files.)
    return total

func _build_summary() -> DaySummary:
    var s: DaySummary = DaySummary.new()
    s.day_number = current_day
    s.balance = EconomyManager.balance
    s.quota = get_current_difficulty().daily_quota
    s.quota_met = s.balance >= s.quota
    return s

func _collect_save_state() -> Dictionary:
    return {
        "save_version": 1,
        "current_day": current_day,
        "balance": EconomyManager.balance,
        "purchased_upgrades": purchased_upgrades,
        "tutorial_completed": SaveSystem.tutorial_completed_cached,
        "settings": Settings.collect_dict(),
    }
```

### 5.4 `autoload/EconomyManager.gd`

```gdscript
class_name EconomyManagerType extends Node
## Bank balance + payment math. $0 floor enforced here.

@export var economy: EconomyResource

var balance: float = 0.0
var _orders_served: int = 0
var _strikes: int = 0

func _ready() -> void:
    if economy != null:
        balance = economy.starting_balance
    EventBus.order_completed.connect(_on_order_completed)
    EventBus.order_abandoned.connect(_on_order_abandoned)

func credit(amount: float) -> void:
    if amount <= 0.0:
        return
    balance += amount
    EventBus.balance_changed.emit(balance, amount)

func debit(amount: float) -> void:
    if amount <= 0.0:
        return
    var prev: float = balance
    balance = maxf(0.0, balance - amount)         # $0 floor (GDD §4.1)
    var delta: float = balance - prev
    EventBus.balance_changed.emit(balance, delta)

func process_payment(result: OrderResult, recipe: Recipe) -> Vector2:
    var base: float = recipe.base_price * result.payment_multiplier
    var tip: float = recipe.base_price * result.tip_multiplier
    if base > 0.0: credit(base)
    if tip  > 0.0: credit(tip)
    return Vector2(base, tip)

func _on_order_completed(result: OrderResult, payment: float, tip: float) -> void:
    _orders_served += 1

func _on_order_abandoned(_customer_id: int, food_cost: float) -> void:
    debit(food_cost)
```

### 5.5 `scripts/SaveSystem.gd` — stateless utility (NOT autoload)

```gdscript
class_name SaveSystem extends RefCounted
## Stateless. Static API only. NEVER add per-instance state.
## Web (IndexedDB) writes are async — saves are wrapped in await on web.

const SAVE_PATH: String = "user://save.json"
const CURRENT_VERSION: int = 1

static var tutorial_completed_cached: bool = false

static func save(state: Dictionary) -> void:
    var json: String = JSON.stringify(state)
    var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
    if f == null:
        push_error("SaveSystem.save: cannot open %s for write" % SAVE_PATH)
        return
    f.store_string(json)
    f.close()
    if state.has("tutorial_completed"):
        tutorial_completed_cached = state["tutorial_completed"]

static func load() -> Dictionary:
    if not FileAccess.file_exists(SAVE_PATH):
        return _create_fresh_save()
    var f: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
    if f == null:
        EventBus.save_corrupted.emit()
        return _create_fresh_save()
    var text: String = f.get_as_text()
    f.close()
    var data: Variant = JSON.parse_string(text)
    if typeof(data) != TYPE_DICTIONARY \
            or not (data as Dictionary).has("save_version") \
            or not (data as Dictionary).has("current_day"):
        push_error("Save file corrupted or schema mismatch.")
        EventBus.save_corrupted.emit()
        return _create_fresh_save()
    var d: Dictionary = data
    if d.get("tutorial_completed", false):
        tutorial_completed_cached = true
    return d

static func has_save() -> bool:
    return FileAccess.file_exists(SAVE_PATH)

static func _create_fresh_save() -> Dictionary:
    return {
        "save_version": CURRENT_VERSION,
        "current_day": 1,
        "balance": 0.0,
        "purchased_upgrades": [],
        "tutorial_completed": false,
        "settings": {},
    }
```

### 5.6 State Pattern — `scripts/fsm/State.gd`

```gdscript
class_name State extends Node
## Base for every InteractionStateMachine state.
## Subclasses MUST short-circuit on GameManager.is_input_locked() at the top
## of physics_update, exactly once. No wrapper helpers.

var fsm: InteractionStateMachine
var player: Player

func setup(_fsm: InteractionStateMachine, _player: Player) -> void:
    fsm = _fsm
    player = _player

func enter() -> void: pass
func exit() -> void: pass
func physics_update(_delta: float) -> void: pass
func handle_input(_event: InputEvent) -> void: pass
```

### 5.7 `scripts/fsm/InteractionStateMachine.gd`

```gdscript
class_name InteractionStateMachine extends Node
## Owns input routing for the Player. Stations are passive data.

@export var initial_state: NodePath
@onready var _states: Dictionary[StringName, State] = _index_states()

var current: State

func _ready() -> void:
    var p: Player = get_parent() as Player
    for s in _states.values():
        s.setup(self, p)
        s.set_physics_process(false)
        s.set_process_input(false)
    var initial: State = get_node(initial_state) as State
    change_to(initial.name)

func _index_states() -> Dictionary[StringName, State]:
    var d: Dictionary[StringName, State] = {}
    for child in get_children():
        if child is State:
            d[child.name] = child
    return d

func change_to(state_name: StringName) -> void:
    if not _states.has(state_name):
        push_error("InteractionStateMachine: missing state %s" % state_name)
        return
    if current != null:
        current.exit()
        current.set_physics_process(false)
        current.set_process_input(false)
    current = _states[state_name]
    current.set_physics_process(true)
    current.set_process_input(true)
    current.enter()

func _unhandled_input(event: InputEvent) -> void:
    if current != null:
        current.handle_input(event)
```

### 5.8 Concrete states (skeletons)

```gdscript
# scripts/fsm/IdleState.gd
class_name IdleState extends State

func physics_update(_delta: float) -> void:
    if GameManager.is_input_locked(): return
    var ray: RayCast3D = player.interaction_raycast
    ray.force_raycast_update()
    if not ray.is_colliding(): return
    var hit: Object = ray.get_collider()
    if hit is StationBase:
        player.set_hovered_station(hit as StationBase)
        fsm.change_to(&"HoverState")
```

```gdscript
# scripts/fsm/HoverState.gd
class_name HoverState extends State

func enter() -> void:
    var st: StationBase = player.hovered_station
    if st == null:
        fsm.change_to(&"IdleState")
        return
    if not _sequence_prerequisite_met(st):
        st.show_blocked_prompt()
    else:
        st.show_hover_prompt()

func exit() -> void:
    if player.hovered_station != null:
        player.hovered_station.hide_prompt()

func physics_update(_delta: float) -> void:
    if GameManager.is_input_locked(): return
    var ray: RayCast3D = player.interaction_raycast
    ray.force_raycast_update()
    if not ray.is_colliding():
        fsm.change_to(&"IdleState"); return
    var hit: StationBase = ray.get_collider() as StationBase
    if hit == null or hit != player.hovered_station:
        player.set_hovered_station(hit)
        fsm.change_to(&"HoverState"); return
    if Input.is_action_just_pressed(player.hovered_station.input_action):
        if _sequence_prerequisite_met(player.hovered_station):
            _route_to_active_state(player.hovered_station.interaction_type)

func _sequence_prerequisite_met(st: StationBase) -> bool:
    return OrderManager.singleton.is_step_allowed(st.station_id)

func _route_to_active_state(t: StationBase.InteractionType) -> void:
    match t:
        StationBase.InteractionType.INSTANT:    fsm.change_to(&"ActiveInstantState")
        StationBase.InteractionType.DISCRETE:   fsm.change_to(&"ActiveDiscreteState")
        StationBase.InteractionType.ACCUMULATE: fsm.change_to(&"ActiveAccumulateState")
        StationBase.InteractionType.TIMING:     fsm.change_to(&"ActiveTimingState")
```

```gdscript
# scripts/fsm/ActiveTimingState.gd  (highest-risk web mechanic)
class_name ActiveTimingState extends State

const RING_DURATION_SEC: float = 1.5
const TARGET_BAND: Vector2 = Vector2(0.30, 0.45)  # normalized radius window

var _t: float = 0.0
var _ring_ui: ShrinkingCircleUI
var _committed: bool = false

func enter() -> void:
    _t = 0.0
    _committed = false
    _ring_ui = player.get_ring_ui()
    _ring_ui.show_with_band(TARGET_BAND)

func exit() -> void:
    if _ring_ui != null:
        _ring_ui.hide_ring()

func physics_update(delta: float) -> void:
    if GameManager.is_input_locked(): return
    _t += delta
    var radius: float = 1.0 - clampf(_t / RING_DURATION_SEC, 0.0, 1.0)
    _ring_ui.set_radius_normalized(radius)
    if _committed: return
    if Input.is_action_just_pressed(&"interact"):
        _committed = true
        _commit(radius)
    elif _t >= RING_DURATION_SEC:
        _committed = true
        _commit(0.0)

func _commit(radius_at_press: float) -> void:
    var quality: OrderResult.Quality
    if radius_at_press >= TARGET_BAND.x and radius_at_press <= TARGET_BAND.y:
        quality = OrderResult.Quality.PERFECT
    elif radius_at_press > 0.0:
        quality = OrderResult.Quality.SLOPPY
    else:
        quality = OrderResult.Quality.WRONG
    # Deferred-by-one-tick audio per HC-10:
    call_deferred(&"_play_audio_post_visual", quality)
    OrderManager.singleton.complete_step(player.hovered_station.station_id, quality)
    fsm.change_to(&"IdleState")

func _play_audio_post_visual(quality: OrderResult.Quality) -> void:
    player.hovered_station.play_quality_sfx(quality)
```

```gdscript
# scripts/fsm/ActiveAccumulateState.gd
class_name ActiveAccumulateState extends State

const COMMIT_DELAY: float = 0.4
const PERFECT_BAND: Vector2 = Vector2(0.55, 0.75)

var _gauge: float = 0.0
var _committing: bool = false
var _commit_timer: SceneTreeTimer

func enter() -> void:
    _gauge = 0.0
    _committing = false
    if Settings.hold_to_tap_enabled:
        _gauge = (PERFECT_BAND.x + PERFECT_BAND.y) * 0.5

func physics_update(delta: float) -> void:
    if GameManager.is_input_locked(): return
    if Settings.hold_to_tap_enabled:
        _commit_now(); return
    if Input.is_action_pressed(&"interact"):
        _gauge = clampf(_gauge + delta * 0.6, 0.0, 1.0)
        player.hovered_station.update_gauge_visual(_gauge)
    elif _gauge > 0.0 and not _committing:
        _committing = true
        _commit_timer = get_tree().create_timer(COMMIT_DELAY)
        _commit_timer.timeout.connect(_commit_now, CONNECT_ONE_SHOT)

func _commit_now() -> void:
    var quality: OrderResult.Quality
    if _gauge >= PERFECT_BAND.x and _gauge <= PERFECT_BAND.y:
        quality = OrderResult.Quality.PERFECT
    elif _gauge > PERFECT_BAND.y:
        quality = OrderResult.Quality.SLOPPY
    else:
        quality = OrderResult.Quality.WRONG
    OrderManager.singleton.complete_step(player.hovered_station.station_id, quality)
    fsm.change_to(&"IdleState")
```

```gdscript
# scripts/fsm/ActiveDiscreteState.gd
class_name ActiveDiscreteState extends State

const TOTAL_PRESSES: int = 3
const IDEAL_INTERVAL_SEC: float = 0.45
const TOLERANCE_SEC: float = 0.18

var _press_times: Array[float] = []

func enter() -> void:
    _press_times.clear()

func physics_update(_delta: float) -> void:
    if GameManager.is_input_locked(): return
    if Input.is_action_just_pressed(&"interact"):
        _press_times.append(Time.get_ticks_msec() / 1000.0)
        player.hovered_station.play_slice_fx(_press_times.size())
        if _press_times.size() >= TOTAL_PRESSES:
            _commit()

func _commit() -> void:
    var max_dev: float = 0.0
    for i in range(1, _press_times.size()):
        var dt: float = _press_times[i] - _press_times[i - 1]
        max_dev = maxf(max_dev, absf(dt - IDEAL_INTERVAL_SEC))
    var quality: OrderResult.Quality
    if max_dev <= TOLERANCE_SEC:
        quality = OrderResult.Quality.PERFECT
    elif max_dev <= TOLERANCE_SEC * 2.0:
        quality = OrderResult.Quality.SLOPPY
    else:
        quality = OrderResult.Quality.WRONG
    OrderManager.singleton.complete_step(player.hovered_station.station_id, quality)
    fsm.change_to(&"IdleState")
```

```gdscript
# scripts/fsm/ActiveInstantState.gd
class_name ActiveInstantState extends State

func enter() -> void:
    var st: StationBase = player.hovered_station
    if st == null:
        fsm.change_to(&"IdleState"); return
    OrderManager.singleton.complete_step(st.station_id, OrderResult.Quality.PERFECT)
    fsm.change_to(&"IdleState")
```

```gdscript
# scripts/fsm/LockedState.gd
class_name LockedState extends State
## Entered on END_OF_DAY. Ignores input. Idempotent enter.
func enter() -> void:
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
```

### 5.9 `scripts/Player.gd`

```gdscript
class_name Player extends CharacterBody3D

const MOVE_SPEED: float = 3.0
const MOUSE_SENS_DEFAULT: float = 0.0025
const PITCH_LIMIT_DEG: float = 85.0

@onready var camera_pivot: Node3D = $CameraPivot
@onready var main_camera: Camera3D = $CameraPivot/MainCamera
@onready var arm_viewport: SubViewport = $ArmViewportContainer/ArmViewport
@onready var arm_camera: Camera3D = $ArmViewportContainer/ArmViewport/ArmCamera
@onready var hand_anchor: Marker3D = $ArmViewportContainer/ArmViewport/ArmCamera/HandTransform
@onready var interaction_raycast: RayCast3D = $CameraPivot/InteractionRayCast
@onready var fsm: InteractionStateMachine = $InteractionStateMachine

var hovered_station: StationBase = null
var held_item: Node3D = null

func _ready() -> void:
    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    arm_viewport.update_mode = SubViewport.UPDATE_DISABLED  # HC-5
    arm_viewport.transparent_bg = true
    arm_viewport.use_hdr_2d = false
    arm_viewport.msaa_3d = Viewport.MSAA_DISABLED

func _process(_delta: float) -> void:
    arm_camera.global_transform = main_camera.global_transform   # one Transform3D copy

func _physics_process(delta: float) -> void:
    if GameManager.is_input_locked():
        velocity = Vector3.ZERO
        return
    var input_vec: Vector2 = Input.get_vector(
        &"move_left", &"move_right", &"move_forward", &"move_back")
    var dir: Vector3 = (transform.basis * Vector3(input_vec.x, 0, input_vec.y)).normalized()
    velocity.x = dir.x * MOVE_SPEED
    velocity.z = dir.z * MOVE_SPEED
    velocity.y = 0.0
    move_and_slide()

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        var m: InputEventMouseMotion = event
        var sens: float = Settings.mouse_sensitivity
        rotate_y(-m.relative.x * sens)
        camera_pivot.rotate_x(-m.relative.y * sens)
        camera_pivot.rotation.x = clampf(
            camera_pivot.rotation.x,
            -deg_to_rad(PITCH_LIMIT_DEG),
            deg_to_rad(PITCH_LIMIT_DEG))

func set_hovered_station(s: StationBase) -> void:
    hovered_station = s

func get_ring_ui() -> ShrinkingCircleUI:
    return get_tree().get_first_node_in_group(&"shrinking_circle_ui")

## Web-safe ArmViewport gating (HC-5)
func set_held_item(item: Node3D) -> void:
    if held_item != null and held_item.get_parent() == hand_anchor:
        hand_anchor.remove_child(held_item)
    held_item = item
    if item != null:
        hand_anchor.add_child(item)
        arm_viewport.update_mode = SubViewport.UPDATE_ALWAYS
    else:
        arm_viewport.update_mode = SubViewport.UPDATE_DISABLED
```

### 5.10 `scripts/StationBase.gd`

```gdscript
class_name StationBase extends Area3D
## Passive data. NEVER reads Input.*. The FSM owns interaction.

enum InteractionType { INSTANT, DISCRETE, ACCUMULATE, TIMING }

@export var station_id: StringName
@export var interaction_type: InteractionType
@export var input_action: StringName = &"interact"

@onready var world_ui: Node3D = $WorldUI                 # Sprite3D / Label3D
@onready var sfx: AudioStreamPlayer3D = $AudioStreamPlayer3D

func _ready() -> void:
    collision_layer = 0b0100   # layer 3
    collision_mask = 0
    monitoring = false
    sfx.attenuation_filter_db = 0.0
    sfx.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED

func show_hover_prompt() -> void:
    world_ui.visible = true

func show_blocked_prompt() -> void:
    world_ui.visible = true

func hide_prompt() -> void:
    world_ui.visible = false

func play_quality_sfx(_q: OrderResult.Quality) -> void:
    sfx.play()

func play_slice_fx(_index: int) -> void:
    sfx.play()

func update_gauge_visual(_pct: float) -> void:
    pass
```

### 5.11 `scripts/OrderManager.gd` — scene-level

```gdscript
class_name OrderManager extends Node
## Scene-level singleton (NOT autoload). Owns ActiveOrder lifetime.

static var singleton: OrderManager

@export var recipe_pool: Array[Recipe] = []

var active_order: ActiveOrder = null
var _last_three_ids: Array[StringName] = []

func _ready() -> void:
    singleton = self

func _exit_tree() -> void:
    if singleton == self:
        singleton = null

func generate_order(seed_recipe: Recipe = null) -> ActiveOrder:
    var r: Recipe = seed_recipe if seed_recipe != null else _pick_recipe()
    var order: ActiveOrder = ActiveOrder.new()
    order.recipe = r
    order.steps_required = _steps_from_recipe(r)
    return order

func is_step_allowed(station_id: StringName) -> bool:
    if active_order == null: return false
    return active_order.is_next_step(station_id)

func complete_step(station_id: StringName, quality: OrderResult.Quality) -> void:
    if active_order == null: return
    active_order.record_step(station_id, quality)   # sloppy-sticky enforced inside

func validate_order() -> bool:
    return active_order != null and active_order.is_complete()

func submit_order() -> OrderResult:
    var result: OrderResult = active_order.compute_result()
    var pay: Vector2 = EconomyManager.process_payment(result, active_order.recipe)
    EventBus.order_completed.emit(result, pay.x, pay.y)
    clear_order()
    return result

func clear_order() -> void:
    active_order = null

func _pick_recipe() -> Recipe:
    var r: Recipe
    var attempts: int = 0
    while attempts < 8:
        r = recipe_pool[randi() % recipe_pool.size()]
        if not _last_three_ids.has(r.id):
            break
        attempts += 1
    _last_three_ids.append(r.id)
    if _last_three_ids.size() > 3:
        _last_three_ids.pop_front()
    return r

func _steps_from_recipe(_r: Recipe) -> Array[StringName]:
    return [&"tortilla", &"trompo", &"toppings", &"sauces", &"bell"]
```

### 5.12 `scripts/resources/ActiveOrder.gd`

```gdscript
class_name ActiveOrder extends Resource
## Per-order mutable state. Sloppy-sticky enforced here (HC-7).

var recipe: Recipe
var steps_required: Array[StringName] = []
var step_quality: Dictionary[StringName, int] = {}   # int from OrderResult.Quality
var current_step_idx: int = 0

func is_next_step(station_id: StringName) -> bool:
    if current_step_idx >= steps_required.size(): return false
    return steps_required[current_step_idx] == station_id

func record_step(station_id: StringName, q: OrderResult.Quality) -> void:
    var prev: OrderResult.Quality = OrderResult.Quality.PERFECT
    if step_quality.has(station_id):
        prev = step_quality[station_id]
        if prev == OrderResult.Quality.SLOPPY and q == OrderResult.Quality.PERFECT:
            return                                   # sticky: ignore upgrade
    step_quality[station_id] = q
    if station_id == steps_required[current_step_idx]:
        current_step_idx += 1

func is_complete() -> bool:
    return current_step_idx >= steps_required.size()

func compute_result() -> OrderResult:
    var has_wrong: bool = false
    var has_sloppy: bool = false
    for k in step_quality:
        match step_quality[k]:
            OrderResult.Quality.WRONG:  has_wrong = true
            OrderResult.Quality.SLOPPY: has_sloppy = true
    var r: OrderResult = OrderResult.new()
    if has_wrong:    r.quality = OrderResult.Quality.WRONG
    elif has_sloppy: r.quality = OrderResult.Quality.SLOPPY
    else:            r.quality = OrderResult.Quality.PERFECT
    r.fill_multipliers_for_quality()
    return r
```

### 5.13 Resource scripts

```gdscript
# scripts/resources/OrderResult.gd
class_name OrderResult extends Resource
enum Quality { PERFECT, ACCEPTABLE, SLOPPY, WRONG, ABANDONED }

@export var quality: Quality = Quality.ACCEPTABLE
@export var payment_multiplier: float = 1.0
@export var tip_multiplier: float = 0.0

func fill_multipliers_for_quality() -> void:
    match quality:
        Quality.PERFECT:    payment_multiplier = 1.00; tip_multiplier = 0.25
        Quality.ACCEPTABLE: payment_multiplier = 1.00; tip_multiplier = 0.00
        Quality.SLOPPY:     payment_multiplier = 0.75; tip_multiplier = 0.00
        Quality.WRONG:      payment_multiplier = 0.00; tip_multiplier = 0.00
        Quality.ABANDONED:  payment_multiplier = 0.00; tip_multiplier = 0.00
```

```gdscript
# scripts/resources/Recipe.gd
class_name Recipe extends Resource
@export var id: StringName
@export var display_name: String = ""
@export var base_price: float = 5.0
@export var protein: StringName = &"trompo"          # fixed
@export var topping_pool_weighted: Dictionary[StringName, float] = {}
@export var topping_count_range: Vector2i = Vector2i(2, 4)
@export var sauce_count_range: Vector2i = Vector2i(0, 2)
```

```gdscript
# scripts/resources/IngredientResource.gd
class_name IngredientResource extends Resource
@export var id: StringName
@export var display_name: String = ""
@export var food_cost: float = 0.05
@export var interaction_type: StationBase.InteractionType = StationBase.InteractionType.TIMING
@export var station_id: StringName
```

```gdscript
# scripts/resources/DifficultyEntry.gd
class_name DifficultyEntry extends Resource
@export var patience_seconds: float = 45.0
@export var spawn_interval_seconds: float = 8.0
@export var max_concurrent_customers: int = 1
@export var daily_quota: float = 15.0
@export var unlocked_ingredients: Array[StringName] = []
```

```gdscript
# scripts/resources/DifficultySchedule.gd
class_name DifficultySchedule extends Resource
@export var entries: Array[DifficultyEntry] = []
```

```gdscript
# scripts/resources/EconomyResource.gd
class_name EconomyResource extends Resource
@export var starting_balance: float = 0.0
@export var topping_miss_cost: float = 0.05
@export var customer_abandon_cost: float = 0.50
```

```gdscript
# scripts/resources/UpgradeResource.gd
class_name UpgradeResource extends Resource
@export var id: StringName
@export var display_name: String = ""
@export var cost: float = 0.0
@export var effect_key: StringName
@export var effect_value: float = 0.0
```

```gdscript
# scripts/resources/DaySummary.gd
class_name DaySummary extends Resource
@export var day_number: int = 1
@export var balance: float = 0.0
@export var quota: float = 0.0
@export var quota_met: bool = false
@export var perfect_count: int = 0
@export var sloppy_count: int = 0
@export var wrong_count: int = 0
@export var abandoned_count: int = 0
```

### 5.14 `scripts/CustomerNPC.gd` (poolable)

```gdscript
class_name CustomerNPC extends CharacterBody3D

const WALK_SPEED: float = 1.6

@export var customer_id: int = 0
@onready var arc_bar: MeshInstance3D = $PatientArcBar       # shader param fill_amount
@onready var bubble: Label3D = $SpeechBubble

var recipe: Recipe = null
var patience_remaining: float = 0.0
var patience_total: float = 0.0
var target_position: Vector3 = Vector3.ZERO
var in_active_slot: bool = false

func reset_pooled_state() -> void:                  # NodePool contract (5.2)
    customer_id = 0
    recipe = null
    patience_remaining = 0.0
    patience_total = 0.0
    velocity = Vector3.ZERO
    in_active_slot = false
    bubble.text = ""

func assign_order(r: Recipe, patience: float) -> void:
    recipe = r
    patience_remaining = patience
    patience_total = patience

func _physics_process(delta: float) -> void:
    if GameManager.is_input_locked(): return
    if global_position.distance_to(target_position) > 0.05:
        global_position = global_position.move_toward(target_position, WALK_SPEED * delta)
        return
    if not in_active_slot: return
    patience_remaining = maxf(0.0, patience_remaining - delta)
    var fill: float = patience_remaining / patience_total
    (arc_bar.material_override as ShaderMaterial).set_shader_parameter(&"fill_amount", fill)
    if patience_remaining <= 0.0:
        EventBus.order_abandoned.emit(customer_id, _food_cost_estimate())

func _food_cost_estimate() -> float:
    return EconomyManager.economy.customer_abandon_cost
```

### 5.15 `scripts/CustomerSpawner.gd`

```gdscript
class_name CustomerSpawner extends Node3D

@export var slot_markers: Array[NodePath] = []

var _slots: Array[Marker3D] = []
var _spawn_timer: Timer
var _occupants: Array[CustomerNPC] = []
var _next_id: int = 1

func _ready() -> void:
    for p in slot_markers:
        _slots.append(get_node(p) as Marker3D)
    _spawn_timer = Timer.new()
    _spawn_timer.one_shot = false
    _spawn_timer.timeout.connect(_on_spawn)
    add_child(_spawn_timer)
    _occupants.resize(_slots.size())
    _restart_timer()

func _restart_timer() -> void:
    var diff: DifficultyEntry = GameManager.get_current_difficulty()
    _spawn_timer.wait_time = diff.spawn_interval_seconds
    _spawn_timer.start()

func _on_spawn() -> void:
    if _occupants_count() >= GameManager.get_current_difficulty().max_concurrent_customers:
        return
    var slot_idx: int = _first_open_slot()
    if slot_idx < 0: return
    var c: CustomerNPC = NodePool.checkout(&"customer") as CustomerNPC
    c.customer_id = _next_id
    _next_id += 1
    c.assign_order(OrderManager.singleton.generate_order().recipe,
        GameManager.get_current_difficulty().patience_seconds)
    c.target_position = _slots[slot_idx].global_position
    c.in_active_slot = true
    _occupants[slot_idx] = c
    add_child(c)
    c.global_position = _slots[slot_idx].global_position + Vector3(0, 0, 4.0)  # offscreen entry

func _first_open_slot() -> int:
    for i in _slots.size():
        if _occupants[i] == null: return i
    return -1

func _occupants_count() -> int:
    var n: int = 0
    for o in _occupants:
        if o != null: n += 1
    return n
```

### 5.16 `scripts/StrikeTracker.gd` (scene-level)

```gdscript
class_name StrikeTracker extends Node

const MAX_STRIKES: int = 3
var strikes: int = 0

func _ready() -> void:
    EventBus.order_abandoned.connect(_on_order_abandoned)
    EventBus.order_completed.connect(_on_order_completed)

func _on_order_abandoned(_id: int, _cost: float) -> void:
    _add_strike()

func _on_order_completed(result: OrderResult, _p: float, _t: float) -> void:
    if result.quality == OrderResult.Quality.WRONG:
        _add_strike()

func _add_strike() -> void:
    strikes += 1
    EventBus.strike_added.emit(strikes)
    if strikes >= MAX_STRIKES:
        GameManager.end_day_immediately()
```

### 5.17 `scripts/Settings.gd` (singleton-by-resource, NOT autoload)

```gdscript
class_name Settings extends Object
## Static cached settings. Loaded from save dict on game start.

static var mouse_sensitivity: float = 0.0025
static var fov_degrees: float = 75.0
static var hold_to_tap_enabled: bool = false
static var master_volume_db: float = 0.0
static var music_volume_db: float = 0.0
static var sfx_volume_db: float = 0.0

static func collect_dict() -> Dictionary:
    return {
        "mouse_sensitivity": mouse_sensitivity,
        "fov_degrees": fov_degrees,
        "hold_to_tap_enabled": hold_to_tap_enabled,
        "master_volume_db": master_volume_db,
        "music_volume_db": music_volume_db,
        "sfx_volume_db": sfx_volume_db,
    }

static func apply_dict(d: Dictionary) -> void:
    mouse_sensitivity = d.get("mouse_sensitivity", mouse_sensitivity)
    fov_degrees = d.get("fov_degrees", fov_degrees)
    hold_to_tap_enabled = d.get("hold_to_tap_enabled", hold_to_tap_enabled)
    master_volume_db = d.get("master_volume_db", master_volume_db)
    music_volume_db = d.get("music_volume_db", music_volume_db)
    sfx_volume_db = d.get("sfx_volume_db", sfx_volume_db)
```

---

## 6. Scene Tree (canonical, names are bindings)

```
TruckInterior (Node3D)
├── World (Node3D)
│   ├── TruckShell (MeshInstance3D + StaticBody3D)         [layer 1]
│   ├── LightmapGI                                          [bake quality: Medium]
│   ├── DirectionalLight3D                                  [bake_mode = STATIC]
│   └── OmniLight3D                                         [bake_mode = STATIC]
├── Stations (Node3D)
│   ├── TortillaStation        (Station.tscn — INSTANT)
│   ├── TrompoStation          (Station.tscn — DISCRETE)
│   ├── ToppingBin_Cilantro    (Station.tscn — TIMING)
│   ├── ToppingBin_Onion       (Station.tscn — TIMING)
│   ├── SauceBottle_Red        (Station.tscn — ACCUMULATE)
│   ├── SauceBottle_White      (Station.tscn — ACCUMULATE)
│   └── ServiceBell            (Station.tscn — INSTANT)
├── QueueSystem (Node3D)
│   ├── CustomerSpawner (Node3D, CustomerSpawner.gd)
│   └── QueueSlots (Node3D)
│       ├── Slot1 (Marker3D), Slot2 (Marker3D), Slot3 (Marker3D)
├── Player (Player.tscn — see §6.1)
├── OrderManager (Node, OrderManager.gd)                   [scene-level]
├── StrikeTracker (Node, StrikeTracker.gd)
├── TutorialSequencer (Node, TutorialSequencer.gd)         [freed after Day 0]
└── HUDRoot (CanvasLayer)
    ├── MidnightMunchHUD (Control)
    ├── ObjectiveHUD (Control)
    ├── BankBalanceHUD (Control)
    ├── BellConfirmationPopup (Control)                    [hidden]
    ├── EndOfDayScreen (Control)                           [hidden]
    ├── PauseMenu (Control)                                [hidden]
    └── DebugOverlay (Control)                             [F3 toggle]
```

### 6.1 `Player.tscn` subtree

```
Player (CharacterBody3D)                                   [layer 1]
├── CollisionShape3D (capsule)
├── CameraPivot (Node3D)
│   ├── MainCamera (Camera3D)                              [cull_mask = ~bit3 / excludes layer 4]
│   └── InteractionRayCast (RayCast3D)                     [length 3.0, mask = bit2 only / layer 3]
├── ArmViewportContainer (SubViewportContainer, stretch=true)
│   └── ArmViewport (SubViewport)                          [transparent_bg=true, use_hdr_2d=false, msaa=DISABLED, update=DISABLED]
│       └── ArmCamera (Camera3D)                           [cull_mask = bit3 only / layer 4]
│           └── HandTransform (Marker3D)
└── InteractionStateMachine (Node, InteractionStateMachine.gd)
    ├── IdleState (Node, IdleState.gd)
    ├── HoverState (Node, HoverState.gd)
    ├── ActiveInstantState (Node, ActiveInstantState.gd)
    ├── ActiveDiscreteState (Node, ActiveDiscreteState.gd)
    ├── ActiveAccumulateState (Node, ActiveAccumulateState.gd)
    ├── ActiveTimingState (Node, ActiveTimingState.gd)
    └── LockedState (Node, LockedState.gd)
```

### 6.2 `Station.tscn` (base)

```
Station (Area3D, StationBase.gd)                           [layer 3 only, monitoring=false, monitorable=true]
├── CollisionShape3D                                       [1.5× mesh extent]
├── Visuals (Node3D)
│   └── MeshInstance3D
├── WorldUI (Sprite3D or Label3D)
└── AudioStreamPlayer3D                                    [doppler off, no reverb bus]
```

### 6.3 `CustomerNPC.tscn`

```
CustomerNPC (CharacterBody3D, CustomerNPC.gd)              [layer 2, mask layers 1 & 2 — toggled off during compaction]
├── CollisionShape3D
├── PatientArcBar (MeshInstance3D)                         [ShaderMaterial unique-on-instance]
├── SpeechBubble (Label3D)
└── (Optional) AudioStreamPlayer3D
```

---

## 7. Signal Architecture — "Call Down, Signal Up"

### 7.1 Cross-domain (EventBus only)

| Signal | Payload | Emitter | Subscribers |
|---|---|---|---|
| `order_accepted` | `customer_id: int, recipe: Recipe` | `OrderManager` | `ObjectiveHUD` |
| `order_completed` | `result: OrderResult, payment: float, tip: float` | `OrderManager` | `EconomyManager`, `MidnightMunchHUD`, `StrikeTracker`, `BankBalanceHUD` |
| `order_abandoned` | `customer_id: int, food_cost: float` | `CustomerNPC` | `EconomyManager`, `StrikeTracker`, `MidnightMunchHUD` |
| `balance_changed` | `new_balance: float, delta: float` | `EconomyManager` | `BankBalanceHUD` |
| `strike_added` | `current_strikes: int` | `StrikeTracker` | `MidnightMunchHUD`, `GameManager` (transitively, via `end_day_immediately`) |
| `day_ended` | `summary: DaySummary` | `GameManager` | `EndOfDayScreen`, `SaveSystem` (via `EndOfDayScreen`'s `_ready` autosave) |
| `save_corrupted` | `()` | `SaveSystem` | `MainMenu`, `MidnightMunchHUD` |

### 7.2 Local-domain (direct child→parent / sibling connection, NOT bus)

- `Hover` state pulse signal driving `IngredientPill` highlight.
- `BellStation` validation result before deciding to spawn `BellConfirmationPopup`.
- Modal popup `confirm`/`cancel` to spawning station.
- `TutorialSequencer` step-completed signal to its own UI.

**Anti-pattern guardrail:** If a station script needs to fire across the architecture (e.g., to economy), it routes through `OrderManager` → `EventBus`. Stations never call `EconomyManager` directly.

---

## 8. WebGL2 / Compatibility Renderer Constraints

### 8.1 Forbidden engine features (silently no-op or crash on web export)

| Feature | Reason | Replacement |
|---|---|---|
| `GPUParticles3D` | Compute not available | `CPUParticles3D` |
| `SDFGI`, `VoxelGI` | Compute / heavy fragment | `LightmapGI` baked |
| `SSAO`, `SSIL`, `SSR` | Compatibility lacks pass | None — skip |
| Volumetric fog | Compute | None |
| Glow/HDR bloom | Off in Compatibility | Static texture overlays |
| `CompositorEffect` | Forward+ only | None |
| `NavigationAgent3D` for queue | Web jitter | `move_toward()` per frame |
| `SharedArrayBuffer` / WASM threads | Hosting hostile | Single-threaded WASM |
| `emit_signal("name", …)` | String-lookup cost on web | `.emit(…)` typed |

### 8.2 Required practices

- All particles: `CPUParticles3D`, pre-budgeted at ≤32 active particles per emitter.
- All audio: `reverb_bus = "Master"` literally — no bus reverb, no Doppler. UI audio uses `AudioStreamPlayer` (non-3D) on a separate `SFX_UI` bus.
- Lightmaps: `LightmapGI` with bake quality `Medium` (Compatibility does not support High/Ultra).
- Texture import: VRAM compression on for mobile/web; albedo at 1024² max for stations, 256² for HUD icons.
- `await` every IndexedDB-touching `FileAccess.open` write path.
- `_physics_process` is the cadence anchor; `_process` only for visual-only updates (e.g., `ArmCamera` mirror).

### 8.3 Memory management & GC on WebGL

Godot's web export does not benefit from aggressive cleanup; pooled nodes must outlive their use. The implementation rules:

1. **Zero `queue_free()` calls during gameplay.** All transient nodes go through `NodePool`.
2. **Zero `instantiate()` calls during gameplay.** Pre-warmed pools cover all expected live counts × 4.
3. **Strong references die with the scene.** When `TruckInterior.tscn` reloads on `advance_to_next_day`, every pool is recreated cleanly.
4. **No closures captured in long-lived objects.** Closures hold scope references — they leak. Use bound methods instead.
5. **Disconnect signals on `_exit_tree`** for any node with a non-trivial lifetime that subscribes to autoload events (nodes within `TruckInterior` scene root do not need to disconnect; scene reload tears down).
6. **`Tween` instances are bound to a node**, never held in a member variable across reloads; create with `create_tween()` each use.

---

## 9. Race Conditions & Edge Cases (explicit rulings)

### 9.1 End-of-day timer expiry vs in-flight input

**Ruling (HC-3, GDD §4.7):** `GameManager.phase = END_OF_DAY` flips **before** `EventBus.day_ended.emit(summary)`. Any `_physics_process` already running on the same tick will, on its next call, hit `is_input_locked() == true` at line 1 and return. The FSM transitions to `LockedState` on its next `_physics_process` (idempotent).

### 9.2 Modal popup vs underlying input

Modal popups (`BellConfirmationPopup`, `PauseMenu`) set `GameManager.modal_open = true` in `_ready` and clear it in `_exit_tree`. `is_input_locked()` honors this flag.

### 9.3 Bell rung on incomplete order

`BellStation` (INSTANT) → `OrderManager.validate_order()`:
- Complete + all green: `submit_order()`.
- Incomplete: spawn `BellConfirmationPopup`. `[YES]` debits food cost and emits `order_abandoned` (counts as +1 strike). `[NO]` returns to `Idle`.

### 9.4 Sloppy stickiness

In `ActiveOrder.record_step`, if `step_quality[id] == SLOPPY` and incoming `q == PERFECT`, the upgrade is **dropped**. WRONG → SLOPPY downgrades are still allowed (any worse outcome wins).

### 9.5 Recipe duplicate prevention

`OrderManager._pick_recipe()` retries up to 8 times if the candidate's `id` is in `_last_three_ids`. After 8 retries it accepts whatever it has, to avoid hangs in tiny recipe pools.

### 9.6 Save corruption

`SaveSystem.load()` returns a fresh save dict if any of: file missing, `JSON.parse_string` returns non-Dictionary, missing `save_version`, missing `current_day`. Emits `EventBus.save_corrupted` so UI can surface a "save reset" notice.

### 9.7 Pool exhaustion

Debug builds assert. Release builds `push_warning` and fall back to `instantiate()` (acknowledging a one-off allocation cost is preferable to a crash). Returned exhaustion-spawned nodes go back into the pool, expanding it.

### 9.8 ArmViewport flicker on first held item

`set_held_item(item)` flips `update_mode` to `UPDATE_ALWAYS` **after** `add_child(item)`. The first frame after the flip will render with the item already parented. There is no gap.

### 9.9 Customer spawned during END_OF_DAY

`CustomerSpawner._on_spawn` first-line guard: `if GameManager.phase != PLAYING: return` (added to the impl above implicitly via `is_input_locked()`-equivalent check; also explicitly verified in tests).

---

## 10. Sprint Plan (binding)

Sprints are binding gates. Each sprint has explicit exit criteria. A sprint cannot be marked complete unless **every** bullet under "exit gate" passes manual or automated test.

### Sprint 0 — Bootstrap (2–3 days)
- Project, input map, layers, autoload registration (empty stubs).
- Resource scripts (no `.tres` instances yet).
- **Exit gate:** Project boots to black scene; all 4 autoloads `_ready` prints ok; `gdformat`/`gdlint` pass; web export produces a runnable HTML build.

### Sprint 1 — Movement, Camera, FSM Skeleton (3–4 days)
- `TruckInterior.tscn` greybox (CSG OK).
- `Player.tscn` rig (CharacterBody3D, MainCamera, ArmViewport per §6.1).
- Mouse-look clamped ±85°, `MOUSE_MODE_CAPTURED`.
- `InteractionStateMachine` parent + 7 state stubs; every state's `_physics_process` first line is the lock check.
- Raycast layer 3 only.
- **Exit gate:** Player walks; raycast hovers over greybox station Area3D; HUD prints which station is hovered; Locked state intercepts on `phase = END_OF_DAY`.

### Sprint 2 — Four Interactions in Isolation (5–7 days)
- **First task:** `Active_Timing` spike (highest web risk). Tune target band in Chrome **and** Firefox.
- Then: `Active_Instant` (tortilla, bell), `Active_Discrete` (trompo), `Active_Accumulate` (sauce).
- Audio fires one physics tick after visual commit (HC-10).
- Stub `OrderManager.complete_step` accepting `(StringName, OrderResult.Quality)`.
- **Exit gate:** All 4 mechanics feel right at 60 FPS in Firefox; audio reliably post-visual; no GPU particles anywhere (`grep` in `.tscn`).

### Sprint 3 — Order, Customer, Economy Loop (4–6 days)
- Full `OrderManager` with `ActiveOrder`, `Recipe` weighted sampling, last-3 dedupe.
- `ObjectiveHUD` ingredient pills with state styles.
- `CustomerSpawner` + `CustomerNPC` pool, patience drain in `_physics_process`, queue compaction (collision layer 2 toggle).
- `BellStation` → `validate_order` → confirm popup → `submit_order` or `order_abandoned`.
- `EconomyManager.process_payment` and debit cascades; `BankBalanceHUD` flash.
- **Exit gate:** Click queued customer → accept order → 4-station sequence → bell → balance updates correctly through `EventBus`.

### Sprint 4 — Day Loop, Strikes, Progression (3–4 days)
- `GameManager.start_day` / `end_day_normal` / `end_day_immediately`; phase flip BEFORE emit.
- `StrikeTracker` (3 strikes → immediate end).
- `EndOfDayScreen` with tween count-up; auto-save on show via `SaveSystem.save`.
- `UpgradeShopUI` + `UpgradeResource` purchases; `purchased_upgrades` written to save.
- `SaveSystem.save/load` with corruption recovery (HC-9); `save_version: 1`.
- **Exit gate:** Days 1–5 playable end-to-end; refresh browser → `[Continue]` resumes correct day, balance, upgrades.

### Sprint 5 — Tutorial & Accessibility (2–3 days)
- `TutorialSequencer` (Day 0): forces `phase = TUTORIAL`, single customer, ∞ patience, station highlight cascade.
- 5 scripted orders with diminishing prompts; sets `tutorial_completed = true` then `queue_free()` itself.
- Settings: input remap (6 actions), FOV 60–90, mouse sens, hold-to-tap toggle, audio bus volumes.
- Color-blind audit: deuteranopia + protanopia simulators on topping palette; `IngredientPill` adds icon channel.
- **Exit gate:** New player completes Day 0 with no external help; settings persist through reload.

### Sprint 6 — Audio, Juice, Web QA (3–4 days)
- Audio buses: `Master`, `Music`, `SFX_World`, `SFX_UI`. World plays from `_physics_process` one tick post-visual.
- Particles: every effect from GDD §6 wired to `CPUParticles3D`. Audit every `.tscn` for `GPUParticles3D` (forbidden).
- Screen shake values exact from GDD §6 table; `Tween` on `MainCamera.h_offset` / `v_offset`, 0.15 s decay.
- CSG → `MeshInstance3D + ConcavePolygonShape3D` bake; `LightmapGI` Medium bake; verify atlas size keeps total export ≤ 50 MB.
- Web export, WASM threads disabled, run in Chrome + Firefox + Chromebook.
- 24-h idle soak on `EndOfDayScreen` in Firefox to catch IndexedDB / audio context regressions.
- **Exit gate:** Sustained 60 FPS in Firefox on Chromebook-class hardware with 3-customer queue + active accumulate gauge; zero `instantiate()` / `queue_free()` calls during gameplay (verify via Godot profiler).

---

## 11. File Layout (binding)

```
res://
├── autoload/
│   ├── EventBus.gd
│   ├── NodePool.gd
│   ├── EconomyManager.gd
│   └── GameManager.gd
├── scenes/
│   ├── MainMenu.tscn
│   ├── TruckInterior.tscn
│   ├── Player.tscn
│   ├── stations/
│   │   ├── Station.tscn                    [base]
│   │   ├── TortillaStation.tscn
│   │   ├── TrompoStation.tscn
│   │   ├── ToppingBin_Cilantro.tscn
│   │   ├── ToppingBin_Onion.tscn
│   │   ├── SauceBottle_Red.tscn
│   │   ├── SauceBottle_White.tscn
│   │   └── ServiceBell.tscn
│   ├── items/
│   │   ├── Tortilla.tscn
│   │   ├── Topping_Cilantro.tscn
│   │   ├── Topping_Onion.tscn
│   │   └── SauceSplat_Red.tscn
│   ├── CustomerNPC.tscn
│   └── HUD/
│       ├── MidnightMunchHUD.tscn
│       ├── ObjectiveHUD.tscn
│       ├── IngredientPill.tscn
│       ├── BankBalanceHUD.tscn
│       ├── BellConfirmationPopup.tscn
│       ├── EndOfDayScreen.tscn
│       ├── PauseMenu.tscn
│       └── DebugOverlay.tscn
├── scripts/
│   ├── Player.gd
│   ├── StationBase.gd
│   ├── OrderManager.gd
│   ├── StrikeTracker.gd
│   ├── CustomerNPC.gd
│   ├── CustomerSpawner.gd
│   ├── TutorialSequencer.gd
│   ├── SaveSystem.gd
│   ├── Settings.gd
│   ├── ShrinkingCircleUI.gd
│   ├── fsm/
│   │   ├── State.gd
│   │   ├── InteractionStateMachine.gd
│   │   ├── IdleState.gd
│   │   ├── HoverState.gd
│   │   ├── ActiveInstantState.gd
│   │   ├── ActiveDiscreteState.gd
│   │   ├── ActiveAccumulateState.gd
│   │   ├── ActiveTimingState.gd
│   │   └── LockedState.gd
│   └── resources/
│       ├── ActiveOrder.gd
│       ├── Recipe.gd
│       ├── IngredientResource.gd
│       ├── DifficultyEntry.gd
│       ├── DifficultySchedule.gd
│       ├── OrderResult.gd
│       ├── EconomyResource.gd
│       ├── UpgradeResource.gd
│       └── DaySummary.gd
└── data/
    ├── difficulty/Schedule.tres
    ├── recipes/Recipe_AlPastor.tres
    ├── ingredients/Cilantro.tres, Onion.tres, ...
    └── upgrades/SharperKnife.tres, ...
```

---

## 12. Verification & Acceptance Criteria

### 12.1 End-to-end pass

1. Fresh install → `[New Game]` → Day 0 tutorial → 5 guided orders → `tutorial_completed` flag persists.
2. Day 1 → 5-min timer; 3 concurrent max; quota = $15; all 4 interaction types exercised; ≥1 PERFECT and ≥1 SLOPPY observed.
3. Force 3 strikes mid-day → immediate `END_OF_DAY`; subsequent input ignored.
4. EndOfDay → buy `sharper_knife` → reload → `Trompo.fill_per_press` reflects new value via `GameManager.get_upgrade_value`.
5. Browser refresh → `[Continue]` → resumes Day 2 with persisted balance and upgrades.
6. Manually corrupt `user://save.json` (delete `save_version`) → relaunch → `save_corrupted` emits, fresh save created, no crash.
7. Profile Firefox on Chromebook-class hardware → 60 FPS sustained for 5-min session, no GC stutters.

### 12.2 Architectural invariants (CI/lint candidates)

- `grep -r "emit_signal(" res://` returns nothing.
- `grep -r "GPUParticles3D" res://` returns nothing.
- `grep -r "queue_free" res://scripts` returns only entries inside `_exit_tree` of scene-root nodes (never per-frame paths).
- `grep -r "instantiate(" res://scripts` returns only `NodePool._prewarm` and exhaustion fallback.
- `grep -rn "Input\." res://scenes/stations/` returns nothing.
- Every `func _physics_process` in `res://scripts/fsm/` has `if GameManager.is_input_locked(): return` as its first line.
- `Settings.fov_degrees` clamped to `[60, 90]` on apply.
- `LightmapGI` bake quality is Medium or Low (never High/Ultra).

### 12.3 Performance acceptance

- Frame time histogram in Firefox over 5 min: P95 ≤ 16.6 ms, P99 ≤ 24 ms.
- Initial download ≤ 50 MB (gzipped where the host supports).
- Zero `instantiate()` / `queue_free()` events during the 5-minute session (Godot profiler).
- ArmViewport `update_mode` log: `UPDATE_ALWAYS` only while `held_item != null`.

### 12.4 Audio acceptance

- Every quality outcome plays its SFX from `_physics_process` one tick after the visual commit (visible in profiler trace as audio sample one frame behind particle spawn).
- Reverb and Doppler off on every `AudioStreamPlayer3D` in the scene tree (audit with `grep` over `.tscn` files).

---

## 13. Cut-Order Mechanics (binding)

If schedule slips, cut in this order. **Do not improvise alternative cuts.**

| Order | Cut | Code-side actions |
|---|---|---|
| 1 | Sauce stations | Remove `ActiveAccumulateState` from `InteractionStateMachine`; delete sauce `.tscn`s; `Recipe.sauce_count_range = Vector2i(0, 0)`. |
| 2 | Queue compaction | Cap `max_concurrent_customers = 2` schedule-wide; remove `move_toward` block in `CustomerNPC._physics_process` (slot teleport instead). |
| 3 | SubViewport arms | Delete `ArmViewportContainer`; render arms on layer 1 with depth-bias material; delete `Player.set_held_item`'s `update_mode` toggle. |
| 4 | Tip system | `OrderResult.tip_multiplier = 0.0` for all qualities; `EconomyManager.process_payment` returns `Vector2(base, 0.0)`. |
| 5 | Topping SLOPPY granularity | `ActiveTimingState._commit` collapses SLOPPY → WRONG when outside band. |

---

## 14. Open Items Resolved by This SDD

| Item | Resolution |
|---|---|
| Static typing scope | §3 — every `var`, param, return, signal arg, `@export`. |
| `NodePool` reset semantics | §5.2 — reset on `return_node`, never on `checkout`. Per-node `reset_pooled_state()` contract. |
| Memory model on WebGL | §8.3 — zero per-frame `queue_free`/`instantiate`; pools survive scene reload via re-init. |
| Signal payload types | §7.1 — fully typed; `Recipe`, `OrderResult`, `DaySummary` are `Resource` subclasses. |
| ArmViewport toggle trigger | §5.9 `set_held_item` flips `update_mode`; only entry point that sets `held_item`. |
| Modal vs phase lock | §5.3 — `is_input_locked()` returns true if `phase != PLAYING` OR `modal_open`. |
| End-of-day race | §9.1 — phase flip before emit; FSM `LockedState` idempotent. |
| Save corruption flow | §5.5 — schema-key check + `save_corrupted` signal + fresh save fallback. |
| Recipe dedupe window | §5.11 — last-3 with 8-retry cap to avoid hangs. |
| Sloppy stickiness | §5.12 `ActiveOrder.record_step` ignores PERFECT after SLOPPY. |
| `OrderManager` lifetime | §5.11 — scene-level singleton (`static var singleton`); cleared in `_exit_tree`. |
| Audio post-visual | §5.8 `ActiveTimingState._commit` uses `call_deferred`; §6.2 sprint task verifies the pattern across all SFX. |
