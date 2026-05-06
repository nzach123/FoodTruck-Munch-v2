# Midnight Munch — Senior Technical Implementation Plan

**Engine:** Godot 4.6 · GDScript only
**Target:** WebGL2 / HTML5 (Chromebook-class), 60 FPS, <16.6 ms frame, <50 MB initial download
**Source of truth:** `Midnight_Munch_-_Master_GDD v3.4.md` (the "GDD") and `Midnight Munch - Implementation Roadmap.md` (the "Roadmap")

---

## Context

This plan is the technical execution layer for the Midnight Munch prototype: a 5-minute first-person taco-truck cooking sim with four interaction modes (Instant / Discrete / Accumulate / Timing), a queue of patience-decaying customers, and a daily quota loop. The GDD specifies the **what** (mechanics, data, performance budgets); this plan specifies the **how** (concrete Godot 4.6 nodes, scripts, signal wiring, sprint sequencing) at a level a solo dev can execute against without re-deriving architecture decisions mid-sprint.

The goal is a shippable web prototype that proves the core loop, the four interactions, and the daily progression — not a polished release. Anything outside that scope is explicitly cut by the GDD's §11 cut-list.

---

## 1. Architecture Overview

### 1.1 Root Scene Tree

The single gameplay scene is `TruckInterior.tscn`. There is no level streaming, no scene swapping mid-session — only `TruckInterior.tscn` ↔ `MainMenu.tscn` ↔ `EndOfDayScreen.tscn` (CanvasLayer overlay, not a scene swap).

```
TruckInterior (Node3D)
├── World (Node3D)
│   ├── TruckShell (MeshInstance3D + StaticBody3D — pre-baked from CSG)
│   ├── LightmapGI (baked, STATIC lights only)
│   └── DirectionalLight3D, OmniLight3D (bake_mode = STATIC)
├── Stations (Node3D)                     # holds one PackedScene instance per station
│   ├── TortillaStation, TrompoStation,
│   ├── ToppingBin_Cilantro, ToppingBin_Onion, …
│   ├── SauceBottle_Red, SauceBottle_White,
│   └── ServiceBell
├── QueueSystem (Node3D)
│   ├── CustomerSpawner (Node3D)
│   └── QueueSlots (Node3D — Slot1, Slot2, Slot3 as Marker3D)
├── Player (CharacterBody3D — see §1.2)
├── OrderManager (Node)                   # scene-level, NOT autoload — owns ActiveOrder
├── DayTimer (Timer, 300 s)
├── TutorialSequencer (Node, freed after Day 0)
└── HUDRoot (CanvasLayer)
    ├── MidnightMunchHUD (Control)
    ├── ObjectiveHUD (Control — ingredient pills)
    ├── BellConfirmationPopup (Control, hidden)
    ├── EndOfDayScreen (Control, hidden)
    ├── PauseMenu (Control, hidden)
    └── DebugOverlay (Control, F3 toggle)
```

The **HUDRoot CanvasLayer is shared** rather than nested under `Player`, because the GDD reserves the player-attached `SubViewportContainer` strictly for first-person arms (cull layer 4). Mixing world-space and screen-space UI under the same Player viewport invites layer-mask bugs.

**Renderer:** Compatibility (OpenGL ES 3.0 / WebGL2). Chosen for the Chromebook-class web target. All scene/lighting/particle decisions in this plan assume Compatibility constraints — see §0.1 for the locked feature list. The §1.8 performance budget is set against Compatibility, not Forward+.

### 1.2 Player Subtree (Mixed 3D + ArmViewport)

Per GDD §2.2 the player's arms render through a `SubViewport` on physics layer 4 to prevent clipping. Critical detail: `ArmViewport.update_mode = UPDATE_DISABLED` whenever no item is held, flipping to `UPDATE_ALWAYS` only on `held_item_changed` — this is the difference between hitting and missing the 2 ms ArmViewport budget on Chromebook hardware.

```
Player (CharacterBody3D)
├── CollisionShape3D
├── CameraPivot (Node3D)
│   ├── MainCamera (Camera3D, cull_mask excludes layer 4, fov = 75)
│   └── InteractionRayCast (RayCast3D, length 3.0 m, mask layer 3 only)
├── ArmViewportContainer (SubViewportContainer, stretch = true)
│   └── ArmViewport (SubViewport, transparent_bg=true, use_hdr_2d=false, msaa=DISABLED)
│       └── ArmCamera (Camera3D, cull_mask = layer 4 only, mirrors MainCamera xform)
│           └── HandTransform (Marker3D)
└── InteractionStateMachine (Node — see §1.4)
    ├── Idle, Hover,
    ├── Active_Instant, Active_Discrete, Active_Accumulate, Active_Timing,
    └── Locked
```

