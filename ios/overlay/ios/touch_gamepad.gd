extends CanvasLayer
## On-screen controller for phones and tablets without a gamepad.
##
## It sends the same joypad events a real Xbox-style controller would (device
## 0, Godot's standard button and axis numbers), so every menu and every action
## works as with a controller, button prompts included. It shows only on
## touch screens, and hides itself while a real controller is connected.

const DEVICE := 0
const STICK_DEADZONE := 0.15

# Godot's JoyButton / JoyAxis numbers, as project.godot binds them.
enum { A = 0, B = 1, X = 2, Y = 3, BACK = 4, START = 6, L3 = 7, LB = 9, RB = 10 }
enum { AXIS_LX = 0, AXIS_LY = 1, AXIS_LT = 4, AXIS_RT = 5 }

class Pad:
	var label: String
	var caption: String
	var button: int = -1      # joypad button, or -1
	var axis: int = -1        # trigger axis, or -1
	var color: Color
	var center: Vector2
	var radius: float
	var touch := -1
	func _init(l: String, c: String, b: int, a: int, col: Color) -> void:
		label = l; caption = c; button = b; axis = a; color = col

var pads: Array[Pad] = []
var stick_touch := -1
var stick_origin := Vector2.ZERO
var stick_position := Vector2.ZERO
var stick_radius := 80.0
var stick_vector := Vector2.ZERO
var canvas: Control
var font: Font
var opacity := 0.55
var enabled := false

func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	canvas = Control.new()
	canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.draw.connect(_draw_controls)
	add_child(canvas)
	font = ThemeDB.fallback_font
	pads = [
		Pad.new("A", "Jump", A, -1, Color(0.30, 0.78, 0.36)),
		Pad.new("B", "Action", B, -1, Color(0.88, 0.30, 0.28)),
		Pad.new("X", "Attack", X, -1, Color(0.27, 0.52, 0.95)),
		Pad.new("Y", "Light Dash", Y, -1, Color(0.95, 0.78, 0.25)),
		Pad.new("LT", "Time Break", -1, AXIS_LT, Color(0.62, 0.48, 0.92)),
		Pad.new("RT", "Speed Break", -1, AXIS_RT, Color(0.97, 0.55, 0.22)),
		Pad.new("LB", "Step", LB, -1, Color(0.75, 0.75, 0.80)),
		Pad.new("RB", "Step", RB, -1, Color(0.75, 0.75, 0.80)),
		Pad.new("L3", "Brake", L3, -1, Color(0.70, 0.70, 0.75)),
		Pad.new("☰", "Pause", START, -1, Color(0.92, 0.92, 0.95)),
		Pad.new("⧉", "Back", BACK, -1, Color(0.92, 0.92, 0.95)),
	]
	Input.joy_connection_changed.connect(func(_device, _connected): _update_enabled())
	get_viewport().size_changed.connect(_layout)
	_update_enabled()
	_layout()

func _update_enabled() -> void:
	var real_pads := Input.get_connected_joypads().size()
	var touch := DisplayServer.is_touchscreen_available() or OS.has_feature("mobile")
	enabled = touch and real_pads == 0
	visible = enabled
	if not enabled:
		_release_all()

func _layout() -> void:
	var size := get_viewport().get_visible_rect().size
	var safe := Rect2(Vector2.ZERO, size)
	var screen_safe := DisplayServer.get_display_safe_area()
	var screen_size := Vector2(DisplayServer.screen_get_size())
	if screen_safe.size.x > 0 and screen_size.x > 0:
		var ratio := size / screen_size
		safe = Rect2(Vector2(screen_safe.position) * ratio, Vector2(screen_safe.size) * ratio)
	var h := size.y
	var r := h * 0.068
	stick_radius = h * 0.13
	var right := safe.end.x - h * 0.05
	var bottom := safe.end.y - h * 0.05
	var diamond := Vector2(right - r * 3.2, bottom - r * 3.2)
	var gap := r * 2.15
	_place("A", diamond + Vector2(0, gap), r)
	_place("B", diamond + Vector2(gap, 0), r)
	_place("X", diamond + Vector2(-gap, 0), r)
	_place("Y", diamond + Vector2(0, -gap), r)
	_place("RT", diamond + Vector2(gap * 0.9, -gap * 2.2), r * 0.9)
	_place("LT", diamond + Vector2(-gap * 0.9, -gap * 2.2), r * 0.9)
	_place("LB", Vector2(safe.position.x + h * 0.11, safe.position.y + h * 0.12), r * 0.8)
	_place("RB", Vector2(safe.end.x - h * 0.11, safe.position.y + h * 0.12), r * 0.8)
	_place("L3", Vector2(safe.position.x + h * 0.44, bottom - r * 0.9), r * 0.75)
	_place("☰", Vector2(size.x * 0.5 + h * 0.09, safe.position.y + h * 0.07), r * 0.6)
	_place("⧉", Vector2(size.x * 0.5 - h * 0.09, safe.position.y + h * 0.07), r * 0.6)
	stick_origin = Vector2(safe.position.x + h * 0.26, bottom - h * 0.22)
	if stick_touch == -1:
		stick_position = stick_origin
	canvas.queue_redraw()

