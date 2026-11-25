import { afterAll, beforeEach, describe, expect, test } from "bun:test"
import { lutimes, mkdir, readdir, rm, symlink, utimes, writeFile } from "node:fs/promises"
import { join } from "node:path"
import {
  DAY,
  eventQueue,
  exists,
  memoryStorage,
  oldFile,
  prepareRoot,
  resetTmp,
  waitFor,
} from "./helpers.ts"

// TMP 在模块加载时确定，所以先定测试目录再 import 插件
const { root, tmp } = await prepareRoot()
const { default: plugin } = await import("../../opencode/plugins/clean-tmp/index.ts")

type Ctx = Parameters<typeof plugin.setup>[0]

const setup = async (options: Record<string, unknown> = {}, storage = memoryStorage()) => {
  const queue = eventQueue()
  const ctx = {
    options,
    storage,
    event: {
      subscribe: ({ signal }: { signal?: AbortSignal }) => queue.iterate(signal),
    },
  } as unknown as Ctx

  const cleanup = (await plugin.setup(ctx)) as (() => void) | undefined
  return { queue, storage, cleanup }
}

/** 起一个插件实例，跑完保证卸载，避免事件循环残留 */
const withPlugin = async (
  options: Record<string, unknown>,
  storage: ReturnType<typeof memoryStorage>,
  body: (context: { queue: ReturnType<typeof eventQueue>; storage: typeof storage }) => Promise<void>,
) => {
  const { queue, cleanup } = await setup(options, storage)
  try {
    await body({ queue, storage })
  } finally {
    queue.close()
    cleanup?.()
  }
}

beforeEach(async () => {
  await resetTmp(tmp)
})

afterAll(async () => {
  await rm(root, { recursive: true, force: true })
})

describe("clean-tmp", () => {
  test("删除过期文件，保留新文件", async () => {
    await oldFile(join(tmp, "old.txt"), 8)
    await writeFile(join(tmp, "new.txt"), "x")

    await withPlugin({}, memoryStorage(), async ({ queue }) => {
      queue.push()
      await waitFor(async () => (await exists(join(tmp, "new.txt"))) && !(await exists(join(tmp, "old.txt"))))
      expect(await readdir(tmp)).toEqual(["new.txt"])
    })
  })

  test("过期目录被递归删除", async () => {
    const dir = join(tmp, "cache")
    await mkdir(join(dir, "nested"), { recursive: true })
    await writeFile(join(dir, "nested", "file"), "x")
    const when = new Date(Date.now() - 8 * DAY)
    await utimes(join(dir, "nested", "file"), when, when)
    await utimes(join(dir, "nested"), when, when)
    await utimes(dir, when, when)

    await withPlugin({}, memoryStorage(), async ({ queue }) => {
      queue.push()
      await waitFor(async () => !(await exists(dir)))
      expect(await readdir(tmp)).toEqual([])
    })
  })

  test("符号链接只删链接，不碰目标", async () => {
    const target = join(root, "victim.txt")
    await writeFile(target, "keep me")
    const link = join(tmp, "stale-link")
    await symlink(target, link)
    // utimes 跟随链接改的是目标；链接自己的 mtime 要用 lutimes
    const when = new Date(Date.now() - 8 * DAY)
    await lutimes(link, when, when)

    await withPlugin({}, memoryStorage(), async ({ queue }) => {
      queue.push()
      await waitFor(async () => !(await exists(link)))
      expect(await exists(target)).toBe(true)
    })
  })

  test("节流窗口内不重复清扫", async () => {
    await oldFile(join(tmp, "old.txt"), 8)
    const storage = memoryStorage({ lastSweep: Date.now() })

    await withPlugin({}, storage, async ({ queue }) => {
      queue.push()
      await Bun.sleep(150)
      expect(await exists(join(tmp, "old.txt"))).toBe(true)
      expect(storage.data.get("lastSweep")).toBeGreaterThan(0)
    })
  })

  test("自定义 maxAgeDays 生效", async () => {
    await oldFile(join(tmp, "two-days.txt"), 2)
    await writeFile(join(tmp, "fresh.txt"), "x")

    await withPlugin({ maxAgeDays: 1 }, memoryStorage(), async ({ queue }) => {
      queue.push()
      await waitFor(async () => !(await exists(join(tmp, "two-days.txt"))))
      expect(await readdir(tmp)).toEqual(["fresh.txt"])
    })
  })

  test("非法 options 让加载失败", async () => {
    for (const options of [{ maxAgeDays: 0 }, { maxAgeDays: "7" }, { minIntervalHours: -1 }, { maxAgeDays: Number.NaN }]) {
      await expect(setup(options)).rejects.toThrow(/must be a positive number/)
    }
  })

  test("目录不存在时静默返回，仍然记录清扫时间", async () => {
    await rm(tmp, { recursive: true, force: true })
    const storage = memoryStorage()

    await withPlugin({}, storage, async ({ queue }) => {
      queue.push()
      await waitFor(() => storage.data.has("lastSweep"))
    })
  })

  test("卸载后不再响应事件", async () => {
    const storage = memoryStorage()
    const { queue, cleanup } = await setup({}, storage)
    cleanup?.()

    queue.push()
    await Bun.sleep(100)
    expect(storage.data.has("lastSweep")).toBe(false)
  })
})
