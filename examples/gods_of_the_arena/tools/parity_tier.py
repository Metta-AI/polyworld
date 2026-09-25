"""Byte-identity battery between two builds of libgota_env. Run it on a build host, not a laptop.

  python3 parity_tier.py OLD_LIB NEW_LIB [--seeds 20] [--ticks 28800] [--jobs 16] [--only L0,L1]

For every seed and lineup, both libraries play the same full match. The battery compares every
step's state hash, the recorded replay bytes and the per-seat counters (stats; defer and override
counts). Each (library, seed, lineup) runs in its own process. Lineups:

L0 no neural seats: base / puller / rusher scripts
L1 hosted packages: random w64 and w128 argmax packages, a w64 sampling package, base.bas elsewhere
L2 defer: an always-defer package and a mixed defer/override package (policy.bas = base.bas)
L3 action mask: conditional and static mask packages
L4 trainer seats: two learners on random actions (one with a shadow script), an override seat,
   capture on, and a package seat
L5 always-defer only: two always-defer packages (no override is ever chosen)
"""
import argparse, hashlib, json, os, sys, tempfile
from concurrent.futures import ProcessPoolExecutor
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "../../../coworld/gota/runtime"))
ROOT = os.path.join(HERE, "..")


def read(path, mode="rb"):
    with open(os.path.join(ROOT, path), mode) as f:
        return f.read()


def weights(hidden, seed, scale=0.05, verb0_bias=0.0):
    rng = np.random.default_rng(seed)
    n_enc, n_rec, n_dec = 1407 * hidden, 3 * hidden * hidden, 92 * hidden
    w = (rng.standard_normal(n_enc + n_rec + n_dec) * scale).astype(np.float32)
    w[n_enc + n_rec: n_enc + n_rec + hidden] += verb0_bias
    return w.tolist()


def packages():
    import neural_package as npk
    base, policy = read("players/base.bas"), read("neural/policy.bas")
    m64, m128 = npk.encode_model(weights(64, 1), 64), npk.encode_model(weights(128, 2), 128)
    always = npk.encode_model(weights(64, 0, scale=0.0, verb0_bias=1.0), 64)
    mixed = npk.encode_model(weights(128, 7, scale=0.05, verb0_bias=0.02), 128)
    return {
        "w64": npk.build(policy, m64),
        "w128": npk.build(policy, m128),
        "sample64": npk.build(policy, m64, decoder={"mode": "sample", "temperature": 0.7}),
        "always_defer": npk.build(base, always, decoder={"defer_script": True}),
        "mixed_defer": npk.build(base, mixed, decoder={"defer_script": True}),
        "mask_conditional": npk.build(policy, m64, decoder={"mask_empty_targets": True}),
        "mask_static": npk.build(policy, m128, decoder={"mask_empty_targets": True, "mask_mode": "static"}),
    }


LINEUPS = ("L0", "L1", "L2", "L3", "L4", "L5")


def configure(Env, lib, lineup, seed, ticks, pk):
    puller, rusher = read("players/puller.bas", "r"), read("players/rusher.bas", "r")
    learners = [1, 6] if lineup == "L4" else []
    env = Env(lib, learner_seats=learners, max_ticks=ticks, record=True, capture=lineup == "L4")
    s = seed % 10
    seats = [(s + k) % 10 for k in range(10)]
    if lineup == "L0":
        env.set_script(seats[0], puller); env.set_script(seats[1], rusher); env.set_script(seats[5], puller)
    elif lineup == "L1":
        env.set_package(seats[0], pk["w64"]); env.set_package(seats[3], pk["w128"])
        env.set_package(seats[6], pk["sample64"]); env.set_script(seats[8], rusher)
    elif lineup == "L2":
        env.set_package(seats[0], pk["always_defer"]); env.set_package(seats[5], pk["mixed_defer"])
    elif lineup == "L3":
        env.set_package(seats[0], pk["mask_conditional"]); env.set_package(seats[7], pk["mask_static"])
    elif lineup == "L5":
        env.set_package(seats[0], pk["always_defer"]); env.set_package(seats[5], pk["always_defer"])
    elif lineup == "L4":
        assert env.set_script(2, puller) == 0 and env.set_script(8, rusher) == 0
        assert env.set_override(5, 1) == 0
        env.lib.L.gota_set_seat_shadow(env.h, 6, read("players/base.bas"), len(read("players/base.bas")))
        env.set_package(3, pk["w64"])
    for seat in range(10):
        code, message = env.status(seat)
        assert code in (0, 1), f"{lineup} seat {seat}: status {code} {message}"
    return env


