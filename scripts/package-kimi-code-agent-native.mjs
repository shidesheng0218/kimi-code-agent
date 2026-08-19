import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { existsSync } from "node:fs"
import { execFileSync, spawnSync } from "node:child_process"
import path from "node:path"
import { fileURLToPath } from "node:url"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const packageJSON = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"))
const version = process.env.KIMI_VERSION || packageJSON.version
const arch = process.arch === "arm64" ? "arm64" : "x64"
// Sparkle update feed and EdDSA public key. The private key lives only in the
// release machine's Keychain (see README release process); losing it blocks
// future signed updates.
const sparkleFeedURL = process.env.KIMI_SPARKLE_FEED_URL || "https://raw.githubusercontent.com/shidesheng0218/kimi-code-agent/master/appcast.xml"
const sparklePublicEDKey = process.env.KIMI_SPARKLE_PUBLIC_ED_KEY || "O5pRt/D5H5bRb/3XmhS+wL7YvuOPK83p0S0QSGz4TTs="
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
const sparkleBinDir = path.join(root, "macos/.cache/sparkle-bin/bin")
const signUpdateTool = path.join(sparkleBinDir, "sign_update")

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
// App icon rendered from media/kimi-readme.svg via scripts/generate-icon.sh.
const iconSource = path.join(root, "media/AppIcon.icns")
if (!existsSync(iconSource)) throw new Error(`App icon missing: ${iconSource}. Run scripts/generate-icon.sh first.`)
await cp(iconSource, path.join(resources, "AppIcon.icns"))
// Sparkle ships as Sparkle.framework (with bundled XPC services inside its
// Resources). Embed it so the packaged app can self-update without extra
// installs; the executable's rpath points at ../Frameworks.
const sparkleFrameworkSource = path.join(binDirectory, "Sparkle.framework")
if (!existsSync(sparkleFrameworkSource)) throw new Error(`Sparkle.framework missing from build output: ${sparkleFrameworkSource}`)
const frameworksDir = path.join(contents, "Frameworks")
await mkdir(frameworksDir, { recursive: true })
await cp(sparkleFrameworkSource, path.join(frameworksDir, "Sparkle.framework"), { recursive: true, verbatimSymlinks: true })

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
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Kimi Code Agent</string><key>CFBundleURLSchemes</key><array><string>kimi-code-agent</string></array></dict></array>
<key>SUFeedURL</key><string>${sparkleFeedURL}</string>
<key>SUPublicEDKey</key><string>${sparklePublicEDKey}</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
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

// Always emit SHA256SUMS next to the artifacts so a release never ships without
// checksums (the release-native dir is wiped at the start of every run).
const shaOutput = execFileSync("shasum", ["-a", "256", path.basename(zip), path.basename(dmg)], { cwd: outRoot, encoding: "utf8" })
await writeFile(path.join(outRoot, "SHA256SUMS.txt"), shaOutput, "utf8")
console.log(`SHA256 written: ${path.join(outRoot, "SHA256SUMS.txt")}`)

// Sparkle EdDSA signature for the ZIP. sign_update reads the private key from
// the release machine's Keychain and prints sparkle:edSignature / length.
if (existsSync(signUpdateTool)) {
  const signatureOutput = execFileSync(signUpdateTool, [zip], { cwd: root, encoding: "utf8" }).trim()
  const signatureMatch = signatureOutput.match(/sparkle:edSignature="([^"]+)"/)
  const lengthMatch = signatureOutput.match(/length="(\d+)"/)
  if (!signatureMatch || !lengthMatch) throw new Error(`sign_update produced unexpected output: ${signatureOutput}`)
  await writeFile(path.join(outRoot, `Kimi-Code-Agent-${version}-mac-${arch}.zip.sparkle.txt`), `${signatureMatch[1]} ${lengthMatch[1]}\n`, "utf8")
  console.log(`Sparkle signature written: release-native/Kimi-Code-Agent-${version}-mac-${arch}.zip.sparkle.txt`)

  const tag = `v${version}`
  const zipName = path.basename(zip)
  const downloadURL = `https://github.com/shidesheng0218/kimi-code-agent/releases/download/${tag}/${zipName}`
  const notesURL = `https://github.com/shidesheng0218/kimi-code-agent/releases/tag/${tag}`
  run("node", [
    "scripts/update-appcast.mjs",
    "--version", version,
    "--build", version.replaceAll(".", ""),
    "--url", downloadURL,
    "--signature", signatureMatch[1],
    "--length", lengthMatch[1],
    "--notes", notesURL
  ])
} else {
  console.warn(`sign_update not found at ${signUpdateTool}; skipping Sparkle signature and appcast update. Run the Sparkle toolchain setup to enable auto-update releases.`)
}
