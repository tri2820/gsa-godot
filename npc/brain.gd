class_name Brain
extends RefCounted

# Streaming PRNG brain: generates wander TimelineSteps on demand.
# Ported from /Users/tri/gsa/scripts/brain.gd. Trimmed to four roles —
# IDLE / WALK / FALL / FALL_SIDE — to match the three clips Brush's
# character.glb ships (Walk, Fall, fall_side). Weights mirror the
# Brush-side `P_WALK = 0.86, P_FALL = 0.07` split in
# apps/brush-cli/src/npc_system.rs:201-203.

const C := preload("res://npc/constants.gd")
const State := preload("res://npc/character_state.gd")

enum Role { LOC_IDLE, LOC_WALK, ONE_FALL, ONE_FALL_SIDE }

const P_WALK := 0.86       # Brush's WALK probability
const P_FALL := 0.07       # Brush's FALL probability
const P_FALL_SIDE := 0.05  # remaining mass minus a sliver for IDLE
# IDLE catches the leftover ~0.02.

var _rng := RandomNumberGenerator.new()

# TimelineStep dict: { duration: float, direction: Vector3, sprint: bool, action: int }
# Matches gsa-godot's brain.gd schema. `action == -1` means "no action"; we
# encode the FALL/FALL_SIDE actions via State.Action when role is a one-shot.
var current_step: Dictionary = {
	"duration": 0.0,
	"direction": Vector3.ZERO,
	"sprint": false,
	"action": -1,
}

var elapsed_in_step: float = 0.0

# Last non-zero locomotion direction. Walk steps drift around this so wanders
# stay coherent across step boundaries (Brush's `last_direction`).
var last_direction: Vector3 = Vector3.ZERO

# One-step lookahead (unused for now — kept so the npc.gd lookup compiles
# unchanged from gsa-godot).
var queued_next = null


func _init(seed: int) -> void:
	_rng.seed = seed


# Sample the next TimelineStep. `clip_durations` is a Dictionary mapping
# StringName clip names → seconds (provided by character.gd at runtime via
# its `_clip_durations` field) — used to size one-shot step durations to
# the actual clip length.
func next_step(clip_durations: Dictionary) -> Dictionary:
	var r := _rng.randf()
	var role: int
	if r < P_WALK:
		role = Role.LOC_WALK
	elif r < P_WALK + P_FALL:
		role = Role.ONE_FALL
	elif r < P_WALK + P_FALL + P_FALL_SIDE:
		role = Role.ONE_FALL_SIDE
	else:
		role = Role.LOC_IDLE

	match role:
		Role.LOC_IDLE:
			return _step(_rng.randf_range(C.STEP_MIN, C.STEP_MAX), Vector3.ZERO, false, -1)
		Role.LOC_WALK:
			return _step(_rng.randf_range(C.STEP_MIN, C.STEP_MAX),
				random_direction(last_direction), false, -1)
		Role.ONE_FALL:
			return _oneshot_step(State.Action.FALL, clip_durations.get(C.ANIM_FALL, C.ACTION_FALL_SECS))
		Role.ONE_FALL_SIDE:
			return _oneshot_step(State.Action.FALL_SIDE, clip_durations.get(C.ANIM_FALL_SIDE, C.ACTION_FALL_SIDE_SECS))
	return _step(0.5, Vector3.ZERO, false, -1)


func _step(duration: float, direction: Vector3, sprint: bool, action: int) -> Dictionary:
	return {
		"duration": duration,
		"direction": direction,
		"sprint": sprint,
		"action": action,
	}


func _oneshot_step(action: int, duration: float) -> Dictionary:
	# One-shots hold direction at zero — the locked_direction the
	# CharacterStateUtil uses comes from the state struct, not the
	# TimelineStep — so the brain just carries the action enum.
	return {
		"duration": duration,
		"direction": Vector3.ZERO,
		"sprint": false,
		"action": action,
	}


# Pick a movement direction. 70% chance to drift the current heading by
# ±DRIFT_RAD; otherwise pick a fully fresh azimuth. Verbatim port of
# /Users/tri/gsa/scripts/brain.gd:100-108 + Brush's random_direction.
func random_direction(current: Vector3) -> Vector3:
	if current.length_squared() > 1e-4 and _rng.randf() < C.DIRECTION_DRIFT_PROB:
		var current_az := atan2(current.x, current.z)
		var az := current_az + _rng.randf_range(-C.DIRECTION_DRIFT_RAD, C.DIRECTION_DRIFT_RAD)
		return Vector3(sin(az), 0.0, cos(az))
	var fresh := _rng.randf_range(0.0, TAU)
	return Vector3(sin(fresh), 0.0, cos(fresh))
