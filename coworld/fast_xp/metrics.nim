import
  std/[algorithm, json, locks, math, monotimes, os, posix, strutils, times]

type
  Histogram = array[96, uint64]
  GameBucket = object
    queue, worker: Histogram
    games, failedGames, timeouts: uint64
  Bucket = object
    minute: int64
    singles, batches, queue, worker, preparation, zip: Histogram
    games, failedGames, timeouts, requests, failedRequests, rejected, hits, misses, bytes: uint64
    byGame: array[3, GameBucket]
  RecentGame = object
    id: array[64, char]
    name: array[32, char]
    seats: int
    index, seed, ticks, status, active: int
    timestamp, queueMs, workerMs: int64
  Sample = object
    elapsed, timestamp: int64
    cpu: float
    memory, temporaryFree, cacheFree: int64
    running, queued, admitted: int
    runningByGame, queuedByGame: array[3, int]
  MetricsState = object
    buckets: array[1440, Bucket]
    samples: array[17280, Sample]
    recent: array[100, RecentGame]
    sampleCount, recentCount: int
    running, queued, admitted, capacity, requestLimit: int
    runningByGame, queuedByGame: array[3, int]
    oldest: int64
    instanceType: array[64, char]

const GameNames = ["gota", "paintbot-pw", "awm"]

var
  metricsLock: Lock
  state: MetricsState
let
  started = getMonoTime()
  epoch = getTime().toUnix()
initLock(metricsLock)

proc elapsedSeconds(): int64 =
  (getMonoTime() - started).inSeconds

proc currentBucket(): ptr Bucket =
  let minute = elapsedSeconds() div 60
  result = addr state.buckets[minute mod 1440]
  if result[].minute != minute:
    result[] = Bucket(minute: minute)

proc observe(hist: var Histogram, ms: int64) =
  let index = if ms <= 0: 0 else: min(95, 1 + int(ceil(ln(float(ms)) / ln(1.25))))
  inc hist[index]

proc histogramJson(hist: Histogram): JsonNode =
  var count: uint64
  for n in hist: count += n
  result = %*{"count": count, "median_ms": newJNull(), "p95_ms": newJNull()}
  if count == 0: return
  for item in [("median_ms", 0.5), ("p95_ms", 0.95)]:
    var accumulated: uint64
    for i, n in hist:
      accumulated += n
      if float(accumulated) >= ceil(float(count) * item[1]):
        result[item[0]] = %(if i == 0: 0.0 else: pow(1.25, float(i - 1)))
        break

proc setCapacity*(capacity: int, requestLimit = 512) =
  var instanceType: array[64, char]
  try:
    if readFile("/sys/devices/virtual/dmi/id/sys_vendor").strip() == "Amazon EC2":
      let name = readFile("/sys/devices/virtual/dmi/id/product_name").strip()
      for i in 0 ..< min(name.len, instanceType.len): instanceType[i] = name[i]
  except CatchableError: discard
  withLock metricsLock:
    state.capacity = capacity
    state.requestLimit = requestLimit
    state.instanceType = instanceType

proc admissionChanged*(delta: int) =
  withLock metricsLock: state.admitted += delta

proc schedulerChanged*(running, queued: int, oldest: MonoTime,
    runningByGame: array[3, int] = default(array[3, int]),
    queuedByGame: array[3, int] = default(array[3, int])) =
  withLock metricsLock:
    state.running = running
    state.queued = queued
    state.runningByGame = runningByGame
    state.queuedByGame = queuedByGame
    state.oldest = if queued == 0: 0 else: oldest.ticks

proc cacheLookup*(hit: bool) =
  withLock metricsLock:
    let bucket = currentBucket()
    if hit: inc bucket.hits
    else: inc bucket.misses

proc requestCompleted*(status, episodes: int, totalMs, preparationMs, zipMs, bytes: int64) =
  withLock metricsLock:
    let bucket = currentBucket()
    inc bucket.requests
    if status != 200: inc bucket.failedRequests
    if status == 429: inc bucket.rejected
    if status == 200:
      if episodes == 1: bucket.singles.observe(totalMs)
      else: bucket.batches.observe(totalMs)
      bucket.preparation.observe(preparationMs)
      bucket.zip.observe(zipMs)
      bucket.bytes += uint64(bytes)

