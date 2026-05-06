# Midnight Munch — Technical Game Design Document v3.4

**Target Engine:** Godot 4.6 (GDScript only)
**Target Platform:** WebGL2 / HTML5 (desktop browsers, Chromebook-class minimum)
**Target Performance:** Stable 60 FPS, <16ms frame budget, <50MB initial download

---

## 1. Game Overview & Mechanics

### 1.1 High-Level Pitch

*Midnight Munch* is a first-person time-management cooking sim in 5-minute sessions. The player runs a late-night taco truck, assembling procedurally generated orders through four distinct timing-based interactions while managing a queue of patience-decaying customers.

### 1.2 Core Session Loop (5:00 timer)

1. **Triage** — Click a queued customer to accept their order.
2. **Assembly** — Visit stations in strict sequence: Tortilla → Trompo → Toppings → Sauces.
3. **Service** — Ring the bell to validate and serve.
4. **Repeat** until timer expires or 3 strikes.
5. **Post-Mortem** — Daily summary, economy update, unlock check.

### 1.3 The Four Interaction Types

| Type | Example Station | Input Pattern | Quality Determined By |
|---|---|---|---|
| `INSTANT` | Tortilla, Bell | Single press | N/A (binary success) |
| `DISCRETE` | Trompo (3 slices) | 3 precise presses | Rhythm consistency |
| `ACCUMULATE` | Sauce bottles | Hold-to-fill gauge | Release within target band |
| `TIMING` | Toppings | Press inside shrinking ring | Ring radius at press |

### 1.4 Order Resolution Spectrum

| Result | Payment | Tip | Customer Reaction |
|---|---|---|---|
| `PERFECT` | 100% | +25% | Smile, particles |
| `ACCEPTABLE` | 100% | 0% | Neutral nod |
| `SLOPPY` | 75% | −tip | Frown |
| `WRONG` | 0% | 0% | Anger, +1 strike |
| `ABANDONED` | −food cost | 0% | Walk-off, +1 strike |

### 1.5 Strikes & Day End

- 3 strikes → day ends immediately, transitions to `END_OF_DAY` phase.
- 5:00 timer expiry → day ends after current order resolves.
- Goal: earn ≥ daily quota (defined per `DifficultyEntry`) to unlock next day.

---

## 2. Scene & Node Architecture

### 2.1 Main Scene Structure

```
TruckInterior (Node3D)
├── Environment (Node3D)
│   ├── TruckShell (MeshInstance3D + StaticBody3D, baked from CSG pre-ship)
│   ├── LightmapGI (baked)
│   └── Lighting (DirectionalLight3D STATIC + OmniLight3D STATIC)
├── QueueSystem (Node3D)
│   ├── CustomerSpawner (Node3D)
│   └── QueueSlots (Node3D)
│       ├── Slot1, Slot2, Slot3 (Marker3D)
├── Stations (Node3D)
│   ├── TortillaStation (PackedScene)
│   ├── TrompoStation (PackedScene)
│   ├── ToppingBin_Cilantro (PackedScene)
│   ├── SauceBottle_Red (PackedScene)
│   └── ServiceBell (PackedScene)
├── TutorialSequencer (Node — freed after Day 0)
└── Player (PackedScene)
```

### 2.2 Player Scene (`Player.tscn`)

The `SubViewport` renders the player's arms and held items on physics layer 4, preventing clipping through truck walls. `ArmViewport` update mode is set to `UPDATE_ALWAYS` only while a held item exists; otherwise `UPDATE_DISABLED`.

