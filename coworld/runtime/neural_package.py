"""Polyworld neural packages: staging validator and builder, shared by every game.

A package is a ZIP holding exactly manifest.json, policy.bas and model.bin (GOTANET1, the
polyworld neural model format). This module mirrors src/polyworld/neural_package.nim rule for
rule, so a submission the staging step accepts is one the game accepts (and the reverse). A game
supplies a Contract (schema, contract hashes, observation size, head sizes, extra manifest and
decoder keys, and an optional options parser); see docs/neural-policies.md. Plain .bas
submissions are not packages and are untouched.

Games wrap this module (e.g. coworld/gota/runtime/neural_package.py); it has no CLI of its own.
"""
import hashlib, io, json, math, struct, zipfile, zlib
from dataclasses import dataclass
from typing import Callable, Optional

FILES = ("manifest.json", "policy.bas", "model.bin")
MAX_PACKAGE = 16 * 1024 * 1024
MAX_POLICY = 256 * 1024
MAX_MANIFEST = 64 * 1024
MAX_PARAMS = 2_000_000
MAX_MODEL = 8 + 24 + 128 + 4 * 32 + 4 * MAX_PARAMS
MAX_ENTRIES = 16
LIMITS = {"manifest.json": MAX_MANIFEST, "policy.bas": MAX_POLICY, "model.bin": MAX_MODEL}
WIDTHS = (64, 128, 256)
MAX_INPUTS = 4096
MAGIC = b"GOTANET1"
DEFAULT_OP_BUDGET = 4_000_000
MANIFEST_KEYS = ("schema", "observation_contract", "action_contract", "decision_period", "files", "model",
                 "decoder")
REQUIRED = ("schema", "observation_contract", "action_contract", "decision_period", "files", "model")
MODEL_KEYS = ("format", "inputs", "hidden", "heads")
DECODER_KEYS = ("mode", "temperature")


class PackageError(ValueError):
    pass


@dataclass
class Contract:
    """The package half of a game's neural contract (neural_package.nim PackageContract)."""
    schema: str
    obs_hash: str
    action_hash: str
    obs_size: int
    heads: list
    max_period: int = 24
    op_budget: int = DEFAULT_OP_BUDGET
    manifest_keys: tuple = ()
    decoder_keys: tuple = ()
    parse_options: Optional[Callable[[dict], object]] = None
    """Validates the game's manifest_keys / decoder_keys (raise PackageError); returns options."""


def contract_hash(text: str) -> str:
    """A contract hash: lowercase SHA-256 hex of the contract's canonical text."""
    return hashlib.sha256(text.encode()).hexdigest()


def is_package(data: bytes) -> bool:
    return data[:4] == b"PK\x03\x04"


def is_int(v) -> bool:
    """A JSON integer: not a bool and not a float (1407.0 is rejected)."""
    return isinstance(v, int) and not isinstance(v, bool)


def is_number(v) -> bool:
    """A JSON number: int or float, never a bool."""
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def require_keys(node, allowed, where):
    if not isinstance(node, dict):
        raise PackageError(f"{where} must be an object")
    for key in node:
        if key not in allowed:
            raise PackageError(f"unknown manifest key {where}.{key}")


def require_bool(node, key, where):
    """An optional boolean key (False when absent)."""
    if key in node:
        if not isinstance(node[key], bool):
            raise PackageError(f"{where}.{key} must be true or false")
        return node[key]
    return False


def _reject_constant(name):
    raise PackageError(f"manifest holds a non-finite number ({name})")


MAX_JSON_DEPTH = 64
"""No valid manifest nests deeper than a few levels; deeper ones are rejected without recursion (json's own
limit depends on the Python version, the Nim parser stops at 1000)."""


def _reject_non_finite(node, where="manifest"):
    """Rejects any non-finite number and any nesting deeper than MAX_JSON_DEPTH (iterative, depth-first)."""
    stack = [(node, where, 0)]
    while stack:
        item, path, depth = stack.pop()
        if depth > MAX_JSON_DEPTH:
            raise PackageError("manifest.json is nested too deeply")
        if isinstance(item, float) and not math.isfinite(item):
            raise PackageError(f"{path} holds a non-finite number")
        if isinstance(item, list):
            stack.extend((child, path, depth + 1) for child in reversed(item))
        elif isinstance(item, dict):
            stack.extend((child, f"{path}.{key}", depth + 1) for key, child in reversed(list(item.items())))


def head_list(heads):
    return "[" + ",".join(str(h) for h in heads) + "]"


