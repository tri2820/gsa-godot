extends Node3D

const AviMjpegWriter = preload("res://avi_mjpeg.gd")

# Gaussian-splat viewer + multi-camera recorder.
#
# Interactive (default):
#   RMB drag · WASDQE · Shift fast · wheel zoom · 1-9 jump · Esc release
#
# Recording (single Godot process, N SubViewports, custom AVI MJPEG writers):
#
#   godot --path . main.tscn \
#       --fixed-fps 30 --quit-after 100 \
#       -- --record --output out --frames 80 --fps 30
#
# All cameras in CAMERAS render in lockstep from one shared World3D. Each one
# is wired to its own SubViewport + AviMjpegWriter, producing out/<name>.avi.

var CAMERAS := [
	# Splat AABB (gdgs world coords): center (-1.84, 0.48, 0.71), size (31, 8, 36).
	# Each entry either has "rot_deg" or "look_at". look_at is easier — just point at a target.
	{ "name": "clip_a", "pos": Vector3(-1.84, 0.7,  12.0), "look_at": Vector3(-1.84, -0.2,  0.71) },
	{ "name": "clip_b", "pos": Vector3(-1.84, 0.7, -10.0), "look_at": Vector3(-1.84, -0.2,  0.71) },
]

const REC_WIDTH       := 1620
const REC_HEIGHT      := 1000
const REC_SETTLE      := 5      # discard the first N frames so GPU + sort stabilise
const JPEG_QUALITY    := 0.9

const MOVE_SPEED := 4.0
const FAST_MULT  := 3.0
const MOUSE_SENS := 0.002
const WHEEL_STEP := 0.4

var _looking := false
var _yaw := 0.0
var _pitch := 0.0
var _active_idx := 0

# Recording state
var _record_mode := false
var _record_output_dir := "out"
var _record_total_frames := 80
var _record_fps := 30
var _record_frames_captured := 0
var _record_settle_remaining := REC_SETTLE
var _record_subviewports: Array[SubViewport] = []
var _record_writers: Array[AviMjpegWriter] = []
var _record_t_start := 0
var _record_done := false

var _fps_label: Label
var _info_label: Label
var _pose_label: Label

# Sidebar (right edge): collapsible panel of live tunables.
var _sidebar_content: VBoxContainer = null
var _sidebar_expanded := true
var _sidebar_toggle_btn: Button = null

# Spawned NPC ref so sidebar sliders can mutate it live.
var _npc: Node3D = null

@onready var camera: Camera3D = $Camera3D


func _ready() -> void:
	_setup_ui()

	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		match args[i]:
			"--record":
				_record_mode = true
			"--output":
				if i + 1 < args.size():
					_record_output_dir = args[i + 1]
					i += 1
			"--frames":
				if i + 1 < args.size():
					_record_total_frames = int(args[i + 1])
					i += 1
			"--fps":
				if i + 1 < args.size():
					_record_fps = int(args[i + 1])
					i += 1
			"--list-cameras":
				for c in CAMERAS: print(c.name)
				get_tree().quit()
				return
			"--auto-screenshot":
				if i + 1 < args.size():
					var p: String = args[i + 1]
					get_tree().create_timer(2.0).timeout.connect(_auto_screenshot.bind(p))
					i += 1
		i += 1

	_spawn_npc()

	if _record_mode:
		_setup_recording()
	else:
		_apply_camera(0)


func _spawn_npc() -> void:
	# One NPC at the splat AABB floor centre (Godot world coords). The NPC
	# walks itself via its embedded Brain — no per-frame wiring from main.gd.
	var npc_scene := load("res://npc/npc.tscn") as PackedScene
	_npc = npc_scene.instantiate() as Node3D
	_npc.brain_seed = 1
	# y tuned empirically by bisection: visible splat floor sits around
	# Godot y≈-1.5; the Mixamo character's feet rest ~0.21 m below
	# CharacterBody3D.position (hip rest offset, exposed by stripping
	# the Walk root translation). -1.71 puts feet on concrete.
	_npc.position = Vector3(0.0, -1.71, 0.0)
	add_child(_npc)


# --- camera state ---

func _apply_camera(idx: int) -> void:
	if CAMERAS.is_empty(): return
	_active_idx = wrapi(idx, 0, CAMERAS.size())
	var c = CAMERAS[_active_idx]
	_apply_pose(camera, c)
	_yaw = camera.rotation.y
	_pitch = camera.rotation.x
	print("[cam] %d → %s" % [_active_idx, c.name])

