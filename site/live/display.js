// QEMU's browser display listener is the producer, never a screenshot player.
// Pass moduleOptions to the engine factory before it starts. dispose() releases
// guest input and DOM listeners; the owning session must terminate its workers.
const linuxKeys = Object.freeze({
  Escape:1, Digit1:2, Digit2:3, Digit3:4, Digit4:5, Digit5:6, Digit6:7,
  Digit7:8, Digit8:9, Digit9:10, Digit0:11, Minus:12, Equal:13,
  Backspace:14, Tab:15, KeyQ:16, KeyW:17, KeyE:18, KeyR:19, KeyT:20,
  KeyY:21, KeyU:22, KeyI:23, KeyO:24, KeyP:25, BracketLeft:26,
  BracketRight:27, Enter:28, ControlLeft:29, KeyA:30, KeyS:31, KeyD:32,
  KeyF:33, KeyG:34, KeyH:35, KeyJ:36, KeyK:37, KeyL:38, Semicolon:39,
  Quote:40, Backquote:41, ShiftLeft:42, Backslash:43, KeyZ:44, KeyX:45,
  KeyC:46, KeyV:47, KeyB:48, KeyN:49, KeyM:50, Comma:51, Period:52,
  Slash:53, ShiftRight:54, NumpadMultiply:55, AltLeft:56, Space:57,
  CapsLock:58, F1:59, F2:60, F3:61, F4:62, F5:63, F6:64, F7:65,
  F8:66, F9:67, F10:68, NumLock:69, ScrollLock:70, Numpad7:71,
  Numpad8:72, Numpad9:73, NumpadSubtract:74, Numpad4:75, Numpad5:76,
  Numpad6:77, NumpadAdd:78, Numpad1:79, Numpad2:80, Numpad3:81,
  Numpad0:82, NumpadDecimal:83, IntlBackslash:86, F11:87, F12:88,
  IntlRo:89, Convert:92, NonConvert:94, NumpadEnter:96, ControlRight:97,
  NumpadDivide:98, PrintScreen:99, AltRight:100, Home:102, ArrowUp:103,
  PageUp:104, ArrowLeft:105, ArrowRight:106, End:107, ArrowDown:108,
  PageDown:109, Insert:110, Delete:111, Pause:119, IntlYen:124,
  MetaLeft:125, MetaRight:126, ContextMenu:127,
});

