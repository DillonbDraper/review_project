const registry = new Map()
let nextId = 1

function now() {
  return Math.round(performance.now())
}

function createProbe(id) {
  return {
    id,
    createdAt: now(),
    touchCount: 0,
    actionCount: 0,
    destroyed: false,
    marker: `probe-${id}`
  }
}

function summary(probe) {
  if (!probe || probe.destroyed) return [0, 0, 0, false]

  return [
    probe.touchCount,
    probe.actionCount,
    now() - probe.createdAt,
    true
  ]
}

function touch(probe, increments = 1) {
  if (!probe || probe.destroyed) return summary(probe)

  probe.actionCount += 1

  for (let i = 0; i < increments; i += 1) {
    probe.touchCount += 1
  }

  return summary(probe)
}

export default {
  dispatchActions(actionName, target = "page", count = 1) {
    for (let i = 0; i < count; i += 1) {
      setTimeout(() => {
        globalThis.Hologram?.dispatchAction(actionName, target, { source: "reference_exercise", index: i })
      }, i)
    }

    return count
  },

  createDirect() {
    return createProbe("direct")
  },

  touchDirect(probe, increments = 1) {
    return touch(probe, increments)
  },

  destroyDirect(probe) {
    if (!probe) return false
    probe.destroyed = true
    return true
  },

  createRegistryObject() {
    const id = `registry-${nextId}`
    nextId += 1
    registry.set(id, createProbe(id))
    return [id]
  },

  touchRegistryObject(id, increments = 1) {
    return touch(registry.get(id), increments)
  },

  destroyRegistryObject(id) {
    const probe = registry.get(id)
    if (probe) probe.destroyed = true
    return registry.delete(id)
  }
}
