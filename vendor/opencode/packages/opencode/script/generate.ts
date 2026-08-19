import path from "path"
import { fileURLToPath } from "url"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const dir = path.resolve(__dirname, "..")

process.chdir(dir)

const modelsUrl = process.env.OPENCODE_MODELS_URL || "https://models.dev"
const vendoredSnapshot = process.env.OPENCODE_MODELS_SNAPSHOT || path.join(dir, "test/tool/fixtures/models-api.json")
const modelsTimeout = Math.min(Math.max(Number.parseInt(process.env.OPENCODE_MODELS_TIMEOUT_MS || "5000", 10) || 5000, 100), 15_000)

async function loadModelsData() {
  if (process.env.MODELS_DEV_API_JSON) return Bun.file(process.env.MODELS_DEV_API_JSON).text()

  try {
    const response = await fetch(`${modelsUrl}/api.json`, { signal: AbortSignal.timeout(modelsTimeout) })
    if (!response.ok) throw new Error(`models.dev returned ${response.status}`)
    const body = await response.text()
    if (!body.trim()) throw new Error("models.dev returned an empty catalog")
    console.log("Loaded models.dev snapshot")
    return body
  } catch (error) {
    const snapshot = Bun.file(vendoredSnapshot)
    if (!(await snapshot.exists())) throw error
    console.warn(`models.dev unavailable; using vendored snapshot at ${vendoredSnapshot}`)
    console.log("Loaded vendored models.dev snapshot")
    return snapshot.text()
  }
}

export const modelsData = await loadModelsData()