`ArmCamera` mirrors `MainCamera`'s transform every `_process` (one Transform3D copy — negligible cost) so the arms track head movement without parenting through the viewport hierarchy.

### 1.3 Autoloads (4 — hard cap, in load order)

The GDD explicitly caps autoloads at 4. Adding a fifth means cutting one — do not exceed.

| # | Autoload | Sole Responsibility | Depends On |
|---|---|---|---|
| 1 | `EventBus` | Signal definitions only — zero state, zero logic | — |
| 2 | `NodePool` | `checkout(id) → Node` / `return_node(n)`. State reset on return, not checkout. Pre-warmed on `_ready`. | EventBus (optional) |
| 3 | `EconomyManager` | Bank balance, $0 floor, daily quota, payment math | EventBus |
| 4 | `GameManager` | Day phase enum, 300 s timer authority, **`is_input_locked()` single source of truth**, difficulty schedule lookup | EventBus, EconomyManager |

`SaveSystem` is **not** an autoload — it is a stateless utility script (`SaveSystem.gd` with `static func save() / load()`). This preserves the 4-autoload cap and keeps save logic where it belongs (called from `GameManager` on phase transitions).

`OrderManager` is **not** an autoload — it is a scene-level node under `TruckInterior`. The active order's lifetime is exactly the scene's lifetime; making it an autoload creates lifetime/reset bugs on day reload.

### 1.4 Input Routing — `InteractionStateMachine` (FSM)

The GDD's "stations are passive data" rule is non-negotiable. Stations export only:

```gdscript
@export var interaction_type: InteractionType   # enum
@export var input_action: StringName
```

The FSM lives on `Player`, reads the raycast hit, looks up `interaction_type`, and routes to the matching `Active_*` substate. No station script reads `Input.*`. Sequence prerequisites (Tortilla → Trompo → Toppings → Sauces) are enforced in `Hover.enter()`, not inside stations.

**Base contract:**

```gdscript
class_name State extends Node
func enter() -> void: pass
func exit() -> void: pass
func physics_update(_d: float) -> void: pass
func handle_input(_e: InputEvent) -> void: pass
```

State swapping toggles `set_physics_process(active)` and `set_process_input(active)` only on the active child. **Every state's `_physics_process` short-circuits on `GameManager.is_input_locked()` at line 1.** This is the GDD's resolution to the end-of-day race condition — do not duplicate the check or wrap it in helpers.

### 1.5 Signal Architecture — "Call Down, Signal Up"

`EventBus` holds **only** cross-domain signals. Local parent/child communication uses direct signal connection, not the bus.

Cross-domain signals (final list, payload types must match GDD §3.2):

```
order_accepted(customer_id: int, recipe: Recipe)
order_completed(result: OrderResult, payment: float, tip: float)
order_abandoned(customer_id: int, food_cost: float)
balance_changed(new_balance: float, delta: float)
strike_added(current_strikes: int)
day_ended(summary: DaySummary)
save_corrupted()
```

All emits use `.emit()` (typed), never `emit_signal()` (string lookup, slower on web). `OrderManager` owns local sticky-quality logic — once an ingredient is `SLOPPY` in the active order's dict, subsequent `PERFECT` signals for that ingredient are dropped (GDD §3.4).

### 1.6 Resource (`.tres`) Layer

All tunable numbers live in resources, never literals. The Inspector is the tuning tool.

| Resource | Fields (abbrev.) |
|---|---|
| `DifficultyEntry.gd` | `patience_seconds`, `spawn_interval_seconds`, `max_concurrent_customers`, `daily_quota`, `unlocked_ingredients: Array[StringName]` |
| `DifficultySchedule.gd` | `entries: Array[DifficultyEntry]` (index = day) |
| `Recipe.gd` | `protein` (fixed=trompo), `topping_pool_weighted: Dictionary[StringName,float]`, `topping_count_range: Vector2i`, `sauce_count_range: Vector2i` |
| `IngredientResource.gd` | `id`, `food_cost`, `interaction_type`, `station_id` |
| `OrderResult.gd` | enum + payment/tip multipliers |
| `EconomyResource.gd` | starting balance, tip table, deductions |
| `UpgradeResource.gd` | `id`, `display_name`, `cost`, `effect_key`, `effect_value` |

### 1.7 Pooling — `NodePool` Contract

