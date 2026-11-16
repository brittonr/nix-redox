import { PROTOCOL, checkSource, checkResult } from './protocol.js';

/** This worker never owns or accesses the independent QEMU worker. */
export class DirectEvaluator {
  constructor({ workerFactory = () => new Worker(new URL('./evaluator-worker.js', import.meta.url), { type: 'module' }), timeoutMs = 5000 } = {}) {
    this.workerFactory = workerFactory;
    this.timeoutMs = timeoutMs;
    this.sequence = 0;
    this.pending = null;
    this.worker = null;
    this.disposed = false;
  }
  replaceWorker() {
    this.worker?.terminate();
    this.worker = null;
    if (this.disposed) return;
    this.worker = this.workerFactory();
  }
  rejectPending(error) {
    if (!this.pending) return;
    clearTimeout(this.pending.timer);
    this.pending.reject(error);
    this.pending = null;
  }
  cancel() {
    ++this.sequence;
    this.rejectPending(new DOMException('Direct evaluation cancelled.', 'AbortError'));
    this.replaceWorker();
  }
  evaluate(source) {
    checkSource(source);
    if (this.disposed) return Promise.reject(new Error('Evaluator is disposed.'));
    // One request per worker; this also releases the previous evaluator heap.
    this.rejectPending(new DOMException('Superseded by a newer evaluation.', 'AbortError'));
    this.replaceWorker();
    const id = ++this.sequence;
    const worker = this.worker;
    return new Promise((resolve, reject) => {
      const settle = (error, result) => {
        if (this.worker !== worker || this.pending?.id !== id || this.sequence !== id) return;
        clearTimeout(this.pending.timer);
        this.pending = null;
        worker.terminate();
        this.worker = null;
        if (error) reject(error); else resolve(result);
      };
      const timer = setTimeout(() => {
        settle(new Error(`Direct evaluation exceeded ${this.timeoutMs / 1000} seconds; its worker was terminated.`));
        if (!this.disposed && !this.worker) this.replaceWorker();
      }, this.timeoutMs);
      this.pending = { id, resolve, reject, timer };
      worker.onmessage = ({ data }) => {
        if (data?.id !== id) return;
        try {
          if (data.type === 'result') settle(null, checkResult(data.result, id));
          else if (data.type === 'failure') settle(new Error(String(data.message).slice(0, 2048)));
        } catch (error) { settle(error); }
      };
      worker.onerror = event => { event.preventDefault?.(); settle(new Error(event.message || 'Direct evaluator worker failed.')); };
      worker.onmessageerror = () => settle(new Error('Direct evaluator response could not be decoded.'));
      try { worker.postMessage({ protocol: PROTOCOL, type: 'evaluate', id, source }); }
      catch (error) { settle(error); }
    });
  }
  dispose() {
    this.disposed = true;
    ++this.sequence;
    this.rejectPending(new DOMException('Evaluator disposed.', 'AbortError'));
    this.worker?.terminate();
    this.worker = null;
  }
}