proc gameCompleted*(id: string, index, seed, ticks, status, active: int, queueMs, workerMs: int64,
    name = "gota", seats = 10) =
  var record = RecentGame(index: index, seed: seed, ticks: ticks, status: status,
    active: active, seats: seats, timestamp: epoch + elapsedSeconds(), queueMs: queueMs, workerMs: workerMs)
  for i in 0 ..< min(id.len, record.id.len): record.id[i] = id[i]
  for i in 0 ..< min(name.len, record.name.len): record.name[i] = name[i]
  withLock metricsLock:
    let bucket = currentBucket()
    let gameIndex = GameNames.find(name)
    doAssert gameIndex >= 0
    let game = addr bucket.byGame[gameIndex]
    if status == 200:
      inc bucket.games
      bucket.queue.observe(queueMs)
      bucket.worker.observe(workerMs)
      inc game.games
      game.queue.observe(queueMs)
      game.worker.observe(workerMs)
    else:
      inc bucket.failedGames
      inc game.failedGames
      if status == 504:
        inc bucket.timeouts
        inc game.timeouts
    state.recent[state.recentCount mod 100] = record
    inc state.recentCount

proc freeBytes(path: string): int64 =
  var info: Statvfs
  if statvfs(path.cstring, info) == 0:
    return int64(info.f_bavail) * int64(info.f_frsize)
  -1

proc serviceMemory(): int64 =
  try:
    for line in readFile("/proc/self/cgroup").splitLines():
      if line.startsWith("0::"):
        # The root cgroup can describe the entire host, not this service.
        let relative = line[3 .. ^1].strip(chars = {'/'})
        if relative.len > 0 and ".." notin relative.split('/'):
          return parseBiggestInt(readFile("/sys/fs/cgroup" / relative / "memory.current").strip())
  except CatchableError: discard
  -1

proc sampleHost*(previousTotal, previousIdle: var int64) =
  var sample = Sample(elapsed: elapsedSeconds(), timestamp: epoch + elapsedSeconds(),
    cpu: -1, memory: serviceMemory(), temporaryFree: freeBytes(getTempDir()),
    cacheFree: freeBytes(getEnv("FAST_XP_CACHE_DIR", getCacheDir() / "polyworld-fast-xp" / "policies")))
  try:
    let fields = readFile("/proc/stat").splitLines()[0].splitWhitespace()
    var total: int64
    for i in 1 .. 8: total += parseBiggestInt(fields[i])
    let idle = parseBiggestInt(fields[4]) + parseBiggestInt(fields[5])
    if previousTotal > 0 and total > previousTotal:
      sample.cpu = clamp(100.0 * (1.0 - float(idle - previousIdle) / float(total - previousTotal)), 0.0, 100.0)
    previousTotal = total
    previousIdle = idle
  except CatchableError: discard
  withLock metricsLock:
    sample.running = state.running
    sample.queued = state.queued
    sample.admitted = state.admitted
    sample.runningByGame = state.runningByGame
    sample.queuedByGame = state.queuedByGame
    state.samples[state.sampleCount mod state.samples.len] = sample
    inc state.sampleCount

proc nullable(value: int64): JsonNode =
  if value < 0: newJNull() else: %value

proc add(target: var Bucket, source: Bucket) =
  for i in 0 ..< 96:
    target.singles[i] += source.singles[i]
    target.batches[i] += source.batches[i]
    target.queue[i] += source.queue[i]
    target.worker[i] += source.worker[i]
    target.preparation[i] += source.preparation[i]
    target.zip[i] += source.zip[i]
    for game in 0 ..< GameNames.len:
      target.byGame[game].queue[i] += source.byGame[game].queue[i]
      target.byGame[game].worker[i] += source.byGame[game].worker[i]
  target.games += source.games
  target.failedGames += source.failedGames
  target.timeouts += source.timeouts
  target.requests += source.requests
  target.failedRequests += source.failedRequests
  target.rejected += source.rejected
  target.hits += source.hits
  target.misses += source.misses
  target.bytes += source.bytes
  for game in 0 ..< GameNames.len:
    target.byGame[game].games += source.byGame[game].games
    target.byGame[game].failedGames += source.byGame[game].failedGames
    target.byGame[game].timeouts += source.byGame[game].timeouts

proc gameJson(games: array[3, GameBucket]): JsonNode =
  result = newJArray()
  for index, game in games:
    result.add %*{"game": GameNames[index], "successful_games": game.games,
      "failed_games": game.failedGames, "timeouts": game.timeouts,
      "queue": histogramJson(game.queue), "worker": histogramJson(game.worker)}

proc timelineJson(bucket: Bucket): JsonNode =
  %*{"timestamp": epoch + bucket.minute * 60,
    "games": bucket.games, "failed_games": bucket.failedGames,
    "queue": histogramJson(bucket.queue), "worker": histogramJson(bucket.worker),
    "by_game": gameJson(bucket.byGame)}