def job(args):
    lib_path, lineup, seed, ticks = args
    from native_env import Env, Lib, random_actions
    lib = Lib(lib_path)
    env = configure(Env, lib, lineup, seed, ticks, packages())
    env.reset(seed)
    rng = np.random.default_rng(seed)
    hashes = hashlib.sha256()
    steps = 0
    while True:
        actions = np.zeros((10, 5), np.int32)
        if lineup == "L4":
            env.observe()
            actions = random_actions(rng)
        r = env.step(actions)
        hashes.update(int(env.state_hash()).to_bytes(8, "little"))
        steps += 1
        if r == 1:
            break
    fd, path = tempfile.mkstemp(suffix=".replay"); os.close(fd)
    env.save_replay(path)
    replay = open(path, "rb").read(); os.unlink(path)
    stats = [env.stats(s).tolist() for s in range(10)]
    defer = [env.defer_stats(s).tolist() for s in range(10)] if hasattr(lib.L, "gota_seat_defer_stats") else []
    final = int(env.state_hash())
    env.close()
    return dict(lib=lib_path, lineup=lineup, seed=seed, steps=steps, final=f"{final:016x}",
                hashes=hashes.hexdigest(), replay=hashlib.sha256(replay).hexdigest(), replay_bytes=len(replay),
                stats=hashlib.sha256(json.dumps(stats).encode()).hexdigest(), defer=defer)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("old")
    ap.add_argument("new")
    ap.add_argument("--seeds", type=int, default=20)
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--ticks", type=int, default=28800)
    ap.add_argument("--jobs", type=int, default=16)
    ap.add_argument("--only", default=",".join(LINEUPS))
    ap.add_argument("--json", default="")
    a = ap.parse_args()
    lineups = [x for x in a.only.split(",") if x]
    seeds = range(a.first_seed, a.first_seed + a.seeds)
    work = [(lib, ln, s, a.ticks) for ln in lineups for s in seeds for lib in (a.old, a.new)]
    with ProcessPoolExecutor(a.jobs) as ex:
        results = list(ex.map(job, work))
    by = {(r["lineup"], r["seed"], r["lib"]): r for r in results}
    rows, same_all = [], True
    for ln in lineups:
        same_n = 0
        for s in seeds:
            o, n = by[(ln, s, a.old)], by[(ln, s, a.new)]
            same = all(o[k] == n[k] for k in ("steps", "final", "hashes", "replay", "stats", "defer"))
            same_n += same
            diff = [k for k in ("steps", "final", "hashes", "replay", "stats", "defer") if o[k] != n[k]]
            print(f"{ln} seed {s:3d} steps {n['steps']:5d} final {n['final']} replay {n['replay'][:12]} "
                  f"{'IDENTICAL' if same else 'DIFFERENT ' + ','.join(diff)} defer={n['defer'] and [d for d in n['defer'] if d != [0, 0]]}")
        rows.append((ln, same_n, len(seeds)))
        same_all &= same_n == len(seeds)
    print("\nlineup  identical")
    for ln, k, n in rows:
        print(f"{ln}      {k}/{n}")
    if a.json:
        json.dump(results, open(a.json, "w"), indent=1)
    print("ALL IDENTICAL" if same_all else "DIFFERENCES FOUND")
    sys.exit(0 if same_all else 1)


if __name__ == "__main__":
    main()