def check_model(data: bytes, contract: Contract):
    """Validates a GOTANET1 model.bin for `contract`; returns (hidden, operations)."""
    if data[:8] != MAGIC:
        raise PackageError("invalid neural actor magic (want GOTANET1)")
    if len(data) < 32:
        raise PackageError("truncated neural actor")
    version, inputs, hidden, outputs, heads, params = struct.unpack_from("<6I", data, 8)
    if version != 1 or not 1 <= inputs <= MAX_INPUTS or hidden not in WIDTHS or not 2 <= outputs <= 1024 or \
            not 1 <= heads <= 32:
        raise PackageError("unsupported neural actor dimensions/version")
    expected = inputs * hidden + 3 * hidden * hidden + outputs * hidden
    if params != expected or expected > MAX_PARAMS or len(data) != 32 + 128 + 4 * heads + 4 * expected:
        raise PackageError("invalid neural actor length/parameter count")
    ohash, ahash = data[32:96].decode("ascii", "replace"), data[96:160].decode("ascii", "replace")
    for h in (ohash, ahash):
        if any(c not in "0123456789abcdef" for c in h):
            raise PackageError("invalid neural contract hash")
    sizes = list(struct.unpack_from(f"<{heads}I", data, 160))
    if any(not 2 <= s <= 1024 for s in sizes) or sum(sizes) != outputs:
        raise PackageError("head/output mismatch")
    weights = memoryview(data)[160 + 4 * heads:].cast("f")
    if not all(math.isfinite(w) for w in weights):
        raise PackageError("nonfinite neural weight")
    ops = 2 * expected + 32 * hidden
    if ops > contract.op_budget:
        raise PackageError(f"neural actor needs {ops} operations per inference, over the "
                           f"{contract.op_budget} budget")
    if ohash != contract.obs_hash or ahash != contract.action_hash:
        raise PackageError("model.bin contract hashes do not match the manifest")
    if inputs != contract.obs_size:
        raise PackageError(f"model.inputs must be {contract.obs_size}")
    if sizes != list(contract.heads):
        raise PackageError(f"model.heads must be {head_list(contract.heads)}")
    return hidden, ops


def read_zip(data: bytes) -> dict:
    """The package files, with each entry's declared size checked against its cap before
    decompressing, and decompression bounded by the declared size."""
    if len(data) > MAX_PACKAGE:
        raise PackageError("package exceeds 16 MiB")
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
        infos = z.infolist()
    except (zipfile.BadZipFile, zipfile.LargeZipFile, ValueError, OSError, EOFError) as e:
        raise PackageError(f"not a zip: {e}")
    if len(infos) > MAX_ENTRIES:
        raise PackageError("too many zip entries")
    files = {}
    for info in infos:
        limit = LIMITS.get(info.filename)
        if limit is None:
            raise PackageError(f"unexpected package entry {info.filename}")
        if info.file_size > limit:
            raise PackageError(f"{info.filename} exceeds its {limit} byte limit")
        if info.flag_bits & 1:
            raise PackageError("encrypted zip entry")
        if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise PackageError(f"unsupported zip compression {info.compress_type}")
        if info.filename in files:
            raise PackageError(f"unexpected package entry {info.filename}")
        files[info.filename] = _read_entry(data, info, limit)
    if len(files) != 3 or sorted(files) != sorted(FILES):
        raise PackageError("package must contain exactly manifest.json, policy.bas and model.bin")
    return files


def _read_entry(data: bytes, info: zipfile.ZipInfo, limit: int) -> bytes:
    """One entry's bytes through its local header, inflating at most `info.file_size` bytes
    (the Nim loader reads the same way; CRCs are not checked by either)."""
    p = info.header_offset
    if p + 30 > len(data) or data[p:p + 4] != b"PK\x03\x04":
        raise PackageError("bad zip entry")
    name_len, extra_len = struct.unpack_from("<HH", data, p + 26)
    start = p + 30 + name_len + extra_len
    if start + info.compress_size > len(data):
        raise PackageError("truncated zip data")
    raw = data[start:start + info.compress_size]
    if info.compress_type == zipfile.ZIP_STORED:
        out = raw
    else:
        d = zlib.decompressobj(-15)
        try:
            out = d.decompress(raw, info.file_size + 1)
        except zlib.error as e:
            raise PackageError(f"bad deflate data for {info.filename}: {e}")
        if len(out) > info.file_size:
            raise PackageError(f"bad deflate data for {info.filename}: inflated data exceeds its limit")
        if not d.eof:
            raise PackageError(f"bad deflate data for {info.filename}: truncated stream")
    if len(out) != info.file_size:
        raise PackageError(f"zip size mismatch for {info.filename}")
    return out


