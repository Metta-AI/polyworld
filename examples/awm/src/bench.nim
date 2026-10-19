## Frame timing for before/after comparisons. Built with -d:awmBench it
## times spans of each frame and, after AWM_BENCH_WARMUP frames (120),
## collects AWM_BENCH_FRAMES more (600) and prints one summary line per span:
## mean, median, 95th percentile and maximum, in milliseconds. With
## AWM_BENCH_GPU=1 it also waits for the GPU at the end of each frame and
## times that wait. Without the define every hook compiles to nothing.
##
## Run it in a -d:takeScreenshot build: its window is hidden and not paced by
## vsync, and its demo scenes are fixed.

type
  BenchSpan* = enum
    CardsBuild  ## Building the table's card vertices.
    CardsDraw   ## Submitting them.
    Ui          ## The HUD, from beginUi to endUi.
    CpuFrame    ## The whole frame on the CPU, before the swap.
    GpuWait     ## glFinish at the end of the frame (AWM_BENCH_GPU=1).

when defined(awmBench):
  import std/[algorithm, monotimes, os, strformat, strutils, times]
  import opengl

  let processStart = getMonoTime()

  var
    samples: array[BenchSpan, seq[float]]
    current: array[BenchSpan, float]
    started: array[BenchSpan, MonoTime]
    frameStart: MonoTime
    frames = 0
    reported = false
    lastCardQuads = 0
    lastUiQuads = 0

  let
    warmup = parseInt(getEnv("AWM_BENCH_WARMUP", "120"))
    count = parseInt(getEnv("AWM_BENCH_FRAMES", "600"))
    timeGpu = getEnv("AWM_BENCH_GPU") == "1"

  proc millis(since: MonoTime): float =
    (getMonoTime() - since).inNanoseconds.float / 1e6

  proc benchStart*(span: BenchSpan) =
    started[span] = getMonoTime()

  proc benchStop*(span: BenchSpan) =
    current[span] += millis(started[span])

  proc benchBeginFrame*() =
    if frames == 0:
      echo &"BENCH startup ms={millis(processStart):.1f}"
    frameStart = getMonoTime()
    for span in BenchSpan:
      current[span] = 0

  proc benchQuads*(cards, ui: int) =
    ## How many card and HUD quads the frame drew, for the summary.
    lastCardQuads = cards
    lastUiQuads = ui

  proc summary(values: seq[float]): string =
    if values.len == 0:
      return "n/a"
    let sorted = values.sorted()
    var total = 0.0
    for value in values:
      total += value
    &"mean={total / values.len.float:.3f} p50={sorted[sorted.len div 2]:.3f} " &
      &"p95={sorted[min(sorted.high, sorted.len * 95 div 100)]:.3f} " &
      &"max={sorted[^1]:.3f}"

  proc benchEndFrame*(scene: string) =
    ## Call just before swapping buffers.
    current[CpuFrame] = millis(frameStart)
    if timeGpu:
      let wait = getMonoTime()
      glFinish()
      current[GpuWait] = millis(wait)
    inc frames
    if frames > warmup and frames <= warmup + count:
      for span in BenchSpan:
        if span != GpuWait or timeGpu:
          samples[span].add current[span]
    if frames == warmup + count and not reported:
      reported = true
      echo &"BENCH scene={scene} frames={count} warmup={warmup}"
      for span in BenchSpan:
        if span != GpuWait or timeGpu:
          echo &"BENCH {span} {summary(samples[span])}"
      echo &"BENCH quads cards={lastCardQuads} ui={lastUiQuads}"
      if getEnv("AWM_BENCH_QUIT", "1") == "1":
        quit(0)
else:
  template benchStart*(span: BenchSpan) = discard
  template benchStop*(span: BenchSpan) = discard
  template benchBeginFrame*() = discard
  template benchQuads*(cards, ui: int) = discard
  template benchEndFrame*(scene: string) = discard