# Single source of truth for applying a CAMERAS entry to ANY Camera3D
# (interactive main camera + recording SubViewport cameras share this).
func _apply_pose(cam: Camera3D, c: Dictionary) -> void:
	cam.position = c.pos
	if c.has("look_at"):
		cam.look_at(c.look_at, Vector3.UP)
	else:
		var r: Vector3 = c.get("rot_deg", Vector3.ZERO)
		cam.rotation = Vector3(deg_to_rad(r.x), deg_to_rad(r.y), deg_to_rad(r.z))


# --- UI overlay ---

func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	_fps_label  = _mk_label(Vector2(24, 18),  40, Color(1, 1, 0))
	_info_label = _mk_label(Vector2(24, 78),  26, Color(0.9, 0.9, 1))
	_pose_label = _mk_label(Vector2(24, 118), 26, Color(0.6, 1, 0.6))
	canvas.add_child(_fps_label)
	canvas.add_child(_info_label)
	canvas.add_child(_pose_label)
	_build_sidebar(canvas)

func _mk_label(pos: Vector2, sz: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.position = pos
	lbl.add_theme_font_size_override("font_size", sz)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color.BLACK)
	lbl.add_theme_constant_override("outline_size", 6)
	return lbl


# --- collapsible right-edge sidebar of live tunables ---

func _build_sidebar(canvas: CanvasLayer) -> void:
	# Container anchored to the right edge of the viewport.
	var sidebar := PanelContainer.new()
	sidebar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	sidebar.position = Vector2(-340, 16)
	sidebar.custom_minimum_size = Vector2(320, 0)
	# Block clicks falling through to the 3D viewport when interacting.
	sidebar.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(sidebar)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	sidebar.add_child(vbox)

	# Toggle button — always visible.
	_sidebar_toggle_btn = Button.new()
	_sidebar_toggle_btn.text = "▼  Controls"
	_sidebar_toggle_btn.add_theme_font_size_override("font_size", 18)
	_sidebar_toggle_btn.pressed.connect(_toggle_sidebar)
	vbox.add_child(_sidebar_toggle_btn)

	# Content lives in its own VBox so we can show/hide as a unit.
	_sidebar_content = VBoxContainer.new()
	_sidebar_content.add_theme_constant_override("separation", 6)
	vbox.add_child(_sidebar_content)

	_add_section_label(_sidebar_content, "NPC")
	_add_slider(_sidebar_content, "Y (feet on floor)", -3.0, 0.5, 0.01, -1.71,
		func(v: float) -> void:
			if _npc != null:
				_npc.position.y = v)

func _toggle_sidebar() -> void:
	_sidebar_expanded = not _sidebar_expanded
	_sidebar_content.visible = _sidebar_expanded
	_sidebar_toggle_btn.text = ("▼  Controls" if _sidebar_expanded else "▶  Controls")

func _add_section_label(parent: VBoxContainer, txt: String) -> void:
	var lbl := Label.new()
	lbl.text = txt
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(0.8, 0.9, 1.0))
	parent.add_child(lbl)

func _add_slider(parent: VBoxContainer, name: String, lo: float, hi: float, step: float, value: float, on_change: Callable) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var caption := Label.new()
	caption.text = name
	caption.add_theme_font_size_override("font_size", 13)
	caption.custom_minimum_size = Vector2(150, 0)
	row.add_child(caption)

	var value_lbl := Label.new()
	value_lbl.text = "%.2f" % value
	value_lbl.add_theme_font_size_override("font_size", 13)
	value_lbl.custom_minimum_size = Vector2(50, 0)
	value_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_lbl)

	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(0, 24)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(func(v: float) -> void:
		value_lbl.text = "%.2f" % v
		on_change.call(v))
	parent.add_child(slider)
	return slider


# --- input (interactive only) ---

func _unhandled_input(event: InputEvent) -> void:
	if _record_mode: return
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_RIGHT:
				_looking = event.pressed
				Input.mouse_mode = (Input.MOUSE_MODE_CAPTURED if _looking
					else Input.MOUSE_MODE_VISIBLE)
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					camera.position -= camera.basis.z * WHEEL_STEP
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					camera.position += camera.basis.z * WHEEL_STEP
	elif event is InputEventMouseMotion and _looking:
		_yaw   -= event.relative.x * MOUSE_SENS
		_pitch -= event.relative.y * MOUSE_SENS
		_pitch = clampf(_pitch, -PI / 2 + 0.01, PI / 2 - 0.01)
		camera.basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
				_apply_camera(event.keycode - KEY_1)
			KEY_LEFT, KEY_PAGEUP:
				_apply_camera(_active_idx - 1)
			KEY_RIGHT, KEY_PAGEDOWN:
				_apply_camera(_active_idx + 1)
			KEY_ESCAPE:
				_looking = false
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# --- per-frame (interactive only; recording uses frame_post_draw signal) ---