export function createBrowserDisplay({canvas, fullscreenTarget = canvas,
  status = null, signal, onFrame = null} = {}) {
  if (!(canvas instanceof HTMLCanvasElement)) throw new TypeError('A guest canvas is required');
  const context = canvas.getContext('2d', {alpha:false});
  if (!context) throw new Error('Canvas 2D is unavailable; use serial diagnostics');
  const listeners = new AbortController();
  const keys = new Set();
  const buttons = new Set();
  const samples = [];
  let input = null, image = null, disposed = false, previous = null;
  let remainderX = 0, remainderY = 0, lastInput = null;
  let frames = 0, dirtyPixels = 0, uploadMs = 0, maximumUploadMs = 0;
  let conversionMs = 0, maximumConversionMs = 0;
  let wasmBreakBytes = null, maximumWasmBreakBytes = 0;
  let firstFrameMs = null, inputToNextFrameMs = null, queueOverflows = 0;
  const started = performance.now();
  canvas.tabIndex = 0;
  canvas.setAttribute('role', 'application');
  canvas.setAttribute('aria-label', 'Redox Orbital guest display; click to focus. Guest keyboard layout is US.');
  canvas.classList.add('guest-framebuffer');
  const say = text => { if (status) status.textContent = text; };
  const listen = (target, name, fn, options = {}) => target.addEventListener(name, fn,
    {...options, signal:listeners.signal});

  function releaseAll() {
    keys.clear(); buttons.clear(); previous = null;
    remainderX = 0; remainderY = 0;
    if (input) Atomics.add(input.heap, input.base + 2, 1);
  }
  function enqueue(type, a = 0, b = 0, c = 0, d = 0, e = 0) {
    if (disposed || !input) return false;
    const {heap, base, capacity, words} = input;
    if (Atomics.load(heap, base + 2) !== Atomics.load(heap, base + 3)) return false;
    const write = Atomics.load(heap, base);
    const next = (write + 1) % capacity;
    if (next === Atomics.load(heap, base + 1)) {
      queueOverflows++; releaseAll();
      say('Guest input queue filled: all keys/buttons released; refocus to continue.');
      return false;
    }
    const offset = base + 8 + write * words;
    heap[offset] = type; heap[offset+1] = a; heap[offset+2] = b;
    heap[offset+3] = c; heap[offset+4] = d; heap[offset+5] = e;
    Atomics.store(heap, base, next);
    lastInput = performance.now();
    return true;
  }
  function keyboard(event, down) {
    const code = linuxKeys[event.code];
    if (!code || event.isComposing) return;
    event.preventDefault();
    if (down) {
      if (!keys.has(code) && enqueue(1, code, 1)) keys.add(code);
    } else if (keys.delete(code)) enqueue(1, code, 0);
  }
  function move(event) {
    if (!image) return;
    const rect = canvas.getBoundingClientRect();
    if (!rect.width || !rect.height) return;
    const locked = document.pointerLockElement === canvas;
    const x = Math.max(0, Math.min(canvas.width - 1, locked ?
      (previous?.x ?? canvas.width/2) + event.movementX * canvas.width/rect.width :
      (event.clientX - rect.left) * canvas.width/rect.width));
    const y = Math.max(0, Math.min(canvas.height - 1, locked ?
      (previous?.y ?? canvas.height/2) + event.movementY * canvas.height/rect.height :
      (event.clientY - rect.top) * canvas.height/rect.height));
    remainderX += locked ? event.movementX * canvas.width / rect.width : previous ? x - previous.x : 0;
    remainderY += locked ? event.movementY * canvas.height / rect.height : previous ? y - previous.y : 0;
    const dx = Math.trunc(remainderX), dy = Math.trunc(remainderY);
    remainderX -= dx; remainderY -= dy; previous = {x,y};
    enqueue(2, Math.round(x), Math.round(y), dx, dy);
  }
  listen(canvas, 'keydown', event => keyboard(event, true));
  listen(canvas, 'keyup', event => keyboard(event, false));
  listen(canvas, 'pointerdown', event => {
    if (event.pointerType !== 'mouse' || event.button > 2) return;
    event.preventDefault(); canvas.focus({preventScroll:true});
    canvas.setPointerCapture(event.pointerId); move(event);
    if (enqueue(3, event.button, 1)) buttons.add(event.button);
  });
  listen(canvas, 'pointermove', event => {
    if (event.pointerType === 'mouse' && document.activeElement === canvas) move(event);
  });
  listen(canvas, 'pointerup', event => {
    if (buttons.delete(event.button)) enqueue(3, event.button, 0);
    if (!buttons.size && canvas.hasPointerCapture(event.pointerId)) canvas.releasePointerCapture(event.pointerId);
  });
  listen(canvas, 'pointercancel', releaseAll);
  listen(canvas, 'lostpointercapture', () => { if (buttons.size) releaseAll(); });
  listen(canvas, 'pointerleave', () => { previous = null; });
  listen(canvas, 'contextmenu', event => event.preventDefault());
  listen(canvas, 'wheel', event => {
    if (document.activeElement !== canvas) return;
    event.preventDefault();
    // One native PS/2 wheel detent per browser wheel event; no invented smooth
    // scrolling protocol and no guest display mode change on page zoom.
    if (event.deltaY) enqueue(4, 0, Math.sign(event.deltaY));
    if (event.deltaX) enqueue(4, 1, Math.sign(event.deltaX));
  }, {passive:false});
  listen(canvas, 'blur', releaseAll);
  listen(window, 'blur', releaseAll);
  listen(document, 'visibilitychange', () => { if (document.hidden) releaseAll(); });
  listen(document, 'pointerlockchange', releaseAll);
  listen(document, 'fullscreenchange', releaseAll);
  listen(window, 'pagehide', releaseAll);

  const moduleOptions = {
    canvas,
    redoxDisplayInput(heap, pointer, capacity, words, headerWords) {
      if (disposed) return;
      if (!(heap.buffer instanceof SharedArrayBuffer) || words !== 6 || capacity !== 256 || headerWords !== 8)
        throw new Error('Incompatible graphical engine input ABI');
      input = {heap, base:pointer >>> 2, capacity, words};
      releaseAll();
      say('Graphical input connected. Waiting for guest framebuffer; serial diagnostics remain available.');
    },
    redoxDisplayFrame(heap, pointer, width, height, stride, x, y, w, h, convertMs, heapBreak) {
      if (disposed) return;
      pointer >>>= 0;
      wasmBreakBytes = heapBreak >>> 0;
      maximumWasmBreakBytes = Math.max(maximumWasmBreakBytes, wasmBreakBytes);
      const begin = performance.now();
      if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0 ||
          stride < width * 4 || pointer < 0 || pointer + stride * height > heap.length)
        throw new Error('Invalid graphical engine framebuffer');
      if (!image || image.width !== width || image.height !== height) {
        // Intrinsic pixels describe the observed guest mode, NEVER DPR or CSS.
        // Browser compositing maps those pixels to the current device scale.
        canvas.width = width; canvas.height = height;
        image = context.createImageData(width, height);
        say('Guest framebuffer ' + width + '×' + height + '. Click for keyboard/mouse; serial diagnostics remain available.');
      }
      if (x < 0 || y < 0 || w <= 0 || h <= 0 || x+w > width || y+h > height)
        throw new Error('Invalid guest dirty rectangle');
      for (let row = y; row < y+h; row++) {
        const source = pointer + row * stride + x * 4;
        image.data.set(heap.subarray(source, source+w*4), (row*width+x)*4);
      }
      context.putImageData(image, 0, 0, x, y, w, h);
      const now = performance.now(), cost = now - begin;
      frames++; dirtyPixels += w*h; uploadMs += cost;
      conversionMs += convertMs; maximumConversionMs = Math.max(maximumConversionMs, convertMs);
      maximumUploadMs = Math.max(maximumUploadMs, cost);
      if (firstFrameMs === null) firstFrameMs = now - started;
      if (lastInput !== null) { inputToNextFrameMs = now-lastInput; lastInput = null; }
      samples.push(cost); if (samples.length > 256) samples.shift();
      onFrame?.({width, height, x, y, w, h, frames, uploadMs:cost});
    },
  };
  function dispose() {
    if (disposed) return;
    releaseAll(); disposed = true;
    if (document.pointerLockElement === canvas) document.exitPointerLock();
    listeners.abort(); input = null; image = null;
    signal?.removeEventListener('abort', dispose);
    say('Graphical session stopped. Serial log is retained by the session.');
  }
  if (signal?.aborted) dispose();
  else signal?.addEventListener('abort', dispose, {once:true});
  return {
    moduleOptions, releaseAll, dispose,
    fullscreen: () => fullscreenTarget.requestFullscreen(),
    capturePointer: () => canvas.requestPointerLock(),
    metrics: () => ({frames, dirtyPixels, uploadMs, maximumUploadMs, conversionMs, maximumConversionMs,
      // Input-to-next-frame is a scheduling observation, NOT action latency.
      recentUploadMs:[...samples], firstFrameMs, inputToNextFrameMs,
      queueOverflows, width:canvas.width, height:canvas.height,
      framebufferBytes:image?.data.byteLength ?? 0,
      wasmHeapBytes:input?.heap.buffer.byteLength ?? null,
      wasmBreakBytes, maximumWasmBreakBytes,
      inputRingBytes:input ? (8 + input.capacity * input.words) * 4 : 0,
      consumedInputs:input ? Object.fromEntries(['keyboard','pointer','button','wheel'].map(
        (name, index) => [name, Atomics.load(input.heap, input.base + 4 + index) >>> 0])) : null,
      devicePixelRatio:window.devicePixelRatio,
      // Inspect the existing ring on demand; no event-path bookkeeping.
      heldKeys:[...keys], heldButtons:[...buttons],
      queuedInputs:input ? (Atomics.load(input.heap, input.base) -
        Atomics.load(input.heap, input.base + 1) + input.capacity) % input.capacity : 0,
      releaseRequested:input ? Atomics.load(input.heap, input.base + 2) : null,
      releaseAcknowledged:input ? Atomics.load(input.heap, input.base + 3) : null,
      inputConnected:input !== null, disposed}),
  };
}