```
Player (CharacterBody3D)
├── CollisionShape3D (standing hitbox)
├── CameraPivot (Node3D)
│   ├── MainCamera (Camera3D — cull_mask excludes layer 4)
│   └── InteractionRayCast (RayCast3D — 3.0m, masks layer 4)
├── ArmViewportContainer (SubViewportContainer)
│   └── ArmViewport (SubViewport — transparent BG, no HDR, no MSAA)
│       └── ArmCamera (Camera3D — cull_mask = layer 4 only)
│           └── HandTransform (Marker3D — held item anchors here)
├── ViewportCanvas (CanvasLayer)
│   ├── MidnightMunchHUD (Control)
│   ├── PauseMenu (Control)
│   └── DebugOverlay (Control — F3 toggle)
└── InteractionStateMachine (Node)
    ├── Idle (Node)
    ├── Hover (Node)
    ├── Active_Instant (Node)
    ├── Active_Discrete (Node)
    ├── Active_Accumulate (Node)
    ├── Active_Timing (Node)
    └── Locked (Node)
```

### 2.3 Base Station Scene (`Station.tscn`)

```
StationBase (Area3D)
├── CollisionShape3D (interaction hitbox)
├── Visuals (Node3D)
│   └── MeshInstance3D
├── WorldUI (Sprite3D or Label3D — context prompt)
└── AudioStreamPlayer3D (interaction SFX — reverb disabled)
```

### 2.4 Composition Strategy

Stations expose two exported properties only:

```gdscript
@export var interaction_type: InteractionType
@export var input_action: StringName
```

The Player's `InteractionStateMachine` reads these via the `RayCast3D` hit and fully owns all input handling. No per-station input scripts. Sequence prerequisites are enforced in `Hover` state, not inside station nodes.

### 2.5 Queue Compaction Strategy

When a customer leaves, `CustomerSpawner` reassigns `target_position` to the next `Marker3D`. NPC-to-NPC collision is disabled during transition. Compaction uses `global_position.move_toward()` per physics frame with a walking animation to fake a smooth shuffle — avoids `NavigationAgent3D` jitter on WebGL2.

---

## 3. Signal & Event Architecture

### 3.1 "Call Down, Signal Up" Rule

Child nodes emit signals upward. The `Player` never reaches into `GameManager` via `get_node("/root/...")`.

### 3.2 EventBus.gd (Autoload — signals only, no logic)

```gdscript
# EventBus.gd
@warning_ignore("unused_signal")

signal order_accepted(customer_id: int, recipe: Recipe)
signal order_completed(result: OrderResult, payment: float, tip: float)
signal order_abandoned(customer_id: int, food_cost: float)
signal balance_changed(new_balance: float, delta: float)
signal strike_added(current_strikes: int)
signal day_ended(summary: DaySummary)
signal save_corrupted()
```

All signals use `.emit()`, never `emit_signal()`. All payload types documented inline.

### 3.3 Cross-Domain Event Flow

```
ServiceBell (local anim complete)
  → OrderManager.validate_order()
    → EventBus.order_completed.emit(result, payment, tip)
      → EconomyManager (updates bank)
      → MidnightMunchHUD (flashes UI)
      → StrikeTracker (increments if WRONG/ABANDONED)
```

### 3.4 Local Order State (`ActiveOrder` Resource)

Holds `Dictionary[StringName, QualityEnum]` mapping each ingredient to its quality. Sloppy is sticky — if `dict[ingredient] == SLOPPY`, subsequent `PERFECT` signals for that ingredient are ignored by `OrderManager`.

---

## 4. GDScript Systems & Data

### 4.1 Singletons / Autoloads (4 maximum)

| Autoload | Responsibility |
|---|---|
| `EventBus` | Signal definitions only |
| `GameManager` | 5-minute timer, day phase, input lock authority |
| `EconomyManager` | Bank balance math, $0 floor, daily quota check |
| `NodePool` | `checkout(id: StringName) → Node` / `return_node(n: Node)` |

**`NodePool` contract:** State is reset on `return_node()`, not on `checkout()`. Pool sizes are pre-warmed to `max_concurrent_customers × 4`. Debug asserts on exhaustion; release build degrades to instancing with a `push_warning`.

### 4.2 Input Lock Authority

`GameManager.is_input_locked() -> bool` is the single source of truth. Every state in the `InteractionStateMachine` calls this at the top of `_physics_process`. No duplicated `day_phase` comparisons elsewhere.

