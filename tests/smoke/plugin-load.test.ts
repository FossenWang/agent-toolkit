import { afterAll, expect, test } from "bun:test"
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

// 加载冒烟：用隔离的 HOME/XDG 和私有端口起一个 OpenCode 服务，
// 确认插件都被真实加载，而不是只在 fake ctx 里跑通。
const repo = join(import.meta.dir, "..", "..")
const plugins = ["clean-tmp", "title-local", "warming"].map((name) => ({
  name,
  dir: join(repo, "opencode", "plugins", name),
}))

const home = await mkdtemp(join(tmpdir(), "plugin-smoke-"))
const env = {
  ...process.env,
  HOME: home,
  XDG_CONFIG_HOME: join(home, ".config"),
  XDG_DATA_HOME: join(home, ".local", "share"),
  XDG_STATE_HOME: join(home, ".local", "state"),
  XDG_CACHE_HOME: join(home, ".cache"),
}

const opencode = Bun.which("opencode")

const run = async (args: string[]) => {
  const proc = Bun.spawn([opencode!, ...args], { cwd: home, env, stdout: "pipe", stderr: "pipe" })
  const [out, err] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()])
  return { code: await proc.exited, out, err }
}

const stopService = async () => {
  if (opencode) await run(["service", "stop"]).catch(() => undefined)
}

afterAll(async () => {
  await stopService()
  await rm(home, { recursive: true, force: true })
})

test.skipIf(!opencode)(
  "三个插件都能被 OpenCode 加载",
  async () => {
    const configDir = join(home, ".config", "opencode")
    await mkdir(configDir, { recursive: true })
    await writeFile(
      join(configDir, "opencode.jsonc"),
      JSON.stringify({ plugins: plugins.map((plugin) => plugin.dir) }, null, 2) + "\n",
    )

    // 私有端口，避免撞上机器上已经在跑的服务
    const port = 49000 + Math.floor(Math.random() * 1000)
    expect((await run(["service", "set", "port", String(port)])).code).toBe(0)
    expect((await run(["service", "start"])).code).toBe(0)

    // 服务先返回，插件是异步加载的；轮询到插件出现为止
    let list = ""
    for (let attempt = 0; attempt < 60; attempt++) {
      const result = await run(["plugin", "list"])
      list = result.out
      if (plugins.every((plugin) => list.includes(plugin.name))) break
      await Bun.sleep(500)
    }

    try {
      for (const plugin of plugins) {
        // 每个插件一行，且路径指向本仓库的源码目录
        const line = list.split("\n").find((row) => row.startsWith(plugin.name))
        expect(line).toBeDefined()
        expect(line).toContain(plugin.dir)
      }
      // 行首是 "-" 代表加载失败（ID 未注册）
      expect(list.split("\n").some((row) => row.startsWith("- "))).toBe(false)
    } finally {
      await stopService()
    }
  },
  90_000,
)
