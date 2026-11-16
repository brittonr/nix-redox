import { PROTOCOL, checkSource } from './protocol.js';
// Initialization (including browser Fetch of the WASM binary) finishes before
// entering synchronous EvalIO. All import sources are compiled into the module.
const evaluator = import('./wasm/snix_wasm.js').then(async module => {
  await module.default();
  return module;
});
self.onmessage = async ({ data }) => {
  if (!data || data.protocol !== PROTOCOL || data.type !== 'evaluate' || !Number.isInteger(data.id)) return;
  const { id, source } = data;
  try {
    checkSource(source);
    const module = await evaluator;
    self.postMessage({ type: 'started', id });
    const result = JSON.parse(module.evaluate_json(JSON.stringify({ id, source })));
    self.postMessage({ type: 'result', id, result });
  } catch (error) {
    self.postMessage({ type: 'failure', id, message: String(error?.message ?? error).slice(0, 2048) });
  }
};