```gdscript
func _physics_process(delta: float) -> void:
    if GameManager.is_input_locked():
        return
    # state logic below
```

### 4.3 Custom Resources (`.tres`)

- **`DifficultyEntry.gd`** — `patience_seconds: float`, `spawn_interval_seconds: float`, `max_concurrent_customers: int`, `daily_quota: float`, `unlocked_ingredients: Array[StringName]`
- **`DifficultySchedule.gd`** — `Array[DifficultyEntry]` indexed by day number
- **`Recipe.gd`** — protein (fixed = trompo), `topping_pool_weighted: Dictionary[StringName, float]`, `topping_count_range: Vector2i`, `sauce_count_range: Vector2i`
- **`OrderResult.gd`** — enum (`PERFECT`, `ACCEPTABLE`, `SLOPPY`, `WRONG`, `ABANDONED`) with payment multipliers

### 4.4 Difficulty Schedule (Reference Targets)

| Day | Concurrent | Patience | Spawn Interval | Quota |
|---|---|---|---|---|
| 0 (Tutorial) | 1 | ∞ | N/A | $0 |
| 1 | 1 | 45s | 8s | $15 |
| 2 | 2 | 40s | 7s | $25 |
| 3 | 2 | 35s | 6s | $35 |
| 4 | 3 | 30s | 5s | $50 |
| 5 | 3 | 25s | 4s | $65 |

### 4.5 State Machine Design (`InteractionStateMachine`)

Base `State` class:

```gdscript
class_name State extends Node

func enter() -> void: pass
func exit() -> void: pass
func physics_update(delta: float) -> void: pass
func handle_input(event: InputEvent) -> void: pass
```

Each concrete state is a child node. Active state is toggled via `set_physics_process(true/false)` and `set_process_input(true/false)`. Only one state active at a time.

**State behaviors:**

- **`Idle`** — Free movement, raycast searching.
- **`Hover`** — Raycast hits `Area3D` station. Sequence prerequisites checked. Prompt visible.
- **`Active_Instant`** — Single press detected, logic fires, returns to `Idle`.
- **`Active_Discrete`** — Listens for 3 `Input.is_action_just_pressed` events in `_physics_process`. Returns to `Idle`.
- **`Active_Accumulate`** — `Input.get_action_strength()` accumulates gauge per physics frame. On release, starts 0.4s `SceneTreeTimer`; timer expiry commits. Returns to `Idle`.
- **`Active_Timing`** — Shrinking ring UI spawned. Listens for commit press. Returns to `Idle`.
- **`Locked`** — Ignores all input. Entered on `END_OF_DAY`.

### 4.6 Recipe Generation Rules

1. Protein: always trompo (fixed, no selection needed).
2. Draw 2–4 toppings from `unlocked_ingredients` weighted pool, without replacement.
3. Draw 0–2 sauces from unlocked sauce pool.
4. Reject any recipe matching either of the previous 3 generated orders (duplicate prevention window).
5. Day index controls `unlocked_ingredients` — start with cilantro + onion, expand per `DifficultyEntry`.

### 4.7 Critical Rulings

**End-of-day race condition:**
`GameManager` emits `day_ended` the moment the 5-minute timer hits 0.0 and sets `day_phase = END_OF_DAY`. `InteractionStateMachine` transitions to `Locked` on the next `_physics_process`. `is_input_locked()` short-circuits any concurrent input on the same frame. End-of-day always wins.

**Save file corruption recovery:**

```gdscript
var data = JSON.parse_string(file.get_as_text())
if typeof(data) != TYPE_DICTIONARY \
        or not data.has("save_version") \
        or not data.has("current_day"):
    push_error("Save file corrupted or schema mismatch.")
    EventBus.save_corrupted.emit()
    return _create_fresh_save()
```

Include `save_version: 1` in all save files from day one. Bump on breaking schema changes.

---

## 5. Tutorial (Day 0)

