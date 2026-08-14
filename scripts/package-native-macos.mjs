import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { access, cp, mkdir, readFile, rm, writeFile, chmod } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const productName = 'Kimi Agent Desktop';
const defaultVersion = '0.3.0';
const defaultArch = 'arm64';

export function releaseVersion(environment = process.env) {
  const raw = (environment.KIMI_VERSION ?? defaultVersion).trim().replace(/^v/, '');
  if (!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(raw)) {
    throw new Error(`KIMI_VERSION 必须是语义化版本，例如 1.4.0；当前为：${raw}`);
  }
  return raw;
}

function productArch(arch) {
  if (arch === 'x64') return 'x86_64';
  return arch;
}

function swiftTripleArch(arch) {
  const normalized = productArch(arch);
  if (normalized === 'x86_64') return 'x86_64';
  return normalized;
}

export function nativeRuntimeResourceNames() {
  return ['kimi.mjs', 'package.json', 'agent-host.cjs'];
}

export function nativeNodeDistribution(nodeVersion, arch = defaultArch) {
  const nodeArch = arch === 'x86_64' ? 'x64' : arch;
  if (!['arm64', 'x64'].includes(nodeArch)) {
    throw new Error(`Unsupported Node architecture: ${arch}`);
  }
  const archiveName = `node-v${nodeVersion}-darwin-${nodeArch}.tar.gz`;
  return {
    archiveName,
    archiveURL: `https://nodejs.org/dist/v${nodeVersion}/${archiveName}`,
    checksumsURL: `https://nodejs.org/dist/v${nodeVersion}/SHASUMS256.txt`
  };
}

export function nativeArtifactPaths(rootDir, arch = defaultArch) {
  const normalizedArch = productArch(arch);
  const releaseDirectory = path.join(rootDir, 'release-native', `mac-${normalizedArch}`);
  const binaryDirectory = arch === 'universal'
    ? path.join(rootDir, 'macos', '.build', 'apple', 'Products', 'Release')
    : path.join(rootDir, 'macos', '.build', `${swiftTripleArch(arch)}-apple-macosx`, 'release');
  return {
    application: path.join(releaseDirectory, `${productName}.app`),
    executable: path.join(binaryDirectory, 'KimiAgentDesktop'),
    resources: path.join(binaryDirectory, 'KimiAgentDesktop_KimiAgentDesktop.bundle')
  };
}

export function releaseVerificationCommands({ appPath, dmgPath, zipPath }) {
  return [
    ['codesign', ['--verify', '--deep', '--strict', '--verbose=2', appPath]],
    ['spctl', ['--assess', '--type', 'execute', '--verbose=2', appPath]],
    ['unzip', ['-t', zipPath]],
    ['hdiutil', ['verify', dmgPath]]
  ];
}

export function swiftBuildArgs(arch = defaultArch, extraArgs = []) {
  if (arch === 'universal') {
    return ['build', '-c', 'release', '--arch', 'arm64', '--arch', 'x86_64', ...extraArgs];
  }
  return ['build', '-c', 'release', '--arch', swiftTripleArch(arch), ...extraArgs];
}

export function codesignArgs({ appPath, identity = '-' }) {
  return [
    '--force',
    '--deep',
    '--options',
    'runtime',
    '--timestamp',
    '--sign',
    identity,
    appPath
  ];
}

export function resolveCodesignIdentity(env = process.env) {
  const developerID = env.KIMI_DEVELOPER_ID_APPLICATION?.trim();
  if (developerID) return { identity: developerID, source: 'developer-id' };
  const localIdentity = env.KIMI_CODESIGN_IDENTITY?.trim();
  if (localIdentity) return { identity: localIdentity, source: 'local' };
  return { identity: undefined, source: 'adhoc' };
}

export function notarizationSubmitArgs({ dmgPath, keychainProfile }) {
  return ['notarytool', 'submit', dmgPath, '--keychain-profile', keychainProfile, '--wait'];
}

