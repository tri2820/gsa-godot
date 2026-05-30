extends "res://npc/character.gd"

# NPC: owns a Brain, ticks brain each physics frame BEFORE letting
# character.gd's pipeline run. Simplified port of
# /Users/tri/gsa/scripts/npc.gd:
#   - drop _check_stuck (no walls to bump into in the MVP)
#   - drop _apply_perception (no neighbour separation in the MVP)
#   - drop npc_label.gd instantiation
#
# Subclass contract is identical to gsa-godot: subclass writes
# `intent["movement"]`, `intent["sprint"]`, `intent["fire"]` before
# calling super._physics_process.

const Brain = preload("res://npc/brain.gd")
# C is inherited from character.gd.

# Seed for the brain's PRNG. Set by the spawner before _ready.
var brain_seed: int = 0

var _brain: Brain = null


func _ready() -> void:
	super._ready()
	add_to_group("npcs")
	_brain = Brain.new(brain_seed)


func _physics_process(delta: float) -> void:
	if _brain == null:
		return
	_brain_tick(delta)
	super._physics_process(delta)


# Advance the brain timeline and translate the current step into the
# parent's `intent` fields. Mirrors gsa-godot's _brain_tick, minus the
# perception coupling — intent is set once on step entry and then left
# alone for the duration of the step.
func _brain_tick(delta: float) -> void:
	_brain.elapsed_in_step += delta
	var entered_new := _brain.elapsed_in_step >= float(_brain.current_step["duration"])
	if entered_new:
		# Snapshot the just-finished step's direction as the next step's
		# drift anchor (keeps wanders coherent across boundaries).
		var prev_dir: Vector3 = _brain.current_step["direction"]
		if prev_dir.length_squared() > 1e-4:
			_brain.last_direction = prev_dir.normalized()

		var nxt: Dictionary
		if _brain.queued_next != null:
			nxt = _brain.queued_next
			_brain.queued_next = null
		else:
			nxt = _brain.next_step(_clip_durations)
		var nxt_dir: Vector3 = nxt["direction"]
		if nxt_dir.length_squared() > 1e-4:
			_brain.last_direction = nxt_dir

		_brain.current_step = nxt
		_brain.elapsed_in_step = 0.0

		# Write intent ONCE on step entry. Locomotion fills movement;
		# one-shots fill fire (the action enum); everything else stays
		# zero so the parent's _tick_character_state derives Idle.
		intent["movement"] = nxt_dir
		intent["sprint"] = bool(nxt.get("sprint", false))
		intent["fire"] = int(nxt.get("action", -1))