- Single customer, infinite patience, no timer pressure.
- Station highlights activate in strict sequence; player cannot interact out of order.
- Each station shows a one-line context prompt on first approach.
- On completion, sets `save.tutorial_completed = true`. Skipped automatically on all subsequent days.
- `TutorialSequencer` node is freed from the tree after Day 0 ends.

---

## 6. Audio & Juice Specification

All non-positional UI/feedback sounds use `AudioStreamPlayer` on a dedicated UI audio bus. Station-local sounds use `AudioStreamPlayer3D` with reverb and Doppler **disabled** (performance on WebGL2 audio graph).

| Event | SFX | Particle | Screen Shake (px) |
|---|---|---|---|
| Tortilla grab | Soft thump | None | 0 |
| Trompo slice (each of 3) | Knife chop | Meat puff | 1 |
| Topping PERFECT | Crisp sprinkle | Green burst | 2 |
| Topping SLOPPY | Dull thud | Grey puff | 0 |
| Sauce commit PERFECT | Satisfying squeeze | Red splash | 3 |
| Sauce commit WRONG | Wet splat | Brown puff | 1 |
| Bell PERFECT/ACCEPTABLE | Ding + chime | Gold sparkle | 4 |
| Bell WRONG | Buzz | Red X flash | 6 |
| Customer ABANDONED | Door slam | None | 8 |
| Strike 3 / Day end | Somber sting | None | 0 |

---

## 7. Performance Budget

Target: 60 FPS, 16.6ms frame time, measured in Firefox on Chromebook-class hardware.

| System | Budget |
|---|---|
| Render (main viewport) | 6ms |
| Render (ArmViewport SubViewport) | 2ms |
| Physics + raycast | 2ms |
| GDScript | 3ms |
| Audio | 1ms |
| Headroom | 2.6ms |

**Pre-ship bake requirements:**
- `CSGCombiner3D` truck shell → `MeshInstance3D` + `ConcavePolygonShape3D`
- All lights set to `STATIC` bake mode, rendered into `LightmapGI`
- `ArmViewport`: `use_hdr_2d = false`, MSAA disabled, `UPDATE_DISABLED` when no held item

---

## 8. Accessibility & Pause

- **Esc** pauses the session (timer pauses). Resume / Restart / Quit options.
- Full input remapping screen for all six actions before gameplay starts.
- Topping palette verified against deuteranopia and protanopia (no red/green only distinction).
- **Hold-to-tap toggle** for all `ACCUMULATE` stations (RSI accommodation, off by default).
- Camera FOV: 75° default, adjustable 60°–90° in settings.
- Mouse sensitivity: adjustable, stored in save file.

---

## 9. Web Platform Notes

- `user://` (IndexedDB) writes are async — wrap all saves in `await` and never block mid-frame.
- Test in Firefox specifically; it is stricter than Chrome on `SharedArrayBuffer` and audio context resume.
- Disable `VoxelGI` on web — use baked `LightmapGI` only.
- Use typed signal calls (`.emit()`) throughout; avoid `emit_signal()` string lookups.

---

## 10. Post-Session Screen (Day Summary)

Displayed after every session before returning to the day select.

- Orders served / orders attempted
- PERFECT / ACCEPTABLE / SLOPPY / WRONG / ABANDONED breakdown
- Tips earned vs. base payment
- Total earned vs. daily quota
- Single goal line: "Earn $X to open Day N+1"

This is the primary retention hook. Do not cut.

---

## 11. Scope Cut Priority (if behind schedule)

Cut in this order — each item is independent:

1. **Sauce stations** — reduces interaction modes from 4 to 3; remove `Active_Accumulate` state.
2. **Dynamic queue compaction** — cap at 2 concurrent customers max, remove compaction animation.
3. **SubViewport arms** — replace with single-camera depth-bias trick on layer 4.
4. **Tip system** — flat payments only, remove `PERFECT` tip bonus.
5. **Topping SLOPPY** — binary pass/fail on timing ring, remove partial quality tracking.
```