- Pool sizes pre-warmed on `_ready`: `max_concurrent_customers × 4` per pool, plus 10 tortillas, ~24 toppings (across types), 12 sauce splats.
- **State is reset in `return_node()`** — checkout is hot-path and must not allocate or reset anything.
- Debug build asserts on exhaustion. Release build degrades to `instantiate()` + `push_warning()` (GDD §4.1). No `queue_free()` is ever called during gameplay.
- NPC-to-NPC collision is disabled during queue compaction (`set_collision_layer_value(2, false)`), re-enabled on slot arrival, to prevent jitter.

### 1.8 Performance Budget Mapping (GDD §7)

| System | Budget | Owned By |
|---|---|---|
| Main viewport render | 6 ms | TruckShell + bake quality |
| ArmViewport render | 2 ms | `UPDATE_DISABLED` when idle |
| Physics + raycast | 2 ms | One 3 m raycast per frame, layer 3 only |
| GDScript | 3 ms | FSM + OrderManager + Customer AI |
| Audio | 1 ms | Reverb/Doppler off, UI bus distinct from world bus |
| Headroom | 2.6 ms | — |

Pre-ship requirement: bake `CSGCombiner3D` truck shell to `MeshInstance3D` + `ConcavePolygonShape3D` before first web export — CSG is a development-time tool only.

---

## 2. Implementation Phases

Six sprints, sequenced so each delivers a runnable build. The Phase-0 foundation is non-negotiable; everything downstream assumes its autoloads, resources, and FSM exist.

### Phase 0 — Bootstrap & Foundation *(2–3 days)*
Project config, input map, all 4 autoloads as empty stubs, `.tres` resource scripts defined (no values yet), version-controlled `.gitignore`. **Exit criteria:** project boots to a black scene with all autoloads `_ready` printing without error.

### Phase 1 — Movement, Camera, & FSM Skeleton *(3–4 days)*
Player CharacterBody3D, mouse-look (clamped), MainCamera + ArmViewport rig, raycast hover detection, `InteractionStateMachine` with empty `Active_*` states, debug crosshair + hover prompt. **Exit criteria:** player can walk around a grey-box truck, raycast highlights stations, `Hover` state prints which station is targeted.

### Phase 2 — The Four Interactions in Isolation *(5–7 days)*
Build each interaction in its own test scene before wiring to orders. **Spike `Active_Timing` first** — shrinking-ring on web is the highest-risk mechanic. Then Discrete (trompo), Accumulate (sauce), Instant (tortilla/bell). Each interaction emits a single typed result back to a stub `OrderManager` and prints. **Exit criteria:** all four mechanics feel correct in Chrome at 60 FPS, audio reliably fires post-visual.

### Phase 3 — Order, Customer, Economy Loop *(4–6 days)*
`OrderManager` with `ActiveOrder` resource, recipe generation, `ObjectiveHUD` pills, `CustomerQueue` with patience drain and queue compaction, `BellStation` → validate → confirm-popup → payment, `EconomyManager` end-to-end including topping-miss debit and customer-abandon debit. **Exit criteria:** a complete order can be served from queue acceptance to bank-balance update.

### Phase 4 — Day Loop, Strikes, Progression *(3–4 days)*
`DayTimer` 300 s, strike tracker, `END_OF_DAY` phase transition (with race-condition handling per GDD §4.7), `EndOfDayScreen` with animated count-up, upgrade shop, `advance_to_next_day`, save/load via `SaveSystem.gd` with corruption recovery and `save_version: 1`. **Exit criteria:** Days 1–5 playable end to end, save persists through browser refresh.

### Phase 5 — Tutorial & Accessibility *(2–3 days)*
Day 0 `TutorialSequencer` with sequenced station highlights and one-line prompts, `tutorial_completed` save flag, full input remapping screen, mouse-sensitivity / FOV / hold-to-tap toggles, deuteranopia-safe topping palette verification. **Exit criteria:** new player can finish Day 0 with no external instructions; settings persist.

### Phase 6 — Audio, Juice, & Web QA *(3–4 days)*
SFX hooks per GDD §6 table (placeholder beeps OK if real audio TBD), particle bursts, screen shake values from the table, baked lightmaps + CSG → mesh conversion, web export with WASM threads disabled, profile in Firefox + Chrome on a Chromebook-class machine. **Exit criteria:** stable 60 FPS in Firefox on target hardware, all save/load paths exercised in IndexedDB.

**Cut order if behind schedule (GDD §11, do not improvise alternatives):** Sauces → queue compaction → SubViewport arms → tip system → topping SLOPPY granularity.

