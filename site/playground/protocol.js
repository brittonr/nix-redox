export const PROTOCOL = 1;
export const REVISION = '34604636d7e3adbad6f7f909c98bb493f26855f9';
export const SOURCE_LIMIT = 65536;
export const OUTPUT_LIMIT = 16384;
export const DIAGNOSTIC_LIMIT = 16;
export function checkSource(source) {
  if (typeof source !== 'string' || new TextEncoder().encode(source).byteLength > SOURCE_LIMIT) {
    throw new RangeError('Source must be text of at most 65536 UTF-8 bytes.');
  }
}
export function checkResult(result, id) {
  if (!result || result.protocol !== PROTOCOL || result.id !== id || result.revision !== REVISION ||
      typeof result.ok !== 'boolean' || typeof result.truncated !== 'boolean' ||
      !(result.value === null || typeof result.value === 'string') ||
      (result.value !== null && new TextEncoder().encode(result.value).byteLength > OUTPUT_LIMIT) ||
      !Array.isArray(result.diagnostics) || result.diagnostics.length > DIAGNOSTIC_LIMIT ||
      !Array.isArray(result.traces) || result.traces.length !== 0) {
    throw new Error('Invalid direct-evaluator response.');
  }
  for (const d of result.diagnostics) {
    if (!d || !['error', 'warning'].includes(d.severity) || typeof d.message !== 'string' ||
        new TextEncoder().encode(d.message).byteLength > 2048 || typeof d.source !== 'string' ||
        !['line', 'column', 'endLine', 'endColumn'].every(key => Number.isInteger(d[key]) && d[key] > 0)) {
      throw new Error('Invalid direct-evaluator diagnostic.');
    }
  }
  return result;
}
