const registry = new Map()

const emptyStats = () => ({
  sampleCount: 0,
  strokeCount: 0,
  latestPoint: null,
  lastStatsAt: 0
})

function dispatch(actionName, target, params = {}) {
  if (globalThis.Hologram?.dispatchAction) {
    globalThis.Hologram.dispatchAction(actionName, target, params)
  }
}

function getCanvasPoint(canvas, event) {
  const rect = canvas.getBoundingClientRect()
  const x = Math.min(Math.max((event.clientX - rect.left) / rect.width, 0), 1)
  const y = Math.min(Math.max((event.clientY - rect.top) / rect.height, 0), 1)

  return {
    x,
    y,
    t: Math.round(performance.now())
  }
}

function pointText(point) {
  return point ? `${point.x.toFixed(3)}, ${point.y.toFixed(3)}` : "—"
}

function configureCanvas(canvas) {
  const rect = canvas.getBoundingClientRect()
  const dpr = globalThis.devicePixelRatio || 1
  const width = Math.max(Math.round(rect.width * dpr), 1)
  const height = Math.max(Math.round(rect.height * dpr), 1)

  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width
    canvas.height = height
  }

  const ctx = canvas.getContext("2d")
  ctx.setTransform(width, 0, 0, height, 0, 0)
  ctx.lineCap = "round"
  ctx.lineJoin = "round"
  ctx.lineWidth = 0.0045
  ctx.strokeStyle = "#67e8f9"

  return { ctx, width, height }
}

function drawStroke(ctx, points, color = "#67e8f9") {
  if (!points || points.length === 0) return

  ctx.save()
  ctx.lineCap = "round"
  ctx.lineJoin = "round"
  ctx.lineWidth = 0.0045
  ctx.strokeStyle = color
  ctx.beginPath()
  ctx.moveTo(points[0].x, points[0].y)

  for (const point of points.slice(1)) {
    ctx.lineTo(point.x, point.y)
  }

  ctx.stroke()
  ctx.restore()
}

function drawSegment(ctx, from, to) {
  ctx.save()
  ctx.beginPath()
  ctx.moveTo(from.x, from.y)
  ctx.lineTo(to.x, to.y)
  ctx.stroke()
  ctx.restore()
}

function ensureProbe(canvasId, target = "page") {
  const existing = registry.get(canvasId)
  if (existing) return existing

  const canvas = document.getElementById(canvasId)
  if (!canvas) {
    throw new Error(`Canvas not found: ${canvasId}`)
  }

  const { ctx, width, height } = configureCanvas(canvas)
  const probe = {
    canvas,
    ctx,
    target,
    width,
    height,
    drawing: false,
    currentStroke: null,
    strokes: [],
    stats: emptyStats(),
    cleanupCallbacks: []
  }

  const sendStats = (force = false) => {
    const now = performance.now()
    if (!force && now - probe.stats.lastStatsAt < 250) return
    probe.stats.lastStatsAt = now

    dispatch("canvas_stats", probe.target, {
      sample_count: probe.stats.sampleCount,
      latest_point: probe.stats.latestPoint,
      latest_point_text: pointText(probe.stats.latestPoint)
    })
  }

  const pointerDown = event => {
    event.preventDefault()
    canvas.setPointerCapture?.(event.pointerId)

    const point = getCanvasPoint(canvas, event)
    probe.drawing = true
    probe.currentStroke = {
      color: "#67e8f9",
      points: [point]
    }
    probe.stats.sampleCount += 1
    probe.stats.latestPoint = point
    sendStats(true)
  }

  const pointerMove = event => {
    if (!probe.drawing || !probe.currentStroke) return
    event.preventDefault()

    const point = getCanvasPoint(canvas, event)
    const points = probe.currentStroke.points
    const previous = points[points.length - 1]
    points.push(point)
    probe.stats.sampleCount += 1
    probe.stats.latestPoint = point
    drawSegment(probe.ctx, previous, point)
    sendStats(false)
  }

  const finishStroke = event => {
    if (!probe.drawing || !probe.currentStroke) return
    event.preventDefault()

    probe.drawing = false
    const stroke = probe.currentStroke
    probe.currentStroke = null
    probe.strokes.push(stroke)
    probe.stats.strokeCount += 1

    dispatch("stroke_recorded", probe.target, {
      stroke,
      point_count: stroke.points.length,
      sample_count: probe.stats.sampleCount,
      latest_point: probe.stats.latestPoint,
      latest_point_text: pointText(probe.stats.latestPoint)
    })
  }

  const resize = () => {
    const previousStrokes = [...probe.strokes]
    const { ctx: nextCtx, width: nextWidth, height: nextHeight } = configureCanvas(canvas)
    probe.ctx = nextCtx
    probe.width = nextWidth
    probe.height = nextHeight
    clearCanvas(probe)
    previousStrokes.forEach(stroke => drawStroke(probe.ctx, stroke.points, stroke.color))
  }

  canvas.addEventListener("pointerdown", pointerDown)
  canvas.addEventListener("pointermove", pointerMove)
  canvas.addEventListener("pointerup", finishStroke)
  canvas.addEventListener("pointercancel", finishStroke)
  globalThis.addEventListener("resize", resize)

  probe.cleanupCallbacks.push(() => canvas.removeEventListener("pointerdown", pointerDown))
  probe.cleanupCallbacks.push(() => canvas.removeEventListener("pointermove", pointerMove))
  probe.cleanupCallbacks.push(() => canvas.removeEventListener("pointerup", finishStroke))
  probe.cleanupCallbacks.push(() => canvas.removeEventListener("pointercancel", finishStroke))
  probe.cleanupCallbacks.push(() => globalThis.removeEventListener("resize", resize))

  registry.set(canvasId, probe)
  return probe
}

function clearCanvas(probe) {
  probe.ctx.save()
  probe.ctx.setTransform(1, 0, 0, 1, 0, 0)
  probe.ctx.clearRect(0, 0, probe.canvas.width, probe.canvas.height)
  probe.ctx.restore()
}

export default {
  initialize(canvasId, target = "page") {
    const probe = ensureProbe(canvasId, target)
    clearCanvas(probe)

    dispatch("canvas_ready", target, {
      width: probe.width,
      height: probe.height,
      sample_count: probe.stats.sampleCount
    })

    return true
  },

  redraw(canvasId, strokes = []) {
    const probe = ensureProbe(canvasId)
    clearCanvas(probe)
    probe.strokes = strokes
    strokes.forEach(stroke => drawStroke(probe.ctx, stroke.points, stroke.color))
    return true
  },

  clear(canvasId) {
    const probe = ensureProbe(canvasId)
    clearCanvas(probe)
    probe.strokes = []
    probe.currentStroke = null
    probe.drawing = false
    probe.stats = emptyStats()
    return true
  },

  destroy(canvasId) {
    const probe = registry.get(canvasId)
    if (!probe) return false
    probe.cleanupCallbacks.forEach(callback => callback())
    registry.delete(canvasId)
    return true
  }
}