---

## 3. Task & Sub-Task Breakdown

### Phase 0 — Bootstrap & Foundation

- [ ] **0.1 Project configuration**
  - [ ] Create Godot 4.6 project, renderer = **Compatibility** (OpenGL ES 3.0 / WebGL2 — required for Chromebook-class web target; smaller export, faster startup, better baseline frame time)
  - [ ] Project Settings → Display → Window: 1280×720, stretch `canvas_items` / aspect `keep`
  - [ ] Project Settings → Physics → Common → Physics Ticks per Second = 60
  - [ ] Project Settings → Rendering → Anti Aliasing → MSAA 3D = Disabled (GDD §7 ArmViewport)
  - [ ] Renderer-locked constraints (Compatibility): no `GPUParticles3D`, no SDFGI/VoxelGI, no SSAO/SSIL/SSR, no volumetric fog, no HDR glow, no `CompositorEffect`. `LightmapGI` is supported (Low/Medium bake quality only).
  - [ ] Web export preset: **WASM threads disabled** (SharedArrayBuffer is blocked on most hosts)
  - [ ] `.gitignore`: `.godot/`, `export/`, `*.import`, `.DS_Store`
  - [ ] Define physics layers: 1 = world, 2 = NPCs, 3 = interactable, 4 = arm-only

- [ ] **0.2 Input map**
  - [ ] `interact` → Left Mouse Button + `E`
  - [ ] `mash` → same bindings as `interact` (FSM disambiguates by context)
  - [ ] `pause` → `Esc`
  - [ ] `ui_accept`, `ui_cancel` → Godot defaults
  - [ ] `move_forward`, `move_back`, `move_left`, `move_right` → WASD

- [ ] **0.3 Autoload stubs (in load order)**
  - [ ] `EventBus.gd` — declare all 7 signals from §1.5 with typed payloads. No `var`, no `func` other than `_ready` (empty)
  - [ ] `NodePool.gd` — empty `checkout`/`return_node` signatures, `_pools: Dictionary[StringName, Array[Node]]`
  - [ ] `EconomyManager.gd` — `balance: float = 0.0`, empty `credit/debit/process_payment/tally_day`
  - [ ] `GameManager.gd` — `enum GamePhase { TUTORIAL, PLAYING, END_OF_DAY }`, `is_input_locked() -> bool: return phase != PLAYING`
  - [ ] Register all four in Project Settings → Autoload (order: EventBus → NodePool → EconomyManager → GameManager)

- [ ] **0.4 Resource class definitions (scripts only — `.tres` instances later)**
  - [ ] `DifficultyEntry.gd extends Resource`
  - [ ] `DifficultySchedule.gd extends Resource`
  - [ ] `Recipe.gd extends Resource`
  - [ ] `IngredientResource.gd extends Resource`
  - [ ] `OrderResult.gd extends Resource` (with enum + multipliers)
  - [ ] `EconomyResource.gd extends Resource`
  - [ ] `UpgradeResource.gd extends Resource`

### Phase 1 — Movement, Camera, FSM Skeleton

- [ ] **1.1 TruckInterior grey-box scene**
  - [ ] `TruckInterior.tscn` with `World` group: floor, 4 walls, counter, serving window cutout (CSG OK at this stage; bake later)
  - [ ] Place 8 station `Marker3D`s matching GDD §2.1 layout — measure, do not eyeball
  - [ ] One static `OmniLight3D` + one `DirectionalLight3D`, both `bake_mode = STATIC`
  - [ ] Three `Marker3D` queue slots behind serving window

- [ ] **1.2 Player rig**
  - [ ] `Player.tscn` as `CharacterBody3D` + `CollisionShape3D` (capsule, standing height)
  - [ ] `CameraPivot` Node3D, `MainCamera` (fov 75, cull layer 4 excluded)
  - [ ] `ArmViewportContainer` + `ArmViewport` (transparent BG, no HDR, no MSAA, `update_mode = UPDATE_DISABLED`)
  - [ ] `ArmCamera` mirrors `MainCamera.global_transform` in `_process` (one assignment)
  - [ ] `HandTransform` Marker3D under `ArmCamera`
  - [ ] `InteractionRayCast` (length 3.0, `collision_mask = layer 3 only`)

- [ ] **1.3 Mouse-look + sensitivity**
  - [ ] Capture mouse on game start (`Input.mouse_mode = CAPTURED`); release on pause
  - [ ] `_unhandled_input`: accumulate `event.relative.x` → `Player.rotate_y(-x * sens)`; `event.relative.y` → `CameraPivot.rotate_x(-y * sens)` clamped to ±85°
  - [ ] Read `sens` from a `Settings` resource (placeholder for Phase 5)

