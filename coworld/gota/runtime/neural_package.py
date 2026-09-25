"""Staging validator and builder for GotA neural packages (gota-neural-basic/1).

GotA's contract on top of the shared polyworld validator (coworld/runtime/neural_package.py),
which mirrors src/polyworld/neural_package.nim; the GotA extension keys (goal, decoder.defer_script,
decoder.mask_empty_targets, decoder.mask_mode) mirror parseGotaOptions in
examples/gods_of_the_arena/neural_contract.nim. Plain .bas submissions are not packages and are
untouched.

  python3 neural_package.py validate PACKAGE.zip [--obs-hash H --action-hash H]
  python3 neural_package.py build OUT.zip --policy policy.bas --model model.bin
      [--period 4] [--decoder argmax|sample --temperature T] [--goal-red 16 floats] [--goal-blue ...]
"""
import argparse, dataclasses, importlib.util, os, sys

_SHARED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../runtime/neural_package.py")
_spec = importlib.util.spec_from_file_location("polyworld_neural_package", _SHARED)
tier = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tier)

PackageError = tier.PackageError
is_package = tier.is_package
SCHEMA = "gota-neural-basic/1"
FILES = tier.FILES
MAX_PACKAGE = tier.MAX_PACKAGE
MAX_POLICY = tier.MAX_POLICY
HEADS = [8, 25, 49, 4, 6]
OBS_SIZE = 1407
MASK_SIZE = 187
GOAL_SIZE = 16
WIDTHS = tier.WIDTHS
MAGIC = tier.MAGIC
OP_BUDGET = tier.DEFAULT_OP_BUDGET
MAX_PARAMS = tier.MAX_PARAMS
# Contract v1 hashes (examples/gods_of_the_arena/neural_contract.nim; gota_*_contract_hash).
OBS_HASH = "ae4046e83cc02e861f9c8cc32550c6cc4d6f9c161c9225a9b34a314d310ea991"
ACTION_HASH = "ecc7d53c11a9db0912467c66ecb3e65b60b3e71ef14dad1442ba3b4f6ac14697"


def _goal(node, where):
    if not isinstance(node, list) or len(node) != GOAL_SIZE or not all(tier.is_number(v) for v in node):
        raise PackageError(f"{where} must be 16 numbers")
    if any(v < -1 or v > 1 for v in node):
        raise PackageError(f"{where} values must be in [-1, 1]")
    if node[15] != 0:
        raise PackageError(f"{where} w_reserved must be 0")


def parse_options(m):
    """GotA manifest keys: goal {red, blue}; decoder.defer_script / mask_empty_targets / mask_mode."""
    options = {"defer_script": False, "mask_mode": None}
    if "goal" in m:
        tier.require_keys(m["goal"], {"red", "blue"}, "goal")
        if set(m["goal"]) != {"red", "blue"}:
            raise PackageError("goal needs red and blue")
        _goal(m["goal"]["red"], "goal.red")
        _goal(m["goal"]["blue"], "goal.blue")
    if "decoder" in m:
        d = m["decoder"]
        masked = tier.require_bool(d, "mask_empty_targets", "decoder")
        if masked:
            options["mask_mode"] = "conditional"
        if "mask_mode" in d:
            if not masked:
                raise PackageError("decoder.mask_mode needs mask_empty_targets true")
            if d["mask_mode"] not in ("conditional", "static"):
                raise PackageError("decoder.mask_mode must be conditional or static")
            options["mask_mode"] = d["mask_mode"]
        options["defer_script"] = tier.require_bool(d, "defer_script", "decoder")
    return options


GOTA = tier.Contract(schema=SCHEMA, obs_hash=OBS_HASH, action_hash=ACTION_HASH, obs_size=OBS_SIZE,
                     heads=HEADS, max_period=24, op_budget=OP_BUDGET, manifest_keys=("goal",),
                     decoder_keys=("defer_script", "mask_empty_targets", "mask_mode"),
                     parse_options=parse_options)


def contract(obs_hash=OBS_HASH, action_hash=ACTION_HASH):
    if obs_hash == OBS_HASH and action_hash == ACTION_HASH:
        return GOTA
    return dataclasses.replace(GOTA, obs_hash=obs_hash, action_hash=action_hash)


def check_model(data: bytes, obs_hash=OBS_HASH, action_hash=ACTION_HASH):
    """Validates a GOTANET1 model.bin; returns (hidden, operations)."""
    return tier.check_model(data, contract(obs_hash, action_hash))


def validate(data: bytes, obs_hash=OBS_HASH, action_hash=ACTION_HASH) -> dict:
    """Raises PackageError with the reason; returns the manifest on success."""
    manifest, _ = tier.validate(data, contract(obs_hash, action_hash))
    return manifest


def encode_model(weights, hidden, obs_hash=OBS_HASH, action_hash=ACTION_HASH, inputs=OBS_SIZE, heads=HEADS):
    """GOTANET1 bytes from a flat float32 list: W_enc[H][I], W_rec[3H][H], W_dec[O][H]."""
    return tier.encode_model(weights, hidden, contract(obs_hash, action_hash), inputs, heads)


def build(policy: bytes, model: bytes, period=4, decoder=None, goal=None) -> bytes:
    return tier.build(policy, model, GOTA, period, decoder, {"goal": goal} if goal else None)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("validate")
    v.add_argument("package")
    v.add_argument("--obs-hash", default=OBS_HASH)
    v.add_argument("--action-hash", default=ACTION_HASH)
    b = sub.add_parser("build")
    b.add_argument("out")
    b.add_argument("--policy", required=True)
    b.add_argument("--model", required=True)
    b.add_argument("--period", type=int, default=4)
    b.add_argument("--decoder", choices=["argmax", "sample"])
    b.add_argument("--temperature", type=float)
    b.add_argument("--defer-script", action="store_true",
                   help="decoder.defer_script: verb 0 defers to policy.bas (e.g. base.bas verbatim)")
    b.add_argument("--mask-empty-targets", action="store_true",
                   help="decoder.mask_empty_targets: host applies the gota_action_mask before decode")
    b.add_argument("--mask-mode", choices=["conditional", "static"])
    b.add_argument("--goal-red", type=float, nargs=16)
    b.add_argument("--goal-blue", type=float, nargs=16)
    a = ap.parse_args()
    if a.cmd == "validate":
        data = open(a.package, "rb").read()
        if not is_package(data):
            print("plain BASIC submission (not a package): unchanged")
            return
        try:
            m = validate(data, a.obs_hash, a.action_hash)
        except PackageError as e:
            print(f"REJECTED: {e}")
            sys.exit(1)
        print(f"OK {SCHEMA} hidden={m['model']['hidden']} period={m['decision_period']}")
    else:
        decoder = None
        if a.decoder:
            decoder = {"mode": a.decoder}
            if a.temperature is not None:
                decoder["temperature"] = a.temperature
        if a.defer_script:
            decoder = dict(decoder or {}, defer_script=True)
        if a.mask_empty_targets:
            decoder = dict(decoder or {}, mask_empty_targets=True)
            if a.mask_mode:
                decoder["mask_mode"] = a.mask_mode
        goal = {"red": a.goal_red, "blue": a.goal_blue} if a.goal_red and a.goal_blue else None
        data = build(open(a.policy, "rb").read(), open(a.model, "rb").read(), a.period, decoder, goal)
        open(a.out, "wb").write(data)
        print(f"wrote {a.out} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
