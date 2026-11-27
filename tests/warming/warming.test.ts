import { describe, expect, test } from "bun:test"
import { createFake, waitFor } from "./helpers.ts"

/** 所有用例都把间隔压到几十毫秒，避免真的等 25 分钟 */
const fast = { intervalMinutes: 0.002, tickSeconds: 0.01, maxIdleHours: 1 }

const withPlugin = async (
  options: Parameters<typeof createFake>[0],
  body: (fake: Awaited<ReturnType<typeof createFake>>) => Promise<void>,
) => {
  const fake = await createFake(options)
  try {
    await body(fake)
  } finally {
    fake.queue.close()
    await fake.cleanup()
  }
}

describe("warming", () => {
  test("默认不保温：没有开启的会话不发 ping", async () => {
    await withPlugin({ options: fast }, async (fake) => {
      await Bun.sleep(150)
      expect(fake.pings).toHaveLength(0)
    })
  })

  test("/warm on 之后到点自动 ping", async () => {
    await withPlugin({ options: fast }, async (fake) => {
      await fake.run("/warm on")
      await waitFor(() => fake.pings.length >= 1)
      expect(fake.pings.length).toBeGreaterThanOrEqual(1)
    })
  })

  test("缓存 miss 后停止调度", async () => {
    await withPlugin({ options: fast, usage: { read: 0, write: 200 } }, async (fake) => {
      await fake.run("/warm on")
      await waitFor(() => fake.pings.length >= 1)
      await Bun.sleep(150)
      expect(fake.pings).toHaveLength(1)
    })
  })

  test("缓存命中则按 interval 继续 ping", async () => {
    await withPlugin({ options: fast, usage: { read: 900, write: 10 } }, async (fake) => {
      await fake.run("/warm on")
      await waitFor(() => fake.pings.length >= 3, 3000)
      expect(fake.pings.length).toBeGreaterThanOrEqual(3)
    })
  })

  test("/warm off 之后不再 ping", async () => {
    await withPlugin({ options: fast }, async (fake) => {
      await fake.run("/warm on")
      await waitFor(() => fake.pings.length >= 1)
      await fake.run("/warm off")
      const before = fake.pings.length
      await Bun.sleep(200)
      expect(fake.pings.length).toBe(before)
    })
  })

  test("/warm now 立即 ping，不受 interval 影响", async () => {
    await withPlugin({ options: { ...fast, intervalMinutes: 60 } }, async (fake) => {
      await fake.run("/warm now")
      expect(fake.pings).toHaveLength(1)
    })
  })

  test("已归档的会话不 ping，并标记停止", async () => {
    await withPlugin({ options: fast, session: { time: { archived: 1 } } }, async (fake) => {
      await fake.run("/warm on")
      await fake.run("/warm now")
      expect(fake.pings).toHaveLength(0)
      const text = fake.synthetic.at(-1) ?? ""
      expect(text).toContain("archived")
    })
  })

  test("真实请求会重置下一次 ping 时间", async () => {
    await withPlugin({ options: { ...fast, intervalMinutes: 0.05 } }, async (fake) => {
      await fake.run("/warm on")
      await Bun.sleep(20)
      fake.queue.push("session.execution.succeeded")
      await Bun.sleep(20)
      const stored = fake.storage.data.get("warming:state") as {
        sessions: Record<string, { nextPingAt: number }>
      }
      const next = stored.sessions.ses_test.nextPingAt
      expect(next - Date.now()).toBeGreaterThan(2000)
    })
  })

  test("非执行事件不重置窗口", async () => {
    await withPlugin({ options: { ...fast, intervalMinutes: 0.05 } }, async (fake) => {
      await fake.run("/warm on")
      const stored = fake.storage.data.get("warming:state") as { sessions: Record<string, { nextPingAt: number }> }
      const before = stored.sessions.ses_test.nextPingAt
      fake.queue.push("session.updated")
      await Bun.sleep(50)
      const after = (fake.storage.data.get("warming:state") as typeof stored).sessions.ses_test.nextPingAt
      expect(after).toBe(before)
    })
  })

  test("/warm status 列出已开启的会话", async () => {
    await withPlugin({ options: fast }, async (fake) => {
      await fake.run("/warm on")
      await fake.run("/warm status")
      const text = fake.synthetic.at(-1) ?? ""
      expect(text).toContain("warming")
      expect(text).toContain("ses_test")
    })
  })

  test("状态会写入 storage，重新加载后仍然有效", async () => {
    const fake = await createFake({ options: fast })
    try {
      await fake.run("/warm on")
      const stored = fake.storage.data.get("warming:state") as { sessions: Record<string, unknown> }
      expect(Object.keys(stored.sessions)).toContain("ses_test")
    } finally {
      fake.queue.close()
      await fake.cleanup()
    }
  })
})
