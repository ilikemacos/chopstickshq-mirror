// Upscaler — Real-ESRGAN via ONNX Runtime Web (WebGPU). Runtime and weights come
// from public CDNs so the deploy stays small; nothing is ever uploaded from here.
const ORT_VERSION = '1.27.0';
const ORT_BASE = `https://cdn.jsdelivr.net/npm/onnxruntime-web@${ORT_VERSION}/dist/`;
const MODEL_BASE = 'https://huggingface.co/yuvraj108c/ComfyUI-Upscaler-Onnx/resolve/main/';
const MODELS = { 2: '2x-ESRGAN.onnx', 4: 'RealESRGAN_x4.onnx' };
const PAD = 16;

const $ = (id) => document.getElementById(id);
const dropEl = $('up-drop'), fileEl = $('up-file'), runEl = $('up-run'), dlEl = $('up-dl');
const srcCanvas = $('up-src'), outCanvas = $('up-out'), statusEl = $('up-status'), fillEl = $('up-fill');

let ort = null;
let sourceBitmap = null;
const sessions = new Map();

const setStatus = (t) => { statusEl.textContent = t; };
const setProgress = (f) => { fillEl.style.width = `${Math.round(f * 100)}%`; };

if (!navigator.gpu) {
  $('up-unsupported').hidden = false;
  runEl.disabled = true;
}

async function loadOrt() {
  if (ort) return ort;
  setStatus('Loading runtime…');
  ort = await import(`${ORT_BASE}ort.webgpu.bundle.min.mjs`);
  ort.env.wasm.wasmPaths = ORT_BASE;
  ort.env.wasm.numThreads = 1;
  return ort;
}

async function getSession(scale, patch) {
  const key = `${scale}:${patch}`;
  if (sessions.has(key)) return sessions.get(key);
  const rt = await loadOrt();
  setStatus(`Downloading ×${scale} model (~68 MB, cached after this)…`);
  const session = await rt.InferenceSession.create(MODEL_BASE + MODELS[scale], {
    executionProviders: ['webgpu'],
    graphOptimizationLevel: 'all',
    // WebGPU needs static shapes — every tile runs at one fixed size.
    freeDimensionOverrides: { batch_size: 1, width: patch, height: patch },
  });
  sessions.set(key, session);
  return session;
}

function drawToCanvas(canvas, source) {
  const ctx = canvas.getContext('2d');
  canvas.width = source.width;
  canvas.height = source.height;
  if (source instanceof ImageData) ctx.putImageData(source, 0, 0);
  else ctx.drawImage(source, 0, 0);
}

function imageDataOf(bitmap) {
  const c = document.createElement('canvas');
  c.width = bitmap.width;
  c.height = bitmap.height;
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(bitmap, 0, 0);
  return ctx.getImageData(0, 0, bitmap.width, bitmap.height);
}

/** Crop a patch to NCHW float, replicating the edge pixel past the image bounds. */
function patchToNCHW(img, x0, y0, patch) {
  const { width: W, height: H, data } = img;
  const out = new Float32Array(3 * patch * patch);
  const plane = patch * patch;
  for (let y = 0; y < patch; y++) {
    const sy = Math.min(y0 + y, H - 1);
    for (let x = 0; x < patch; x++) {
      const si = (sy * W + Math.min(x0 + x, W - 1)) * 4;
      const di = y * patch + x;
      out[di] = data[si] / 255;
      out[plane + di] = data[si + 1] / 255;
      out[2 * plane + di] = data[si + 2] / 255;
    }
  }
  return out;
}

/** Copy the valid core of an upscaled tile into the output image. */
function blitPatch(tensor, patch, scale, out, dstX, dstY, offY, offX, w, h) {
  const p = patch * scale;
  const plane = p * p;
  const d = tensor.data;
  const clamp = (v) => (v < 0 ? 0 : v > 255 ? 255 : v);
  for (let y = 0; y < h; y++) {
    const rowBase = (offY + y) * p + offX;
    let di = ((dstY + y) * out.width + dstX) * 4;
    for (let x = 0; x < w; x++) {
      const si = rowBase + x;
      out.data[di] = clamp(Math.round(d[si] * 255));
      out.data[di + 1] = clamp(Math.round(d[plane + si] * 255));
      out.data[di + 2] = clamp(Math.round(d[2 * plane + si] * 255));
      out.data[di + 3] = 255;
      di += 4;
    }
  }
}

