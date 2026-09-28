"""Exercise public converters using generated coefficients and model bytes."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] /
                       "examples/gods_of_the_arena/tools"))
import convert_david
import convert_richard


def rejected(call):
    """Require converters to reject unsupported or inconsistent input."""
    try:
        call()
    except ValueError:
        return True
    return False


def layer(hidden, outputs, fixed=False):
    """Generate ordered synthetic affine/ReLU blocks without trained weights."""
    zero = "0.0" if fixed else "0"
    coefficient = "0.5" if fixed else "2"
    normalized = " / 100.0" if fixed else ""
    result = ""
    for i in range(hidden):
        result += (f"h({i}) = {zero} + f(0){normalized} * ({coefficient})\n"
                   f"if h({i}) < {zero} then\n  h({i}) = {zero}\nend if\n")
    score = "residualScore" if fixed else "score"
    for i in range(outputs):
        result += f"{score} = {zero} + h(0) * ({coefficient})\n"
        result += f"if {score} > bestScore then\n  bestScore = {score}\nend if\n"
    return result


source = "bestScore = -2147483647\n" + layer(16, 18) + layer(8, 19, True)
converted, resources = convert_richard.convert(source)
assert converted.count("nn_richard(") == 2
assert "bestScore = -32767.9999847412109375" in converted
assert "nnCombatData(nnIndex) = f(nnIndex)" in converted
assert "nnResidualData(nnIndex) = f(nnIndex)" in converted
assert len(resources["combat.bin"]) == 12 + 4 * (26 * 16 + 17 * 18)
assert len(resources["residual.bin"]) == 12 + 4 * (32 * 8 + 9 * 19)
assert struct.unpack_from("<i", resources["combat.bin"], 16)[0] == 2
assert struct.unpack_from("<i", resources["residual.bin"], 16)[0] == 32768
assert rejected(lambda: convert_richard.convert(source.replace("h(0) < 0 then", "h(0) < 1 then", 1)))
assert rejected(lambda: convert_richard.convert(source.replace("f(0) * (2)", "f(0) * (2) + f(0) * (1)", 1)))
assert rejected(lambda: convert_richard.word("0.1", True))

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "legacy.zip"
    params = 64 * (1407 + 3 * 64 + 92)
    model = (b"GOTANET1" + struct.pack("<6I", 1, 1407, 64, 92, 5, params) +
             "".join(convert_david.CONTRACTS.values()).encode() +
             struct.pack("<5I", 8, 25, 49, 4, 6) + bytes(params * 4))
    basic = b"if selfHp <= 0 then\nend\nend if\nacted = gota_act()\n"
    manifest = {
        "schema": "gota-neural-basic/1",
        "files": {"policy.bas": hashlib.sha256(basic).hexdigest(),
                  "model.bin": hashlib.sha256(model).hexdigest()},
        **convert_david.CONTRACTS,
        "decision_period": 7,
        "goal": {"w_score": 0.5, "w_win": 1},
        "decoder": {"mode": "sample", "mask_empty_targets": True,
                    "mask_mode": "static", "temperature": 0.75},
    }

    def write_package():
        """Write the current synthetic legacy configuration."""
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("manifest.json", json.dumps(manifest))
            archive.writestr("policy.bas", basic)
            archive.writestr("model.bin", model)

    write_package()
    output, weights = convert_david.convert(path)
    assert weights == model
    assert "gota_act" not in output
    assert "nnPeriod = 7" in output and "nnTemperature = 0.7500000000" in output
    assert "nnGoals(0) = 0.5000000000" in output
    assert "nnGoals(1) = 1.0000000000" in output
    assert "blobClear(nnState)" in output
    manifest["decoder"]["mask_mode"] = "conditional"
    write_package()
    assert rejected(lambda: convert_david.convert(path))
    manifest["decoder"]["mask_mode"] = "static"
    manifest["defer_script"] = True
    write_package()
    assert rejected(lambda: convert_david.convert(path))
    manifest["defer_script"] = False
    manifest["files"]["model.bin"] = "bad"
    write_package()
    assert rejected(lambda: convert_david.convert(path))

print("Synthetic Richard and David converters passed")
