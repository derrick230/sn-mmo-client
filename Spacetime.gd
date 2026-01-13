extends Node

@export var host_http: String = "http://localhost:3000"
@export var db_name: String = "server"

var identity: String = ""
var token: String = ""

var ws := WebSocketPeer.new()
var _http_identity := HTTPRequest.new()
var _http_reducer := HTTPRequest.new()
var _http_sql := HTTPRequest.new()

func _ready() -> void:
	add_child(_http_identity)
	add_child(_http_reducer)
	add_child(_http_sql)
	connect_ws()
	# Request identity immediately
	ensure_identity(func(ok: bool) -> void:
		if ok:
			print("[CLIENT] Identity ready: %s" % identity)
		else:
			push_error("[CLIENT] Failed to get identity")
	)

# ---------------- WebSocket subscribe (optional, but nice for later) ----------------

func connect_ws() -> void:
	var ws_url := host_http.replace("http://", "ws://").replace("https://", "wss://")
	ws_url += "/v1/database/%s/subscribe" % db_name

	ws.supported_protocols = PackedStringArray(["v1.json.spacetimedb"])

	var err := ws.connect_to_url(ws_url)
	if err != OK:
		push_error("WS connect_to_url failed: %s" % err)
	else:
		print("Connecting to ", ws_url)

func _process(_delta: float) -> void:
	ws.poll()

# ---------------- Identity ----------------

func ensure_identity(cb: Callable) -> void:
	if token != "" and identity != "":
		cb.call(true)
		return

	var url := host_http + "/v1/identity"
	_http_identity.request_completed.connect(_on_identity_done.bind(cb), CONNECT_ONE_SHOT)

	var err: int = _http_identity.request(url, [], HTTPClient.METHOD_POST, "")
	if err != OK:
		push_error("Identity request failed: %s" % err)
		cb.call(false)

func _on_identity_done(result: int, code: int, headers: PackedStringArray, body: PackedByteArray, cb: Callable) -> void:
	if code < 200 or code >= 300:
		push_error("Identity HTTP %s: %s" % [code, body.get_string_from_utf8()])
		cb.call(false)
		return

	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Identity JSON parse failed: " + body.get_string_from_utf8())
		cb.call(false)
		return

	var dict := parsed as Dictionary
	identity = str(dict.get("identity", ""))
	token = str(dict.get("token", ""))
	print("[CLIENT] Got identity: %s" % identity)
	cb.call(token != "" and identity != "")

# ---------------- Reducers (match your lib.rs) ----------------

func call_set_pos(tile: Vector2i, face: Vector2i, seq: int) -> void:
	ensure_identity(func(ok: bool) -> void:
		if not ok:
			return

		var url: String = "%s/v1/database/%s/call/set_pos" % [host_http, db_name]
		var headers := PackedStringArray([
			"Content-Type: application/json",
			"Authorization: Bearer %s" % token
		])

		var body: String = JSON.stringify({
			"x": tile.x,
			"y": tile.y,
			"facing_x": face.x,
			"facing_y": face.y,
			"seq": seq
		})

		_http_reducer.request_completed.connect(_on_set_pos_done, CONNECT_ONE_SHOT)
		var err: int = _http_reducer.request(url, headers, HTTPClient.METHOD_POST, body)
		if err != OK:
			push_error("set_pos request failed: %s" % err)
	)

func _on_set_pos_done(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if code < 200 or code >= 300:
		push_error("[CLIENT] set_pos HTTP %s: %s" % [code, body.get_string_from_utf8()])
	else:
		print("[CLIENT] set_pos successfully sent to server (HTTP %d)" % code)

func call_set_online(online: bool) -> void:
	ensure_identity(func(ok: bool) -> void:
		if not ok:
			return

		var url: String = "%s/v1/database/%s/call/set_online" % [host_http, db_name]
		var headers := PackedStringArray([
			"Content-Type: application/json",
			"Authorization: Bearer %s" % token
		])

		var body: String = JSON.stringify({ "online": online })

		_http_reducer.request_completed.connect(_on_set_online_done, CONNECT_ONE_SHOT)
		var err: int = _http_reducer.request(url, headers, HTTPClient.METHOD_POST, body)
		if err != OK:
			push_error("set_online request failed: %s" % err)
	)

func _on_set_online_done(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if code < 200 or code >= 300:
		push_error("set_online HTTP %s: %s" % [code, body.get_string_from_utf8()])

# ---------------- SQL polling ----------------

signal sql_result(query: String, payload: Variant)

func sql(query: String) -> void:
	# Don't block polling - if identity isn't ready, skip this poll
	if token == "" or identity == "":
		print("[CLIENT] Skipping SQL query - identity not ready yet")
		return
	
	var url: String = "%s/v1/database/%s/sql" % [host_http, db_name]
	var headers := PackedStringArray([
		"Content-Type: text/plain",
		"Authorization: Bearer %s" % token
	])

	_http_sql.request_completed.connect(_on_sql_done.bind(query), CONNECT_ONE_SHOT)
	var err: int = _http_sql.request(url, headers, HTTPClient.METHOD_POST, query)
	if err != OK:
		push_error("SQL request failed: %s" % err)

func _on_sql_done(result: int, code: int, headers: PackedStringArray, body: PackedByteArray, query: String) -> void:
	if code < 200 or code >= 300:
		push_error("SQL HTTP %s: %s" % [code, body.get_string_from_utf8()])
		return

	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	sql_result.emit(query, parsed)