export function createGraphicalPanel(options = {}) {
  const element = document.createElement('section');
  element.className = 'graphical-display';
  const toolbar = document.createElement('div');
  toolbar.className = 'graphical-toolbar';
  const fullscreen = document.createElement('button');
  fullscreen.type = 'button'; fullscreen.textContent = 'Full screen';
  const capture = document.createElement('button');
  capture.type = 'button'; capture.textContent = 'Capture relative pointer';
  const status = document.createElement('p');
  status.className = 'graphical-status'; status.setAttribute('aria-live', 'polite');
  status.textContent = 'Display not started. Serial diagnostics are independently available.';
  const canvas = document.createElement('canvas');
  canvas.width = 1; canvas.height = 1;
  const hint = document.createElement('p');
  hint.textContent = 'Guest login: root / redox for the bundled system demo; user / redox for an unprivileged desktop. US physical keyboard layout. Escape releases captured pointer. In orbterm run: bash /etc/browser-demo/run.sh all';
  toolbar.append(fullscreen, capture); element.append(toolbar, status, canvas, hint);
  const display = createBrowserDisplay({...options, canvas, status, fullscreenTarget:element});
  fullscreen.addEventListener('click', () => display.fullscreen().catch(error => { status.textContent = error.message; }));
  capture.addEventListener('click', () => {
    canvas.focus({preventScroll:true});
    Promise.resolve(display.capturePointer()).catch(error => { status.textContent = error.message; });
  });
  return {element, canvas, status, ...display};
}
