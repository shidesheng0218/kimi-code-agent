import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { existsSync } from "node:fs"
import { execFileSync, spawnSync } from "node:child_process"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const packageJSON = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"))
const version = process.env.KIMI_VERSION || packageJSON.version
const arch = process.arch === "arm64" ? "arm64" : "x64"
const outRoot = path.join(root, "release-native")
const appRoot = path.join(outRoot, "Kimi Code Agent.app")
const contents = path.join(appRoot, "Contents")
const resources = path.join(contents, "Resources")
const macos = path.join(contents, "MacOS")
const swiftBin = execFileSync("swift", ["build", "--package-path", "macos", "--configuration", "release", "--product", "KimiCodeAgent"], { cwd: root, encoding: "utf8", stdio: "inherit" })
void swiftBin
const nativeBin = execFileSync("swift", ["build", "--package-path", "macos", "--configuration", "release", "--product", "KimiNativeBridge"], { cwd: root, encoding: "utf8", stdio: "inherit" })
void nativeBin
const binDirectory = execFileSync("swift", ["build", "--package-path", "macos", "--configuration", "release", "--show-bin-path"], { cwd: root, encoding: "utf8" }).trim()

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: root, stdio: "inherit", env: { ...process.env, ...options.env } })
  if (result.status !== 0) throw new Error(`${command} exited with ${result.status ?? "unknown"}`)
}

await rm(outRoot, { recursive: true, force: true })
await mkdir(macos, { recursive: true })
await mkdir(path.join(resources, "runtime"), { recursive: true })
await mkdir(path.join(resources, "native"), { recursive: true })

const opencodePackage = path.join(root, "vendor/opencode/packages/opencode")
const pluginSource = path.join(root, "vendor/opencode/packages/kimi-code-agent-plugin/src/index.ts")
const pluginBundle = path.join(resources, "kimi-native-plugin.mjs")

// Compile OpenCode into a standalone Bun executable so released users do not
// need Bun, Node, or Electron installed locally.
run("npx", ["--yes", "bun@1.3.14", "run", "--cwd", opencodePackage, "script/build.ts", "--single", "--skip-install", "--skip-embed-web-ui"], {
  env: { OPENCODE_MODELS_URL: "http://127.0.0.1:9" },
})
const openCodeBinary = path.join(opencodePackage, "dist", `opencode-darwin-${arch}`, "bin", "opencode")
if (!existsSync(openCodeBinary)) throw new Error(`OpenCode standalone binary missing: ${openCodeBinary}`)

run("npx", ["--yes", "bun@1.3.14", "build", pluginSource, "--outfile", pluginBundle, "--target", "bun", "--format", "esm"])

await cp(path.join(binDirectory, "KimiCodeAgent"), path.join(macos, "KimiCodeAgent"))
await cp(path.join(binDirectory, "KimiNativeBridge"), path.join(resources, "native/KimiNativeBridge"))
await cp(openCodeBinary, path.join(resources, "runtime/opencode"))

const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Kimi Code Agent</string>
<key>CFBundleExecutable</key><string>KimiCodeAgent</string>
<key>CFBundleIdentifier</key><string>com.kimicode.agent</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Kimi Code Agent</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${version}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Kimi Code Agent</string><key>CFBundleURLSchemes</key><array><string>kimi-code-agent</string></array></dict></array>
</dict></plist>
`
await mkdir(path.join(contents, "Resources"), { recursive: true })
await writeFile(path.join(contents, "Info.plist"), plist)
await writeFile(path.join(contents, "PkgInfo"), "APPL????")

const identity = process.env.CSC_NAME?.trim()
if (identity) {
  run("codesign", ["--deep", "--force", "--options", "runtime", "--sign", identity, appRoot])
} else {
  // Swift toolchain binaries may carry an incompatible ad-hoc signature. A
  // fresh ad-hoc signature makes local/GitHub test artifacts structurally
  // verifiable while remaining explicit that they are not notarized.
  run("codesign", ["--deep", "--force", "--sign", "-", appRoot])
  console.warn("No Developer ID configured; using ad-hoc signing (not notarized).")
}

const zip = path.join(outRoot, `Kimi-Code-Agent-${version}-mac-${arch}.zip`)
const dmg = path.join(outRoot, `Kimi-Code-Agent-${version}-mac-${arch}.dmg`)
run("ditto", ["-c", "-k", "--keepParent", appRoot, zip])
run("hdiutil", ["create", "-volname", "Kimi Code Agent", "-srcfolder", appRoot, "-ov", "-format", "UDZO", dmg])
console.log(`Native package created: ${zip}`)
console.log(`Native package created: ${dmg}`)