def validate(data: bytes, contract: Contract):
    """Raises PackageError with the reason; returns (manifest, options) on success."""
    files = read_zip(data)
    try:
        m = json.loads(files["manifest.json"], parse_constant=_reject_constant)
    except PackageError:
        raise
    except (ValueError, UnicodeDecodeError, RecursionError) as e:
        raise PackageError(f"manifest.json is not JSON: {e}")
    require_keys(m, MANIFEST_KEYS + tuple(contract.manifest_keys), "manifest")
    _reject_non_finite(m)
    for key in REQUIRED:
        if key not in m:
            raise PackageError(f"manifest is missing {key}")
    for key in ("schema", "observation_contract", "action_contract"):
        if not isinstance(m[key], str):
            raise PackageError(f"manifest.{key} must be a string")
    if m["schema"] != contract.schema:
        raise PackageError(f"manifest schema must be {contract.schema}")
    if m["observation_contract"] != contract.obs_hash:
        raise PackageError("observation contract mismatch")
    if m["action_contract"] != contract.action_hash:
        raise PackageError("action contract mismatch")
    p = m["decision_period"]
    if not is_int(p):
        raise PackageError("manifest.decision_period must be an integer")
    if not 1 <= p <= contract.max_period:
        raise PackageError(f"decision_period must be an integer 1..{contract.max_period}")
    require_keys(m["files"], {"policy.bas", "model.bin"}, "files")
    if set(m["files"]) != {"policy.bas", "model.bin"}:
        raise PackageError("files must list policy.bas and model.bin")
    for n in ("policy.bas", "model.bin"):
        if not isinstance(m["files"][n], str):
            raise PackageError(f"files.{n} must be a string")
        if m["files"][n] != hashlib.sha256(files[n]).hexdigest():
            raise PackageError(f"{n} sha256 mismatch")
    if len(files["policy.bas"]) > MAX_POLICY:
        raise PackageError("policy.bas exceeds 256 KiB")
    model = m["model"]
    require_keys(model, MODEL_KEYS, "model")
    for key in MODEL_KEYS:
        if key not in model:
            raise PackageError(f"model is missing {key}")
    if not isinstance(model["format"], str):
        raise PackageError("model.format must be a string")
    if model["format"] != "GOTANET1":
        raise PackageError("model.format must be GOTANET1")
    hidden, _ = check_model(files["model.bin"], contract)
    for key in ("inputs", "hidden"):
        if not is_int(model[key]):
            raise PackageError(f"model.{key} must be an integer")
    if model["inputs"] != contract.obs_size:
        raise PackageError(f"model.inputs must be {contract.obs_size}")
    if model["hidden"] != hidden:
        raise PackageError("model.hidden does not match model.bin")
    if not isinstance(model["heads"], list) or not all(is_int(h) for h in model["heads"]):
        raise PackageError("model.heads must be a list of integers")
    if model["heads"] != list(contract.heads):
        raise PackageError(f"model.heads must be {head_list(contract.heads)}")
    if "decoder" in m:
        d = m["decoder"]
        require_keys(d, DECODER_KEYS + tuple(contract.decoder_keys), "decoder")
        mode = d.get("mode", "argmax")
        if not isinstance(mode, str):
            raise PackageError("decoder.mode must be a string")
        if mode == "argmax":
            if "temperature" in d:
                raise PackageError("decoder.temperature needs mode sample")
        elif mode == "sample":
            t = d.get("temperature", 1.0)
            if not is_number(t):
                raise PackageError("decoder.temperature must be a number")
            if not 0.01 <= t <= 10:
                raise PackageError("decoder.temperature must be 0.01..10")
        else:
            raise PackageError("decoder.mode must be argmax or sample")
    options = contract.parse_options(m) if contract.parse_options else None
    return m, options


def encode_model(weights, hidden, contract: Contract, inputs=None, heads=None):
    """GOTANET1 bytes from a flat float32 list: W_enc[H][I], W_rec[3H][H], W_dec[O][H]."""
    inputs = contract.obs_size if inputs is None else inputs
    heads = list(contract.heads) if heads is None else list(heads)
    outputs = sum(heads)
    expected = inputs * hidden + 3 * hidden * hidden + outputs * hidden
    assert len(weights) == expected
    return (MAGIC + struct.pack("<6I", 1, inputs, hidden, outputs, len(heads), expected) +
            contract.obs_hash.encode() + contract.action_hash.encode() + struct.pack(f"<{len(heads)}I", *heads) +
            struct.pack(f"<{expected}f", *weights))


def manifest_for(policy: bytes, model: bytes, contract: Contract, period=4, decoder=None, extra=None) -> dict:
    hidden = struct.unpack_from("<I", model, 16)[0]
    m = {"schema": contract.schema, "observation_contract": contract.obs_hash,
         "action_contract": contract.action_hash, "decision_period": period,
         "files": {"policy.bas": hashlib.sha256(policy).hexdigest(), "model.bin": hashlib.sha256(model).hexdigest()},
         "model": {"format": "GOTANET1", "inputs": contract.obs_size, "hidden": hidden,
                   "heads": list(contract.heads)}}
    if extra:
        m.update(extra)
    if decoder:
        m["decoder"] = decoder
    return m


def zip_files(files: dict) -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items():
            z.writestr(name, data)
    return out.getvalue()


def build(policy: bytes, model: bytes, contract: Contract, period=4, decoder=None, extra=None) -> bytes:
    """A validated package (deflate ZIP) for `contract`."""
    m = manifest_for(policy, model, contract, period, decoder, extra)
    data = zip_files({"manifest.json": json.dumps(m, indent=1), "policy.bas": policy, "model.bin": model})
    validate(data, contract)
    return data
