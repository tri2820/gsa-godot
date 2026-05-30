extends RefCounted
# Loaded via `const AviMjpegWriter = preload("res://avi_mjpeg.gd")` — no
# class_name so we don't depend on the project cache being warm.

# Minimal AVI MJPEG writer. Frames are JPEG-compressed and packed into a
# RIFF/AVI container with an idx1 index. Compatible with QuickTime, VLC,
# and ffmpeg as input.

var _file: FileAccess
var _width: int
var _height: int
var _fps: int
var _quality: float = 0.9

var _frame_count := 0
var _frame_index: PackedByteArray = PackedByteArray()  # built up over recording

# File-offset bookmarks we patch at close time.
var _riff_size_off := 0
var _avih_total_frames_off := 0
var _strh_length_off := 0
var _movi_size_off := 0
var _movi_fourcc_off := 0   # byte offset where the 'movi' fourcc word begins


func open(path: String, width: int, height: int, fps: int, jpeg_quality: float = 0.9) -> bool:
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		push_error("AviMjpegWriter: cannot open %s (err=%d)" % [path, FileAccess.get_open_error()])
		return false
	_file.big_endian = false
	_width = width
	_height = height
	_fps = fps
	_quality = jpeg_quality
	_write_header()
	return true


func write_frame(image: Image) -> void:
	if _file == null:
		push_error("AviMjpegWriter: write_frame on closed writer")
		return
	# Image source from a SubViewport is RGBA8 with bottom-up not flipped — that's
	# fine for MJPG; we just need RGB before JPEG.
	if image.get_format() != Image.FORMAT_RGB8:
		image = image.duplicate()
		image.convert(Image.FORMAT_RGB8)
	var jpg: PackedByteArray = image.save_jpg_to_buffer(_quality)
	var jpg_size := jpg.size()

	var chunk_pos := _file.get_position()
	var chunk_off_in_movi := chunk_pos - _movi_fourcc_off  # offset relative to 'movi' fourcc start

	_store_fourcc("00dc")
	_file.store_32(jpg_size)
	_file.store_buffer(jpg)
	if jpg_size % 2 == 1:
		_file.store_8(0)  # AVI chunks word-aligned

	# Build idx1 entry now: 4×4 bytes = fourcc + flags + offset + size.
	_frame_index.append_array("00dc".to_utf8_buffer())
	_append_u32(_frame_index, 0x10)               # AVIIF_KEYFRAME
	_append_u32(_frame_index, chunk_off_in_movi)
	_append_u32(_frame_index, jpg_size)
	_frame_count += 1


func close() -> void:
	if _file == null: return

	# Patch movi LIST size (includes the 'movi' fourcc itself, not the LIST/size words).
	var movi_end := _file.get_position()
	var movi_size := movi_end - _movi_fourcc_off
	_file.seek(_movi_size_off)
	_file.store_32(movi_size)
	_file.seek(movi_end)

	# idx1.
	_store_fourcc("idx1")
	_file.store_32(_frame_index.size())
	_file.store_buffer(_frame_index)

	var file_end := _file.get_position()

	# RIFF size = total file size - 8 (RIFF fourcc + size field).
	_file.seek(_riff_size_off)
	_file.store_32(file_end - 8)

	# dwTotalFrames in avih + dwLength in strh.
	_file.seek(_avih_total_frames_off)
	_file.store_32(_frame_count)
	_file.seek(_strh_length_off)
	_file.store_32(_frame_count)

	_file.close()
	_file = null


# --- header layout ---

func _write_header() -> void:
	# RIFF <size> 'AVI '
	_store_fourcc("RIFF")
	_riff_size_off = _file.get_position()
	_file.store_32(0)  # patched in close()
	_store_fourcc("AVI ")

	# LIST <size> 'hdrl'
	_store_fourcc("LIST")
	var hdrl_size_off := _file.get_position()
	_file.store_32(0)
	_store_fourcc("hdrl")
	var hdrl_data_start := _file.get_position()

	# 'avih' 56 + 56-byte AVIMainHeader.
	_store_fourcc("avih")
	_file.store_32(56)
	_file.store_32(int(1_000_000.0 / float(_fps)))  # dwMicroSecPerFrame
	_file.store_32(0)            # dwMaxBytesPerSec
	_file.store_32(0)            # dwPaddingGranularity
	_file.store_32(0x10)         # dwFlags = AVIF_HASINDEX
	_avih_total_frames_off = _file.get_position()
	_file.store_32(0)            # dwTotalFrames (patched)
	_file.store_32(0)            # dwInitialFrames
	_file.store_32(1)            # dwStreams
	_file.store_32(0)            # dwSuggestedBufferSize
	_file.store_32(_width)
	_file.store_32(_height)
	for _i in 4: _file.store_32(0)  # dwReserved[4]

	# LIST <size> 'strl'
	_store_fourcc("LIST")
	var strl_size_off := _file.get_position()
	_file.store_32(0)
	_store_fourcc("strl")
	var strl_data_start := _file.get_position()

	# 'strh' 56 + 56-byte AVIStreamHeader (video, MJPG).
	_store_fourcc("strh")
	_file.store_32(56)
	_store_fourcc("vids")
	_store_fourcc("MJPG")
	_file.store_32(0)            # dwFlags
	_file.store_16(0)            # wPriority
	_file.store_16(0)            # wLanguage
	_file.store_32(0)            # dwInitialFrames
	_file.store_32(1)            # dwScale
	_file.store_32(_fps)         # dwRate
	_file.store_32(0)            # dwStart
	_strh_length_off = _file.get_position()
	_file.store_32(0)            # dwLength (patched)
	_file.store_32(0)            # dwSuggestedBufferSize
	_file.store_32(0)            # dwQuality
	_file.store_32(0)            # dwSampleSize
	_file.store_16(0); _file.store_16(0)
	_file.store_16(_width); _file.store_16(_height)

	# 'strf' 40 + BITMAPINFOHEADER.
	_store_fourcc("strf")
	_file.store_32(40)
	_file.store_32(40)           # biSize
	_file.store_32(_width)
	_file.store_32(_height)
	_file.store_16(1)            # biPlanes
	_file.store_16(24)           # biBitCount
	_store_fourcc("MJPG")        # biCompression
	_file.store_32(_width * _height * 3)  # biSizeImage
	_file.store_32(0)            # biXPelsPerMeter
	_file.store_32(0)            # biYPelsPerMeter
	_file.store_32(0)            # biClrUsed
	_file.store_32(0)            # biClrImportant

	# Patch strl LIST size (= bytes from 'strl' fourcc through end of strf).
	var strl_end := _file.get_position()
	_file.seek(strl_size_off)
	_file.store_32(strl_end - strl_data_start + 4)
	_file.seek(strl_end)

	# Patch hdrl LIST size.
	var hdrl_end := _file.get_position()
	_file.seek(hdrl_size_off)
	_file.store_32(hdrl_end - hdrl_data_start + 4)
	_file.seek(hdrl_end)

	# LIST <size> 'movi'
	_store_fourcc("LIST")
	_movi_size_off = _file.get_position()
	_file.store_32(0)
	_store_fourcc("movi")
	_movi_fourcc_off = _file.get_position() - 4  # position of 'movi' word itself


# --- helpers ---

func _store_fourcc(s: String) -> void:
	_file.store_buffer(s.to_utf8_buffer())

func _append_u32(buf: PackedByteArray, v: int) -> void:
	buf.append(v & 0xff)
	buf.append((v >> 8) & 0xff)
	buf.append((v >> 16) & 0xff)
	buf.append((v >> 24) & 0xff)
