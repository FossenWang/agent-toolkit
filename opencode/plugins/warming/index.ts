import { Plugin } from "@opencode/plugin"

// 按会话保温：默认关闭，只对显式开启的 top-level session 定时发 ping。
// 与官方 warming 的区别是不做模型级配置、没有默认行为，必须逐个会话开启。

const DEFAULTS = {
  intervalMinutes: 25,
  maxIdleHours: 12,
  tickSeconds: 30,
  prompt: "This is a keep-alive request. Do not perform any work or use tools. Reply with exactly: OK",
}

const STORAGE_KEY = "warming:state"

/** 单个会话的保温状态，整体以 JSON 落到插件 storage */
type SessionState = {
  enabled: boolean
  /** 最近一次真实请求（不是 ping）的时间 */
  lastRealActivity: number
  lastPingAt?: number
  nextPingAt?: number
  lastResult?: "hit" | "miss" | "error"
  pings: number
  misses: number
  /** 停止原因；有值表示 enabled 仍为 true 但不再调度 */
  stopped?: string
}

type Persisted = { sessions: Record<string, SessionState> }

const fresh = (now: number): SessionState => ({
  enabled: true,
  lastRealActivity: now,
  nextPingAt: now,
  pings: 0,
  misses: 0,
})

const parseNumber = (value: unknown, fallback: number) => {
  const parsed = typeof value === "number" ? value : Number(value)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback
}