- [ ] **1.4 InteractionStateMachine skeleton**
  - [ ] `State.gd` base class with the four virtual methods from §1.4
  - [ ] `InteractionStateMachine.gd` parent: holds `current: State`, `change_to(name: StringName)`
  - [ ] Child nodes: `Idle`, `Hover`, `Active_Instant`, `Active_Discrete`, `Active_Accumulate`, `Active_Timing`, `Locked`
  - [ ] All `_physics_process` first line: `if GameManager.is_input_locked(): return`
  - [ ] `Idle.physics_update`: cast ray, on hit → `change_to(&"Hover")` storing the Area3D
  - [ ] `Hover.physics_update`: re-cast; if no hit or different station → return to `Idle`; if `interact` pressed → check sequence prerequisite, route to matching `Active_*`
  - [ ] Empty `Active_*` states: print state name on `enter`, return to `Idle` after one tick

- [ ] **1.5 Station base scene**
  - [ ] `Station.tscn` as `Area3D` (collision layer 3) + `CollisionShape3D` (1.5× mesh extent) + `Visuals` (Node3D) + `WorldUI` (Sprite3D label) + `AudioStreamPlayer3D` (reverb off, doppler off)
  - [ ] `StationBase.gd`: `@export var interaction_type: int` (enum), `@export var input_action: StringName = &"interact"`
  - [ ] One concrete instance per station from §1.1 layout, scripts deferred until Phase 2

### Phase 2 — Four Interactions in Isolation

- [ ] **2.1 SPIKE: Shrinking-ring timing (DO FIRST — web risk)**
  - [ ] `SpikeRing.tscn` standalone: one topping bin Area3D, one `ShrinkingCircleUI` Control on a CanvasLayer
  - [ ] `ShrinkingCircleUI._draw()` paints outer ring + fixed target band; radius shrinks in `_physics_process` only
  - [ ] Target band visible from frame 1 (no fade-in)
  - [ ] Native window × 1.3 (+30% web latency margin per GDD §1.3)
  - [ ] Click hit-test against radius at the current physics tick; emit `result: PERFECT | SLOPPY | MISS`
  - [ ] Audio fires from `_physics_process` one tick AFTER the visual commit, never sync to input event
  - [ ] Test in Chrome AND Firefox; tune band width here, not later

- [ ] **2.2 `Active_Instant` — tortilla, bell**
  - [ ] On `interact` in Hover, fire `interaction_completed`, return to `Idle`
  - [ ] Tortilla case: `NodePool.checkout(&"tortilla")` → reparent to `HandTransform`; emit order step
  - [ ] HUD `HeldItemHUD` icon shows when held

- [ ] **2.3 `Active_Discrete` — trompo (3 slices)**
  - [ ] Listen for 3 `Input.is_action_just_pressed(&"interact")` events in `_physics_process`
  - [ ] Track inter-press intervals; emit per-slice quality and overall rhythm consistency
  - [ ] Per-slice particle (`CPUParticles3D` — final, not prototype: Compatibility renderer disallows GPU particles) + 1 px screen shake (GDD §6)
  - [ ] After 3rd slice, return to Idle

- [ ] **2.4 `Active_Accumulate` — sauces**
  - [ ] `Input.get_action_strength(&"interact")` accumulated per physics frame into `gauge_fill`
  - [ ] On release, start `0.4 s` `SceneTreeTimer`; on timer expiry, evaluate band: under / green (PERFECT) / red (SLOPPY)
  - [ ] Sauce-bottle gauge `TextureProgressBar` visible while in Hover, hidden on exit
  - [ ] Hold-to-tap accessibility toggle: when enabled, single press auto-fills at average rate; off by default (GDD §8)
  - [ ] Pour SFX loops while held; warning tone when crossing into red

- [ ] **2.5 `Active_Timing` — toppings (post-spike integration)**
  - [ ] Wire `ShrinkingCircleUI` from spike to the FSM
  - [ ] Hit → `NodePool.checkout(&"topping_<id>")`, animate into taco
  - [ ] Miss → checkout floor-drop topping (RigidBody3D briefly enabled, frozen on contact, returned via 10 s `Timer`); `EconomyManager.debit(0.05)`
  - [ ] Sloppy stickiness: first miss for an ingredient sets `topping_sloppy[id] = true` for the order

