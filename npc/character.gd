extends CharacterBody3D

# Base character: intent → state → apply → move_and_slide. Ported from
# /Users/tri/gsa/scripts/character.gd; swapped RigidBody3D for
# CharacterBody3D per the plan so collision-aware movement is in place
# but turned off for the MVP (no gravity, no shape penetration).
#
# Subclasses (npc.gd) write to `intent` BEFORE calling super._physics_process.

const C := preload("res://npc/constants.gd")
const CharacterStateUtil := preload("res://npc/character_state.gd")

# What the brain/player wants this frame. Subclass fills these in.
var intent: Dictionary = {
	"movement": Vector3.ZERO,
	"sprint": false,
	"fire": -1,    # State.Action enum value, or -1 for "no fire"
}

# Current state machine state. Mutated by _tick_character_state, consumed
# by _apply_character_state.
var state: Dictionary = CharacterStateUtil.default_state()

# Set up at _ready() in _attach_visual_and_animations.
var _visual: Node3D = null
var _anim_player: AnimationPlayer = null
var _clip_durations: Dictionary = {}    # StringName → seconds
var _last_anim: StringName = &""


func _ready() -> void:
	_attach_visual_and_animations()


func _physics_process(delta: float) -> void:
	_tick_character_state(delta)
	_apply_character_state()
	move_and_slide()


# Load the GLB, parent it as `Visual` under self, find the AnimationPlayer,
# enumerate clips into _clip_durations, set loop modes per C.LOOPING_ANIMS,
# and force opaque transparency on any alpha-blended materials so the gdgs
# compositor occludes the character correctly.
func _attach_visual_and_animations() -> void:
	var packed: PackedScene = load(C.CHARACTER_GLB)
	if packed == null:
		push_error("character.gd: cannot load %s" % C.CHARACTER_GLB)
		return
	_visual = packed.instantiate()
	_visual.name = "Visual"
	_visual.scale = Vector3.ONE * C.VISUAL_SCALE
	_visual.position = Vector3(0.0, C.VISUAL_Y_OFFSET, 0.0)
	add_child(_visual)

	_anim_player = _visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim_player == null:
		push_error("character.gd: no AnimationPlayer in %s" % C.CHARACTER_GLB)
		return

	# Enumerate clips + set loop modes + strip root motion from locomotion
	# clips. Mixamo Walk ships a hip POSITION_3D track that translates ~1.2 m
	# forward per loop; combined with our own velocity-based movement, the
	# visual position bounces (clip translation + world velocity, then resets
	# at loop). Mirrors Brush's `strip_root` toggle.
	for lib_name in _anim_player.get_animation_library_list():
		var lib: AnimationLibrary = _anim_player.get_animation_library(lib_name)
		for short_name in lib.get_animation_list():
			var full_name: StringName = StringName(short_name) if String(lib_name).is_empty() else StringName("%s/%s" % [lib_name, short_name])
			var anim: Animation = lib.get_animation(short_name)
			anim.loop_mode = Animation.LOOP_LINEAR if full_name in C.LOOPING_ANIMS else Animation.LOOP_NONE
			# Strip root translation on Walk only (Falls *should* have the
			# hip dropping — that IS the fall).
			if full_name == C.ANIM_WALK:
				_strip_root_position_track(anim)
			_clip_durations[full_name] = anim.length

	# Force opaque on materials so gdgs's depth-aware compositor correctly
	# occludes the character. character.glb ships with TRANSPARENCY_ALPHA_DEPTH_PRE_PASS,
	# which writes depth but also alpha-blends and can interact oddly with
	# the splat composite. Plain opaque is the safe default for the MVP.
	_force_opaque_materials(_visual)


# Disable the POSITION_3D track on the rig's root bone (Mixamo: `Hips`)
# so the clip animates joints in place and we drive world motion ourselves.
func _strip_root_position_track(anim: Animation) -> void:
	for i in range(anim.get_track_count()):
		if anim.track_get_type(i) != Animation.TYPE_POSITION_3D:
			continue
		var path := String(anim.track_get_path(i))
		# Mixamo's root bone is `mixamorig_Hips` (sometimes `Hips`).
		if path.ends_with(":mixamorig_Hips") or path.ends_with(":Hips"):
			anim.track_set_enabled(i, false)
			return


