include ../coworld/fast_xp/metrics

doAssert sizeof(MetricsState) < 20 * 1024 * 1024

let empty = snapshot(60)
doAssert empty["single_request"]["median_ms"].kind == JNull
doAssert empty["recent_games"].len == 0
setCapacity(6)
doAssert snapshot(60)["request_limit"].getInt == 512
setCapacity(6, 32)
doAssert snapshot(60)["request_limit"].getInt == 32
admissionChanged(1)
schedulerChanged(2, 8, getMonoTime())
requestCompleted(200, 1, 1000, 10, 2, 100)
requestCompleted(200, 10, 2000, 10, 2, 1000)
requestCompleted(429, 0, 1, 0, 0, 0)
cacheLookup(true)
cacheLookup(false)
for i in 0 ..< 110:
  gameCompleted("test", i, i, 28800, 200, 10, 100, 500)
gameCompleted("failed", 0, 202, 28800, 422, -1, 20, 5)
gameCompleted("timeout", 0, 999, 28800, 504, -1, 30, 120000)
gameCompleted("cancelled", 0, 700, 28800, 503, -1, 40, 0)
let full = snapshot(60)
doAssert full["running"].getInt == 2 and full["queued"].getInt == 8
doAssert full["admitted_requests"].getInt == 1
doAssert full["successful_games"].getInt == 110
doAssert full["failed_games"].getInt == 3
doAssert full["timeouts"].getInt == 1
doAssert full["rejected_requests"].getInt == 1
doAssert full["single_request"]["count"].getInt == 1
doAssert full["batch_request"]["count"].getInt == 1
doAssert full["queue"]["count"].getInt == 110
doAssert full["cache_hits"].getInt == full["cache_misses"].getInt
let median = full["single_request"]["median_ms"].getFloat
doAssert median >= 1000 and median < 1250
doAssert full["recent_games"].len == 100
doAssert full["recent_games"][0]["request_id"].getStr == "cancelled"
let expired = snapshotAt(1440, 86460)
doAssert expired["successful_games"].getInt == 0
doAssert expired["recent_games"].len == 0
for i in 0 ..< 20000:
  state.samples[i mod state.samples.len] = Sample(elapsed: i * 5, timestamp: epoch + i * 5,
    cpu: -1, memory: -1, temporaryFree: -1, cacheFree: -1)
  inc state.sampleCount
let bounded = snapshotAt(1440, 99995)
doAssert bounded["samples"].len <= 1441
doAssert bounded["samples"][0]["cpu_percent"].kind == JNull
doAssert bounded["samples"][0]["service_memory_bytes"].kind == JNull

state = default(MetricsState)
for i in 0 ..< 95:
  gameCompleted("awm-fast", i, i, 28800, 200, 5, 20, 50, "awm", 5)
for i in 0 ..< 5:
  gameCompleted("paintbot", i, i, 14400, 200, 16, 100, 5000, "paintbot-pw", 16)
gameCompleted("paintbot-timeout", 0, 10, 14400, 504, -1, 200, 120000, "paintbot-pw", 16)
gameCompleted("gota", 0, 1, 28800, 200, 10, 30, 500)
var later = Bucket(minute: 7, games: 10)
later.byGame[1].games = 10
for i in 0 ..< 10:
  later.worker.observe(50000)
  later.queue.observe(1000)
  later.byGame[1].worker.observe(50000)
  later.byGame[1].queue.observe(1000)
state.buckets[7] = later
schedulerChanged(3, 4, getMonoTime(), [1, 2, 0], [0, 1, 3])
var total, idle: int64
sampleHost(total, idle)
let grouped = snapshotAt(1440, 8 * 60)
doAssert grouped["bucket_minutes"].getInt == 15
doAssert grouped["timeline"].len == 1
doAssert grouped["timeline"][0]["games"].getInt == 111
doAssert grouped["timeline"][0]["failed_games"].getInt == 1
doAssert grouped["by_game"][2]["successful_games"].getInt == 95
doAssert grouped["by_game"][1]["successful_games"].getInt == 15
doAssert grouped["by_game"][1]["failed_games"].getInt == 1
doAssert grouped["by_game"][1]["timeouts"].getInt == 1
doAssert grouped["by_game"][1]["worker"]["count"].getInt == 15
let paintbotMedian = grouped["by_game"][1]["worker"]["median_ms"].getFloat
let awmP95 = grouped["by_game"][2]["worker"]["p95_ms"].getFloat
doAssert paintbotMedian >= 50000 and paintbotMedian < 62500
doAssert awmP95 >= 50 and awmP95 < 62.5
doAssert grouped["timeline"][0]["by_game"][1]["worker"] == grouped["by_game"][1]["worker"]
doAssert grouped["samples"][0]["by_game"][1]["running"].getInt == 2
doAssert grouped["samples"][0]["by_game"][2]["queued"].getInt == 3
let short = snapshotAt(10, 12 * 60)
doAssert short["bucket_minutes"].getInt == 1
doAssert short["timeline"].len == 1 and short["timeline"][0]["games"].getInt == 10
doAssert short["by_game"][2]["successful_games"].getInt == 0
doAssert short["recent_games"].len == 0
doAssert snapshotAt(1440, 90000)["by_game"][1]["successful_games"].getInt == 0
