## Archers Warriors Mages — Polyworld native and browser client.
import awmsim
export awmsim

when not defined(headless):
  import std/[math, options, os, random, strformat, tables, times]
  when defined(takeScreenshot):
    import std/strutils

when not defined(headless):
  import
    chroma, opengl, pixie, shady, silky, vmath, windy,
    cardfaces, cardrenderer, vfxrenderer, awmsessions, awmweb, awmbots,
    polyworld/[assets, characters, chrome, common, viewers]

  const
    WindowTitle = "AWM — Archers Warriors Mages"
    BoardWidth = 18.0'f32
    BoardDepth = 11.0'f32
    CardWidth = 1.45'f32
    CardDepth = 2.05'f32
    CardHeight = 0.12'f32
    CardPlaneY = 0.18'f32
    CardMoveDuration = 0.46'f32
    DrawMoveDuration = 0.72'f32
    AttackLungeDuration = 0.22'f32
    AttackReturnDuration = 0.30'f32
    GameCameraHeight = 14.0'f32
    GameCameraDistance = 17.0'f32
    HandCenterY = 0.60'f32
    ActiveHandDistance = 5.75'f32
    OpponentHandDistance = 4.35'f32
    HandFanAngle = 0.24'f32
    PlayerPanelWidth = 500.0'f32
    PlayerPanelHeight = 170.0'f32
    ShaderTarget =
      when defined(emscripten):
        glsl3WebGL
      else:
        glsl4Desktop

    CharacterPaths: array[HeroClass, string] = [
      DataRoot & "/characters/mini_legion/human/archer.glb",
      DataRoot & "/characters/mini_legion/human/footman.glb",
      DataRoot & "/characters/mini_legion/human/mage.glb"
    ]

  type
    AppPhase = enum
      ChooseClasses
      PlayGame

    UiRect = object
      origin: Vec2
      size: Vec2

    CardPose = object
      position: Vec3
      yaw: float32
      pitch: float32

    CardAnimation = object
      card: Card
      heroClass: HeroClass
      fromPose: CardPose
      toPose: CardPose
      elapsed: float32
      duration: float32
      arcHeight: float32
      suppressBoardId: int
      suppressHandOwner: int
      suppressHandIndex: int
      suppressDiscardOwner: int
      hidden: bool
      trackingTarget: Choice

    DyingMinion = object
      ## A slain minion held where it died until the effects aimed at it end.
      ## It keeps its board slot, so neighbours don't shift until it leaves.
      target: Choice
      card: Card
      power: int  ## Live power when it died.
      heroClass: HeroClass
      boardIndex: int  ## Live board index just before it was removed.
      atLunge: bool  ## Slain while attacking: held at `lungePoint`.
      held: bool  ## Its death's beat hasn't played yet: it stays put.
      bouncing: bool
        ## Not slain: a bounced card holding its slot until its beat, when it
        ## flies to hand instead of the discard pile.
      lungePoint: Vec3

    SolidRenderer = object
      program: GLuint
      vertexArray: GLuint
      vertexBuffer: GLuint
      vertices: seq[float32]

  var
    solidViewProjection: Uniform[Mat4]
    solidLightDirection: Uniform[Vec3]

  proc solidVertex(
      gl_Position: var Vec4,
      fragmentNormal: var Vec3,
      fragmentColor: var Vec4,
      position: Vec3,
      normal: Vec3,
      color: Vec4
  ) =
    gl_Position = solidViewProjection * vec4(position, 1)
    fragmentNormal = normal
    fragmentColor = color

  proc solidFragment(
      outputColor: var Vec4,
      fragmentNormal: Vec3,
      fragmentColor: Vec4
  ) =
    let light =
      0.55'f32 +
      0.45'f32 * max(
        dot(normalize(fragmentNormal), normalize(solidLightDirection)),
        0.0'f32
      )
    outputColor = vec4(fragmentColor.xyz * light, fragmentColor.w)

  proc compileStage(
      kind: GLenum,
      source,
      label: string
  ): GLuint =
    result = glCreateShader(kind)
    let sources = allocCStringArray([source])
    defer:
      deallocCStringArray(sources)
    glShaderSource(result, 1, sources, nil)
    glCompileShader(result)
    var status: GLint
    glGetShaderiv(result, GL_COMPILE_STATUS, status.addr)
    if status == 0:
      var length: GLint
      glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
      var log = newString(length)
      glGetShaderInfoLog(result, length, nil, log.cstring)
      raise newException(
        CatchableError,
        label & " shader failed:\n" & log & "\n" & source
      )

  proc compileSolidProgram(): GLuint =
    let
      vertexShader = compileStage(
        GL_VERTEX_SHADER,
        toShader(solidVertex, ShaderTarget, shaderVertex),
        "AWM solid vertex"
      )
      fragmentShader = compileStage(
        GL_FRAGMENT_SHADER,
        toShader(solidFragment, ShaderTarget, shaderFragment),
        "AWM solid fragment"
      )
    result = glCreateProgram()
    glAttachShader(result, vertexShader)
    glAttachShader(result, fragmentShader)
    glLinkProgram(result)
    glDeleteShader(vertexShader)
    glDeleteShader(fragmentShader)
    var status: GLint
    glGetProgramiv(result, GL_LINK_STATUS, status.addr)
    if status == 0:
      var length: GLint
      glGetProgramiv(result, GL_INFO_LOG_LENGTH, length.addr)
      var log = newString(length)
      glGetProgramInfoLog(result, length, nil, log.cstring)
      raise newException(
        CatchableError,
        "AWM solid program failed:\n" & log
      )

  proc initSolidRenderer(): SolidRenderer =
    result.program = compileSolidProgram()
    glGenVertexArrays(1, result.vertexArray.addr)
    glBindVertexArray(result.vertexArray)
    glGenBuffers(1, result.vertexBuffer.addr)
    glBindBuffer(GL_ARRAY_BUFFER, result.vertexBuffer)
    const stride = (10 * sizeof(float32)).GLsizei
    for attribute in [
      (name: "position", count: 3, offset: 0),
      (name: "normal", count: 3, offset: 3 * sizeof(float32)),
      (name: "color", count: 4, offset: 6 * sizeof(float32))
    ]:
      let location = glGetAttribLocation(
        result.program,
        attribute.name.cstring
      )
      doAssert location >= 0
      glEnableVertexAttribArray(location.GLuint)
      glVertexAttribPointer(
        location.GLuint,
        attribute.count.GLint,
        cGL_FLOAT,
        GL_FALSE,
        stride,
        cast[pointer](attribute.offset)
      )
    glBindVertexArray(0)

  proc clear(renderer: var SolidRenderer) =
    renderer.vertices.setLen(0)

  proc addVertex(
      renderer: var SolidRenderer,
      position,
      normal: Vec3,
      color: Vec4
  ) =
    renderer.vertices.add position.x
    renderer.vertices.add position.y
    renderer.vertices.add position.z
    renderer.vertices.add normal.x
    renderer.vertices.add normal.y
    renderer.vertices.add normal.z
    renderer.vertices.add color.x
    renderer.vertices.add color.y
    renderer.vertices.add color.z
    renderer.vertices.add color.w

  proc addQuad(
      renderer: var SolidRenderer,
      a,
      b,
      c,
      d,
      normal: Vec3,
      color: Vec4
  ) =
    renderer.addVertex(a, normal, color)
    renderer.addVertex(b, normal, color)
    renderer.addVertex(c, normal, color)
    renderer.addVertex(a, normal, color)
    renderer.addVertex(c, normal, color)
    renderer.addVertex(d, normal, color)

  proc rotateAroundY(value: Vec3, angle: float32): Vec3 =
    let
      cosine = cos(angle)
      sine = sin(angle)
    vec3(
      value.x * cosine - value.z * sine,
      value.y,
      value.x * sine + value.z * cosine
    )

  proc rotateAroundX(value: Vec3, angle: float32): Vec3 =
    let
      cosine = cos(angle)
      sine = sin(angle)
    vec3(
      value.x,
      value.y * cosine - value.z * sine,
      value.y * sine + value.z * cosine
    )

  proc transformCardVector(
      pose: CardPose,
      value: Vec3
  ): Vec3 =
    rotateAroundX(rotateAroundY(value, pose.yaw), pose.pitch)

  proc inverseCardVector(
      pose: CardPose,
      value: Vec3
  ): Vec3 =
    rotateAroundY(rotateAroundX(value, -pose.pitch), -pose.yaw)

  proc cardNormal(pose: CardPose): Vec3 =
    pose.transformCardVector(vec3(0, 1, 0))

  proc darker(color: Vec4, factor: float32): Vec4 =
    vec4(
      color.x * factor,
      color.y * factor,
      color.z * factor,
      color.w
    )

  proc addBox(
      renderer: var SolidRenderer,
      center,
      size: Vec3,
      topColor: Vec4,
      yaw = 0.0'f32,
      sideFactor = 0.62'f32,
      pitch = 0.0'f32
  ) =
    let
      h = size * 0.5'f32
      localCorners = [
        vec3(-h.x, -h.y, -h.z),
        vec3(h.x, -h.y, -h.z),
        vec3(h.x, -h.y, h.z),
        vec3(-h.x, -h.y, h.z),
        vec3(-h.x, h.y, -h.z),
        vec3(h.x, h.y, -h.z),
        vec3(h.x, h.y, h.z),
        vec3(-h.x, h.y, h.z)
      ]
    let pose = CardPose(yaw: yaw, pitch: pitch)
    var corners: array[8, Vec3]
    for i, corner in localCorners:
      corners[i] = center + pose.transformCardVector(corner)
    let
      sideColor = topColor.darker(sideFactor)
      bottomColor = topColor.darker(sideFactor * 0.72'f32)
      up = pose.transformCardVector(vec3(0, 1, 0))
      down = pose.transformCardVector(vec3(0, -1, 0))
      north = pose.transformCardVector(vec3(0, 0, -1))
      south = pose.transformCardVector(vec3(0, 0, 1))
      west = pose.transformCardVector(vec3(-1, 0, 0))
      east = pose.transformCardVector(vec3(1, 0, 0))
    renderer.addQuad(
      corners[4], corners[7], corners[6], corners[5], up, topColor)
    renderer.addQuad(
      corners[0], corners[1], corners[2], corners[3], down, bottomColor)
    renderer.addQuad(
      corners[0], corners[4], corners[5], corners[1], north, sideColor)
    renderer.addQuad(
      corners[3], corners[2], corners[6], corners[7], south, sideColor)
    renderer.addQuad(
      corners[0], corners[3], corners[7], corners[4], west, sideColor)
    renderer.addQuad(
      corners[1], corners[5], corners[6], corners[2], east, sideColor)

  proc draw(
      renderer: var SolidRenderer,
      viewProjection: Mat4
  ) =
    if renderer.vertices.len == 0:
      return
    glBindBuffer(GL_ARRAY_BUFFER, renderer.vertexBuffer)
    glBufferData(
      GL_ARRAY_BUFFER,
      renderer.vertices.len * sizeof(float32),
      renderer.vertices[0].addr,
      GL_DYNAMIC_DRAW
    )
    glEnable(GL_DEPTH_TEST)
    glDepthMask(GL_TRUE)
    glDisable(GL_BLEND)
    glDisable(GL_CULL_FACE)
    glUseProgram(renderer.program)
    solidViewProjection = viewProjection
    solidLightDirection = normalize(vec3(-0.5, 1.0, 0.65))
    glUniformMatrix4fv(
      glGetUniformLocation(renderer.program, "solidViewProjection"),
      1,
      GL_FALSE,
      cast[ptr float32](solidViewProjection.addr)
    )
    glUniform3f(
      glGetUniformLocation(renderer.program, "solidLightDirection"),
      solidLightDirection.x,
      solidLightDirection.y,
      solidLightDirection.z
    )
    glBindVertexArray(renderer.vertexArray)
    glDrawArrays(
      GL_TRIANGLES,
      0,
      (renderer.vertices.len div 10).GLsizei
    )
    glBindVertexArray(0)

  proc contains(rect: UiRect, point: Vec2): bool =
    point.x >= rect.origin.x and
      point.y >= rect.origin.y and
      point.x <= rect.origin.x + rect.size.x and
      point.y <= rect.origin.y + rect.size.y

  proc classColor(heroClass: HeroClass): Vec4 =
    case heroClass
    of Archer:
      vec4(0.17, 0.68, 0.31, 1)
    of Warrior:
      vec4(0.78, 0.18, 0.14, 1)
    of Mage:
      vec4(0.18, 0.38, 0.86, 1)

  proc classUiColor(heroClass: HeroClass): ColorRGBX =
    case heroClass
    of Archer:
      rgbx(70, 205, 102, 255)
    of Warrior:
      rgbx(226, 74, 61, 255)
    of Mage:
      rgbx(76, 121, 236, 255)

  var activeCameraPlayer: int = 0

  proc seatSide(playerIndex: int): float32 =
    if playerIndex == 0: 1.0'f32 else: -1.0'f32

  proc cardYaw(playerIndex: int): float32 =
    if activeCameraPlayer == 0: 0.0'f32 else: PI.float32

  proc avatarPosition(playerIndex: int): Vec3 =
    vec3(
      if playerIndex == 0: -7.0'f32 else: 7.0'f32,
      0.02'f32,
      playerIndex.seatSide() * 1.65'f32
    )

  proc handPoses(
      playerIndex,
      count: int,
      cameraSide: float32
  ): seq[CardPose] =
    if count <= 0:
      return
    let
      spacing =
        if count == 1:
          0.0'f32
        else:
          min(1.08'f32, 7.8'f32 / (count - 1).float32)
      middle = (count - 1).float32 * 0.5'f32
      side = playerIndex.seatSide()
      z = side * (
        if side == cameraSide:
          ActiveHandDistance
        else:
          OpponentHandDistance
      )
      center = vec3(0, HandCenterY, z)
      # The near and far hands need different pitches to face the same camera.
      pitch = arctan2(
        cameraSide * GameCameraDistance - z,
        GameCameraHeight - HandCenterY
      )
      fanRadius =
        if middle > 0:
          spacing * middle / sin(HandFanAngle)
        else:
          0.0'f32
    result.setLen(count)
    for i in 0 ..< count:
      let
        offset = i.float32 - middle
        normalized =
          if middle > 0:
            offset / middle
          else:
            0.0'f32
        angle = normalized * HandFanAngle
        fanOffset = rotateAroundX(
          vec3(
            sin(angle) * fanRadius,
            0,
            cameraSide * (1.0'f32 - cos(angle)) * fanRadius
          ),
          pitch
        )
      result[i] = CardPose(
        # A tiny separation keeps overlapping illustrated faces from sharing
        # exactly the same depth, and matches the hand's back-to-front order.
        position: center + fanOffset +
          rotateAroundX(vec3(0, i.float32 * 0.003'f32, 0), pitch),
        # Keep the card's width tangent to the fan circle.
        yaw: playerIndex.cardYaw() + cameraSide * angle,
        pitch: pitch
      )

  proc boardPoses(playerIndex, count: int): seq[CardPose] =
    if count <= 0:
      return
    let
      spacing =
        if count == 1:
          0.0'f32
        else:
          min(1.75'f32, 9.0'f32 / (count - 1).float32)
      start = -spacing * (count - 1).float32 * 0.5'f32
      z = playerIndex.seatSide() * 1.25'f32
    result.setLen(count)
    for i in 0 ..< count:
      result[i] = CardPose(
        position: vec3(start + spacing * i.float32, CardPlaneY, z),
        yaw: playerIndex.cardYaw()
      )

  proc deckPose(playerIndex: int): CardPose =
    CardPose(
      position: vec3(
        -7.25,
        CardPlaneY,
        playerIndex.seatSide() * 3.7'f32
      ),
      yaw: playerIndex.cardYaw()
    )

  proc discardPose(playerIndex: int): CardPose =
    CardPose(
      position: vec3(
        7.25,
        CardPlaneY,
        playerIndex.seatSide() * 3.7'f32
      ),
      yaw: playerIndex.cardYaw()
    )

  proc addDeckZone(
      renderer: var SolidRenderer,
      playerIndex: int,
      heroClass: HeroClass
  ) =
    let pose = deckPose(playerIndex)
    renderer.addBox(
      vec3(pose.position.x, 0.035'f32, pose.position.z),
      vec3(CardWidth + 0.48'f32, 0.07'f32, CardDepth + 0.55'f32),
      heroClass.classColor().darker(0.34'f32),
      pose.yaw,
      0.48'f32
    )

  proc stackTopPose(pose: CardPose, count: int): CardPose =
    result = pose
    result.position.y +=
      max(0, min(count, 7) - 1).float32 * 0.035'f32

  proc addCard(
      renderer: var SolidRenderer,
      faces: var CardRenderer,
      sk: Silky,
      pose: CardPose,
      heroClass: HeroClass,
      hidden,
      enabled,
      hovered: bool,
      targetable = false,
      card = Card(),
      currentPower = -1,
      currentToughness = -1,
      damageFlash = 0.0'f32,
      lostKeywords: set[Keyword] = {}
  ) =
    ## A minion on the battlefield passes its live stats (currentToughness
    ## >= 0); they are drawn over a stat-less face.
    var raised = pose.position
    if targetable:
      raised.y += 0.08'f32
    if hovered:
      raised.y += 0.16'f32
    let
      edgeColor =
        if targetable: vec4(0.9, 0.04, 0.07, 1)
        elif hovered: vec4(0.92, 0.78, 0.48, 1)
        else: vec4(0.16, 0.13, 0.095, 1)
      rim = if hovered or targetable: 0.09'f32 else: 0.0'f32
    renderer.addBox(
      raised,
      vec3(CardWidth + rim, CardHeight, CardDepth + rim),
      edgeColor,
      pose.yaw,
      0.55,
      pose.pitch
    )
    let
      halfWidth = CardWidth * 0.5'f32
      halfDepth = CardDepth * 0.5'f32
      surfaceY = CardHeight * 0.5'f32 + 0.004'f32
      local = [
        vec3(-halfWidth, surfaceY, -halfDepth),
        vec3(-halfWidth, surfaceY, halfDepth),
        vec3(halfWidth, surfaceY, halfDepth),
        vec3(halfWidth, surfaceY, -halfDepth)
      ]
      liveStats = not hidden and card.name.len > 0 and
        card.kind == Minion and currentToughness >= 0
      imageKey =
        if hidden or card.name.len == 0: CardBackKey
        else: sk.bakedCardImage(card)
      brightness = if hidden or enabled: 1.0'f32 else: 0.68'f32
    var corners: array[4, Vec3]
    for i in 0 ..< corners.len:
      corners[i] = raised + pose.transformCardVector(local[i])
    faces.addSurface(sk, corners, imageKey, brightness, damageFlash)
    if liveStats:
      faces.addMinionOverlays(sk, corners, card,
        if currentPower >= 0: currentPower else: card.power,
        currentToughness, lostKeywords, brightness, damageFlash)

  proc addCardGlow(renderer: var VfxRenderer, pose: CardPose,
      hovered, targetable, targeting: bool, time: float32) =
    if not hovered and not targetable: return
    let
      lift = (if hovered: 0.16'f32 else: 0.0'f32) +
        (if targetable: 0.08'f32 else: 0.0'f32)
      center = pose.position + vec3(0, lift, 0) +
        pose.cardNormal() * (CardHeight * 0.5'f32 + 0.01'f32)
      pulse = 0.88'f32 + 0.12'f32 * sin(time * 5)
    renderer.addCardHalo(center,
      pose.transformCardVector(vec3(1, 0, 0)),
      pose.transformCardVector(vec3(0, 0, 1)), vec2(CardWidth, CardDepth),
      (if targeting: TargetRed else: HoverGold),
      pulse * (if hovered: 1.15'f32 else: 0.28'f32))

  proc addCardStack(
      renderer: var SolidRenderer,
      faces: var CardRenderer,
      sk: Silky,
      pose: CardPose,
      count: int,
      heroClass: HeroClass,
      hidden = true,
      card = Card()
  ) =
    for i in 0 ..< min(count, 7):
      var cardPose = pose
      cardPose.position.y += i.float32 * 0.035'f32
      renderer.addCard(
        faces, sk, cardPose, heroClass, hidden, true, false, card = card
      )

  proc newCardAnimation(
      card: Card,
      heroClass: HeroClass,
      fromPose,
      toPose: CardPose,
      arcHeight = 1.4'f32,
      suppressBoardId = -1,
      suppressHandOwner = -1,
      suppressHandIndex = -1,
      suppressDiscardOwner = -1,
      hidden = false,
      duration = CardMoveDuration,
      trackingTarget = Canceled
  ): CardAnimation =
    CardAnimation(
      card: card,
      heroClass:
        if card.class.isSome:
          card.class.get()
        else:
          heroClass,
      fromPose: fromPose,
      toPose: toPose,
      duration: duration,
      arcHeight: arcHeight,
      suppressBoardId: suppressBoardId,
      suppressHandOwner: suppressHandOwner,
      suppressHandIndex: suppressHandIndex,
      suppressDiscardOwner: suppressDiscardOwner,
      hidden: hidden,
      trackingTarget: trackingTarget
    )

  proc addDrawAnimation(
      animations: var seq[CardAnimation],
      game: GameState,
      playerIndex: int,
      cameraSide: float32,
      hidden = true,
      handIndex = -1
  ) =
    ## Flies a card from the deck to `handIndex` (default: the last slot).
    if game.players[playerIndex].hand.len == 0:
      return
    let
      destinationIndex =
        if handIndex in 0 ..< game.players[playerIndex].hand.len: handIndex
        else: game.players[playerIndex].hand.high
      sourcePose = stackTopPose(
        deckPose(playerIndex),
        game.players[playerIndex].deck.len + 1
      )
      destinationPose = handPoses(
        playerIndex,
        game.players[playerIndex].hand.len,
        cameraSide
      )[destinationIndex]
    animations.add newCardAnimation(
      game.players[playerIndex].hand[destinationIndex],
      game.players[playerIndex].heroClass,
      sourcePose,
      destinationPose,
      arcHeight = 1.0'f32,
      suppressHandOwner = playerIndex,
      suppressHandIndex = destinationIndex,
      hidden = hidden,
      duration = DrawMoveDuration
    )

  proc animateTransition(animations: var seq[CardAnimation],
      before, after: GameState, cameraSide: float32) =
    ## The server and local bot use the same card movement as human input.
    if after.turnNumber != before.turnNumber:
      # Draws animate from their DrawVfx events.
      return
    let owner = before.currentPlayer
    let oldPlayer = before.players[owner]
    let newPlayer = after.players[owner]
    if oldPlayer.hand.len > 0:
      # The built-in bot always chooses the first affordable card. Base decks
      # contain one card type, so locating a played face is unambiguous.
      var playedIndex = 0
      for i, card in oldPlayer.hand:
        if card.energyCost <= oldPlayer.energy:
          playedIndex = i
          break
      let source = handPoses(owner, oldPlayer.hand.len, cameraSide)[playedIndex]
      # Only the card that left the hand flies from it; minions its rules
      # summoned enter after it and appear on their own beat.
      for i, minion in newPlayer.board:
        if not before.minionLocation(minion.id).found:
          animations.add newCardAnimation(minion.card, newPlayer.heroClass,
            source, boardPoses(owner, i + 1)[i],
            suppressBoardId = minion.id)
          break
      if newPlayer.discardPile.len > oldPlayer.discardPile.len and
          newPlayer.hand.len < oldPlayer.hand.len:
        animations.add newCardAnimation(newPlayer.discardPile[^1],
          newPlayer.heroClass, source,
          stackTopPose(discardPose(owner), newPlayer.discardPile.len),
          suppressDiscardOwner = owner)

  proc animationPose(animation: CardAnimation): CardPose =
    let
      raw =
        if animation.duration > 0:
          clamp(animation.elapsed / animation.duration, 0.0'f32, 1.0'f32)
        else:
          1.0'f32
      eased = raw * raw * (3.0'f32 - 2.0'f32 * raw)
      angleDifference = arctan2(
        sin(animation.toPose.yaw - animation.fromPose.yaw),
        cos(animation.toPose.yaw - animation.fromPose.yaw)
      )
    result.position =
      animation.fromPose.position +
      (animation.toPose.position - animation.fromPose.position) * eased
    result.position.y += sin(PI.float32 * raw) * animation.arcHeight
    result.yaw = animation.fromPose.yaw + angleDifference * eased
    result.pitch =
      animation.fromPose.pitch +
      (animation.toPose.pitch - animation.fromPose.pitch) * eased

  proc advanceAnimations(
      animations: var seq[CardAnimation],
      deltaTime: float32
  ) =
    if animations.len == 0:
      return
    for animation in animations.mitems:
      animation.elapsed += deltaTime
    for i in countdown(animations.high, 0):
      if animations[i].elapsed >= animations[i].duration:
        animations.delete(i)

  proc boardCardSuppressed(
      animations: openArray[CardAnimation],
      minionId: int
  ): bool =
    for animation in animations:
      if animation.suppressBoardId == minionId:
        return true

  proc handCardSuppressed(
      animations: openArray[CardAnimation],
      playerIndex,
      cardIndex: int
  ): bool =
    for animation in animations:
      if animation.suppressHandOwner == playerIndex and
          animation.suppressHandIndex == cardIndex:
        return true

  proc queuedDraw(queued: openArray[VisualEvent], owner, index: int): bool =
    ## A card still on its way to the hand (drawn or bounced) whose beat
    ## hasn't played yet stays out of the hand.
    for event in queued:
      if event.target.owner == owner and
          ((event.kind == DrawVfx and event.boardIndex == index) or
            (event.kind == BounceVfx and event.handIndex == index)):
        return true

  proc queuedSummon(queued: openArray[VisualEvent], minionId: int): bool =
    ## A summoned minion whose beat hasn't played yet stays off the board.
    for event in queued:
      if event.kind == SummonVfx and event.target.kind == CreatureChoice and
          event.target.creatureId == minionId:
        return true

  proc discardCardsSuppressed(
      animations: openArray[CardAnimation],
      playerIndex: int
  ): int =
    for animation in animations:
      if animation.suppressDiscardOwner == playerIndex:
        inc result

  proc screenPosition(
      window: Window,
      position: Vec3,
      viewProjection: Mat4
  ): Vec2 =
    let clip = viewProjection * vec4(position, 1)
    if clip.w <= 0:
      return vec2(-10000)
    let normalized = vec2(clip.x / clip.w, clip.y / clip.w)
    vec2(
      (normalized.x * 0.5'f32 + 0.5'f32) * window.size.x.float32,
      (0.5'f32 - normalized.y * 0.5'f32) * window.size.y.float32
    )

  proc mouseRay(
      window: Window,
      viewProjection: Mat4
  ): tuple[origin, direction: Vec3] =
    let
      width = max(window.size.x.float32, 1)
      height = max(window.size.y.float32, 1)
      ndcX = 2.0'f32 * window.mousePos.vec2.x / width - 1.0'f32
      ndcY = 1.0'f32 - 2.0'f32 * window.mousePos.vec2.y / height
      inverseViewProjection = inverse(viewProjection)
    var
      nearPoint = inverseViewProjection * vec4(ndcX, ndcY, -1, 1)
      farPoint = inverseViewProjection * vec4(ndcX, ndcY, 1, 1)
    result.origin = nearPoint.xyz / nearPoint.w
    let farPosition = farPoint.xyz / farPoint.w
    result.direction = normalize(farPosition - result.origin)

  proc mousePlanePoint(
      window: Window,
      viewProjection: Mat4,
      planeY: float32
  ): tuple[hit: bool, point: Vec3] =
    let
      ray = mouseRay(window, viewProjection)
    if abs(ray.direction.y) < 1e-5'f32:
      return
    let distance = (planeY - ray.origin.y) / ray.direction.y
    if distance <= 0:
      return
    (true, ray.origin + ray.direction * distance)

  proc mouseCardOffset(
      window: Window,
      viewProjection: Mat4,
      pose: CardPose
  ): float32 =
    ## How far the mouse's point on the card is from the card's centre, or
    ## -1 when the mouse isn't over the card. Crowded boards overlap, so the
    ## closest card is the one under the mouse.
    result = -1
    let
      ray = mouseRay(window, viewProjection)
      normal = pose.cardNormal()
      denominator = dot(ray.direction, normal)
    if abs(denominator) < 1e-5'f32:
      return
    let distance = dot(pose.position - ray.origin, normal) / denominator
    if distance <= 0:
      return
    let local = pose.inverseCardVector(
      ray.origin + ray.direction * distance - pose.position
    )
    if abs(local.x) <= CardWidth * 0.5'f32 and
        abs(local.z) <= CardDepth * 0.5'f32:
      result = sqrt(local.x * local.x + local.z * local.z)

  proc mouseHitsCard(
      window: Window,
      viewProjection: Mat4,
      pose: CardPose
  ): bool =
    mouseCardOffset(window, viewProjection, pose) >= 0

  proc mouseOverBoard(
      window: Window,
      viewProjection: Mat4
  ): bool =
    let hit = mousePlanePoint(window, viewProjection, CardPlaneY)
    hit.hit and
      abs(hit.point.x) <= BoardWidth * 0.5'f32 and
      abs(hit.point.z) <= BoardDepth * 0.5'f32

  proc hoveredCard(
      window: Window,
      viewProjection: Mat4,
      game: GameState,
      cameraSide: float32,
      handOwner = -1
  ): int =
    ## The hovered card in `handOwner`'s hand (default: the current player).
    result = -1
    let
      playerIndex = if handOwner >= 0: handOwner else: game.currentPlayer
      poses = handPoses(
        playerIndex,
        game.players[playerIndex].hand.len,
        cameraSide
      )
    if poses.len == 0:
      return
    for i in countdown(poses.high, 0):
      if mouseHitsCard(window, viewProjection, poses[i]):
        return i

  proc choiceIsLegal(
      choices: openArray[Choice],
      wanted: Choice
  ): bool =
    for choice in choices:
      if choice == wanted:
        return true

  proc selectableTargetCount(choices: openArray[Choice]): int =
    for choice in choices:
      if not choice.isNoTarget:
        inc result

  proc hoveredHeroTarget(
      window: Window,
      viewProjection: Mat4,
      choices: openArray[Choice]
  ): Choice =
    result = Canceled
    var closestDistanceSquared = 72.0'f32 * 72.0'f32
    for playerIndex in 0 ..< PlayerCount:
      let wanted = heroChoice(playerIndex)
      if not choices.choiceIsLegal(wanted):
        continue
      let
        screen = screenPosition(
          window,
          avatarPosition(playerIndex) + vec3(0, 1.25, 0),
          viewProjection
        )
        delta = screen - window.mousePos.vec2
        distanceSquared = delta.x * delta.x + delta.y * delta.y
      if distanceSquared <= closestDistanceSquared:
        closestDistanceSquared = distanceSquared
        result = wanted

  var hiddenSummons: array[PlayerCount, int]
    ## Summoned minions per side whose beat hasn't played yet. They're the
    ## last cards on that board and take no room until they appear.

  proc boardSlots(
      dying: openArray[DyingMinion],
      owner,
      liveCount: int
  ): seq[int] =
    ## Presented board order: live indices 0 ..< liveCount, with each dying
    ## minion (as -1 - its index in `dying`) back where it stood. Re-inserting
    ## the newest first undoes the removals in reverse, so every slot lands
    ## exactly where it was. Summons still waiting for their beat are left
    ## out, so the cards already shown don't shift before they appear.
    for i in 0 ..< max(0, liveCount - hiddenSummons[owner]):
      result.add i
    for i in countdown(dying.high, 0):
      if dying[i].target.owner == owner:
        result.insert(-1 - i, min(dying[i].boardIndex, result.len))

  proc liveBoardPose(
      dying: openArray[DyingMinion],
      owner,
      liveIndex,
      liveCount: int
  ): CardPose =
    ## A card left out of the layout (a summon whose beat hasn't played)
    ## gets the first slot; it isn't drawn until it appears. An empty
    ## layout still has one slot to hand out.
    let
      slots = dying.boardSlots(owner, liveCount)
      poses = boardPoses(owner, max(1, slots.len))
    poses[clamp(slots.find(liveIndex), 0, poses.high)]

  proc dyingPose(
      dying: openArray[DyingMinion],
      index,
      liveCount: int
  ): CardPose =
    let
      owner = dying[index].target.owner
      slots = dying.boardSlots(owner, liveCount)
      poses = boardPoses(owner, max(1, slots.len))
    result = poses[clamp(slots.find(-1 - index), 0, poses.high)]
    if dying[index].atLunge:
      result.position = dying[index].lungePoint

  proc hoveredCreatureTarget(
      window: Window,
      viewProjection: Mat4,
      game: GameState,
      choices: openArray[Choice],
      dying: openArray[DyingMinion] = []
  ): Choice =
    result = Canceled
    let hit = mousePlanePoint(window, viewProjection, CardPlaneY)
    if not hit.hit:
      return
    for playerIndex in 0 ..< PlayerCount:
      let player = game.players[playerIndex]
      for minionIndex in countdown(player.board.high, 0):
        let
          minion = player.board[minionIndex]
          wanted = creatureChoice(playerIndex, minion.id)
        if not choices.choiceIsLegal(wanted):
          continue
        if mouseHitsCard(
            window,
            viewProjection,
            dying.liveBoardPose(playerIndex, minionIndex, player.board.len)
        ):
          return wanted

  proc hoveredWorldTarget(
      window: Window,
      viewProjection: Mat4,
      game: GameState,
      choices: openArray[Choice],
      dying: openArray[DyingMinion] = []
  ): Choice =
    result = hoveredCreatureTarget(
      window,
      viewProjection,
      game,
      choices,
      dying
    )
    if result.isCanceled:
      result = hoveredHeroTarget(window, viewProjection, choices)

  proc polyworldRoot(): string =
    var candidates: seq[string]
    let configured = getEnv("POLYWORLD_REPO")
    if configured.len > 0:
      candidates.add configured
    let appDir = getAppDir()
    for base in [appDir, getCurrentDir()]:
      candidates.add base / ".." / ".."
    candidates.add getCurrentDir()
    for candidate in candidates:
      let root = absolutePath(candidate)
      if fileExists(root / "src" / "polyworld" / "common.nim") and
          dirExists(root / ".." / "polyworld_data"):
        return root

  proc idleClip(model: CharacterModel): int =
    for name in ["Idle", "Idle01", "Idle_Battle", "Idle_Normal"]:
      if model.clips.hasKey(name):
        return model.clipIndex(name)
    0

  proc cardAssetsRoot(): string =
    for candidate in [
      getAppDir() / "artwork" / "cards",
      getCurrentDir() / "artwork" / "cards",
      currentSourcePath().parentDir / "artwork" / "cards"
    ]:
      if dirExists(candidate / "frames") and dirExists(candidate / "fonts"):
        return candidate
    raise newException(IOError, "Could not find artwork/cards beside the game.")

  proc drawButton(
      sk: Silky,
      window: Window,
      rect: UiRect,
      label: string,
      accent: ColorRGBX,
      enabled = true
  ): bool =
    let hovered = rect.contains(sk.mousePos)
    let fill =
      if not enabled:
        rgbx(64, 67, 76, 245)
      elif hovered:
        accent
      else:
        rgbx(
          (accent.r.int * 3 div 5).uint8,
          (accent.g.int * 3 div 5).uint8,
          (accent.b.int * 3 div 5).uint8,
          245
        )
    sk.drawRect(rect.origin, rect.size, rgbx(19, 22, 30, 245))
    sk.drawRect(
      rect.origin + vec2(3),
      rect.size - vec2(6),
      fill
    )
    sk.drawLabel(
      label,
      rect.origin,
      rect.size,
      rgbx(248, 248, 244, 255),
      "Default",
      CenterAlign
    )
    enabled and hovered and window.buttonPressed[MouseLeft]

  proc hudScale(window: Window): float32 =
    let density = when defined(emscripten): window.contentScale else: 1.0'f32
    min(density, min(window.size.x.float32 / 2400.0'f32,
      window.size.y.float32 / 1500.0'f32))

  proc hudSize(window: Window): Vec2 =
    window.size.vec2 / max(hudScale(window), 0.01'f32)

  proc finishRect(window: Window): UiRect =
    UiRect(
      origin: vec2(hudSize(window).x - 278, hudSize(window).y - 102),
      size: vec2(248, 70)
    )

  proc drawPlayerPanel(
      sk: Silky,
      window: Window,
      game: GameState,
      playerIndex: int
  ) =
    let
      width = PlayerPanelWidth
      origin =
        if playerIndex == 0:
          vec2(28, 24)
        else:
          vec2(hudSize(window).x - width - 28, 24)
      rect = UiRect(
        origin: origin,
        size: vec2(width, PlayerPanelHeight)
      )
      player = game.players[playerIndex]
      active = playerIndex == game.currentPlayer
      accent = player.heroClass.classUiColor()
    sk.drawRect(
      rect.origin,
      rect.size,
      if active: rgbx(29, 33, 45, 248) else: rgbx(18, 21, 29, 232)
    )
    sk.drawRect(
      rect.origin,
      vec2(rect.size.x, 5),
      if active: accent else: rgbx(73, 77, 88, 255)
    )
    sk.drawLabel(
      &"PLAYER {playerIndex + 1} | {player.heroClass.className()}",
      rect.origin + vec2(18, 12),
      vec2(rect.size.x - 36, 44),
      accent,
      "Default"
    )
    sk.drawLabel(
      &"LIFE  {player.life}",
      rect.origin + vec2(18, 62),
      vec2(140, 38),
      rgbx(240, 102, 100, 255),
      "Hud"
    )
    sk.drawLabel(
      &"ENERGY  {player.energy}/{player.totalEnergy}",
      rect.origin + vec2(180, 62),
      vec2(290, 38),
      rgbx(108, 175, 247, 255),
      "Hud"
    )
    sk.drawLabel(
      &"Deck {player.deck.len}   Hand {player.hand.len}   Board {player.board.len}   Discard {player.discardPile.len}",
      rect.origin + vec2(18, 116),
      vec2(rect.size.x - 36, 34),
      rgbx(190, 194, 204, 255),
      "Small"
    )

  proc drawCardReadingView(
      sk: Silky,
      window: Window,
      game: GameState,
      viewProjection: Mat4,
      animations: openArray[CardAnimation],
      hoverIndex: int,
      hidden: bool,
      dying: openArray[DyingMinion] = [],
      canPlayCards = true,
      discardFlights: openArray[CardAnimation] = [],
      queued: openArray[VisualEvent] = [],
      handOwner = -1
  ) =
    ## The large preview of the hovered card: in hand, on the board, or on
    ## top of a discard pile.
    if hidden:
      return
    var
      card: Card
      power = -1
      toughness = -1
      lost: set[Keyword]
      onBoard = false
      inDiscard = false
      found = false
    let
      owner = if handOwner >= 0: handOwner else: game.currentPlayer
      player = game.players[owner]
    if hoverIndex >= 0 and hoverIndex < player.hand.len and
        not animations.handCardSuppressed(owner, hoverIndex) and
        not queued.queuedDraw(owner, hoverIndex):
      card = player.hand[hoverIndex]
      found = true
    else:
      # One card: the closest under the mouse. Its stats come from it alone,
      # never left over from another card the mouse also touches.
      var nearest = high(float32)
      for owner in 0 ..< PlayerCount:
        for i, minion in game.players[owner].board:
          if animations.boardCardSuppressed(minion.id) or
              queued.queuedSummon(minion.id):
            continue
          let offset = mouseCardOffset(window, viewProjection,
            dying.liveBoardPose(owner, i, game.players[owner].board.len))
          if offset < 0 or offset >= nearest:
            continue
          nearest = offset
          card = minion.card
          onBoard = true
          found = true
          if card.kind == Minion:
            power = minion.power
            toughness = minion.currentToughness
            lost = minion.lostKeywords
          else:
            power = -1
            toughness = -1
            lost = {}
      if not found:
        # The visible top of a discard pile, matching how the pile is drawn:
        # cards still flying there or still dying on the board aren't shown.
        for owner in 0 ..< PlayerCount:
          let pile = game.players[owner].discardPile
          var hiddenCards = animations.discardCardsSuppressed(owner) +
            discardFlights.discardCardsSuppressed(owner)
          for slain in dying:
            if slain.target.owner == owner and not slain.bouncing:
              inc hiddenCards
          let shown = pile.len - hiddenCards
          if shown > 0 and mouseHitsCard(window, viewProjection,
              stackTopPose(discardPose(owner), shown)):
            card = pile[shown - 1]
            inDiscard = true
            found = true
    when defined(takeScreenshot):
      if getEnv("AWM_DEMO_CARD_HOVER") == "1" and player.hand.len > 0:
        card = player.hand[0]
        found = true
    if not found:
      return
    let
      height = max(120.0'f32, min(850.0'f32, hudSize(window).y - 360.0'f32))
      size = vec2(height * CardFaceWidth.float32 / CardFaceHeight.float32, height)
      origin = vec2(32, 220)
      liveStats = toughness >= 0
      imageKey = sk.bakedCardImage(card)
    sk.drawRect(origin + vec2(8, 12), size, rgbx(0, 0, 0, 165))
    sk.drawCardImage(imageKey, origin, size)
    if liveStats:
      sk.drawMinionOverlays(card, power, toughness, lost, origin, size)
    sk.drawLabel(
      if onBoard: "ON THE BATTLEFIELD"
      elif inDiscard: "IN THE DISCARD PILE"
      elif card.energyCost > player.energy: "NOT ENOUGH ENERGY"
      elif canPlayCards: "CLICK THE CARD IN YOUR HAND TO PLAY"
      else: "IN HAND",
      origin + vec2(0, size.y + 12),
      vec2(size.x, 34),
      rgbx(215, 199, 158, 255),
      "Small",
      CenterAlign
    )

  proc drawDeckLabels(
      sk: Silky,
      window: Window,
      game: GameState,
      viewProjection: Mat4
  ) =
    for playerIndex in 0 ..< PlayerCount:
      let screen = screenPosition(
        window,
        deckPose(playerIndex).position + vec3(0, 0.28'f32, 0),
        viewProjection
      ) / hudScale(window)
      let rect = UiRect(
        origin: screen + vec2(-58, -17),
        size: vec2(116, 30)
      )
      sk.drawRect(rect.origin, rect.size, rgbx(12, 15, 20, 225))
      sk.drawLabel(
        &"DECK {game.players[playerIndex].deck.len}",
        rect.origin,
        rect.size,
        game.players[playerIndex].heroClass.classUiColor(),
        "Small",
        CenterAlign
      )

  proc runAwm*() =
    if "--help" in commandLineParams() or "-h" in commandLineParams():
      echo "AWM: --seed N --class archer|warrior|mage --opponent archer|warrior|mage --bot PATH --human"
      return
    let sessionOptions = parseSessionOptions(commandLineParams())
    when defined(emscripten):
      let appDir = "/"
      let cardAssets = "/artwork/cards"
      setCurrentDir("/")
    else:
      const sourceDir = currentSourcePath().parentDir
      let
        appDir =
          if dirExists(getAppDir() / "players"): getAppDir()
          elif dirExists(sourceDir / "players"): sourceDir
          else: getAppDir()
        root = polyworldRoot()
        cardAssets = cardAssetsRoot()
      if root.len == 0:
        raise newException(IOError,
          "Could not find Polyworld. Set POLYWORLD_REPO to its repository root.")
      setCurrentDir(root)

    let
      atlasPath = appDir / "awm.atlas.png"
      atlasBuilder = newHudAtlas(4096)
    initCardAssets(cardAssets)
    atlasBuilder.addBaseCardImages()
    atlasBuilder.addFont(BoldFontPath, "H1", 60.0)
    atlasBuilder.addFont(DefaultFontPath, "Default", 34.5)
    atlasBuilder.addFont(DefaultFontPath, "Hud", 28.5)
    atlasBuilder.addFont(DefaultFontPath, "Small", 22.5)
    atlasBuilder.write(atlasPath)

    var window: Window
    var sk: Silky
    (window, sk) = initGameWindow(
      WindowTitle,
      atlasPath,
      ivec2(3200, 2000),
      vsync = true
    )

    var
      solid = initSolidRenderer()
      cardSurfaces = initCardRenderer()
      vfx = initVfxRenderer(cardAssets.parentDir / "vfx" / "textures")
    let scene = newCharacterScene(window)
    scene.useToonShading()
    var
      models: array[HeroClass, CharacterModel]
      idleClips: array[HeroClass, int]
    for heroClass in HeroClass:
      models[heroClass] = loadCharacterModel(
        CharacterPaths[heroClass],
        2.6
      )
      idleClips[heroClass] = models[heroClass].idleClip()

    var
      phase = ChooseClasses
      selectedClass: HeroClass
      game: GameState
      pendingTargeting = false
      pendingCardIndex = -1
      pendingCard: Card
      pendingChoices: seq[Choice]
      pendingPicks: seq[Choice]  ## Targets chosen so far for pendingCard.
      pendingTrigger = false  ## Targeting answers a waiting trigger.
      tossPicking = false  ## The human is choosing cards to discard.
      tossPicks: seq[int]  ## Hand positions picked so far.
      animations: seq[CardAnimation]
      activeVfx: seq[ActiveVfx]
      # Visual seeds never advance the game's RNG. Captures can replay a cast.
      visualRng = when defined(takeScreenshot):
        initRand(parseBiggestInt(getEnv("AWM_VFX_SEED", "20260909")))
      else:
        initRand()
      statusMessage = ""
      animationTime = 0.0'f32
      lastFrameTime = epochTime()
      botWait = 1.2'f32
      botPlays = 0
      botClassWait = 1.5'f32
      selectedAttacker = 0
      attackActive = false
      attackSteps: seq[int]
      attackTarget = Canceled
      attackPoint: Vec3
      dyingMinions: seq[DyingMinion]
      discardFlights: seq[CardAnimation]  # Never block input or bots.
      queuedEvents: seq[VisualEvent]  ## Visual events waiting for their beat.
      lastBeatWasDraw = false
      lastDrawStart = 0.0'f32
      attackIndex = 0
      attackForward = true
      attackElapsed = 0.0'f32
      attackFinishTurn = false
      attackDamageApplied = false
    var
      botVms: array[PlayerCount, BotVm]
      seedRng = initRand()

    proc gameSeed(): int64 =
      ## --seed replays one deal; otherwise every game gets a fresh one.
      when defined(takeScreenshot):
        return sessionOptions.seed
      if sessionOptions.seedGiven:
        return sessionOptions.seed
      result = seedRng.rand(high(int)).int64
      echo "AWM seed ", result, " (replay with --seed ", result, ")"

    proc cameraPlayer(): int =
      if sessionOptions.human or phase == ChooseClasses: 0
      else: game.currentPlayer

    proc humanTurn(): bool =
      sessionOptions.human and botVms[game.currentPlayer] == nil

    proc presentedCardPose(target: Choice, slot, count: int): CardPose =
      ## Where a targeted card is shown right now: its live slot, or the slot
      ## it's held in while its death or bounce waits for its beat. Only if
      ## it's neither does the slot it had when the event was recorded count.
      let location = game.minionLocation(target.creatureId)
      if location.found:
        return dyingMinions.liveBoardPose(location.player, location.index,
          game.players[location.player].board.len)
      for i, held in dyingMinions:
        if held.target == target:
          return dyingMinions.dyingPose(i,
            game.players[target.owner].board.len)
      boardPoses(target.owner, max(1, count))[clamp(slot, 0, max(0, count - 1))]

    proc countHiddenSummons() =
      hiddenSummons = default(array[PlayerCount, int])
      for event in queuedEvents:
        if event.kind == SummonVfx:
          inc hiddenSummons[event.target.owner]

    proc presentationIdle(): bool =
      ## Nothing is animating and no visual beat is still waiting to play,
      ## including events the game produced that the UI hasn't taken yet.
      animations.len == 0 and activeVfx.len == 0 and queuedEvents.len == 0 and
        game.visualEvents.len == 0

    proc humanActs(): bool =
      ## The human must act now: on their turn, or answering their trigger.
      sessionOptions.human and botVms[game.actingPlayer()] == nil

    proc attackPointFor(target: Choice): Vec3 =
      ## Where an attacker lunges. Captured when the attack starts, because a
      ## slain defender leaves the board halfway through the animation.
      if target.kind == CreatureChoice:
        let location = game.minionLocation(target.creatureId)
        if location.found:
          return dyingMinions.liveBoardPose(location.player, location.index,
            game.players[location.player].board.len).position
      avatarPosition(target.owner)

    proc attackLungePoint(fromPose: CardPose): Vec3 =
      ## Far end of the lunge: toward the hero, or just short of a defender
      ## so both cards stay visible.
      if attackTarget.kind == HeroChoice:
        vec3(fromPose.position.x * 0.3, CardPlaneY + 0.3, attackPoint.z * 0.7)
      else:
        fromPose.position + (attackPoint - fromPose.position) * 0.8'f32 +
          vec3(0, 0.3, 0)

    proc dyingDiscards(owner: int): int =
      ## Slain cards already in the discard pile but still shown on the board.
      for dying in dyingMinions:
        if dying.target.owner == owner and not dying.bouncing:
          inc result

    proc handVisible(owner: int): bool =
      owner == cameraPlayer()

    block:
      var sources: array[PlayerCount, string]
      if sessionOptions.botPaths.len > 0:
        if sessionOptions.human:
          for i in 0 ..< min(sessionOptions.botPaths.len, PlayerCount - 1):
            sources[i + 1] = readFile(sessionOptions.botPaths[i])
        elif sessionOptions.botPaths.len == 1:
          let src = readFile(sessionOptions.botPaths[0])
          sources[0] = src
          sources[1] = src
        else:
          for i in 0 ..< min(sessionOptions.botPaths.len, PlayerCount):
            sources[i] = readFile(sessionOptions.botPaths[i])
      else:
        let defaultBot = appDir / "players" / "base.bas"
        if fileExists(defaultBot):
          let src = readFile(defaultBot)
          if not sessionOptions.human:
            sources = [src, src]
          else:
            sources[1] = src
      botVms = loadBots(sources)

    if sessionOptions.human:
      phase = ChooseClasses
      statusMessage = "Choose your class."
    else:
      phase = ChooseClasses
      statusMessage = "Bots are choosing classes..."

    when defined(takeScreenshot):
      var screenshotFrame = 0
    if getEnv("AWM_AUTOSTART") == "1":
      game = newGame(Archer, Mage, 20260904)
      phase = PlayGame
      animations.addDrawAnimation(
        game,
        game.currentPlayer,
        game.currentPlayer.seatSide(),
        hidden = false
      )
      statusMessage =
        &"Player {game.currentPlayer + 1} begins."
    when defined(takeScreenshot):
      if getEnv("AWM_DEMO_BOARD") == "1":
        animations.setLen(0)
        let creatureTargetDemo =
          getEnv("AWM_DEMO_CREATURE_TARGET") == "1"
        game.currentPlayer = 0
        if creatureTargetDemo:
          game.players[0].heroClass = Mage
          game.players[1].heroClass = Warrior
        game.players[0].energy = 1
        game.players[0].totalEnergy = 1
        game.players[0].hand = @[
          if creatureTargetDemo:
            Mage.classCard()
          else:
            Archer.classCard()
        ]
        game.players[0].board = @[
          MinionState(
            id: 1,
            owner: 0,
            card: Mage.classCard(),
            currentToughness: 1
          )
        ]
        game.players[1].board = @[
          MinionState(
            id: 2,
            owner: 1,
            card: Warrior.classCard(),
            currentToughness: 2
          )
        ]
        game.nextMinionId = 3
        # AWM_DEMO_ENEMY_BOARD: that many enemy cards, alternating Snipers
        # (which die to 1 damage) and Bears.
        let enemyCards = parseInt(getEnv("AWM_DEMO_ENEMY_BOARD", "0"))
        if enemyCards > 0:
          game.players[1].board.setLen(0)
          for i in 0 ..< enemyCards:
            let card =
              if i mod 2 == 0: baseCard("sniper-2") else: Warrior.classCard()
            game.players[1].board.add MinionState(id: 10 + i, owner: 1,
              card: card, currentToughness: card.toughness)
          game.nextMinionId = 10 + enemyCards
        statusMessage =
          if creatureTargetDemo:
            "Demo board: Bouncer can target any minion, including itself."
          else:
            "Demo board: Bolt can target either hero."
        if getEnv("AWM_DEMO_TARGET") == "1":
          pendingCard = game.players[0].hand[0]
          pendingTargeting = true
          if creatureTargetDemo:
            let
              sourcePose = handPoses(0, 1, 1.0'f32)[0]
              minionId = game.playMinion(0)
              destinationPose =
                boardPoses(0, game.players[0].board.len)[^1]
            animations.add newCardAnimation(
              pendingCard,
              game.players[0].heroClass,
              sourcePose,
              destinationPose,
              suppressBoardId = minionId
            )
            pendingCardIndex = -1
            pendingChoices = game.availableChoices(pendingCard)
          else:
            pendingCardIndex = 0
            pendingChoices = game.availableChoices(0)
        elif getEnv("AWM_DEMO_DISCARD_ANIMATION") == "1":
          let
            card = game.players[0].hand[0]
            sourcePose = handPoses(0, 1, 1.0'f32)[0]
          if game.playCard(0, heroChoice(1)):
            animations.add newCardAnimation(
              card,
              game.players[0].heroClass,
              sourcePose,
              stackTopPose(
                discardPose(0),
                game.players[0].discardPile.len
              ),
              suppressDiscardOwner = 0
            )
            statusMessage = "Demo animation: Bolt moves to discard."
        elif getEnv("AWM_DEMO_BOUNCE_ANIMATION") == "1":
          if game.runMinionRules(
              Mage.classCard(),
              creatureChoice(1, 2)
          ):
            statusMessage = "Demo animation: Bear returns to hand."

        if getEnv("AWM_DEMO_CARD_SET") == "1":
          animations.setLen(0)
          game.players[0].hand = @[
            Archer.classCard(), Warrior.classCard(), Mage.classCard()
          ]
          game.players[0].energy = 3
          game.players[0].totalEnergy = 3
          statusMessage = "Hover a card to inspect its artwork and rules."
        if getEnv("AWM_DEMO_PLAYER_TWO") == "1":
          animations.setLen(0)
          game.currentPlayer = 1
        if getEnv("AWM_DEMO_SWORDS") == "1":
          # One Bear already buffed, one damaged: Swords raises both.
          animations.setLen(0)
          game.players[0].heroClass = Warrior
          game.players[0].board = @[
            MinionState(id: 1, owner: 0, card: Warrior.classCard(),
              currentToughness: 2, bonusPower: 1),
            MinionState(id: 3, owner: 0, card: Warrior.classCard(),
              currentToughness: 1)
          ]
          game.nextMinionId = 4
          # AWM_DEMO_SPELL picks another board-wide spell, e.g. shields-1.
          game.players[0].hand =
            @[baseCard(getEnv("AWM_DEMO_SPELL", "swords-2"))]
          game.players[0].energy = 5
          game.players[0].totalEnergy = 5
          let spell = game.players[0].hand[0]
          if game.playCard(0):
            statusMessage = &"Demo: {spell.name} resolves."
        if getEnv("AWM_DEMO_DUEL") == "1":
          # A Bear duels a sturdy Sniper that loses Ranged and survives.
          animations.setLen(0)
          game.players[0].heroClass = Warrior
          game.players[1].heroClass = Archer
          game.players[0].board = @[MinionState(id: 1, owner: 0,
            card: Warrior.classCard(), currentToughness: 2)]
          game.players[1].board = @[MinionState(id: 2, owner: 1,
            card: baseCard("sniper-2"), currentToughness: 5)]
          game.nextMinionId = 3
          game.players[0].hand = @[baseCard("duel-2")]
          game.players[0].energy = 2
          game.players[0].totalEnergy = 2
          if game.playCard(0, @[creatureChoice(0, 1), creatureChoice(1, 2)]):
            statusMessage = "Demo: Duel."
        if getEnv("AWM_DEMO_TACTICIAN") == "1":
          # Tactician enters and weakens the enemy Bear.
          animations.setLen(0)
          game.players[0].heroClass = Warrior
          game.players[0].hand = @[baseCard("tactician-2")]
          game.players[0].energy = 2
          game.players[0].totalEnergy = 2
          if game.playCard(0, creatureChoice(1, 2)):
            statusMessage = "Demo: Tactician."
        if getEnv("AWM_DEMO_OOZIFICATION") == "1":
          # Oozification destroys the enemy Bear (toughness 2): its owner
          # gets two Oozes.
          # AWM_DEMO_OOZE_TARGET picks which enemy card (see
          # AWM_DEMO_ENEMY_BOARD).
          animations.setLen(0)
          let targetIndex = parseInt(getEnv("AWM_DEMO_OOZE_TARGET", "0"))
          game.players[0].hand = @[baseCard("oozification-4")]
          game.players[0].energy = 4
          game.players[0].totalEnergy = 4
          let targetId = game.players[1].board[targetIndex].id
          if game.playCard(0, creatureChoice(1, targetId)):
            statusMessage = "Demo: Oozification."
        if getEnv("AWM_DEMO_PLAN") == "1":
          # Plan enters the board as a trinket and draws a card.
          animations.setLen(0)
          game.players[0].heroClass = Mage
          game.players[0].hand = @[baseCard("plan-3")]
          game.players[0].energy = 3
          game.players[0].totalEnergy = 3
          if game.playCard(0):
            statusMessage = "Demo: Plan."
        if getEnv("AWM_DEMO_STUDY") == "1":
          # Study draws two, then player 1 chooses a card to discard.
          animations.setLen(0)
          game.players[0].heroClass = Mage
          game.players[0].hand = @[baseCard("study-2"), baseCard("bouncer-1"),
            baseCard("plan-3")]
          game.players[0].energy = 2
          game.players[0].totalEnergy = 2
          if game.playCard(0):
            statusMessage = "Demo: Study."
        if getEnv("AWM_DEMO_PRIMORDIAL") == "1":
          # Primordial returns every other card, Plan included, to its
          # owner's hand (see AWM_DEMO_ENEMY_BOARD for the other side).
          animations.setLen(0)
          game.players[0].heroClass = Mage
          game.players[0].board.add MinionState(id: 5, owner: 0,
            card: baseCard("plan-3"), enteredTurn: game.turnNumber)
          game.nextMinionId = max(game.nextMinionId, 6)
          game.players[0].hand = @[baseCard("primordial-10")]
          game.players[0].energy = 10
          game.players[0].totalEnergy = 10
          if game.playCard(0):
            statusMessage = "Demo: Primordial."
        if getEnv("AWM_DEMO_SHARPSHOOTER_TARGET").len > 0:
          # Sharpshooter enters and shoots that enemy card.
          animations.setLen(0)
          let index = parseInt(getEnv("AWM_DEMO_SHARPSHOOTER_TARGET"))
          game.players[0].hand = @[baseCard("sharpshooter-3")]
          game.players[0].energy = 3
          game.players[0].totalEnergy = 3
          if game.playCard(0,
              creatureChoice(1, game.players[1].board[index].id)):
            statusMessage = "Demo: Sharpshooter."
        if getEnv("AWM_DEMO_PLAN_TRIGGER") == "1":
          # Plan fires at the start of player 1's next turn: the turn draw,
          # Plan's draw 0.25 s later, then Plan is destroyed.
          animations.setLen(0)
          game.players[0].heroClass = Mage
          game.players[0].board.add MinionState(id: 3, owner: 0,
            card: baseCard("plan-3"), enteredTurn: game.turnNumber)
          game.nextMinionId = 4
          game.finishTurn()
          discard game.takeVisualEvents()
          game.finishTurn()
          statusMessage = "Demo: Plan's trigger."
        if getEnv("AWM_DEMO_TRIGGER_TARGET") == "1":
          # A trinket's trigger waits for player 1 to pick its target.
          animations.setLen(0)
          let snare = Card(name: "Snare", energyCost: 0, kind: Trinket,
            class: some(Mage),
            rules: rules(on(nextTurn(You), damage(1, target({Minion})))))
          game.players[0].board.add MinionState(id: 3, owner: 0, card: snare,
            enteredTurn: game.turnNumber - 2)
          game.nextMinionId = 4
          game.pendingTriggers = @[PendingTrigger(owner: 0, sourceId: 3,
            trigger: 0)]

    window.onFrame = proc() =
      let dt = frameDelta(lastFrameTime)
      activeCameraPlayer = cameraPlayer()
      animationTime += dt
      animations.advanceAnimations(dt)
      discardFlights.advanceAnimations(dt)
      activeVfx.advance(dt)
      sk.uiScale = hudScale(window)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale

      if phase == ChooseClasses and not sessionOptions.human:
        botClassWait -= dt
        if botClassWait <= 0:
          let
            playerClass = visualRng.rand(HeroClass)
            opponentClass = visualRng.rand(HeroClass)
          selectedClass = playerClass
          game = newGame(playerClass, opponentClass, gameSeed())
          dyingMinions.setLen(0)
          queuedEvents.setLen(0)
          tossPicking = false
          discardFlights.setLen(0)
          phase = PlayGame
          animations.addDrawAnimation(game, game.currentPlayer,
            cameraPlayer().seatSide(),
            hidden = not handVisible(game.currentPlayer))
          botWait = 1.2'f32
          botPlays = 0
          statusMessage = "Watching bot match..."

      if phase == PlayGame and game.waitingToss and not tossPicking and
          not pendingTargeting and presentationIdle() and not attackActive and
          not game.gameOver:
        let pending = game.pendingToss
        if humanActs():
          tossPicking = true
          tossPicks.setLen(0)
          selectedAttacker = 0
          statusMessage = &"{pending.source}: choose cards to discard."
        else:
          botWait -= dt
          if botWait <= 0:
            if game.applyBotAction(game.nextBotAction()):
              statusMessage = &"{pending.source}: the bot discards."
            botWait = 1.2'f32

      if phase == PlayGame and game.waitingTrigger and
          not game.waitingToss and not pendingTargeting and
          presentationIdle() and not attackActive and
          not game.gameOver:
        let waiting = game.waitingTriggerRules()
        if humanActs():
          pendingTargeting = true
          pendingTrigger = true
          pendingCard = waiting.card
          pendingCardIndex = -1
          pendingPicks.setLen(0)
          pendingChoices = game.triggerChoices()
          selectedAttacker = 0
          statusMessage = &"{waiting.card.name}'s trigger needs a target."
        else:
          botWait -= dt
          if botWait <= 0:
            let before = game.copyGameState()
            if game.applyBotAction(game.nextBotAction()):
              animations.animateTransition(before, game,
                cameraPlayer().seatSide())
              statusMessage = &"{waiting.card.name}'s trigger resolves."
            botWait = 1.2'f32

      if phase == PlayGame and botVms[game.currentPlayer] != nil and
          not game.waitingChoice and
          presentationIdle() and not attackActive and
          not game.gameOver:
        botWait -= dt
        if botWait <= 0:
          let current = game.currentPlayer
          discard game.takeVisualEvents()
          let before = game.copyGameState()
          let decision = botVms[current].runDecision(game)
          case decision
          of BotPlayedCard:
            animations.animateTransition(before, game,
              cameraPlayer().seatSide())
            inc botPlays
            statusMessage = "Bot is playing..."
          of BotEndedTurn:
            let attackers = game.eligibleAttackers()
            if attackers.len > 0:
              attackActive = true
              attackSteps = attackers
              attackTarget = heroChoice((game.currentPlayer + 1) mod PlayerCount)
              attackPoint = attackPointFor(attackTarget)
              attackIndex = 0
              attackForward = true
              attackElapsed = 0
              attackDamageApplied = false
              attackFinishTurn = true
              statusMessage = "Bot is attacking..."
            else:
              game.finishTurn()
              animations.animateTransition(before, game,
                cameraPlayer().seatSide())
              botPlays = 0
              if botVms[game.currentPlayer] == nil:
                statusMessage = "Your turn. Select a card to play."
              else:
                statusMessage = "Bot is thinking..."
          of BotFailed:
            statusMessage = "Bot error: " & botVms[current].lastError
          botWait = 1.2'f32

      if attackActive:
        attackElapsed += dt
        if attackForward:
          if attackElapsed >= AttackLungeDuration:
            if not attackDamageApplied:
              discard game.attack(attackSteps[attackIndex], attackTarget)
              attackDamageApplied = true
            attackForward = false
            attackElapsed = 0
        else:
          if attackElapsed >= AttackReturnDuration:
            inc attackIndex
            if attackIndex >= attackSteps.len:
              attackActive = false
              selectedAttacker = 0
              if attackFinishTurn and not game.gameOver:
                let before = game.copyGameState()
                game.finishTurn()
                animations.animateTransition(before, game,
                  cameraPlayer().seatSide())
                botPlays = 0
                botWait = 1.2'f32
                if botVms[game.currentPlayer] == nil:
                  statusMessage = "Your turn. Select a card to play."
                else:
                  statusMessage = "Bot is thinking..."
            else:
              attackForward = true
              attackElapsed = 0
              attackDamageApplied = false

      let
        aspect = window.size.x.float32 / max(window.size.y.float32, 1)
        currentSide =
          if phase == PlayGame:
            cameraPlayer().seatSide()
          else:
            1.0'f32
        cameraEye =
          if phase == ChooseClasses:
            vec3(0, 6.2, 13.5)
          else:
            vec3(
              0,
              GameCameraHeight,
              GameCameraDistance * currentSide
            )
        cameraTarget =
          if phase == ChooseClasses:
            vec3(0, 1.0, 0)
          else:
            vec3(0, 0, 0)
        view = lookAt(cameraEye, cameraTarget, vec3(0, 1, 0))
        projection = perspective(42.0'f32, aspect, 0.1'f32, 100.0'f32)
        viewProjection = projection * view

      var
        hoverIndex = -1
        hoveredTarget = Canceled
        hoveredBoard = Canceled
      if phase == PlayGame:
        if tossPicking:
          hoverIndex = hoveredCard(window, viewProjection, game, currentSide,
            handOwner = game.pendingToss.player)
        elif humanTurn() or (botVms[0] != nil and botVms[1] != nil):
          hoverIndex = hoveredCard(
            window, viewProjection, game, currentSide
          )
        if hoverIndex < 0:
          var boardChoices: seq[Choice]
          for owner in 0 ..< PlayerCount:
            for minion in game.players[owner].board:
              if not animations.boardCardSuppressed(minion.id) and
                  not queuedEvents.queuedSummon(minion.id):
                boardChoices.add creatureChoice(owner, minion.id)
          hoveredBoard = hoveredCreatureTarget(window, viewProjection,
            game, boardChoices, dyingMinions)
        if tossPicking and humanActs() and presentationIdle() and
            not game.gameOver:
          let pending = game.pendingToss
          if window.buttonPressed[KeyEscape] or
              window.buttonPressed[MouseRight]:
            tossPicks.setLen(0)
            statusMessage = "Discard picks cleared."
          elif window.buttonPressed[MouseLeft] and hoverIndex >= 0:
            let at = tossPicks.find(hoverIndex)
            if at >= 0:
              tossPicks.delete(at)
            else:
              tossPicks.add hoverIndex
            if tossPicks.len == pending.count:
              let picks = tossPicks
              tossPicking = false
              tossPicks.setLen(0)
              statusMessage =
                if game.resolvePendingToss(picks): &"{pending.source}: discarded."
                else: "Those cards can't be discarded."
        elif humanTurn() and presentationIdle() and
            not pendingTargeting and not attackActive and not game.gameOver:
          if hoverIndex >= 0 and
              window.buttonPressed[MouseLeft] and
              not finishRect(window).contains(sk.mousePos):
            let
              player = game.players[game.currentPlayer]
              card = player.hand[hoverIndex]
            if card.energyCost > player.energy:
              statusMessage =
                &"Not enough energy to play {card.name}."
            elif card.needsChoice():
              if card.kind != Spell:
                let
                  sourcePose = handPoses(
                    game.currentPlayer,
                    player.hand.len,
                    currentSide
                  )[hoverIndex]
                  minionId = game.playMinion(hoverIndex)
                if minionId != 0:
                  # Its own slot, counting only the cards up to it: minions
                  # its rules summon come after it and appear later.
                  let
                    playedIndex = game.minionLocation(minionId).index
                    destinationPose = dyingMinions.liveBoardPose(
                      game.currentPlayer, playedIndex, playedIndex + 1)
                  animations.add newCardAnimation(
                    card,
                    player.heroClass,
                    sourcePose,
                    destinationPose,
                    suppressBoardId = minionId
                  )
                  pendingCard = card
                  pendingCardIndex = -1
                  pendingPicks.setLen(0)
                  pendingChoices = game.availableChoices(card)
                  hoverIndex = -1
                  if pendingChoices.selectableTargetCount() == 0:
                    discard game.runMinionRules(card, NoTarget,
                      sourceId = minionId)
                    pendingChoices.setLen(0)
                    statusMessage =
                      &"{card.name} enters play without a target."
                  else:
                    pendingTargeting = true
                    selectedAttacker = 0
                    statusMessage =
                      &"{card.name} enters play. Click a highlighted minion or the empty board."
              else:
                pendingCard = card
                pendingCardIndex = hoverIndex
                pendingPicks.setLen(0)
                pendingChoices = game.availableChoices(hoverIndex)
                if pendingChoices.len == 0:
                  pendingCardIndex = -1
                  pendingChoices.setLen(0)
                  statusMessage =
                    &"{card.name} has no valid targets."
                else:
                  pendingTargeting = true
                  selectedAttacker = 0
                  statusMessage =
                    &"Click the highlighted avatar for {card.name}."
            else:
              let sourcePose = handPoses(
                game.currentPlayer,
                player.hand.len,
                currentSide
              )[hoverIndex]
              case card.kind
              of Minion, Trinket:
                let minionId = game.playMinion(hoverIndex)
                if minionId != 0:
                  discard game.runMinionRules(card, sourceId = minionId)
                  # Its own slot, counting only the cards up to it: minions
                  # its rules summon come after it and appear later.
                  let
                    playedIndex = game.minionLocation(minionId).index
                    destinationPose = dyingMinions.liveBoardPose(
                      game.currentPlayer, playedIndex, playedIndex + 1)
                  animations.add newCardAnimation(
                    card,
                    player.heroClass,
                    sourcePose,
                    destinationPose,
                    suppressBoardId = minionId
                  )
                  statusMessage = &"{card.name} enters the board."
                  hoverIndex = -1
              of Spell:
                if game.playCard(hoverIndex):
                  let destinationPose = stackTopPose(
                    discardPose(game.currentPlayer),
                    game.players[game.currentPlayer].discardPile.len
                  )
                  animations.add newCardAnimation(
                    card,
                    player.heroClass,
                    sourcePose,
                    destinationPose,
                    suppressDiscardOwner = game.currentPlayer
                  )
                  statusMessage =
                    &"{card.name} resolves and is discarded."
                  hoverIndex = -1
          elif window.buttonPressed[MouseLeft] and
              not finishRect(window).contains(sk.mousePos):
            let
              attackable =
                if selectedAttacker != 0: game.attackTargets(selectedAttacker)
                else: @[]
              clicked = hoveredWorldTarget(window, viewProjection, game,
                attackable, dyingMinions)
            if not clicked.isCanceled:
              attackActive = true
              attackSteps = @[selectedAttacker]
              attackTarget = clicked
              attackPoint = attackPointFor(clicked)
              attackIndex = 0
              attackForward = true
              attackElapsed = 0
              attackDamageApplied = false
              attackFinishTurn = false
              statusMessage = "Attacking!"
            elif hoveredBoard.kind == CreatureChoice and
                hoveredBoard.owner == game.currentPlayer:
              let minionId = hoveredBoard.creatureId
              if minionId == selectedAttacker:
                selectedAttacker = 0
                statusMessage = "Attack canceled."
              elif game.attackTargets(minionId).len > 0:
                selectedAttacker = minionId
                statusMessage =
                  "Click an enemy minion or hero to attack. Right-click cancels."
              else:
                statusMessage = "That minion can't attack this turn."
          elif selectedAttacker != 0 and
              (window.buttonPressed[MouseRight] or
                window.buttonPressed[KeyEscape]):
            selectedAttacker = 0
            statusMessage = "Attack canceled."
        elif humanActs() and pendingTargeting and presentationIdle() and
            not game.gameOver:
          hoveredTarget = hoveredWorldTarget(
            window,
            viewProjection,
            game,
            pendingChoices,
            dyingMinions
          )
          let
            card = pendingCard
            pendingRules =
              if pendingTrigger: game.waitingTriggerRules().rules
              else: card.rules
          if pendingTrigger and (window.buttonPressed[KeyEscape] or
              window.buttonPressed[MouseRight]):
            statusMessage =
              &"{card.name}'s trigger can't be canceled: choose a target."
          elif window.buttonPressed[KeyEscape] or
              window.buttonPressed[MouseRight]:
            if card.kind != Spell:
              discard game.runMinionRules(card, NoTarget)
              statusMessage =
                &"{card.name}'s rule finishes without a target."
            else:
              statusMessage = &"{card.name} canceled."
            pendingTargeting = false
            pendingCardIndex = -1
            pendingChoices.setLen(0)
          elif window.buttonPressed[MouseLeft] and
              not finishRect(window).contains(sk.mousePos):
            var selectedChoice = hoveredTarget
            if selectedChoice.isCanceled and
                card.kind != Spell and
                hoverIndex < 0 and
                mouseOverBoard(window, viewProjection) and
                pendingChoices.choiceIsLegal(NoTarget):
              selectedChoice = NoTarget
            if not selectedChoice.isCanceled and
                pendingPicks.len + 1 < pendingRules.targetCount():
              # More targets to choose (Duel): keep the pick, offer the next.
              pendingPicks.add selectedChoice
              pendingChoices =
                if pendingTrigger:
                  game.triggerChoices(pendingPicks)
                elif card.kind != Spell:
                  game.availableChoices(card, pendingPicks)
                else:
                  game.availableChoices(pendingCardIndex, pendingPicks)
              statusMessage =
                &"Choose target {pendingPicks.len + 1} of " &
                  &"{pendingRules.targetCount()} for {card.name}."
            elif not selectedChoice.isCanceled:
              var
                spellAnimation = false
                spellSourcePose: CardPose
                spellClass: HeroClass
              if card.kind == Spell and
                  pendingCardIndex >= 0 and
                  pendingCardIndex <
                    game.players[game.currentPlayer].hand.len:
                spellAnimation = true
                spellClass =
                  game.players[game.currentPlayer].heroClass
                spellSourcePose = handPoses(
                  game.currentPlayer,
                  game.players[game.currentPlayer].hand.len,
                  currentSide
                )[pendingCardIndex]
              let resolved =
                if pendingTrigger:
                  game.resolvePendingTrigger(pendingPicks & selectedChoice)
                elif card.kind != Spell:
                  game.runMinionRules(card, pendingPicks & selectedChoice)
                else:
                  game.playCard(pendingCardIndex, pendingPicks & selectedChoice)
              if resolved and spellAnimation:
                let destinationPose = stackTopPose(
                  discardPose(game.currentPlayer),
                  game.players[game.currentPlayer].discardPile.len
                )
                animations.add newCardAnimation(
                  card,
                  spellClass,
                  spellSourcePose,
                  destinationPose,
                  suppressDiscardOwner = game.currentPlayer
                )
              if resolved:
                statusMessage =
                  if pendingTrigger:
                    &"{card.name}'s trigger resolves."
                  elif card.kind != Spell:
                    if selectedChoice.isNoTarget:
                      &"{card.name}'s rule finishes without a target."
                    else:
                      &"{card.name}'s rule resolves."
                  else:
                    &"{card.name} resolves and is discarded."
              else:
                statusMessage = &"{card.name} could not resolve."
              pendingTargeting = false
              pendingTrigger = false
              pendingCardIndex = -1
              pendingChoices.setLen(0)

      when defined(takeScreenshot):
        if getEnv("AWM_DEMO_HALO") == "1":
          if pendingTargeting:
            for choice in pendingChoices:
              if choice.kind == CreatureChoice:
                hoveredBoard = choice
                hoveredTarget = choice
                break
              elif choice.kind == HeroChoice:
                hoveredTarget = choice
                break
          else:
            hoverIndex = 0

      var
        attackHoverTarget = Canceled
        attackChoices: seq[Choice]
      if selectedAttacker != 0 and not attackActive:
        attackChoices = game.attackTargets(selectedAttacker)
        if attackChoices.len == 0:
          # The attacker left the board or can no longer attack.
          selectedAttacker = 0
      if humanTurn() and attackChoices.len > 0 and
          not pendingTargeting and presentationIdle():
        attackHoverTarget = hoveredWorldTarget(window, viewProjection, game,
          attackChoices, dyingMinions)

      if phase == PlayGame:
        # Visual events play beat by beat. A beat waits until the previous
        # beats' animations and effects finish; a draw right after a draw
        # only waits 0.25 s, so draws overlap. Until its beat plays, a slain
        # card holds its place and a summoned or drawn card stays hidden.
        for event in game.takeVisualEvents():
          if event.kind == DeathVfx:
            var dying = DyingMinion(target: event.target, card: event.card,
              power: event.power,
              heroClass: game.players[event.target.owner].heroClass,
              boardIndex: event.boardIndex, held: true)
            if attackActive and attackIndex < attackSteps.len and
                attackSteps[attackIndex] == event.target.creatureId:
              # A slain attacker stays where its lunge landed.
              dying.atLunge = true
              dying.lungePoint = attackLungePoint(dyingMinions.liveBoardPose(
                event.target.owner, event.boardIndex, event.boardCount))
            dyingMinions.add dying
          elif event.kind == BounceVfx:
            # Keep the card in its slot until its beat sends it home.
            dyingMinions.add DyingMinion(target: event.target, card: event.card,
              heroClass: game.players[event.target.owner].heroClass,
              boardIndex: event.boardIndex, held: true, bouncing: true)
          queuedEvents.add event
        # Before any beat plays: VFX positions are fixed when they start, so
        # the layout must already leave out summons that haven't appeared.
        countHiddenSummons()
        while queuedEvents.len > 0:
          let beat = queuedEvents[0].beat
          var
            count = 0
            drawOnly = true
          while count < queuedEvents.len and queuedEvents[count].beat == beat:
            if queuedEvents[count].kind != DrawVfx:
              drawOnly = false
            inc count
          # A slain card whose death already played is part of that beat's
          # animation until it has left the board for its discard pile.
          var slainLeaving = discardFlights.len > 0
          for dying in dyingMinions:
            if not dying.held:
              slainLeaving = true
          let ready =
            if drawOnly and lastBeatWasDraw:
              animationTime - lastDrawStart >= 0.25'f32
            else:
              animations.len == 0 and activeVfx.len == 0 and not slainLeaving
          if not ready:
            break
          for event in queuedEvents[0 ..< count]:
            case event.kind
            of DrawVfx:
              let owner = event.target.owner
              animations.addDrawAnimation(game, owner,
                cameraPlayer().seatSide(), hidden = not handVisible(owner),
                handIndex = event.boardIndex)
            of DeathVfx:
              for dying in dyingMinions.mitems:
                if dying.held and dying.target == event.target:
                  dying.held = false
                  break
            of SummonVfx:
              discard  # Leaving the queue is what reveals the minion.
            of TossVfx:
              let owner = event.target.owner
              animations.add newCardAnimation(event.card,
                game.players[owner].heroClass,
                handPoses(owner, max(1, event.boardCount),
                  cameraPlayer().seatSide())[
                    clamp(event.handIndex, 0, max(0, event.boardCount - 1))],
                stackTopPose(discardPose(owner),
                  game.players[owner].discardPile.len),
                suppressDiscardOwner = owner)
            of BounceVfx:
              let
                owner = event.target.owner
                source = presentedCardPose(event.target, event.boardIndex,
                  event.boardCount)
              for i in 0 ..< dyingMinions.len:
                if dyingMinions[i].bouncing and
                    dyingMinions[i].target == event.target:
                  dyingMinions.delete(i)
                  break
              var flight = newCardAnimation(event.card,
                game.players[owner].heroClass, source,
                handPoses(owner, max(1, game.players[owner].hand.len),
                  cameraPlayer().seatSide())[
                    clamp(event.handIndex, 0,
                      max(0, game.players[owner].hand.len - 1))],
                arcHeight = 1.15'f32, suppressHandOwner = owner,
                suppressHandIndex = event.handIndex, duration = 0.82'f32,
                trackingTarget = event.target,
                hidden = not handVisible(owner))
              # Its bubble (same beat) forms first, then rides along.
              flight.elapsed = -0.2'f32
              animations.add flight
            else:
              let position =
                if event.target.kind == HeroChoice:
                  avatarPosition(event.target.owner) + vec3(0, 1.25, 0)
                else:
                  presentedCardPose(event.target, event.boardIndex,
                    event.boardCount).position + vec3(0, CardHeight, 0)
              activeVfx.add newVfx(event.kind, event.target, position,
                visualRng.rand(0x7fff_ffff))
          queuedEvents = queuedEvents[count .. ^1]
          lastBeatWasDraw = drawOnly
          if drawOnly:
            lastDrawStart = animationTime
          countHiddenSummons()
        for effect in activeVfx.mitems:
          if effect.kind == BubbleVfx:
            for animation in animations:
              if animation.trackingTarget == effect.target:
                effect.position = animation.animationPose().position + vec3(0, CardHeight, 0)
        for i in countdown(dyingMinions.high, 0):
          let dying = dyingMinions[i]
          var effectsPending = false
          for effect in activeVfx:
            if effect.target == dying.target:
              effectsPending = true
          if not effectsPending and not dying.held:
            let owner = dying.target.owner
            discardFlights.add newCardAnimation(dying.card, dying.heroClass,
              dyingMinions.dyingPose(i, game.players[owner].board.len),
              stackTopPose(discardPose(owner),
                game.players[owner].discardPile.len),
              suppressDiscardOwner = owner)
            dyingMinions.delete(i)

      solid.clear()
      cardSurfaces.clear()
      vfx.clear()
      if phase == ChooseClasses:
        solid.addBox(
          vec3(0, -0.3, 0),
          vec3(15, 0.55, 7),
          vec4(0.20, 0.24, 0.30, 1),
          sideFactor = 0.5
        )
        for heroClass in HeroClass:
          let x = (heroClass.ord.float32 - 1.0'f32) * 4.2'f32
          solid.addBox(
            vec3(x, 0.05, 0),
            vec3(3.0, 0.18, 3.0),
            heroClass.classColor().darker(0.72),
            sideFactor = 0.55
          )
      else:
        solid.addBox(
          vec3(0, -0.32, 0),
          vec3(BoardWidth, 0.64, BoardDepth),
          vec4(0.20, 0.27, 0.25, 1),
          sideFactor = 0.42
        )
        solid.addBox(
          vec3(0, 0.015, 0),
          vec3(0.16, 0.03, BoardDepth - 0.5),
          vec4(0.73, 0.55, 0.20, 1),
          sideFactor = 0.8
        )
        for playerIndex in 0 ..< PlayerCount:
          let
            player = game.players[playerIndex]
            hiddenDiscardCards =
              animations.discardCardsSuppressed(playerIndex) +
              discardFlights.discardCardsSuppressed(playerIndex) +
              dyingDiscards(playerIndex)
          solid.addDeckZone(playerIndex, player.heroClass)
          solid.addCardStack(
            cardSurfaces, sk,
            deckPose(playerIndex),
            player.deck.len,
            player.heroClass,
          )
          solid.addCardStack(
            cardSurfaces, sk,
            discardPose(playerIndex),
            max(0, player.discardPile.len - hiddenDiscardCards),
            player.heroClass,
            hidden = false,
            card =
              if player.discardPile.len > hiddenDiscardCards:
                player.discardPile[player.discardPile.high - hiddenDiscardCards]
              else:
                Card()
          )
          for minionIndex in 0 ..< player.board.len:
            let
              pose = dyingMinions.liveBoardPose(playerIndex, minionIndex,
                player.board.len)
              minion = player.board[minionIndex]
              minionChoice = creatureChoice(
                playerIndex,
                minion.id
              )
              targetable =
                (pendingTargeting and
                  pendingChoices.choiceIsLegal(minionChoice)) or
                attackChoices.choiceIsLegal(minionChoice)
              attackerSelected =
                playerIndex == game.currentPlayer and
                minion.id == selectedAttacker
            if animations.boardCardSuppressed(minion.id) or
                queuedEvents.queuedSummon(minion.id):
              continue
            if attackActive and attackIndex < attackSteps.len and
                attackSteps[attackIndex] == minion.id:
              continue
            solid.addCard(
              cardSurfaces, sk,
              pose,
              player.heroClass,
              false,
              true,
              hoveredBoard == minionChoice or attackerSelected,
              targetable or attackerSelected,
              card = minion.card,
              currentPower = minion.power,
              currentToughness = minion.currentToughness,
              damageFlash = activeVfx.flashStrength(minionChoice),
              lostKeywords = minion.lostKeywords
            )
            vfx.addCardGlow(pose,
                hoveredBoard == minionChoice or attackerSelected,
                targetable or attackerSelected,
                pendingTargeting or attackerSelected,
                animationTime)

        let current = cameraPlayer()
        for i, pose in handPoses(
            current,
            game.players[current].hand.len,
            currentSide
        ):
          if animations.handCardSuppressed(current, i) or
              queuedEvents.queuedDraw(current, i):
            continue
          let
            card = game.players[current].hand[i]
            tossingHere = tossPicking and current == game.pendingToss.player
            picked = tossingHere and i in tossPicks
          solid.addCard(
            cardSurfaces, sk,
            pose,
            game.players[current].heroClass,
            not handVisible(current),
            (humanTurn() and card.energyCost <= game.players[current].energy) or
              tossingHere,
            (
              i == hoverIndex or
              (pendingTargeting and i == pendingCardIndex)
            ),
            targetable = picked,
            card = card
          )
          vfx.addCardGlow(pose,
              i == hoverIndex or (pendingTargeting and i == pendingCardIndex),
              picked, pendingTargeting or tossingHere, animationTime)

        let opponent = (current + 1) mod PlayerCount
        for i, pose in handPoses(
            opponent,
            game.players[opponent].hand.len,
            currentSide
        ):
          if animations.handCardSuppressed(opponent, i) or
              queuedEvents.queuedDraw(opponent, i):
            continue
          solid.addCard(
            cardSurfaces, sk,
            pose,
            game.players[opponent].heroClass,
            not handVisible(opponent),
            false,
            false,
            card = game.players[opponent].hand[i]
          )

        for animation in animations & discardFlights:
          solid.addCard(
            cardSurfaces, sk,
            animation.animationPose(),
            animation.heroClass,
            animation.hidden,
            true,
            false,
            card = animation.card
          )

        for i, dying in dyingMinions:
          solid.addCard(
            cardSurfaces, sk,
            dyingMinions.dyingPose(i,
              game.players[dying.target.owner].board.len),
            dying.heroClass,
            false, true, false,
            card = dying.card,
            currentPower = dying.power,
            currentToughness = 0,
            damageFlash = activeVfx.flashStrength(dying.target)
          )

        if attackActive and attackIndex < attackSteps.len:
          let
            atkMinionId = attackSteps[attackIndex]
            atkLocation = game.minionLocation(atkMinionId)
          if atkLocation.found:
            let
              atkMinion = game.players[atkLocation.player].board[atkLocation.index]
              atkFromPose = dyingMinions.liveBoardPose(atkLocation.player,
                atkLocation.index, game.players[atkLocation.player].board.len)
              atkForwardPos = CardPose(position: attackLungePoint(atkFromPose),
                yaw: atkFromPose.yaw)
              atkDuration = if attackForward: AttackLungeDuration
                else: AttackReturnDuration
              atkRaw = clamp(attackElapsed / atkDuration, 0.0'f32, 1.0'f32)
              atkEased = atkRaw * atkRaw * (3.0'f32 - 2.0'f32 * atkRaw)
            var atkPose: CardPose
            if attackForward:
              atkPose.position = atkFromPose.position +
                (atkForwardPos.position - atkFromPose.position) * atkEased
              atkPose.position.y += sin(PI.float32 * atkRaw) * 0.8'f32
            else:
              atkPose.position = atkForwardPos.position +
                (atkFromPose.position - atkForwardPos.position) * atkEased
              atkPose.position.y += sin(PI.float32 * atkRaw) * 0.4'f32
            atkPose.yaw = atkFromPose.yaw
            solid.addCard(
              cardSurfaces, sk,
              atkPose,
              game.players[atkLocation.player].heroClass,
              false, true, false,
              card = atkMinion.card,
              currentPower = atkMinion.power,
              currentToughness = atkMinion.currentToughness,
              lostKeywords = atkMinion.lostKeywords
            )
            vfx.addCardGlow(atkPose, true, true, true, animationTime)

      glClearColor(0.035, 0.045, 0.065, 1)
      glStencilMask(0xff)
      glClearStencil(0)
      glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT or GL_STENCIL_BUFFER_BIT)
      solid.draw(viewProjection)
      cardSurfaces.draw(sk, viewProjection)

      scene.setToonHour(14)
      beginCharacters(scene, window, view, projection, cameraEye)
      glEnable(GL_STENCIL_TEST)
      glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE)
      glStencilFunc(GL_ALWAYS, 0, 0xff)
      if phase == ChooseClasses:
        for heroClass in HeroClass:
          let
            x = (heroClass.ord.float32 - 1.0'f32) * 4.2'f32
            chosen = selectedClass == heroClass
          drawCharacter(
            scene,
            models[heroClass],
            vec3(x, 0.15, 0),
            0,
            idleClips[heroClass],
            animationTime,
            tint =
              if chosen:
                color(1.08, 1.08, 1.08, 1)
              else:
                color(1, 1, 1, 1),
            sizeFactor = if chosen: 1.06'f32 else: 1.0'f32
          )
      else:
        for playerIndex in 0 ..< PlayerCount:
          let
            player = game.players[playerIndex]
            heroTarget = heroChoice(playerIndex)
            spellTargetable =
              pendingTargeting and
              pendingChoices.choiceIsLegal(heroTarget)
            attackTargetable =
              attackChoices.choiceIsLegal(heroTarget) and not pendingTargeting
            targetable = spellTargetable or attackTargetable
            spellTargetHovered = spellTargetable and hoveredTarget == heroTarget
            attackTargetHovered = attackTargetable and
              attackHoverTarget == heroTarget
            targetHovered = spellTargetHovered or attackTargetHovered
            damageFlash = activeVfx.flashStrength(heroTarget)
          glStencilFunc(GL_ALWAYS, (playerIndex + 1).GLint, 0xff)
          if targetable:
            vfx.addTargetRing(avatarPosition(playerIndex) + vec3(0, 0.04, 0),
              cameraEye, 0.95, if targetHovered: 1.1'f32 else: 0.28'f32)
          drawCharacter(
            scene,
            models[player.heroClass],
            avatarPosition(playerIndex),
            if playerIndex == 0: PI.float32 else: 0,
            idleClips[player.heroClass],
            animationTime,
            tint =
              if damageFlash > 0:
                color(1.0, 1.0, 1.0, 1)
              elif targetHovered:
                color(1.5, 0.52, 0.52, 1)
              elif targetable:
                color(1.18, 0.85, 0.85, 1)
              elif pendingTargeting:
                color(0.52, 0.52, 0.58, 1)
              elif playerIndex == game.currentPlayer:
                color(1.08, 1.08, 1.08, 1)
              else:
                color(0.72, 0.72, 0.78, 1),
            sizeFactor =
              if targetHovered:
                1.08'f32
              elif targetable:
                1.02'f32
              elif playerIndex == game.currentPlayer:
                1.0'f32
              else:
                0.92'f32
          )
      finishCharacters(scene)
      glDisable(GL_STENCIL_TEST)
      if phase == PlayGame:
        for playerIndex in 0 ..< PlayerCount:
          vfx.drawCharacterFlash(playerIndex + 1,
            activeVfx.flashStrength(heroChoice(playerIndex)))
        if attackActive and not attackTarget.isCanceled:
          vfx.addTargetRing(
            attackPoint + vec3(0, 0.04, 0),
            cameraEye, 0.95, 0.8'f32)
        vfx.addEffects(activeVfx, cameraEye)
        vfx.draw(viewProjection)

      glDisable(GL_DEPTH_TEST)
      glDisable(GL_CULL_FACE)
      glDisable(GL_BLEND)
      when not defined(emscripten):
        glDisable(GL_MULTISAMPLE)
      glActiveTexture(GL_TEXTURE0)
      glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
      sk.beginUi(window, window.size)
      sk.mousePos = window.mousePos.vec2 / sk.uiScale

      if phase == ChooseClasses:
        sk.drawRect(
          vec2(0),
          vec2(hudSize(window).x, 180),
          rgbx(14, 17, 24, 238)
        )
        sk.drawLabel(
          "ARCHERS | WARRIORS | MAGES",
          vec2(0, 15),
          vec2(hudSize(window).x, 78),
          rgbx(243, 218, 153, 255),
          "H1",
          CenterAlign
        )
        sk.drawLabel(
          (if sessionOptions.human: "CHOOSE YOUR CLASS"
           else: "BOTS ARE CHOOSING CLASSES..."),
          vec2(0, 104),
          vec2(hudSize(window).x, 48),
          rgbx(221, 225, 233, 255),
          "Default",
          CenterAlign
        )
        if sessionOptions.human:
          for heroClass in HeroClass:
            let
              x = hudSize(window).x * 0.5'f32 +
                (heroClass.ord.float32 - 1.0'f32) * 400.0'f32
              rect = UiRect(
                origin: vec2(x - 140, hudSize(window).y - 180),
                size: vec2(280, 84)
              )
            if drawButton(
                sk,
                window,
                rect,
                heroClass.className(),
                heroClass.classUiColor()
            ):
              selectedClass = heroClass
              game = newGame(
                heroClass,
                sessionOptions.opponentClass,
                gameSeed()
              )
              dyingMinions.setLen(0)
              queuedEvents.setLen(0)
              tossPicking = false
              discardFlights.setLen(0)
              phase = PlayGame
              animations.addDrawAnimation(game, game.currentPlayer,
                cameraPlayer().seatSide(),
                hidden = not handVisible(game.currentPlayer))
              botWait = 1.2'f32
              botPlays = 0
              if game.currentPlayer == 0:
                statusMessage = "Your turn. Select a card to play."
              else:
                statusMessage = "Your opponent is thinking..."
      else:
        drawPlayerPanel(sk, window, game, 0)
        drawPlayerPanel(sk, window, game, 1)
        sk.drawLabel(
          &"TURN {game.turnNumber} | PLAYER {game.currentPlayer + 1}",
          vec2(PlayerPanelWidth + 58, 31),
          vec2(
            hudSize(window).x - (PlayerPanelWidth + 58) * 2,
            42
          ),
          game.players[game.currentPlayer].heroClass.classUiColor(),
          "Default",
          CenterAlign
        )
        sk.drawLabel(
          statusMessage,
          vec2(PlayerPanelWidth + 58, 79),
          vec2(
            hudSize(window).x - (PlayerPanelWidth + 58) * 2,
            32
          ),
          rgbx(205, 209, 219, 255),
          "Small",
          CenterAlign
        )
        drawCardReadingView(
          sk,
          window,
          game,
          viewProjection,
          animations,
          hoverIndex,
          false,
          dying = dyingMinions,
          discardFlights = discardFlights,
          queued = queuedEvents,
          handOwner = if tossPicking: game.pendingToss.player else: -1,
          canPlayCards = humanTurn()
        )
        drawDeckLabels(sk, window, game, viewProjection)
        sk.drawLabel(
          if attackActive:
            "Minions are attacking..."
          elif selectedAttacker != 0:
            "Click an enemy minion or hero to attack. Right-click cancels."
          elif tossPicking:
            "Click cards in your hand to discard them."
          elif pendingTargeting and pendingTrigger:
            "Select a highlighted target in the 3D world, or the empty board for none."
          elif pendingTargeting and pendingCard.kind != Spell:
            "Select a highlighted target in the 3D world. Right-click: no target."
          elif pendingTargeting:
            "Select a highlighted target in the 3D world. Right-click cancels."
          elif sessionOptions.human:
            "YOUR GAME | You are Player 1 | Your opponent is a bot"
          else:
            "Hover to inspect a card.",
          vec2(30, hudSize(window).y - 88),
          vec2(640, 36),
          rgbx(186, 190, 201, 255),
          "Small"
        )
        let finish = finishRect(window)
        if drawButton(
            sk,
            window,
            finish,
            (if not humanTurn(): "OPPONENT" else: "FINISH TURN"),
            rgbx(179, 126, 46, 255),
            enabled =
              humanTurn() and
              not game.waitingChoice and
              not pendingTargeting and
              not attackActive and
              not game.gameOver and
              presentationIdle()
        ):
          selectedAttacker = 0
          game.finishTurn()
          botWait = 1.2'f32
          botPlays = 0
          statusMessage = "Your opponent is thinking..."
          pendingTargeting = false
          pendingCardIndex = -1
          pendingChoices.setLen(0)

        if tossPicking:
          let
            pending = game.pendingToss
            accent = game.players[pending.player].heroClass.classUiColor()
            ask =
              if pending.count == 1: "Choose a card to discard."
              else: &"Choose {pending.count} cards to discard " &
                &"({tossPicks.len} of {pending.count} chosen)."
            banner = UiRect(
              origin: vec2(hudSize(window).x * 0.5'f32 - 430, 204),
              size: vec2(860, 112)
            )
          sk.drawRect(banner.origin, banner.size, rgbx(18, 21, 30, 244))
          sk.drawRect(banner.origin, vec2(banner.size.x, 5), accent)
          sk.drawLabel(ask, banner.origin + vec2(22, 10),
            vec2(banner.size.x - 44, 30), accent, "Hud", CenterAlign)
          sk.drawLabel(&"{pending.source}: {pending.text}",
            banner.origin + vec2(22, 46), vec2(banner.size.x - 44, 28),
            rgbx(216, 220, 230, 255), "Small", CenterAlign)
          sk.drawLabel("Click cards in your hand. Right-click clears your picks.",
            banner.origin + vec2(22, 76), vec2(banner.size.x - 44, 28),
            rgbx(160, 166, 180, 255), "Small", CenterAlign)

        if pendingTargeting:
          let
            card = pendingCard
            rules =
              if pendingTrigger: game.waitingTriggerRules().rules
              else: card.rules
            step = pendingPicks.len
            count = rules.targetCount()
            # The rules' own text: "Choose a minion." for "Deal 1 damage to
            # a minion."
            prompt = rules.targetPrompt(card, step)
            accent =
              game.players[game.actingPlayer()].heroClass.classUiColor()
            progress = if count > 1: &" ({step + 1} of {count})" else: ""
            source = if pendingTrigger: &"{card.name}'s trigger" else: card.name
            hint =
              if pendingTrigger:
                "Click the empty board for no target."
              elif card.kind != Spell:
                "Right-click or the empty board: no target."
              else:
                "Right-click cancels."
            banner = UiRect(
              origin: vec2(
                hudSize(window).x * 0.5'f32 - 430,
                204
              ),
              size: vec2(860, 112)
            )
          sk.drawRect(banner.origin, banner.size, rgbx(18, 21, 30, 244))
          sk.drawRect(banner.origin, vec2(banner.size.x, 5), accent)
          sk.drawLabel(
            prompt.choose & progress,
            banner.origin + vec2(22, 10),
            vec2(banner.size.x - 44, 30),
            accent,
            "Hud",
            CenterAlign
          )
          sk.drawLabel(
            &"{source}: {prompt.rule}",
            banner.origin + vec2(22, 46),
            vec2(banner.size.x - 44, 28),
            rgbx(216, 220, 230, 255),
            "Small",
            CenterAlign
          )
          sk.drawLabel(
            hint,
            banner.origin + vec2(22, 76),
            vec2(banner.size.x - 44, 28),
            rgbx(160, 166, 180, 255),
            "Small",
            CenterAlign
          )

        if selectedAttacker != 0 and not pendingTargeting:
          let
            accent =
              game.players[game.currentPlayer].heroClass.classUiColor()
            instruction =
              if attackActive: "Attacking!"
              else: "Click an enemy minion or hero. Right-click cancels."
            banner = UiRect(
              origin: vec2(
                hudSize(window).x * 0.5'f32 - 430,
                204
              ),
              size: vec2(860, 84)
            )
          sk.drawRect(banner.origin, banner.size, rgbx(18, 21, 30, 244))
          sk.drawRect(banner.origin, vec2(banner.size.x, 5), accent)
          sk.drawLabel(
            "COMBAT",
            banner.origin + vec2(22, 10),
            vec2(banner.size.x - 44, 30),
            accent,
            "Hud",
            CenterAlign
          )
          sk.drawLabel(
            instruction,
            banner.origin + vec2(22, 46),
            vec2(banner.size.x - 44, 28),
            rgbx(216, 220, 230, 255),
            "Small",
            CenterAlign
          )

        if game.gameOver and presentationIdle() and not attackActive:
          let
            winnerAccent =
              game.players[game.winner].heroClass.classUiColor()
            winnerText =
              if sessionOptions.human:
                (if game.winner == 0: "YOU WIN!" else: "YOU LOSE!")
              else:
                &"PLAYER {game.winner + 1} WINS!"
            winnerDetail =
              &"Turn {game.turnNumber} — " &
              game.players[game.winner].heroClass.className() &
              " is victorious."
            overlay = UiRect(
              origin: vec2(
                hudSize(window).x * 0.5'f32 - 380,
                hudSize(window).y * 0.5'f32 - 80),
              size: vec2(760, 160))
          sk.drawRect(overlay.origin - vec2(4), overlay.size + vec2(8),
            rgbx(0, 0, 0, 180))
          sk.drawRect(overlay.origin, overlay.size, rgbx(14, 17, 24, 250))
          sk.drawRect(overlay.origin, vec2(overlay.size.x, 6),
            winnerAccent)
          sk.drawLabel(
            winnerText,
            overlay.origin + vec2(0, 18),
            vec2(overlay.size.x, 70),
            winnerAccent,
            "H1",
            CenterAlign
          )
          sk.drawLabel(
            winnerDetail,
            overlay.origin + vec2(0, 100),
            vec2(overlay.size.x, 40),
            rgbx(205, 209, 219, 255),
            "Default",
            CenterAlign
          )

      when defined(emscripten):
        let role = if sessionOptions.human: "Human player" else: "Bot match"
        var summary = role & ". " & statusMessage
        if phase == PlayGame:
          summary.add &" Turn {game.turnNumber}. Active player {game.currentPlayer + 1}."
          for owner, player in game.players:
            summary.add &" Player {owner + 1} {player.heroClass.className()}: life {player.life}, energy {player.energy}/{player.totalEnergy}, hand {player.hand.len}, board {player.board.len}, deck {player.deck.len}, discard {player.discardPile.len}."
          if humanTurn() and not pendingTargeting and
              presentationIdle():
            summary.add " Ready for your action."
        publishStatus(summary.cstring)

      sk.endUi()
      when defined(takeScreenshot):
        if existsEnv("AWM_CAPTURE_SEQUENCE"):
          inc screenshotFrame
          if screenshotFrame mod 2 == 0:
            let
              outputDir = getEnv("AWM_CAPTURE_SEQUENCE")
              frameImage = newImage(window.size.x, window.size.y)
            createDir(outputDir)
            glReadPixels(0, 0, window.size.x.GLsizei, window.size.y.GLsizei,
              GL_RGBA, GL_UNSIGNED_BYTE, frameImage.data[0].addr)
            frameImage.flipVertical()
            frameImage.writeFile(outputDir / &"frame-{screenshotFrame div 2:04}.png")
          if screenshotFrame >= max(2, parseInt(getEnv("AWM_CAPTURE_FRAME", "120"))):
            quit(0)
        else:
          captureScreenshot(
            window,
            screenshotFrame,
            (if existsEnv("AWM_CAPTURE_FRAME"): max(1, parseInt(getEnv("AWM_CAPTURE_FRAME")))
              elif getEnv("AWM_CAPTURE_SETTLED") == "1": 80 else: 20),
            appDir / "awm_shot.png"
          )
      window.swapBuffers()

    while not window.closeRequested:
      pollEvents()

  when isMainModule:
    runAwm()

when defined(headless):
  when isMainModule:
    echo "AWM headless module loaded."
