import { Plugin } from "@opencode/plugin"
import { lstat, readdir, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

// OpenCode 自己的临时目录（`opencode debug paths tmp`），跟随 TMPDIR
const TMP = join(tmpdir(), "opencode")

const DEFAULTS = { maxAgeDays: 7, minIntervalHours: 24 }
const HOUR = 60 * 60 * 1000
const DAY = 24 * HOUR

// session.idle 在服务端事件流里不发，用同一时机的执行结束事件
const EXECUTION_END = [
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
] as const

const option = (value: unknown, fallback: number, name: string): number => {
  if (value === undefined) return fallback
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    throw new Error(`clean-tmp: options.${name} must be a positive number, got ${JSON.stringify(value)}`)
  }
  return value
}

export default Plugin.define({
  id: "clean-tmp",
  async setup(ctx) {
    // 配置错误直接抛：加载失败比拿错阈值静默清理更容易发现
    const maxAge = option(ctx.options?.maxAgeDays, DEFAULTS.maxAgeDays, "maxAgeDays") * DAY
    const minInterval = option(ctx.options?.minIntervalHours, DEFAULTS.minIntervalHours, "minIntervalHours") * HOUR
    const owner = process.getuid?.()

    const report = async (error: unknown) => {
      const code = (error as NodeJS.ErrnoException)?.code
      if (code === "ENOENT") return // 目录或条目已经不在了，属于正常
      if (code === "EACCES" || code === "EPERM") {
        // 目录不可写时只吭一声，否则插件会安静地永不生效
        if (await ctx.storage.get("warnedUnwritable")) return
        await ctx.storage.set("warnedUnwritable", true)
        console.warn(`[clean-tmp] cannot delete inside ${TMP} (${code}); cleanup stays a no-op until it is writable`)
        return
      }
      console.error("[clean-tmp]", error)
    }

    const sweep = async () => {
      let names: string[]
      try {
        names = await readdir(TMP)
      } catch (error) {
        await report(error)
        return
      }
      const now = Date.now()
      for (const name of names) {
        const path = join(TMP, name)
        try {
          // lstat 不跟随符号链接：删的是链接本身，不会顺着链接删到别处
          const info = await lstat(path)
          if (owner !== undefined && info.uid !== owner) continue // 别人的文件一律不碰
          if (now - info.mtimeMs <= maxAge) continue
          await rm(path, { recursive: true, force: true })
        } catch (error) {
          await report(error)
        }
      }
    }

    let running = false

    const sweepIfDue = async () => {
      if (running) return
      running = true
      try {
        const last = await ctx.storage.get("lastSweep")
        if (typeof last === "number" && Date.now() - last < minInterval) return
        // 先记时间再扫：扫失败也不要在每次执行结束时重试
        await ctx.storage.set("lastSweep", Date.now())
        await sweep()
      } catch (error) {
        await report(error)
      } finally {
        running = false
      }
    }

    // 执行结束时本轮已经收尾，清理不会和模型/工具调用抢 I/O
    const controller = new AbortController()
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({
          types: EXECUTION_END,
          signal: controller.signal,
        })) {
          if (
            event.type === "session.execution.succeeded" ||
            event.type === "session.execution.failed" ||
            event.type === "session.execution.interrupted"
          ) {
            // fire-and-forget：清理不阻塞事件处理
            void sweepIfDue()
          }
        }
      } catch (error) {
        // 插件卸载时 abort 属于正常退出
        if (!controller.signal.aborted) await report(error)
      }
    })()
    return () => controller.abort()
  },
})