- [ ] **2.6 Stub `OrderManager` for isolation testing**
  - [ ] Holds an `ActiveOrder` resource: `Dictionary[StringName, OrderResult.Quality]`
  - [ ] Methods: `complete_step(id, quality)`, `print_state()`
  - [ ] Each interaction calls `OrderManager.complete_step` so Phase 2 builds verify end-to-end

### Phase 3 — Order, Customer, Economy Loop

- [ ] **3.1 `OrderManager` (full)**
  - [ ] `generate_order(recipe: Recipe) → ActiveOrder`: tortilla + trompo always; sample 2–4 toppings from weighted pool without replacement; sample 0–2 sauces; reject if matches any of last 3 generated (duplicate-prevention window per GDD §4.6)
  - [ ] `accept_order(customer)`, `complete_step(id, quality)` (sloppy-sticky enforced here), `validate_order() → bool`, `submit_order() → OrderResult`, `clear_order()`
  - [ ] On submit, emit `EventBus.order_completed(result, payment, tip)`

- [ ] **3.2 ObjectiveHUD (top-right)**
  - [ ] `ObjectiveHUD.tscn`: `VBoxContainer` of `IngredientPill` instances
  - [ ] `IngredientPill.tscn`: `PanelContainer` + `Label`, `StyleBox` swapped per state (grey / pulsing white / green-✓ / orange-~ / red-✗)
  - [ ] Pulsing-white drives off `Hover` state's current target station signal
  - [ ] `show()` on `order_accepted`, `hide()` on `order_completed | order_abandoned`

- [ ] **3.3 Customer queue & patience**
  - [ ] `CustomerNPC.tscn`: `CharacterBody3D` (collision layer 2), Kenney humanoid placeholder, world-space `PatientArcBar` (MeshInstance3D quad with shader param `fill_amount`, `is_urgent` at ≤10 s), `Label3D` speech bubble
  - [ ] `CustomerSpawner`: `Timer` interval = `current_difficulty.spawn_interval_seconds`. On timeout: `NodePool.checkout(&"customer")`, assign new `Recipe`, slot into next open `Marker3D`
  - [ ] Patience drain in `_physics_process`, only on customers in active queue slots
  - [ ] Click on customer in Idle (no active order): `OrderManager.accept_order(c)`, speech bubble → "[WAITING]"
  - [ ] Patience expiry: `EventBus.order_abandoned`, anger SFX (door slam, screen shake 8 px), `NodePool.return_node(c)`
  - [ ] Queue compaction: `move_toward` per physics frame, NPC layer-2 collision disabled during transit

- [ ] **3.4 Bell + confirmation popup**
  - [ ] `BellStation.gd`: `interaction_type = INSTANT`. On complete → `OrderManager.validate_order()`
  - [ ] If complete & all-green → `submit_order()`
  - [ ] If incomplete → spawn `BellConfirmationPopup` (modal CanvasLayer); set `GameManager.modal_open = true` (extend `is_input_locked` to honor it)
  - [ ] `[YES — Serve]` → debit food cost, `EventBus.order_abandoned` flow (counts as wrong/strike per GDD §1.4)
  - [ ] `[NO — Keep Cooking]` → close popup, clear modal flag, return to Idle

- [ ] **3.5 EconomyManager wiring**
  - [ ] `process_payment(result, recipe)`: payment % per `OrderResult` enum; tip per GDD §1.4 table; emit `balance_changed`
  - [ ] `debit(amount)` clamps `balance = max(0, balance - amount)` ($0 floor per GDD §4.1)
  - [ ] All connections per GDD §3.3 cross-domain flow; verify in editor that no station calls `EconomyManager` directly (must go through bus)
  - [ ] `BankBalanceHUD`: green flash on credit, red flash on debit (`Tween` modulate, 0.3 s)

### Phase 4 — Day Loop, Strikes, Progression

- [ ] **4.1 DayTimer + END_OF_DAY race handling**
  - [ ] `DayTimer` (Timer, 300 s, autostart on `GameManager.start_day()`)
  - [ ] On `timeout`: `GameManager.phase = END_OF_DAY` THEN `EventBus.day_ended.emit(summary)` (order matters — phase must flip first so any in-flight `_physics_process` sees `is_input_locked() == true`)
  - [ ] FSM `Locked.enter` runs on next physics tick, idempotent

- [ ] **4.2 Strike tracker**
  - [ ] `StrikeTracker.gd` (scene-level Node) listens to `order_completed (WRONG | ABANDONED)`
  - [ ] On 3rd strike → `GameManager.end_day_immediately()` (sets phase + emits `day_ended` mid-timer)
  - [ ] HUD strike pips animate filled

