#!/usr/bin/env node
// Bundle the dynamic planning CLI with all dependencies
import { build } from 'esbuild';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const rootDir = join(__dirname, '..');

async function bundleCLI() {
  try {
    console.log('📦 Bundling dynamic planning CLI...');

    await build({
      entryPoints: [join(rootDir, 'dist/src/cli/dynamicPlanningCLI.js')],
      bundle: true,
      platform: 'node',
      target: 'node18',
      format: 'cjs',
      outfile: join(rootDir, 'dist/dynamicPlanningCLI.bundle.cjs'),
      external: [], // Bundle everything
      minify: false,
      sourcemap: true,
      banner: {
        js: '#!/usr/bin/env node'
      }
    });

    console.log('✅ CLI bundled successfully to dist/dynamicPlanningCLI.bundle.cjs');
  } catch (error) {
    console.error('❌ Bundle failed:', error);
    process.exit(1);
  }
}

bundleCLI();
