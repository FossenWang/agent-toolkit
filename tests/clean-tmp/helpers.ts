import { rmSync } from "node:fs"
import { mkdir, mkdtemp, rm, stat, utimes, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

export const DAY = 24 * 60 * 60 * 1000

// TMPDIR 是进程级变量，测试结束后必须还回去，否则同进程里后面的测试都会指到已删除目录
const originalTmpDir = process.env.TMPDIR

const restoreEnv = () => {
  if (originalTmpDir === undefined) delete process.env.TMPDIR
  else process.env.TMPDIR = originalTmpDir
}

/** 插件在模块加载时算 TMP，所以测试目录要在 import 插件之前定下来 */
export const prepareRoot = async () => {
  const root = await mkdtemp(join(tmpdir(), "clean-tmp-test-"))
  process.env.TMPDIR = root
  return { root, tmp: join(root, "opencode") }
}

/** 正常结束时恢复；中断时用同步版本，避免退出前目录已被删 */
export const restoreRoot = async (root: string) => {
  await rm(root, { recursive: true, force: true })
  restoreEnv()
}

export const restoreRootSync = (root: string) => {
  rmSync(root, { recursive: true, force: true })
  restoreEnv()
}

export const resetTmp = async (tmp: string) => {
  await rm(tmp, { recursive: true, force: true })
  await mkdir(tmp, { recursive: true })
}

export const oldFile = async (path: string, days: number) => {
  await writeFile(path, "x")
  const when = new Date(Date.now() - days * DAY)
  await utimes(path, when, when)
}

export const exists = async (path: string) => {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

/** 内存版 ctx.storage；preset 用于预置 lastSweep 之类的键 */
export const memoryStorage = (preset: Record<string, unknown> = {}) => {
  const data = new Map(Object.entries(preset))
  return {
    data,
    get: async (key: string) => data.get(key),
    set: async (key: string, value: unknown) => void data.set(key, value),
    remove: async (key: string) => void data.delete(key),
  }
}

/** 手动推送事件的异步流；close 或 abort 都能让迭代结束 */
export const eventQueue = () => {
  const items: { type: string; data: { sessionID: string } }[] = []
  let wake: (() => void) | undefined
  let closed = false

  const push = (type = "session.execution.succeeded") => {
    items.push({ type, data: { sessionID: "ses_test" } })
    wake?.()
  }

  const close = () => {
    closed = true
    wake?.()
  }

  const iterate = async function* (signal?: AbortSignal) {
    for (;;) {
      if (closed || signal?.aborted) return
      if (items.length === 0) {
        await new Promise<void>((resolve) => {
          wake = resolve
          signal?.addEventListener("abort", () => resolve(), { once: true })
        })
        wake = undefined
        continue
      }
      yield items.shift()
    }
  }

  return { push, close, iterate }
}

/** 轮询等待异步副作用落地 */
export const waitFor = async (check: () => boolean | Promise<boolean>, timeout = 2000) => {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    if (await check()) return
    await Bun.sleep(10)
  }
  throw new Error("timed out waiting for condition")
}