- [ ] **4.3 EndOfDayScreen**
  - [ ] CanvasLayer overlay on `HUDRoot`, hidden by default, shown on `EventBus.day_ended`
  - [ ] Tween animate counter labels from 0 to actual values over 1.5 s
  - [ ] Quota check: "Earn $X to open Day N+1" green if met, red otherwise
  - [ ] **Auto-save fires here, before the player presses anything** — `SaveSystem.save()` from `_on_day_ended`
  - [ ] `[Save & Exit]` → main menu; `[Next Day]` → `GameManager.advance_to_next_day()` → reload `TruckInterior.tscn`

- [ ] **4.4 Upgrade shop**
  - [ ] `UpgradeShopUI` child of EndOfDayScreen, lists `UpgradeResource[]`
  - [ ] Card grays out if `balance < cost` or already in `purchased_upgrades`
  - [ ] On buy: debit, append to purchased, emit `upgrade_purchased`
  - [ ] Stations read upgrade values via `GameManager.get_upgrade_value(&"effect_key")` on `_ready` and on `upgrade_purchased`

- [ ] **4.5 SaveSystem (with corruption recovery)**
  - [ ] `static func save(state: Dictionary)` writes JSON to `user://save.json` including `save_version: 1`, `current_day`, `balance`, `purchased_upgrades`, `tutorial_completed`, `settings`
  - [ ] `static func load() → Dictionary`: corruption check per GDD §4.7 — if not Dictionary or missing `save_version`/`current_day`, `EventBus.save_corrupted.emit()` and return `_create_fresh_save()`
  - [ ] Web platform: all writes wrapped in `await` (IndexedDB is async per GDD §9)
  - [ ] Main menu: `FileAccess.file_exists(...)` toggles `[Continue]` / `[New Game]`

### Phase 5 — Tutorial & Accessibility

- [ ] **5.1 Day 0 TutorialSequencer**
  - [ ] `TutorialSequencer.gd`: forces `phase = TUTORIAL`, disables DayTimer, single-customer-infinite-patience
  - [ ] Drives station highlights: only the next-in-sequence station has its `WorldUI` prompt visible
  - [ ] `Hover` state respects this — non-active stations behave as no-hit
  - [ ] Five scripted orders with progressively fewer prompts (Roadmap §3.4)
  - [ ] On final order served, set `save.tutorial_completed = true`, free `TutorialSequencer` from tree
  - [ ] Subsequent days check the flag and skip; never re-enter tutorial

- [ ] **5.2 Settings & remap**
  - [ ] `Settings.tres` resource with FOV, mouse sens, hold-to-tap, audio buses
  - [ ] Remap screen: list all 6 actions (interact, pause, WASD), capture next input on click
  - [ ] FOV slider 60–90, default 75; live-applied to `MainCamera` and `ArmCamera`
  - [ ] Hold-to-tap: replaces accumulator with one-press-fills behavior in `Active_Accumulate`
  - [ ] Persist via `SaveSystem` settings dict

- [ ] **5.3 Color-blind audit**
  - [ ] Run topping palette through deuteranopia + protanopia simulators (offline check)
  - [ ] If any topping pair becomes ambiguous, change palette in `IngredientResource.tres` only — no shader swap
  - [ ] Add shape/icon differentiation on `IngredientPill` so color is never the sole channel

### Phase 6 — Audio, Juice, Web QA

- [ ] **6.1 Audio bus structure**
  - [ ] Buses: `Master → Music`, `Master → SFX_World`, `Master → SFX_UI`
  - [ ] `SFX_World` per-station `AudioStreamPlayer3D` (reverb OFF, doppler OFF)
  - [ ] `SFX_UI` `AudioStreamPlayer` (non-3D) for HUD events
  - [ ] Volume sliders write `AudioServer.set_bus_volume_db()` per bus

- [ ] **6.2 Wire SFX + particles + screen shake (GDD §6 table)**
  - [ ] One row at a time, exactly the values in §6 — do not improvise different shake amounts
  - [ ] Screen shake is `Tween` on `MainCamera.h_offset` / `v_offset`, 0.15 s decay
  - [ ] All audio plays from `_physics_process` one tick after the visual commit (web latency mitigation)
  - [ ] All particle systems are `CPUParticles3D`. Audit every `.tscn` before ship — any `GPUParticles3D` node will silently no-op in Compatibility export.