func _process(delta: float) -> void:
	if _record_mode: return

	var vel := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): vel -= camera.basis.z
	if Input.is_key_pressed(KEY_S): vel += camera.basis.z
	if Input.is_key_pressed(KEY_A): vel -= camera.basis.x
	if Input.is_key_pressed(KEY_D): vel += camera.basis.x
	if Input.is_key_pressed(KEY_E): vel += Vector3.UP
	if Input.is_key_pressed(KEY_Q): vel -= Vector3.UP
	if vel != Vector3.ZERO:
		var spd := MOVE_SPEED
		if Input.is_key_pressed(KEY_SHIFT):
			spd *= FAST_MULT
		camera.position += vel.normalized() * spd * delta

	_fps_label.text  = "FPS: %d" % Engine.get_frames_per_second()
	var cam_label: String = "(no cameras)"
	if not CAMERAS.is_empty():
		cam_label = "%d/%d %s" % [_active_idx + 1, CAMERAS.size(), CAMERAS[_active_idx].name]
	_info_label.text = "%s   |   RMB look · WASDQE move · Shift fast · wheel zoom · 1-9 cams" % cam_label
	_pose_label.text = _pose_text()


func _pose_text() -> String:
	var p := camera.position
	var r := camera.rotation_degrees
	return "pos  %6.2f %6.2f %6.2f   rot_deg  %6.1f %6.1f %6.1f" % [
		p.x, p.y, p.z, r.x, r.y, r.z
	]


# --- recording: one process, N SubViewports, custom AVI MJPEG writers ---

func _setup_recording() -> void:
	if CAMERAS.is_empty():
		printerr("[record] no CAMERAS defined")
		get_tree().quit()
		return

	DirAccess.make_dir_recursive_absolute(_record_output_dir)

	# Hide UI and main camera; main viewport is unused during recording.
	camera.current = false
	_fps_label.hide(); _info_label.hide(); _pose_label.hide()

	# Build one SubViewport + Camera3D per camera, sharing the main World3D so
	# they all see the same splat + the gdgs CompositorEffect.
	var shared_world := get_world_3d()
	for c in CAMERAS:
		var sv := SubViewport.new()
		sv.size = Vector2i(REC_WIDTH, REC_HEIGHT)
		sv.own_world_3d = false
		sv.world_3d = shared_world
		sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		sv.transparent_bg = false
		add_child(sv)

		var sv_cam := Camera3D.new()
		sv_cam.fov = camera.fov
		sv_cam.near = camera.near
		sv_cam.far  = camera.far
		sv_cam.current = true
		sv.add_child(sv_cam)
		# Apply pose AFTER add_child so the camera is in its World3D when
		# look_at resolves global transforms — same path as interactive.
		_apply_pose(sv_cam, c)

		_record_subviewports.append(sv)

		var w := AviMjpegWriter.new()
		var path := "%s/%s.avi" % [_record_output_dir, c.name]
		if not w.open(path, REC_WIDTH, REC_HEIGHT, _record_fps, JPEG_QUALITY):
			printerr("[record] cannot open writer for %s" % path)
			get_tree().quit()
			return
		_record_writers.append(w)

	_record_t_start = Time.get_ticks_msec()
	print("[record] %d cameras × %d frames @ %d fps  (%dx%d) → %s/" % [
		CAMERAS.size(), _record_total_frames, _record_fps,
		REC_WIDTH, REC_HEIGHT, _record_output_dir
	])

	# Capture after each frame finishes rendering on the GPU.
	RenderingServer.frame_post_draw.connect(_record_post_draw)


func _record_post_draw() -> void:
	if _record_done: return

	if _record_settle_remaining > 0:
		_record_settle_remaining -= 1
		return

	if _record_frames_captured >= _record_total_frames:
		_finish_recording()
		return

	for i in _record_subviewports.size():
		var sv := _record_subviewports[i]
		var tex := sv.get_texture()
		if tex == null: continue
		var img := tex.get_image()
		if img == null: continue
		_record_writers[i].write_frame(img)

	_record_frames_captured += 1
	if _record_frames_captured % 10 == 0:
		print("[record]   %d/%d frames" % [_record_frames_captured, _record_total_frames])


func _finish_recording() -> void:
	_record_done = true
	for w in _record_writers:
		w.close()
	var elapsed := (Time.get_ticks_msec() - _record_t_start) / 1000.0
	var total_frames := _record_total_frames * CAMERAS.size()
	print("[record] wrote %d clips × %d frames in %.2fs (%.1f cam-frames/s)" % [
		CAMERAS.size(), _record_total_frames, elapsed, total_frames / elapsed
	])
	get_tree().quit()


# --- auto-screenshot (CLI: --auto-screenshot <path>) ---

func _auto_screenshot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img != null and img.save_png(path) == OK:
		print("[screenshot] saved → ", path)
	get_tree().quit()