proc snapshotAt(windowMinutes: int, now: int64): JsonNode =
  let minutes = clamp(windowMinutes, 1, 1440)
  var
    buckets: seq[Bucket]
    samples: seq[Sample]
    recent: seq[RecentGame]
    running, queued, admitted, capacity, requestLimit: int
    oldest: int64
    instanceType: array[64, char]
  withLock metricsLock:
    running = state.running
    queued = state.queued
    admitted = state.admitted
    capacity = state.capacity
    requestLimit = state.requestLimit
    oldest = state.oldest
    instanceType = state.instanceType
    for bucket in state.buckets:
      if bucket.minute >= max(0'i64, now div 60 - minutes + 1) and
          bucket.minute <= now div 60 and bucket.games + bucket.failedGames + bucket.requests > 0:
        buckets.add bucket
    for i in max(0, state.sampleCount - state.samples.len) ..< state.sampleCount:
      let sample = state.samples[i mod state.samples.len]
      if sample.elapsed >= now - int64(minutes * 60): samples.add sample
    for i in countdown(state.recentCount - 1, max(0, state.recentCount - 100)):
      if state.recent[i mod 100].timestamp >= epoch + now - int64(minutes * 60):
        recent.add state.recent[i mod 100]
  var aggregate: Bucket
  var timeline = newJArray()
  let interval = if minutes == 1440: 15 else: 1
  buckets.sort(proc(a, b: Bucket): int = cmp(a.minute, b.minute))
  var group: Bucket
  var hasGroup = false
  for bucket in buckets:
    aggregate.add(bucket)
    let minute = bucket.minute div interval * interval
    if hasGroup and minute != group.minute:
      timeline.add timelineJson(group)
      hasGroup = false
    if not hasGroup:
      group = Bucket(minute: minute)
      hasGroup = true
    group.add(bucket)
  if hasGroup: timeline.add timelineJson(group)
  var instanceName = ""
  for ch in instanceType:
    if ch == '\0': break
    instanceName.add ch
  result = %*{"instance_type": (if instanceName.len == 0: newJNull() else: %instanceName),
    "timestamp": epoch + now, "uptime_seconds": now, "window_minutes": minutes,
    "bucket_minutes": interval, "by_game": gameJson(aggregate.byGame),
    "running": running, "queued": queued, "admitted_requests": admitted,
    "worker_limit": capacity, "request_limit": requestLimit,
    "oldest_queue_ms": (if queued == 0: 0'i64 else: max(0'i64, (getMonoTime().ticks - oldest) div 1_000_000)),
    "successful_games": aggregate.games, "failed_games": aggregate.failedGames,
    "timeouts": aggregate.timeouts, "requests": aggregate.requests,
    "failed_requests": aggregate.failedRequests, "rejected_requests": aggregate.rejected,
    "games_per_minute": float(aggregate.games) / max(1.0 / 60, float(min(now + 1, int64(minutes * 60))) / 60),
    "cache_hits": aggregate.hits, "cache_misses": aggregate.misses, "response_bytes": aggregate.bytes,
    "single_request": histogramJson(aggregate.singles), "batch_request": histogramJson(aggregate.batches),
    "queue": histogramJson(aggregate.queue), "worker": histogramJson(aggregate.worker),
    "preparation": histogramJson(aggregate.preparation), "zip": histogramJson(aggregate.zip),
    "timeline": timeline, "samples": [], "recent_games": []}
  let stride = max(1, (samples.len + 1439) div 1440)
  for i, sample in samples:
    if i mod stride != 0 and i != samples.high: continue
    result["samples"].add %*{"timestamp": sample.timestamp,
      "cpu_percent": (if sample.cpu < 0: newJNull() else: %sample.cpu),
      "service_memory_bytes": nullable(sample.memory),
      "temporary_free_bytes": nullable(sample.temporaryFree), "cache_free_bytes": nullable(sample.cacheFree),
      "running": sample.running, "queued": sample.queued, "admitted_requests": sample.admitted}
    result["samples"][^1]["by_game"] = newJArray()
    for game in 0 ..< GameNames.len:
      result["samples"][^1]["by_game"].add %*{"game": GameNames[game],
        "running": sample.runningByGame[game], "queued": sample.queuedByGame[game]}
  for game in recent:
    var id = ""
    var name = ""
    for ch in game.name:
      if ch == '\0': break
      name.add ch
    for ch in game.id:
      if ch == '\0': break
      id.add ch
    result["recent_games"].add %*{"request_id": id, "index": game.index, "seed": game.seed,
      "game": name, "seats": game.seats,
      "max_ticks": game.ticks, "status": game.status, "active_bots": game.active,
      "timestamp": game.timestamp, "queue_ms": game.queueMs, "worker_ms": game.workerMs}

proc snapshot*(windowMinutes: int): JsonNode =
  snapshotAt(windowMinutes, elapsedSeconds())
