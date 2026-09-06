"""Offline cross-codec test using the unchanged SRC package, no network/state."""
import hashlib
import pathlib
import sys

from floatcut_sync_ref.protocol.codec import FrameDecoder, b64url_decode, encode_message

directory = pathlib.Path(sys.argv[1])
decoder = FrameDecoder()
raw = (directory / "floatcut.frames").read_bytes()
messages = []
for offset in range(0, len(raw), 7919):
    messages.extend(decoder.feed(raw[offset:offset + 7919]))
decoder.finish()
image = bytearray()
begin = None
images = texts = 0
output = bytearray()
for message in messages:
    kind = message["type"]
    if kind == "CLIPBOARD_UPDATE":
        texts += 1
    elif kind == "CLIPBOARD_IMAGE_BEGIN":
        assert begin is None
        begin = message
        image = bytearray()
    elif kind == "CLIPBOARD_IMAGE_CHUNK":
        assert begin and message["clip_id"] == begin["clip_id"]
        image.extend(b64url_decode(message["data"]))
    elif kind == "CLIPBOARD_IMAGE_COMMIT":
        assert begin and len(image) == begin["byte_size"]
        assert hashlib.sha256(image).hexdigest() == begin["content_sha256"]
        suffix = "png" if begin["content_type"] == "image/png" else "jpeg"
        assert image == (directory / f"source.{suffix}").read_bytes()
        images += 1
        begin = None
    output.extend(encode_message(kind, **{key: value for key, value in message.items() if key != "type"}))
assert images == 2 and texts == 1 and begin is None
(directory / "src.frames").write_bytes(output)
print("Floatcut → SRC: text and multi-chunk PNG/JPEG validated, byte-identical")