async function writeChecksums(files, destination) {
  const lines = await Promise.all(files.map(async file => {
    const digest = createHash('sha256').update(await readFile(file)).digest('hex');
    return `${digest}  ${path.basename(file)}`;
  }));
  await writeFile(destination, `${lines.join('\n')}\n`, 'utf8');
}

function run(command, args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, stdio: 'inherit' });
    child.once('error', reject);
    child.once('exit', code => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(new Error(`${command} exited with code ${code ?? 'unknown'}`));
    });
  });
}

function capture(command, args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, stdio: ['ignore', 'pipe', 'inherit'] });
    let output = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => { output += chunk; });
    child.once('error', reject);
    child.once('exit', code => {
      if (code === 0) {
        resolve(output.trim());
        return;
      }
      reject(new Error(`${command} exited with code ${code ?? 'unknown'}`));
    });
  });
}

function infoPlist(version) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleDisplayName</key><string>${productName}</string>
  <key>CFBundleExecutable</key><string>${productName}</string>
  <key>CFBundleIdentifier</key><string>com.kimiagent.desktop.native</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${productName}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
`;
}

async function fetchFile(url, destination) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`下载失败：${url} (${response.status})`);
  }
  await writeFile(destination, Buffer.from(await response.arrayBuffer()));
}

async function buildNativeAgentHost(rootDir, resourcesDirectory) {
  await rm(path.join(resourcesDirectory, 'agent-host.mjs'), { force: true });
  await build({
    entryPoints: [path.join(rootDir, 'src', 'runtime', 'nativeAgentHost.ts')],
    outfile: path.join(resourcesDirectory, 'agent-host.cjs'),
    bundle: true,
    platform: 'node',
    format: 'cjs',
    target: 'node22',
    legalComments: 'none'
  });
}

async function provisionNode(rootDir, nodeVersion, arch = defaultArch) {
  const distribution = nativeNodeDistribution(nodeVersion, arch);
  const nodeArch = arch === 'x86_64' ? 'x64' : arch;
  const cacheDirectory = path.join(rootDir, 'macos', '.cache', `node-v${nodeVersion}-darwin-${nodeArch}`);
  const archivePath = path.join(cacheDirectory, distribution.archiveName);
  const extractedDirectory = path.join(cacheDirectory, `node-v${nodeVersion}-darwin-${nodeArch}`);
  const nodePath = path.join(extractedDirectory, 'bin', 'node');

  try {
    await access(nodePath);
    return nodePath;
  } catch {
    await mkdir(cacheDirectory, { recursive: true });
  }

  const checksums = await fetch(distribution.checksumsURL);
  if (!checksums.ok) {
    throw new Error(`无法下载 Node 校验文件：${distribution.checksumsURL}`);
  }
  const checksumLine = (await checksums.text())
    .split('\n')
    .find(line => line.endsWith(`  ${distribution.archiveName}`));
  const expectedChecksum = checksumLine?.split(/\s+/)[0];
  if (!expectedChecksum) {
    throw new Error(`Node 校验文件未包含 ${distribution.archiveName}`);
  }

  try {
    await access(archivePath);
  } catch {
    await fetchFile(distribution.archiveURL, archivePath);
  }

  const actualChecksum = createHash('sha256').update(await readFile(archivePath)).digest('hex');
  if (actualChecksum !== expectedChecksum) {
    await rm(archivePath, { force: true });
    throw new Error(`Node 校验失败：期望 ${expectedChecksum}，实际 ${actualChecksum}`);
  }

  await rm(extractedDirectory, { recursive: true, force: true });
  await run('tar', ['-xzf', archivePath, '-C', cacheDirectory], rootDir);
  await access(nodePath);
  return nodePath;
}

async function copyBundledNode(rootDir, appResources, nodeVersion, arch) {
  if (arch === 'universal') {
    const armNode = await provisionNode(rootDir, nodeVersion, 'arm64');
    const x64Node = await provisionNode(rootDir, nodeVersion, 'x64');
    await cp(armNode, path.join(appResources, 'node-arm64'), { force: true });
    await cp(x64Node, path.join(appResources, 'node-x64'), { force: true });
    await cp(armNode, path.join(appResources, 'node'), { force: true });
    await chmod(path.join(appResources, 'node-arm64'), 0o755);
    await chmod(path.join(appResources, 'node-x64'), 0o755);
    await chmod(path.join(appResources, 'node'), 0o755);
    return;
  }

  const bundledNode = await provisionNode(rootDir, nodeVersion, arch);
  const nodeResourceName = productArch(arch) === 'x86_64' ? 'node-x64' : 'node-arm64';
  await cp(bundledNode, path.join(appResources, nodeResourceName), { force: true });
  await chmod(path.join(appResources, nodeResourceName), 0o755);
  await cp(bundledNode, path.join(appResources, 'node'), { force: true });
  await chmod(path.join(appResources, 'node'), 0o755);
}

async function maybeCodesignApp(rootDir, appPath) {
  const { identity, source } = resolveCodesignIdentity();
  const effectiveIdentity = identity ?? '-';
  if (!identity) {
    console.warn([
    'warning: No stable macOS signing identity configured.',
    'The local build will receive an ad-hoc signature and use its protected local credential vault instead of macOS Keychain, avoiding repeated Keychain password prompts.',
    'You may need to save API credentials once in this build. Set KIMI_DEVELOPER_ID_APPLICATION for release signing or KIMI_CODESIGN_IDENTITY for a local development certificate.'
    ].join('\n'));
  }
  await run('codesign', codesignArgs({ appPath, identity: effectiveIdentity }), rootDir);
  return { signed: true, identity: effectiveIdentity, source };
}

async function maybeNotarizeApp(rootDir, appPath, notarizationZipPath) {
  const keychainProfile = process.env.KIMI_NOTARY_KEYCHAIN_PROFILE;
  if (keychainProfile) {
    await rm(notarizationZipPath, { force: true });
    await run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', appPath, notarizationZipPath], rootDir);
    await run('xcrun', notarizationSubmitArgs({ dmgPath: notarizationZipPath, keychainProfile }), rootDir);
    await run('xcrun', ['stapler', 'staple', appPath], rootDir);
    await rm(notarizationZipPath, { force: true });
  }
}

async function verifyRelease(rootDir, { appPath, dmgPath, zipPath }) {
  if (process.env.KIMI_NATIVE_VERIFY_RELEASE === '1') {
    for (const [command, args] of releaseVerificationCommands({ appPath, dmgPath, zipPath })) {
      await run(command, args, rootDir);
    }
  }
}

export async function packageNativeMacOS(rootDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')) {
  const arch = productArch(process.env.KIMI_NATIVE_ARCH ?? process.arch);
  const version = releaseVersion();
  if (process.platform !== 'darwin') {
    throw new Error('当前原生构建脚本仅支持 macOS。');
  }

  const macosDirectory = path.join(rootDir, 'macos');
  const resourcesDirectory = path.join(macosDirectory, 'Sources', 'KimiAgentDesktop', 'Resources');
  const runtimeSource = path.join(rootDir, 'node_modules', '@moonshot-ai', 'kimi-code', 'dist', 'main.mjs');
  const runtimePackageSource = path.join(rootDir, 'node_modules', '@moonshot-ai', 'kimi-code', 'package.json');
  const nodeVersion = process.env.KIMI_NODE_VERSION ?? process.versions.node;
  const artifacts = nativeArtifactPaths(rootDir, arch);
  const binaryDirectory = await capture('swift', swiftBuildArgs(arch, ['--show-bin-path']), macosDirectory);
  const appContents = path.join(artifacts.application, 'Contents');
  const appResources = path.join(appContents, 'Resources');
  const dmgPath = path.join(rootDir, 'release-native', `Kimi-Agent-Desktop-${version}-${arch}.dmg`);
  const zipPath = path.join(rootDir, 'release-native', `Kimi-Agent-Desktop-${version}-${arch}.zip`);
  const checksumPath = path.join(rootDir, 'release-native', `Kimi-Agent-Desktop-${version}-${arch}-SHA256SUMS.txt`);
  const notarizationZipPath = path.join(rootDir, 'release-native', `.Kimi-Agent-Desktop-${version}-${arch}-notarization.zip`);
  const executable = path.join(binaryDirectory, 'KimiAgentDesktop');
  const resourceBundle = path.join(binaryDirectory, 'KimiAgentDesktop_KimiAgentDesktop.bundle');

  await mkdir(resourcesDirectory, { recursive: true });
  await cp(runtimeSource, path.join(resourcesDirectory, 'kimi.mjs'), { force: true });
  await cp(runtimePackageSource, path.join(resourcesDirectory, 'package.json'), { force: true });

  // 创建 kimi 可执行文件的符号链接（SDK 会查找名为 'kimi' 的命令）
  const kimiSymlink = path.join(resourcesDirectory, 'kimi');
  const kimiMjs = path.join(resourcesDirectory, 'kimi.mjs');
  try {
    await rm(kimiSymlink, { force: true });
  } catch {}
  await cp(kimiMjs, kimiSymlink, { force: true });
  await chmod(kimiSymlink, 0o755);

  await buildNativeAgentHost(rootDir, resourcesDirectory);
  await run('swift', swiftBuildArgs(arch), macosDirectory);

  await rm(artifacts.application, { recursive: true, force: true });
  await mkdir(path.join(appContents, 'MacOS'), { recursive: true });
  await mkdir(appResources, { recursive: true });
  await cp(executable, path.join(appContents, 'MacOS', productName), { force: true });
  await chmod(path.join(appContents, 'MacOS', productName), 0o755);
  await cp(resourceBundle, path.join(appResources, path.basename(resourceBundle)), { recursive: true, force: true });
  // Swift WebRuntime is the default Search/Fetch path. Do not ship the
  // deprecated Node bridge merely because an older source bundle still has a
  // compatibility resource checked in.
  const copiedBundle = path.join(appResources, path.basename(resourceBundle));
  await rm(path.join(copiedBundle, 'Resources', 'web-research-bridge.cjs'), { force: true });
  await rm(path.join(copiedBundle, 'Contents', 'Resources', 'Resources', 'web-research-bridge.cjs'), { force: true });
  // `dist/` bundled the retired Node network gateway and dynamic-planning
  // entrypoint. Swift no longer loads those files in the default app path.
  for (const resourceRoot of [
    path.join(copiedBundle, 'Resources'),
    path.join(copiedBundle, 'Contents', 'Resources', 'Resources')
  ]) {
    await rm(path.join(resourceRoot, 'dist'), { recursive: true, force: true });
    await rm(path.join(resourceRoot, 'dynamicPlanningCLI.bundle.cjs'), { force: true });
    await rm(path.join(resourceRoot, 'dynamicPlanningCLI.bundle.js'), { force: true });
  }
  await copyBundledNode(rootDir, appResources, nodeVersion, arch);
  await writeFile(path.join(appContents, 'Info.plist'), infoPlist(version), 'utf8');
  await maybeCodesignApp(rootDir, artifacts.application);
  await maybeNotarizeApp(rootDir, artifacts.application, notarizationZipPath);

  await mkdir(path.dirname(dmgPath), { recursive: true });
  await run('hdiutil', ['create', '-volname', productName, '-srcfolder', artifacts.application, '-ov', '-format', 'UDZO', dmgPath], rootDir);
  await rm(zipPath, { force: true });
  await run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', artifacts.application, zipPath], rootDir);
  await writeChecksums([dmgPath, zipPath], checksumPath);
  await verifyRelease(rootDir, { appPath: artifacts.application, dmgPath, zipPath });

  return { application: artifacts.application, dmgPath, zipPath, checksumPath };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  packageNativeMacOS().catch(error => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
