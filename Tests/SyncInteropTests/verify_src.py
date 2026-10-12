"""Independent V3 contract artifacts; deliberately never load the v2 runtime."""
import importlib.util
import json
import os
import pathlib
import struct
import subprocess
import sys

src = pathlib.Path(sys.argv[1]).resolve()
artifacts = pathlib.Path(sys.argv[2]).resolve()
contract_path = src / "tests/test_v3_contract.py"
spec = importlib.util.spec_from_file_location("floatcut_immutable_v3_contract", contract_path)
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)

# Disable bytecode/cache files in the read-only specification checkout.
environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
subprocess.run([sys.executable, "-B", "-m", "pytest", "-q", "-p", "no:cacheprovider",
                str(contract_path)], cwd=artifacts, env=environment, check=True)

expected = [contract.read_fixture("clipboard-update.json")]
for name in ("image-transfer.json", "file-transfer.json", "control-messages.json", "progress-messages.json"):
    expected.extend(contract.read_fixture(name)["messages"])
pairing = contract.read_fixture("pairing-vectors.json")
for vector in pairing:
    expected.extend(vector["messages"])
file = contract.read_fixture("file-transfer.json")
expected.extend(file["data_messages"])
channels = json.loads((artifacts / "channels.json").read_text())
raw = (artifacts / "floatcut-v3.frames").read_bytes()
cursor = 0
for channel, expected_message in zip(channels, expected, strict=True):
    size = struct.unpack_from("!I", raw, cursor)[0]
    frame = raw[cursor:cursor + size + 4]
    cursor += size + 4
    maximum = 16384 if channel == "file" else 1048576
    decoded = contract._decode_control_frame(frame, max_payload=maximum)
    assert decoded == expected_message
    contract.schema_validator("data-channel" if channel == "file" else "message").validate(decoded)
assert cursor == len(raw)
digests = json.loads((artifacts / "floatcut-v3-digests.json").read_text())
for actual, vector in zip(digests["pairing"], pairing, strict=True):
    for key, value in actual.items():
        assert value == vector[key], key
assert digests["offer_sha256"] == file["offer_sha256"]
print(f"Independent Python V3 contract/schema verification: {len(expected)} Swift messages and exact digest vectors")
