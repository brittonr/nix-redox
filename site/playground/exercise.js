import { DirectEvaluator } from './client.js';
import { REVISION, OUTPUT_LIMIT } from './protocol.js';

async function fixtures() {
  const response = await fetch(new URL('./fixtures/v1/manifest.json', import.meta.url));
  if (!response.ok) throw new Error(`Fixture manifest HTTP ${response.status}`);
  const manifest = await response.json();
  if (manifest.version !== 1 || manifest.revision !== REVISION || !Array.isArray(manifest.cases)) throw new Error('Fixture metadata mismatch.');
  return manifest.cases;
}
function requireCondition(condition, message) { if (!condition) throw new Error(message); }
export async function exerciseDirectEvaluator() {
  let signalStarted;
  let started;
  const evaluator = new DirectEvaluator({ workerFactory: () => {
    const worker = new Worker(new URL('./evaluator-worker.js', import.meta.url), { type: 'module' });
    worker.addEventListener('message', ({ data }) => {
      if (data?.type === 'started') signalStarted?.();
    });
    return worker;
  } });
  const report = [];
  try {
    for (const fixture of await fixtures()) {
      const result = await evaluator.evaluate(fixture.source);
      requireCondition(result.ok && result.value === fixture.expected, `${fixture.id}: unexpected direct value ${JSON.stringify(result)}`);
      report.push({ id: fixture.id, direct: result.value });
    }
    for (const source of ['let\n x = ;\nin x', 'let\n x = 1 / 0;\nin x', 'import ./missing.nix', 'import /etc/passwd', 'builtins.getEnv "HOME"']) {
      const result = await evaluator.evaluate(source);
      requireCondition(!result.ok && result.diagnostics.some(d => d.source && d.line > 0 && d.column > 0), `Missing located diagnostic for ${source}`);
      if (source.startsWith('let')) requireCondition(result.diagnostics.some(d => d.line >= 2), `Lost source line for ${source}`);
      report.push({ source, diagnostics: result.diagnostics });
    }
    const bounded = await evaluator.evaluate('builtins.concatStringsSep "" (builtins.genList (_: "abcdefgh") 4096)');
    requireCondition(bounded.ok && bounded.truncated && new TextEncoder().encode(bounded.value).byteLength <= OUTPUT_LIMIT, 'Unbounded direct output.');
    started = new Promise(resolve => { signalStarted = resolve; });
    const endless = evaluator.evaluate('let loop = x: loop x; in loop 0');
    const rejected = endless.then(() => false, error => error.name === 'AbortError');
    let startTimer;
    await Promise.race([started, new Promise((_, reject) => { startTimer = setTimeout(() => reject(new Error('Worker never started evaluation.')), 4000); })]).finally(() => clearTimeout(startTimer));
    // This main-thread timer must run while the evaluator worker is occupied.
    await new Promise(resolve => setTimeout(resolve, 10));
    evaluator.cancel();
    requireCondition(await rejected, 'Cancellation did not reject the active request.');
    const newer = await evaluator.evaluate('40 + 2');
    requireCondition(newer.ok && newer.value === '42', 'Worker recreation did not evaluate the newer request.');
    report.push({ cancellation: 'terminated and recreated', newer: newer.value });
    return { revision: REVISION, report };
  } finally { evaluator.dispose(); }
}

/** Pass the SAME actual live-guest callback used by mountPlayground. */
export async function comparePortableFixtures(executeExpression) {
  if (typeof executeExpression !== 'function') throw new TypeError('Actual live guest executeExpression callback required.');
  const evaluator = new DirectEvaluator();
  const report = [];
  try {
    for (const fixture of await fixtures()) {
      const direct = await evaluator.evaluate(fixture.source);
      const guest = await executeExpression(fixture.source);
      requireCondition(direct.ok && direct.value === fixture.expected, `${fixture.id}: direct evaluator mismatch.`);
      requireCondition(guest?.exitCode === 0 && typeof guest.stdout === 'string' && guest.stdout.trim() === fixture.expected,
        `${fixture.id}: actual guest mismatch ${JSON.stringify(guest)}`);
      report.push({ id: fixture.id, direct: direct.value, guest: guest.stdout.trim(), exitCode: guest.exitCode });
    }
    return { revision: REVISION, report };
  } finally { evaluator.dispose(); }
}