func _force_opaque_materials(n: Node) -> void:
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n
		var mesh := mi.mesh
		if mesh != null:
			for surf in range(mesh.get_surface_count()):
				var mat := mi.get_active_material(surf)
				if mat is BaseMaterial3D:
					(mat as BaseMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	for c in n.get_children():
		_force_opaque_materials(c)


func clip_duration(name: StringName) -> float:
	return _clip_durations.get(name, 0.5)


# --- pipeline: intent → state ---

func _tick_character_state(_delta: float) -> void:
	var fire: int = intent.get("fire", -1)
	intent["fire"] = -1   # consume one-shot trigger

	match state["kind"]:
		CharacterStateUtil.StateKind.LOCOMOTION:
			if fire >= 0:
				state = _enter_action(fire)
			else:
				var movement: Vector3 = intent.get("movement", Vector3.ZERO)
				var sprint: bool = intent.get("sprint", false)
				var loco_kind: int = CharacterStateUtil.derive_kind(movement, sprint)
				state = CharacterStateUtil.make_locomotion(loco_kind, movement)
		CharacterStateUtil.StateKind.ONESHOT:
			state["remaining"] = float(state["remaining"]) - _delta
			if float(state["remaining"]) <= 0.0:
				state = CharacterStateUtil.default_state()
		CharacterStateUtil.StateKind.HELD:
			# No HELD action ships today; if any subclass enters one,
			# any non-zero movement intent breaks out.
			var mv: Vector3 = intent.get("movement", Vector3.ZERO)
			if mv.length_squared() >= C.IDLE_EPSILON_SQ:
				state = CharacterStateUtil.default_state()


func _enter_action(action: int) -> Dictionary:
	# Brush's clips are all stationary one-shots (Fall, FallSide). No
	# Jump grounded-check needed.
	var dur: float = CharacterStateUtil.one_shot_duration(action)
	var locked := intent.get("movement", Vector3.ZERO) as Vector3
	return CharacterStateUtil.make_oneshot(action, dur, locked)


# --- pipeline: state → apply ---

func _apply_character_state() -> void:
	var v: Vector3 = CharacterStateUtil.velocity_for(state)
	# CharacterBody3D.velocity is the XYZ velocity move_and_slide consumes.
	# Y is left at 0 — no gravity simulation for the MVP.
	velocity.x = v.x
	velocity.y = 0.0
	velocity.z = v.z

	# Face walking direction (LOCOMOTION only). gsa's offset (+PI) flipped
	# Z to account for Quaternius's +Z forward; Brush's Mixamo character
	# also has +Z forward in the glb, so the same flip should apply. Will
	# tune empirically.
	if state["kind"] == CharacterStateUtil.StateKind.LOCOMOTION:
		var dir: Vector3 = state["direction"]
		if dir.length_squared() >= C.IDLE_EPSILON_SQ and _visual != null:
			var target := global_position + dir
			_visual.look_at(target, Vector3.UP)
			_visual.rotate_object_local(Vector3.UP, PI)

	# Animation switching.
	if _anim_player == null:
		return
	var desired: StringName = CharacterStateUtil.anim_for(state)
	# Empty desired = bind pose; stop and leave skeleton at rest.
	if String(desired).is_empty():
		if _anim_player.is_playing():
			_anim_player.stop()
		_last_anim = &""
		return
	if desired != _last_anim and _anim_player.has_animation(desired):
		# Snap when entering/leaving a stationary one-shot; otherwise short blend.
		var blend := 0.15
		if _is_stationary_clip(desired) or _is_stationary_clip(_last_anim):
			blend = 0.0
		_anim_player.play(desired, blend)
		_last_anim = desired


func _is_stationary_clip(name: StringName) -> bool:
	return name == C.ANIM_FALL or name == C.ANIM_FALL_SIDE
