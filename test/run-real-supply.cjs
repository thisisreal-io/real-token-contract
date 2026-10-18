// Cross-platform local test runner. No live-chain RPC or private keys are used.
const {spawn} = require('node:child_process');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const port = 18548;
let test, finished = false, startup = '';
const chain = spawn(process.execPath, [
  path.join(root, 'node_modules/hardhat/dist/src/cli.js'), 'node',
  '--hostname', '127.0.0.1', '--port', String(port),
], {cwd:root, windowsHide:true, stdio:['ignore','pipe','pipe']});
const timeout = setTimeout(() => finish(1, 'Local contract tests timed out'), 120000);
function finish(code, message) {
  if (finished) return;
  finished = true;
  clearTimeout(timeout);
  if (message) console.error(message);
  test?.kill();
  chain.kill();
  process.exitCode = code ?? 1;
}
chain.on('error', error => finish(1, error.message));
chain.on('exit', code => {if (!finished) finish(1, `Local chain exited early (${code})`);});
chain.stderr.on('data', data => process.stderr.write(data));
chain.stdout.on('data', data => {
  if (test || finished) return;
  startup += data.toString();
  if (!startup.includes('Started HTTP')) return;
  test = spawn(process.execPath, [process.argv[2] || 'test/real-supply-oracle.mjs'], {
    cwd:root, windowsHide:true, stdio:'inherit',
    env:{...process.env, REAL_ORACLE_TEST_RPC:`http://127.0.0.1:${port}`},
  });
  test.on('error', error => finish(1, error.message));
  test.on('exit', code => finish(code));
});
process.on('SIGINT', () => finish(130));
process.on('SIGTERM', () => finish(143));
