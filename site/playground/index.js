import { DirectEvaluator } from './client.js';
import { REVISION, checkSource } from './protocol.js';

/** executeExpression is the live guest's safe source-as-data transfer API. */
export function mountPlayground(root, { executeExpression, guestReady = () => false } = {}) {
  const evaluator = new DirectEvaluator();
  let directGeneration = 0;
  let guestGeneration = 0;
  let disposed = false;
  let guestOutcome = '';
  const element = (tag, text, attrs = {}) => {
    const node = document.createElement(tag);
    node.textContent = text;
    for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
    return node;
  };
  const title = element('h2', 'Snix expression playground');
  const scope = element('p', 'Direct WASM evaluation works before the VM starts. Supported: arithmetic, attribute sets, lists, functions and import ./lib/math.nix. No host filesystem, environment, network fetching, arbitrary flakes, nixpkgs or build execution. Trace collection is unavailable. Direct results are not Redox execution.');
  const metadata = element('p', `Evaluator revision ${REVISION}; source tree v1. Direct time limit 5 seconds, source 64 KiB, value 16 KiB, at most 16 diagnostics of 2 KiB each.`);
  const label = element('label', 'Nix expression', { for: 'playground-source' });
  const source = element('textarea', '', { id: 'playground-source', rows: '8', spellcheck: 'false', 'aria-describedby': 'playground-direct-status' });
  source.value = 'let math = import ./lib/math.nix; in math.square 7 + math.offset';
  const evaluate = element('button', 'Evaluate directly (WASM)', { type: 'button' });
  const cancel = element('button', 'Cancel / reset direct worker', { type: 'button' });
  const guest = element('button', 'Run in Redox', { type: 'button' });
  const directStatus = element('p', 'Direct evaluator idle; no VM required.', { id: 'playground-direct-status', role: 'status' });
  const directOutput = element('pre', '', { 'aria-label': 'Direct WASM result', tabindex: '0' });
  const guestStatus = element('p', '', { role: 'status' });
  const guestOutput = element('pre', '', { 'aria-label': 'Actual Redox guest output', tabindex: '0' });
  const controls = element('div', '');
  controls.append(evaluate, cancel, guest);
  root.replaceChildren(title, scope, metadata, label, source, controls,
    element('h3', 'Direct evaluator result — browser WASM'), directStatus, directOutput,
    element('h3', 'Run in Redox — guest process output'), guestStatus, guestOutput);
  function refreshGuestState() {
    if (!guestReady() && guest.dataset.busy === 'true') {
      ++guestGeneration;
      guest.dataset.busy = 'false';
    }
    guest.disabled = disposed || typeof executeExpression !== 'function' || !guestReady() || guest.dataset.busy === 'true';
    if (guest.dataset.busy === 'true') return;
    // A completed result stays visible until the guest becomes unavailable.
    if (guest.disabled) guestOutcome = '';
    guestStatus.textContent = guest.disabled ? 'Start the live Redox VM and wait for its shell to enable guest execution.' : guestOutcome || 'Redox shell ready. This action executes a guest Snix process.';
  }
  evaluate.onclick = async () => {
    const generation = ++directGeneration;
    directStatus.textContent = 'Evaluating in the independent WASM worker…';
    directOutput.textContent = '';
    try {
      const result = await evaluator.evaluate(source.value);
      if (disposed || generation !== directGeneration) return;
      directStatus.textContent = `${result.ok ? 'Direct evaluation complete.' : 'Direct evaluation failed.'}${result.truncated ? ' Output or diagnostics were truncated.' : ''}`;
      const diagnostics = result.diagnostics.map(d => `${d.severity}: ${d.source}:${d.line}:${d.column}: ${d.message}`).join('\n');
      directOutput.textContent = [result.value, diagnostics].filter(value => value !== null && value !== '').join('\n');
    } catch (error) {
      if (disposed || generation !== directGeneration) return;
      directStatus.textContent = String(error.message ?? error).slice(0, 2048);
    }
  };
  cancel.onclick = () => {
    ++directGeneration;
    evaluator.cancel();
    directStatus.textContent = 'Direct worker terminated and recreated. The Redox VM was not touched.';
    directOutput.textContent = '';
  };
  guest.onclick = async () => {
    if (guest.disabled) return;
    const generation = ++guestGeneration;
    guest.dataset.busy = 'true';
    guest.disabled = true;
    guestStatus.textContent = 'Executing source inside Redox…';
    guestOutput.textContent = '';
    try {
      const text = source.value;
      checkSource(text);
      const result = await executeExpression(text);
      if (disposed || generation !== guestGeneration) return;
      if (!result || typeof result.stdout !== 'string' || !Number.isInteger(result.exitCode)) throw new Error('Invalid guest execution response.');
      guestStatus.textContent = guestOutcome = `Actual Redox guest process exited with status ${result.exitCode}.`;
      const textOutput = result.stdout + (result.stderr ? '\n' + result.stderr : '');
      guestOutput.textContent = textOutput.slice(0, 32768) + (textOutput.length > 32768 ? '\n[guest display truncated]' : '');
    } catch (error) {
      if (!disposed && generation === guestGeneration) guestStatus.textContent = guestOutcome = `Guest execution failed: ${String(error.message ?? error).slice(0, 2048)}`;
    } finally {
      if (!disposed && generation === guestGeneration) {
        guest.dataset.busy = 'false';
        refreshGuestState();
      }
    }
  };
  refreshGuestState();
  return { evaluator, refreshGuestState, dispose() { disposed = true; ++directGeneration; ++guestGeneration; evaluator.dispose(); root.replaceChildren(); } };
}