func _place(label: String, center: Vector2, radius: float) -> void:
	for pad in pads:
		if pad.label == label:
			pad.center = center
			pad.radius = radius

func _input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_down(event.index, event.position)
		else:
			_touch_up(event.index)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		if event.index == stick_touch:
			_move_stick(event.position)
		else:
			_slide(event.index, event.position)
		get_viewport().set_input_as_handled()

func _touch_down(index: int, position: Vector2) -> void:
	var pad := _pad_at(position)
	if pad:
		_press(pad, index)
		return
	var size := get_viewport().get_visible_rect().size
	if stick_touch == -1 and position.x < size.x * 0.5:
		stick_touch = index
		# The stick starts where the thumb lands (within reach of its home).
		stick_origin = position
		_move_stick(position)

func _touch_up(index: int) -> void:
	if index == stick_touch:
		stick_touch = -1
		stick_vector = Vector2.ZERO
		_send_axis(AXIS_LX, 0.0)
		_send_axis(AXIS_LY, 0.0)
		_layout()
		return
	for pad in pads:
		if pad.touch == index:
			_release(pad)

# A thumb sliding across the face buttons presses the one it reaches.
func _slide(index: int, position: Vector2) -> void:
	var held: Pad = null
	for pad in pads:
		if pad.touch == index:
			held = pad
	var under := _pad_at(position)
	if held == under or under == null:
		return
	if held and (held.label in ["A", "B", "X", "Y"]) and (under.label in ["A", "B", "X", "Y"]):
		_release(held)
		_press(under, index)

func _pad_at(position: Vector2) -> Pad:
	for pad in pads:
		if pad.center.distance_to(position) <= pad.radius * 1.25:
			return pad
	return null

func _press(pad: Pad, index: int) -> void:
	pad.touch = index
	if pad.button >= 0:
		_send_button(pad.button, true)
	else:
		_send_axis(pad.axis, 1.0)
	canvas.queue_redraw()

func _release(pad: Pad) -> void:
	pad.touch = -1
	if pad.button >= 0:
		_send_button(pad.button, false)
	else:
		_send_axis(pad.axis, 0.0)
	canvas.queue_redraw()

func _release_all() -> void:
	for pad in pads:
		if pad.touch != -1:
			_release(pad)
	if stick_touch != -1:
		_touch_up(stick_touch)

func _move_stick(position: Vector2) -> void:
	var offset := position - stick_origin
	if offset.length() > stick_radius:
		offset = offset.normalized() * stick_radius
	stick_position = stick_origin + offset
	var value := offset / stick_radius
	if value.length() < STICK_DEADZONE:
		value = Vector2.ZERO
	stick_vector = value
	_send_axis(AXIS_LX, value.x)
	_send_axis(AXIS_LY, value.y)
	canvas.queue_redraw()

func _send_button(button: int, pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = DEVICE
	event.button_index = button
	event.pressed = pressed
	event.pressure = 1.0 if pressed else 0.0
	Input.parse_input_event(event)

func _send_axis(axis: int, value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.device = DEVICE
	event.axis = axis
	event.axis_value = value
	Input.parse_input_event(event)

func _draw_controls() -> void:
	var base := Color(1, 1, 1, opacity * 0.35)
	canvas.draw_circle(stick_origin, stick_radius, Color(0, 0, 0, opacity * 0.35))
	canvas.draw_arc(stick_origin, stick_radius, 0, TAU, 48, base, 3.0)
	canvas.draw_circle(stick_position, stick_radius * 0.45, Color(1, 1, 1, opacity * (0.75 if stick_touch != -1 else 0.45)))
	for pad in pads:
		var pressed := pad.touch != -1
		var fill := pad.color
		fill.a = opacity * (0.95 if pressed else 0.55)
		canvas.draw_circle(pad.center, pad.radius, fill)
		canvas.draw_arc(pad.center, pad.radius, 0, TAU, 40, Color(1, 1, 1, opacity * 0.8), 2.0)
		var font_size := int(pad.radius * 0.8)
		var text_size := font.get_string_size(pad.label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		canvas.draw_string(font, pad.center + Vector2(-text_size.x * 0.5, text_size.y * 0.32), pad.label,
			HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color(1, 1, 1, opacity + 0.3))
		var caption_size := int(pad.radius * 0.38)
		var caption_width := font.get_string_size(pad.caption, HORIZONTAL_ALIGNMENT_CENTER, -1, caption_size).x
		canvas.draw_string(font, pad.center + Vector2(-caption_width * 0.5, pad.radius + caption_size * 1.1), pad.caption,
			HORIZONTAL_ALIGNMENT_CENTER, -1, caption_size, Color(1, 1, 1, opacity * 0.9))
