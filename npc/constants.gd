class_name NpcConstants
extends RefCounted

# Tuning constants for the NPC subsystem. Ported from
# /Users/tri/gsa/scripts/constants.gd, trimmed to what character.glb
# (Brush's Mixamo rig) actually supports.

# --- locomotion speeds (m/s) ---
const MOVE_SPEED := 1.4   # Brush's npc_system.rs WALK_SPEED
const RUN_SPEED  := 4.0   # unused (no Run clip), kept for parity

# --- one-shot action durations (s). Brush ships Fall + fall_side as
#     stationary one-shots; the others stay as constants so future code
#     that uses Action.JUMP/PUNCH/... compiles without churn. ---
const ACTION_FALL_SECS      := 2.57   # matches glb clip length
const ACTION_FALL_SIDE_SECS := 3.33

# --- animation clip names. Brush's character.glb ships an empty-string
#     animation library, so clips are bare names (verified with a headless
#     dump — see dump_glb.gd in commit history). ---
const ANIM_IDLE      := &""         # no Idle clip → bind pose
const ANIM_WALK      := &"Walk"
const ANIM_FALL      := &"Fall"
const ANIM_FALL_SIDE := &"fall_side"

# Only Walk needs to loop. Idle is bind pose (no clip). Falls are one-shots
# that should play once and freeze on the last frame.
const LOOPING_ANIMS: Array[StringName] = [ANIM_WALK]

# --- asset ---
const CHARACTER_GLB := "res://character.glb"

# --- visual transform on the instantiated GLB ---
# Mixamo rig is already ~1.75 m tall at scale 1.0 and its origin sits at
# the feet, so no scale or Y-offset needed in the common case. Will tune
# after first render if the character is the wrong size / floating.
const VISUAL_SCALE    := 1.0
const VISUAL_Y_OFFSET := 0.0

# --- step duration bounds (s). brain.gd samples each TimelineStep's
#     duration uniformly from [STEP_MIN, STEP_MAX]. Matches gsa-godot
#     and Brush. ---
const STEP_MIN := 1.5
const STEP_MAX := 4.0

# --- state-machine epsilon: smaller than this magnitude² of `intent.movement`
#     counts as "no intent to move" (→ Idle). ---
const IDLE_EPSILON_SQ := 0.01

# --- direction picker tuning (brain.random_direction). 70% chance to
#     drift the current heading by ±DRIFT_RAD; otherwise pick a fully
#     fresh azimuth. ---
const DIRECTION_DRIFT_PROB := 0.7
const DIRECTION_DRIFT_RAD  := 0.524  # ±~30°
