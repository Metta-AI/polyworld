## Clip playback with cross-fades for gltf node trees.
##
## The gltf library plays one clip by writing node transforms directly, so
## switching clips snaps. ClipPlayer keeps the outgoing clip running while
## the new one fades in, sampling both into scratch poses and blending per
## node (lerp for translation and scale, slerp for rotation). It also knows
## which clips loop and which play once: a one-shot holds its last frame,
## then chains into its `next` clip or, without one, fades back to the
## looping clip that was playing before it (walk, attack, back to walk).

import
  std/math,
  vmath, gltf

type
  ClipRule* = object
    loop*: bool
    next*: string   ## one-shots only: clip to chain into; "" = return

  Pose = seq[tuple[pos: Vec3, rot: Quat, scale: Vec3]]

  ClipPlayer* = ref object
    paused*: bool             ## Freeze playback clocks but still pose the tree.
    rate: float32             ## Nonnegative presentation time multiplier.
    root: Node
    nodes: seq[Node]
    rules: seq[ClipRule]        ## per clip index in root.animations
    current: int                ## clip index, -1 for bind pose
    currentTime: float32
    previous: int               ## outgoing clip, -1 for the bind pose
    outgoingFrozen: bool        ## interrupted fades retain their composed pose
    previousTime: float32
    fadeTime, fadeDuration: float32
    lastLoop: int               ## the looping clip one-shots return to
    outgoing: Pose

proc newClipPlayer*(root: Node): ClipPlayer =
  ## Every clip loops until `setRule` says otherwise.
  result = ClipPlayer(root: root, nodes: root.walkNodes, current: -1,
    previous: -1, lastLoop: -1, rate: 1)
  result.rules = newSeq[ClipRule](root.animations.len)
  for rule in result.rules.mitems:
    rule.loop = true
  result.outgoing.setLen(result.nodes.len)

proc clipIndex*(player: ClipPlayer, name: string): int =
  for i, clip in player.root.animations:
    if clip.name == name:
      return i
  -1

proc setRule*(player: ClipPlayer, name: string, rule: ClipRule) =
  let index = player.clipIndex(name)
  doAssert index >= 0, "no clip named " & name
  player.rules[index] = rule

proc current*(player: ClipPlayer): int = player.current
proc currentTime*(player: ClipPlayer): float32 = player.currentTime
proc fading*(player: ClipPlayer): bool = player.fadeTime < player.fadeDuration

proc captureOutgoing(player: ClipPlayer) =
  for i, node in player.nodes:
    player.outgoing[i] = (node.pos, node.rot, node.scale)

proc timeScale*(player: ClipPlayer): float32 = player.rate

proc `timeScale=`*(player: ClipPlayer, value: float32) =
  ## Scales clip and fade clocks together. Zero freezes time; reverse playback
  ## is not supported by the one-shot chaining contract.
  if not (value >= 0 and value < Inf):
    raise newException(ValueError, "animation time scale must be finite and nonnegative")
  player.rate = value

proc applyPose(player: ClipPlayer)

proc play*(player: ClipPlayer, clip: int, fade = 0.2'f32) =
  ## Starts a clip (or the bind pose for -1), fading from whatever is
  ## posed now. Restarting the current clip just rewinds it.
  if not (fade >= 0 and fade < Inf):
    raise newException(ValueError, "animation fade must be finite and nonnegative")
  if clip == player.current:
    player.currentTime = 0
    return
  if fade > 0 and (player.current >= 0 or player.fading):
    player.outgoingFrozen = player.fading
    if player.outgoingFrozen:
      player.applyPose()
      player.captureOutgoing()
    player.previous = player.current
    player.previousTime = player.currentTime
    player.fadeTime = 0
    player.fadeDuration = fade
  else:
    player.fadeTime = 0
    player.fadeDuration = 0
  player.current = clip
  player.currentTime = 0
  if clip >= 0 and player.rules[clip].loop:
    player.lastLoop = clip

proc play*(player: ClipPlayer, name: string, fade = 0.2'f32) =
  player.play(player.clipIndex(name), fade)

proc restart*(player: ClipPlayer) =
  player.currentTime = 0

proc clipTime(player: ClipPlayer, clip: int, time: float32): float32 =
  ## Looping clips wrap inside applyClipAt; one-shots hold their last frame.
  if player.rules[clip].loop:
    time
  else:
    min(time, player.root.animations[clip].duration)

proc applyPose(player: ClipPlayer) =
  let root = player.root
  root.resetToBase()
  if player.fading and not player.outgoingFrozen:
    if player.previous >= 0:
      applyClipAt(
        root.animations[player.previous],
        player.clipTime(player.previous, player.previousTime))
    player.captureOutgoing()
    root.resetToBase()
  if player.current >= 0:
    applyClipAt(
      root.animations[player.current],
      player.clipTime(player.current, player.currentTime))
  if not player.fading:
    return
  let w = clamp(player.fadeTime / player.fadeDuration, 0, 1)
  for i, node in player.nodes:
    let a = player.outgoing[i]
    node.pos = mix(a.pos, node.pos, w)
    node.rot = slerp(a.rot, node.rot, w)
    node.scale = mix(a.scale, node.scale, w)

proc seek*(player: ClipPlayer, time: float32) =
  ## Samples the selected clip immediately, ending any transition. One-shot
  ## seeks clamp at the final pose without chaining; looping seeks wrap.
  if not (time >= 0 and time < Inf):
    raise newException(ValueError, "animation seek time must be finite and nonnegative")
  player.currentTime = if player.current >= 0:
    player.clipTime(player.current, time)
  else: 0
  player.fadeTime = 0
  player.fadeDuration = 0
  player.applyPose()

proc update*(player: ClipPlayer, dt: float32) =
  ## Advances time, chains finished one-shots, and poses the tree.
  if not (dt >= 0 and dt < Inf):
    raise newException(ValueError, "animation delta must be finite and nonnegative")
  let root = player.root
  let elapsed = if player.paused: 0'f32 else: dt * player.rate
  player.currentTime += elapsed
  if player.fading:
    player.previousTime += elapsed
    player.fadeTime += elapsed

  if elapsed > 0 and player.current >= 0 and not player.rules[player.current].loop and
      player.currentTime >= root.animations[player.current].duration:
    let rule = player.rules[player.current]
    if rule.next.len > 0:
      player.play(rule.next)
    elif player.lastLoop >= 0 and player.lastLoop != player.current:
      player.play(player.lastLoop)
  player.applyPose()
