## LvD's visual clock, deliberately separate from authoritative simulation.
## Tick scheduling, delay simulation and diagnostics remain in polyworld/networks.
import polyworld/networks

type NetworkPresentation* = object
  elapsedSeconds: float64
  hasTick: bool

proc startFrame*(presentation: var NetworkPresentation, dt: float64) =
  ## Advance presentation only; receiving no packet never advances simulation.
  presentation.elapsedSeconds += max(dt, 0.0)

proc appliedTick*(presentation: var NetworkPresentation) =
  ## Restart interpolation only after an authoritative packet was applied.
  presentation.elapsedSeconds = 0
  presentation.hasTick = true

proc frameAlpha*(presentation: NetworkPresentation, playback: TickPlayback,
    stats: NetworkStats, now: float64, tickRate: int): float32 =
  ## Interpolate the last two received poses; never extrapolate a future tick.
  if not presentation.hasTick:
    return 0
  let elapsed =
    if stats != nil and stats.smoothPlayback and playback.started:
      playback.elapsed(now, tickRate)
    else:
      presentation.elapsedSeconds
  clamp(elapsed * tickRate.float64, 0.0, 1.0).float32
