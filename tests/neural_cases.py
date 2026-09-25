"""Shared neural-package corruption suite, Python half (stdlib only; CI runs it).

  python3 tests/neural_cases.py OUT_DIR

Builds the toy contract of tests/neural_toy.nim ("toy-neural/1"), writes a good package and
every corruption case to OUT_DIR/<case>.zip, validates each with the shared Python validator
(coworld/runtime/neural_package.py) and records the verdicts in OUT_DIR/verdicts.json. Then
tests/test_neural_cases.nim validates the same files with the Nim loader and fails on any
disagreement, so the two validators cannot drift apart.
"""
import io, json, os, struct, sys, zipfile, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../coworld/runtime"))
import neural_package as npk  # noqa: E402

TOY = npk.Contract(
    schema="toy-neural/1",
    obs_hash=npk.contract_hash("toy-neural/1 observation v1 float32[3]: bias,x,alive"),
    action_hash=npk.contract_hash("toy-neural/1 action v1 heads move2,aim3"),
    obs_size=3, heads=[2, 3], max_period=8, op_budget=200_000,
    manifest_keys=("tag",), decoder_keys=("hold",))


def _toy_options(m):
    if "tag" in m and (not isinstance(m["tag"], str) or len(m["tag"].encode()) > 32):
        raise npk.PackageError("tag must be a string of at most 32 bytes")
    if "decoder" in m:
        npk.require_bool(m["decoder"], "hold", "decoder")
    return None


TOY.parse_options = _toy_options
POLICY = b"' toy policy\nx = neuralModel(1)\n"


def model(hidden=64, seed=1, obs_hash=TOY.obs_hash, inputs=3, heads=(2, 3)):
    n = inputs * hidden + 3 * hidden * hidden + sum(heads) * hidden
    s = (seed * 2654435761 + 1) & 0xFFFFFFFF
    w = []
    for _ in range(n):
        s = (s * 1664525 + 1013904223) & 0xFFFFFFFF
        w.append(((s >> 8) / 16777216 - 0.5) * 0.5)
    return npk.encode_model(w, hidden, npk.Contract(TOY.schema, obs_hash, TOY.action_hash, inputs, list(heads)),
                            inputs, list(heads))


def manifest(policy=POLICY, mdl=None, **edits):
    m = npk.manifest_for(policy, mdl if mdl is not None else model(), TOY, period=2)
    for k, v in edits.items():
        if v is DELETE:
            m.pop(k)
        else:
            m[k] = v
    return m


DELETE = object()


def package(m=None, policy=POLICY, mdl=None, raw_manifest=None):
    mdl = mdl if mdl is not None else model()
    text = raw_manifest if raw_manifest is not None else json.dumps(m if m is not None else manifest(policy, mdl))
    return npk.zip_files({"manifest.json": text, "policy.bas": policy, "model.bin": mdl})


def raw_zip(entries):
    """entries: (name, data, method, flags, declared_size or None, stored_payload or None)."""
    out, central = bytearray(), bytearray()
    for name, data, method, flags, declared, payload in entries:
        if payload is None:
            if method == 8:
                c = zlib.compressobj(9, zlib.DEFLATED, -15)
                payload = c.compress(data) + c.flush()
            else:
                payload = data
        size = len(data) if declared is None else declared
        crc = zlib.crc32(data)
        off = len(out)
        nb = name.encode()
        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, flags, method, 0, 0, crc, len(payload), size, len(nb), 0)
        out += nb + payload
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, flags, method, 0, 0, crc, len(payload), size,
                               len(nb), 0, 0, 0, 0, 0, off) + nb
    cd = len(out)
    out += central + struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries), len(central), cd, 0)
    return bytes(out)


def with_model_bytes(mdl):
    return package(manifest(POLICY, mdl), POLICY, mdl)


