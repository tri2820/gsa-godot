class_name CharacterStateUtil
extends RefCounted

# Pure-function state machine for the NPC pipeline. Ported from
# /Users/tri/gsa/scripts/character_state.gd, trimmed to the actions
# Brush's character.glb actually ships (Walk, Fall, fall_side).
#
# state = {
#   "kind": StateKind,
#   "loco": LocomotionKind,      # only valid when kind == LOCOMOTION
#   "direction": Vector3,        # only valid when kind == LOCOMOTION
#   "action": Action,            # only valid when kind in [ONESHOT, HELD]
#   "remaining": float,          # only valid when kind == ONESHOT
#   "locked_direction": Vector3, # only valid when kind == ONESHOT
# }

enum StateKind { LOCOMOTION, ONESHOT, HELD }
enum LocomotionKind { IDLE, WALK, RUN }     # RUN unused; kept for parity
enum Action { FALL, FALL_SIDE }              # trimmed from gsa's 6-action set

const C := preload("res://npc/constants.gd")


static func is_stationary(action: int) -> bool:
	# Both falls hold the character in place during the clip.
	return action == Action.FALL or action == Action.FALL_SIDE


static func one_shot_duration(action: int) -> float:
	match action:
		Action.FALL:      return C.ACTION_FALL_SECS
		Action.FALL_SIDE: return C.ACTION_FALL_SIDE_SECS
	return 0.5


# --- factory functions (mirror gsa-godot's `make_*` helpers) ---

static func make_locomotion(kind: int, direction: Vector3) -> Dictionary:
	return {
		"kind": StateKind.LOCOMOTION,
		"loco": kind,
		"direction": direction,
		"action": Action.FALL,
		"remaining": 0.0,
		"locked_direction": Vector3.ZERO,
	}

static func make_oneshot(action: int, remaining: float, locked_direction: Vector3) -> Dictionary:
	return {
		"kind": StateKind.ONESHOT,
		"loco": LocomotionKind.IDLE,
		"direction": Vector3.ZERO,
		"action": action,
		"remaining": remaining,
		"locked_direction": locked_direction,
	}

static func make_held(action: int) -> Dictionary:
	# No HELD action shipped today, but the factory stays so future
	# Idle/Sit additions don't have to retrofit the state struct.
	return {
		"kind": StateKind.HELD,
		"loco": LocomotionKind.IDLE,
		"direction": Vector3.ZERO,
		"action": action,
		"remaining": 0.0,
		"locked_direction": Vector3.ZERO,
	}

static func default_state() -> Dictionary:
	return make_locomotion(LocomotionKind.IDLE, Vector3.ZERO)


# --- derived queries ---

static func derive_kind(movement: Vector3, _sprint: bool) -> int:
	# RUN ignored — Brush's glb doesn't ship a Run clip.
	if movement.length_squared() < C.IDLE_EPSILON_SQ:
		return LocomotionKind.IDLE
	return LocomotionKind.WALK


static func anim_for(state: Dictionary) -> StringName:
	match state["kind"]:
		StateKind.LOCOMOTION:
			match state["loco"]:
				LocomotionKind.IDLE: return C.ANIM_IDLE  # empty = bind pose
				LocomotionKind.WALK: return C.ANIM_WALK
				LocomotionKind.RUN:  return C.ANIM_WALK  # fall back to walk
		StateKind.ONESHOT, StateKind.HELD:
			match state["action"]:
				Action.FALL:      return C.ANIM_FALL
				Action.FALL_SIDE: return C.ANIM_FALL_SIDE
	return C.ANIM_IDLE


static func velocity_for(state: Dictionary) -> Vector3:
	match state["kind"]:
		StateKind.LOCOMOTION:
			match state["loco"]:
				LocomotionKind.IDLE: return Vector3.ZERO
				LocomotionKind.WALK: return _normalize_or_zero(state["direction"]) * C.MOVE_SPEED
				LocomotionKind.RUN:  return _normalize_or_zero(state["direction"]) * C.RUN_SPEED
		StateKind.ONESHOT:
			if is_stationary(state["action"]):
				return Vector3.ZERO
			return _normalize_or_zero(state["locked_direction"]) * C.MOVE_SPEED
		StateKind.HELD:
			return Vector3.ZERO
	return Vector3.ZERO


static func _normalize_or_zero(v: Vector3) -> Vector3:
	if v.length_squared() < 1e-6:
		return Vector3.ZERO
	return v.normalized()