async function upscale(bitmap, scale, tile) {
  const patch = tile + 2 * PAD;
  const session = await getSession(scale, patch);
  const img = imageDataOf(bitmap);
  const { width: W, height: H } = img;
  const out = new ImageData(W * scale, H * scale);
  const cols = Math.ceil(W / tile), rows = Math.ceil(H / tile);
  const total = cols * rows;
  let done = 0;
  const t0 = performance.now();

  for (let ty = 0; ty < rows; ty++) {
    for (let tx = 0; tx < cols; tx++) {
      const x0 = tx * tile, y0 = ty * tile;
      const x1 = Math.min(x0 + tile, W), y1 = Math.min(y0 + tile, H);
      const px0 = Math.max(0, x0 - PAD), py0 = Math.max(0, y0 - PAD);

      const input = new ort.Tensor('float32', patchToNCHW(img, px0, py0, patch), [1, 3, patch, patch]);
      const res = await session.run({ [session.inputNames[0]]: input });
      const tensor = res[session.outputNames[0]];
      blitPatch(tensor, patch, scale, out, x0 * scale, y0 * scale,
        (y0 - py0) * scale, (x0 - px0) * scale, (x1 - x0) * scale, (y1 - y0) * scale);
      input.dispose?.();
      tensor.dispose?.();

      done++;
      setProgress(done / total);
      setStatus(`Tile ${done}/${total} — ${((performance.now() - t0) / 1000).toFixed(1)}s`);
      await new Promise((r) => setTimeout(r, 0));
    }
  }
  return { out, seconds: (performance.now() - t0) / 1000 };
}

async function loadFile(file) {
  if (!file || !file.type.startsWith('image/')) return;
  sourceBitmap = await createImageBitmap(file);
  drawToCanvas(srcCanvas, sourceBitmap);
  $('up-label').textContent = `${file.name} — ${sourceBitmap.width}×${sourceBitmap.height}`;
  runEl.disabled = !navigator.gpu;
  dlEl.hidden = true;
  setProgress(0);
  setStatus('Ready.');
}

fileEl.addEventListener('change', (e) => loadFile(e.target.files[0]));
dropEl.addEventListener('dragover', (e) => { e.preventDefault(); dropEl.classList.add('over'); });
dropEl.addEventListener('dragleave', () => dropEl.classList.remove('over'));
dropEl.addEventListener('drop', (e) => {
  e.preventDefault();
  dropEl.classList.remove('over');
  loadFile(e.dataTransfer.files[0]);
});

runEl.addEventListener('click', async () => {
  if (!sourceBitmap) return;
  const scale = Number(document.querySelector('input[name=up-scale]:checked').value);
  const fmt = document.querySelector('input[name=up-fmt]:checked').value;
  const tile = Number($('up-tile').value);
  runEl.disabled = true;
  dlEl.hidden = true;
  try {
    const { out, seconds } = await upscale(sourceBitmap, scale, tile);
    drawToCanvas(outCanvas, out);
    const blob = await new Promise((r) => outCanvas.toBlob(r, `image/${fmt}`, 0.95));
    dlEl.href = URL.createObjectURL(blob);
    dlEl.download = `upscaled_x${scale}.${fmt === 'jpeg' ? 'jpg' : fmt}`;
    dlEl.hidden = false;
    setStatus(`${out.width}×${out.height} in ${seconds.toFixed(1)}s on WebGPU — nothing was uploaded.`);
  } catch (err) {
    console.error(err);
    setProgress(0);
    setStatus(`Failed: ${err.message}`);
  } finally {
    runEl.disabled = false;
  }
});