def cases():
    good_model = model()
    m = manifest()
    text = json.dumps(m)
    nan_weight = bytearray(good_model)
    nan_weight[160 + 8 + 20:160 + 8 + 24] = struct.pack("<f", float("nan"))
    bad_magic = b"X" + good_model[1:]
    yield "good", package(), True
    yield "good stored", raw_zip([("manifest.json", text.encode(), 0, 0, None, None),
                                  ("policy.bas", POLICY, 0, 0, None, None),
                                  ("model.bin", good_model, 0, 0, None, None)]), True
    yield "good sample decoder", package(manifest(decoder={"mode": "sample", "temperature": 0.5, "hold": True},
                                                  tag="v1")), True
    yield "unknown top key", package(manifest(extra=1)), False
    yield "unknown decoder key", package(manifest(decoder={"fire": 1})), False
    yield "unknown model key", package(dict(m, model=dict(m["model"], layers=1))), False
    yield "unknown files key", package(dict(m, files=dict(m["files"], **{"notes.txt": "x"}))), False
    yield "game decoder key wrong type", package(manifest(decoder={"hold": 1})), False
    yield "game manifest key wrong type", package(manifest(tag=7)), False
    yield "decoder not an object", package(manifest(decoder="argmax")), False
    yield "heads not a list", package(dict(m, model=dict(m["model"], heads=3))), False
    yield "float int inputs", package(dict(m, model=dict(m["model"], inputs=3.0))), False
    yield "float int heads", package(dict(m, model=dict(m["model"], heads=[2.0, 3]))), False
    yield "float int period", package(manifest(decision_period=2.0)), False
    yield "bool period", package(manifest(decision_period=True)), False
    yield "period out of range", package(manifest(decision_period=9)), False
    yield "temperature true", package(manifest(decoder={"mode": "sample", "temperature": True})), False
    yield "temperature out of range", package(manifest(decoder={"mode": "sample", "temperature": 20})), False
    yield "temperature without sample", package(manifest(decoder={"temperature": 1})), False
    yield "bad decoder mode", package(manifest(decoder={"mode": "beam"})), False
    yield "schema not a string", package(manifest(schema=1)), False
    yield "wrong schema", package(manifest(schema="other/1")), False
    yield "obs contract mismatch", package(manifest(observation_contract="0" * 64)), False
    yield "missing model key", package(manifest(model=DELETE)), False
    yield "manifest not json", package(raw_manifest="{not json"), False
    yield "manifest array", package(raw_manifest="[1, 2]"), False
    yield "manifest NaN token", package(raw_manifest=text.replace('"decision_period": 2', '"decision_period": NaN')), False
    yield "manifest infinity", package(raw_manifest=text.replace('"decision_period": 2',
                                                                 '"decision_period": 2, "tag": 1e999')), False
    deep = "[" * 30000 + "]" * 30000
    yield "manifest deeply nested", package(raw_manifest=text.replace('"decision_period": 2',
                                                                      '"decision_period": 2, "tag": ' + deep)), False
    yield "missing model file", npk.zip_files({"manifest.json": text, "policy.bas": POLICY}), False
    yield "extra file", npk.zip_files({"manifest.json": text, "policy.bas": POLICY, "model.bin": good_model,
                                        "notes.txt": b"hi"}), False
    yield "duplicate entry", raw_zip([("manifest.json", text.encode(), 8, 0, None, None),
                                      ("policy.bas", POLICY, 8, 0, None, None),
                                      ("policy.bas", POLICY, 8, 0, None, None)]), False
    yield "encrypted entry", raw_zip([("manifest.json", text.encode(), 8, 0, None, None),
                                      ("policy.bas", POLICY, 8, 0, None, None),
                                      ("model.bin", good_model, 8, 1, None, None)]), False
    yield "unsupported compression", raw_zip([("manifest.json", text.encode(), 8, 0, None, None),
                                              ("policy.bas", POLICY, 8, 0, None, None),
                                              ("model.bin", good_model, 12, 0, None, good_model)]), False
    yield "zip bomb", raw_zip([("manifest.json", text.encode(), 8, 0, None, None),
                               ("policy.bas", POLICY, 8, 0, None, None),
                               ("model.bin", b"\0" * (8 << 20), 8, 0, 1024, None)]), False
    yield "declared size over cap", raw_zip([("manifest.json", text.encode(), 8, 0, None, None),
                                             ("policy.bas", POLICY, 0, 0, 256 * 1024 + 1, POLICY),
                                             ("model.bin", good_model, 8, 0, None, None)]), False
    yield "declared size lies", raw_zip([("manifest.json", text.encode(), 8, 0, None, None),
                                         ("policy.bas", POLICY, 0, 0, len(POLICY) + 1, POLICY),
                                         ("model.bin", good_model, 8, 0, None, None)]), False
    yield "corrupt deflate", raw_zip([("manifest.json", text.encode(), 8, 0, None, None),
                                      ("policy.bas", POLICY, 8, 0, None, b"\xff\xff\xff\xff"),
                                      ("model.bin", good_model, 8, 0, None, None)]), False
    yield "truncated zip", package()[:600], False
    yield "not a zip", b"PK\x03\x04" + b"\0" * 100, False
    yield "oversized package", b"PK\x03\x04" + b"\0" * (16 << 20), False
    yield "bad model magic", with_model_bytes(bad_magic), False
    yield "nonfinite weight", with_model_bytes(bytes(nan_weight)), False
    yield "truncated model", with_model_bytes(good_model[:-4]), False
    yield "policy hash mismatch", package(manifest(POLICY, good_model), POLICY + b"' edit\n", good_model), False
    yield "model hash mismatch", package(manifest(POLICY, good_model), POLICY, model(seed=2)), False
    yield "model contract hash mismatch", with_model_bytes(model(obs_hash="a" * 64)), False
    yield "model inputs mismatch", with_model_bytes(model(inputs=4)), False
    yield "model heads mismatch", with_model_bytes(model(heads=(3, 2))), False
    big = model(hidden=256)  # 2*(3*256+3*256*256+5*256)+32*256 > 200000 ops
    yield "over op budget", package(manifest(POLICY, big), POLICY, big), False


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    verdicts, failures = {}, []
    for i, (name, data, expected) in enumerate(cases()):
        try:
            npk.validate(data, TOY)
            accepted, reason = True, ""
        except npk.PackageError as e:
            accepted, reason = False, str(e)
        except Exception as e:  # any other exception is a validator bug
            accepted, reason = None, f"{type(e).__name__}: {e}"
        file = f"case{i:02d}.zip"
        with open(os.path.join(out, file), "wb") as f:
            f.write(data)
        verdicts[file] = {"name": name, "accepted": accepted, "reason": reason}
        ok = accepted is expected
        print(("PASS " if ok else "FAIL ") + f"{name}: " + ("accepted" if accepted else f"rejected ({reason})"))
        if not ok:
            failures.append(name)
    with open(os.path.join(out, "verdicts.json"), "w") as f:
        json.dump(verdicts, f, indent=1)
    print(f"{len(verdicts)} cases, {len(failures)} failures {failures if failures else ''}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