- [ ] **6.3 Pre-ship bake**
  - [ ] CSG truck shell → bake to `MeshInstance3D` + `ConcavePolygonShape3D` (manual — `Mesh > Convert to MeshInstance`)
  - [ ] Bake `LightmapGI` with all lights set to `STATIC`. Bake Quality = **Medium** (Compatibility renderer does not support High/Ultra). Verify lightmap atlas size fits the <50 MB total export budget.
  - [ ] Confirm no `CSGCombiner3D` nodes remain in shipped scene

- [ ] **6.4 Web export & QA**
  - [ ] Export preset Web/HTML5; WASM threads disabled; GDExtension none
  - [ ] In the Web export preset, confirm Renderer = `gl_compatibility`. Run the exported build once and check the browser console for any `Method 'X' not supported in Compatibility` warnings — these indicate a feature snuck in that needs replacing.
  - [ ] Verify `<50 MB` initial download (GDD target)
  - [ ] Test save/load in incognito Chrome (IndexedDB writes)
  - [ ] **Firefox is the gating browser** (GDD §9 — stricter SAB and audio context resume)
  - [ ] Profile in Chrome DevTools Performance tab; confirm 60 FPS hold during 3-customer queue with active accumulate gauge
  - [ ] Confirm zero `instantiate()` / `queue_free()` calls during gameplay (Godot profiler)
  - [ ] Audio-after-visual verification on shrinking ring + sauce gauge in Chrome AND Firefox

### Cross-cutting verification gates

- [ ] After each phase, run a **smoke test**: load save, complete one full day, confirm balance + upgrades persist through reload
- [ ] After Phase 4, run a **strike test**: trigger 3 abandons → confirm immediate `END_OF_DAY` and FSM `Locked` lock-out
- [ ] After Phase 6, run a **24-hour soak**: leave the game on the EndOfDay screen overnight in Firefox to catch IndexedDB / audio context regressions

---

## Verification

End-to-end test pass once all phases complete:

1. Fresh install → `[New Game]` → Day 0 tutorial → 5 guided orders → `tutorial_completed` flag set
2. Day 1 → 5-minute timer runs, 3 customers max simultaneously, quota = $15, all 4 interaction types exercised, at least one `PERFECT` and one `SLOPPY` resolution
3. Force 3 strikes mid-day → confirm immediate `END_OF_DAY` transition, no input accepted post-flip
4. EndOfDay → buy `sharper_knife` upgrade → reload → confirm `Trompo` `fill_per_press` reflects upgraded value
5. Refresh browser → `[Continue]` → resume on Day 2 with persisted balance and upgrades
6. Manually corrupt `user://save.json` (delete `save_version`) → relaunch → `save_corrupted` emits, fresh save created, no crash
7. Profile Firefox on Chromebook-class hardware → 60 FPS sustained for 5-minute session, no GC stutters

---

## Critical Files (to be created during execution)

| Path | Role |
|---|---|
| `autoload/EventBus.gd` | Signal definitions only |
| `autoload/NodePool.gd` | Pool checkout/return |
| `autoload/EconomyManager.gd` | Bank, payments, quota |
| `autoload/GameManager.gd` | Phase, timer, `is_input_locked` |
| `resources/*.gd` | Resource class scripts (Recipe, DifficultyEntry, etc.) |
| `data/*.tres` | Tunable resource instances (one per recipe, ingredient, day, upgrade) |
| `scenes/TruckInterior.tscn` | Single gameplay scene |
| `scenes/Player.tscn` | CharacterBody3D + ArmViewport rig + FSM |
| `scripts/InteractionStateMachine/*.gd` | Base State + 7 concrete states |
| `scenes/stations/*.tscn` | One scene per station, all using `Station.tscn` base |
| `scenes/CustomerNPC.tscn` | Pooled customer |
| `scripts/OrderManager.gd` | Scene-level order owner |
| `scripts/SaveSystem.gd` | Stateless save/load utility (NOT autoload) |
| `scenes/HUD/*.tscn` | ObjectiveHUD, BankBalanceHUD, EndOfDayScreen, BellConfirmationPopup, PauseMenu |

---

## Confirmed Scope Decisions

1. **Save scope:** Between days only — auto-save fires on `EndOfDayScreen.show()`. No mid-day serialization of `OrderManager` / `NodePool` / patience timers.
2. **Player movement:** Enabled — `CharacterBody3D` with ~3 m/s WASD. Mouse-look as designed.
3. **Tutorial timing:** Phase 5 — built after all interactions and `OrderManager` are stable, to avoid scripting against a moving target.