const clock = (time: number) => {
  const date = new Date(time)
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`
}

/** 命令文本可能带前导 `/warm`，也可能只有参数 */
const argsOf = (text: string) =>
  text
    .trim()
    .replace(/^\/warm\b/i, "")
    .trim()
    .split(/\s+/)
    .filter(Boolean)

export default Plugin.define({
  id: "warming",
  async setup(ctx) {
    const interval = parseNumber(ctx.options.intervalMinutes, DEFAULTS.intervalMinutes) * 60_000
    const maxIdle = parseNumber(ctx.options.maxIdleHours, DEFAULTS.maxIdleHours) * 3_600_000
    const tick = parseNumber(ctx.options.tickSeconds, DEFAULTS.tickSeconds) * 1_000
    const prompt = typeof ctx.options.prompt === "string" ? ctx.options.prompt : DEFAULTS.prompt

    // storage 里只有 JSON；读失败或格式不对时从空状态开始，不阻塞插件加载
    const load = async (): Promise<Map<string, SessionState>> => {
      try {
        const stored = (await ctx.storage.get(STORAGE_KEY)) as Persisted | undefined
        const sessions = stored?.sessions
        if (!sessions || typeof sessions !== "object") return new Map()
        return new Map(Object.entries(sessions))
      } catch {
        return new Map()
      }
    }

    const states = await load()
    const pinging = new Set<string>()

    const save = async () => {
      const sessions = Object.fromEntries(states)
      await ctx.storage.set(STORAGE_KEY, { sessions } as unknown as Parameters<typeof ctx.storage.set>[1])
    }

    // 自己的 ping 也会产生执行事件，不能把它当成用户回来了
    let savePending: Promise<void> | undefined
    const persist = () => {
      savePending ??= save().finally(() => {
        savePending = undefined
      })
      return savePending
    }

    const stop = async (sessionID: string, reason: string) => {
      const state = states.get(sessionID)
      if (!state) return
      state.stopped = reason
      state.nextPingAt = undefined
      await persist()
    }

    const enable = async (sessionID: string) => {
      const existing = states.get(sessionID)
      const now = Date.now()
      const state = existing ?? fresh(now)
      state.enabled = true
      state.stopped = undefined
      state.lastRealActivity = now
      state.nextPingAt = now + interval
      states.set(sessionID, state)
      await persist()
      return state
    }

    /** 一次 ping：命中则排下一次，miss 则停，异常则保留状态等下一次重试 */
    const ping = async (sessionID: string, force = false): Promise<SessionState | undefined> => {
      const state = states.get(sessionID)
      if (!state || !state.enabled || pinging.has(sessionID)) return state

      pinging.add(sessionID)
      try {
        const info = await ctx.session.get({ sessionID }).catch(() => undefined)
        if (info?.time?.archived) {
          await stop(sessionID, "archived")
          return state
        }
        if (info?.time?.busy) return state
        if (!force && Date.now() - state.lastRealActivity > maxIdle) {
          await stop(sessionID, "idle")
          return state
        }

        const result = await ctx.session.generate({ sessionID, prompt })
        const cache = result.tokens.cache
        state.lastPingAt = Date.now()
        state.pings += 1

        // 与官方 warming 同口径：写入多于读取说明缓存没命中
        if (cache.write > cache.read) {
          state.lastResult = "miss"
          state.misses += 1
          await stop(sessionID, "cache miss")
          return state
        }

        state.lastResult = "hit"
        state.nextPingAt = Date.now() + interval
        await persist()
        return state
      } catch {
        state.lastResult = "error"
        state.nextPingAt = Date.now() + interval
        await persist()
        return state
      } finally {
        pinging.delete(sessionID)
      }
    }

    const tickOnce = async () => {
      const now = Date.now()
      const due = [...states.entries()].filter(
        ([sessionID, state]) => state.enabled && !state.stopped && !pinging.has(sessionID) && (state.nextPingAt ?? 0) <= now,
      )
      await Promise.all(due.map(([sessionID]) => ping(sessionID)))
    }

    const timer = setInterval(() => void tickOnce(), tick)
    // Node/bun 下不阻止进程退出；测试里 cleanup 会清掉
    ;(timer as unknown as { unref?: () => void }).unref?.()

    // 真实请求会刷新保温窗口；归档/删除停止调度
    const abort = new AbortController()
    const listen = async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: abort.signal })) {
          const sessionID = (event as { data?: { sessionID?: string } }).data?.sessionID
          if (!sessionID || pinging.has(sessionID)) continue

          if (event.type === "session.deleted" || event.type === "session.archived") {
            await stop(sessionID, event.type === "session.deleted" ? "deleted" : "archived")
            continue
          }

          // 只把执行事件当作真实请求；消息更新、重命名之类不重置窗口
          if (!event.type.startsWith("session.execution.")) continue

          const state = states.get(sessionID)
          if (!state?.enabled) continue
          // ping 自己也会产生执行事件，事件可能晚于 generate 返回，用时间窗排除
          if (state.lastPingAt && Date.now() - state.lastPingAt < 5_000) continue
          state.lastRealActivity = Date.now()
          if (!state.stopped) state.nextPingAt = Date.now() + interval
          await persist()
        }
      } catch {
        // 事件流断开不影响已有 timer；下一次插件加载会重建订阅
      }
    }
    void listen()

    const status = () => {
      const rows = [...states.entries()]
      if (rows.length === 0) {
        return `warming · 未开启任何会话\n\n/warm on 开启当前会话`
      }
      const lines = rows.map(([sessionID, state]) => {
        const short = sessionID.length > 12 ? sessionID.slice(0, 12) : sessionID
        if (!state.enabled) return `· ${short} 关闭`
        if (state.stopped) return `✗ ${short} 已停：${state.stopped}`
        const next = state.nextPingAt ? clock(state.nextPingAt) : "—"
        const last = state.lastResult ?? "未 ping"
        return `✓ ${short} next ${next} · ${last} · ${state.pings} pings`
      })
      return [`warming · ${Math.round(interval / 60_000)}m 间隔 · 空闲 ${Math.round(maxIdle / 3_600_000)}h 停止`, "", ...lines].join("\n")
    }

    await ctx.command.transform((editor) =>
      editor.add({
        name: "warm",
        description: "按会话开启缓存保温",
        execute: async ({ sessionID, prompt: input }) => {
          const args = argsOf(input.text)
          const action = (args[0] ?? "status").toLowerCase()
          const say = (text: string) => ctx.session.synthetic({ sessionID, text, resume: false })

          switch (action) {
            case "on": {
              const state = await enable(sessionID)
              await say(`warming · 已开启\nnext ${clock(state.nextPingAt ?? Date.now())} · ${Math.round(interval / 60_000)}m 间隔`)
              return
            }
            case "off": {
              const state = states.get(sessionID)
              if (state) {
                state.enabled = false
                state.stopped = undefined
                state.nextPingAt = undefined
                await persist()
              }
              await say("warming · 已关闭")
              return
            }
            case "now": {
              await enable(sessionID)
              const state = await ping(sessionID, true)
              const result = state?.stopped ? `已停：${state.stopped}` : (state?.lastResult ?? "未 ping")
              await say(`warming · ${result}`)
              return
            }
            case "status":
              await say(status())
              return
            default:
              await say([status(), "", "/warm on|off|now|status"].join("\n"))
          }
        },
      }),
    )

    return async () => {
      abort.abort()
      clearInterval(timer)
      await savePending
    }
  },
})
