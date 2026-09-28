// Renders the 17 Cuelume cues (https://github.com/Danilaa1/cuelume, MIT) to the sound files
// Main Thing ships in Resources/Sounds/cuelume/.
//
// Cuelume synthesizes each cue with Web Audio at play time. This runs the library's own engine,
// unchanged, once per cue at its defaults (volume 1) in headless Chromium, with an
// OfflineAudioContext standing in for the live AudioContext, so the render is the graph the
// library builds: the same oscillators, noise, filters, shimmer echo and output limiter. The noise
// is seeded per cue, so a rerun gives the same samples. Each render is trimmed of the silence at
// both ends, scaled by one gain to a -1 dBFS peak, and encoded to AAC in a .caf with afconvert.
// The gain leaves the sound as it is; it is there because Cuelume renders quietly (a tick peaks
// near -32 dBFS) and the app matches every sound to the pen's loudness with a player volume that
// stops at 1, so an unscaled tick could never get as loud as the pen.
//
//   cd scripts/render-cues && npm ci && node render.mjs
//
// Needs node, macOS afconvert, and Playwright's headless Chromium for playwright-core 1.63.0
// (`npx playwright-core install chromium-headless-shell` if it is not cached yet). No window opens.
import { chromium } from "playwright-core";
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const out = join(root, "Resources", "Sounds", "cuelume");
const pkg = join(here, "node_modules", "cuelume");

const SAMPLE_RATE = 48000;
const RENDER_SECONDS = 3; // the longest cue, arrival, rings out in about 1.8 s
const START_THRESHOLD = 1e-4; // -80 dBFS: the first audible sample
const END_THRESHOLD = 1e-3; // -60 dBFS: the tail is over
const PAD_SECONDS = 0.002; // kept before the first audible sample
const FADE_SECONDS = 0.02; // a short fade after the tail, so the cut never clicks
const AAC_BITRATE = 64000;
const PEAK_DBFS = -1; // every cue is scaled to this peak before encoding

const version = JSON.parse(readFileSync(join(pkg, "package.json"), "utf8")).version;

function wav(samples, rate) {
  const data = Buffer.alloc(samples.length * 2);
  samples.forEach((s, i) => data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, s)) * 32767), i * 2));
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + data.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20); // PCM
  header.writeUInt16LE(1, 22); // mono
  header.writeUInt32LE(rate, 24);
  header.writeUInt32LE(rate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(data.length, 40);
  return Buffer.concat([header, data]);
}

/// The audible part: from just before the first sample above -80 dBFS to 20 ms past the last one
/// above -60 dBFS, faded over those last 20 ms.
function trim(samples, rate) {
  let first = samples.findIndex((s) => Math.abs(s) > START_THRESHOLD);
  if (first < 0) throw new Error("silent render");
  let last = samples.length - 1;
  while (last > first && Math.abs(samples[last]) <= END_THRESHOLD) last--;
  const start = Math.max(0, first - Math.round(PAD_SECONDS * rate));
  const fade = Math.round(FADE_SECONDS * rate);
  const end = Math.min(samples.length, last + fade);
  const kept = samples.slice(start, end);
  const from = Math.max(0, kept.length - fade);
  for (let i = from; i < kept.length; i++) {
    kept[i] *= 0.5 * (1 + Math.cos((Math.PI * (i - from + 1)) / fade));
  }
  return kept;
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
// The engine's modules, served from the installed package under a local origin.
await page.route("http://cuelume.test/**", (route) => {
  const path = new URL(route.request().url()).pathname;
  if (path === "/") return route.fulfill({ contentType: "text/html", body: "<!doctype html><title>render</title>" });
  const file = join(pkg, path);
  return route.fulfill({ contentType: "text/javascript", body: readFileSync(file, "utf8") });
});
await page.goto("http://cuelume.test/");
// play() does nothing before the page has had a user gesture, as in a browser tab.
await page.mouse.click(1, 1);

const names = await page.evaluate(async () => (await import("/dist/index.js")).sounds);

const work = mkdtempSync(join(tmpdir(), "cuelume-"));
mkdirSync(out, { recursive: true });
const rows = [];
try {
  for (const name of names) {
    const samples = await page.evaluate(
      async ({ name, rate, seconds }) => {
        // Seeded noise: mulberry32 from the cue's name.
        let seed = [...name].reduce((h, c) => (Math.imul(h ^ c.charCodeAt(0), 16777619) >>> 0), 2166136261);
        const random = Math.random;
        Math.random = () => {
          seed = (seed + 0x6d2b79f5) >>> 0;
          let t = seed;
          t = Math.imul(t ^ (t >>> 15), t | 1);
          t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
          return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };
        const context = new OfflineAudioContext(1, Math.round(rate * seconds), rate);
        // The engine asks for `new window.AudioContext()` and plays at once when it is running.
        Object.defineProperty(context, "state", { get: () => "running" });
        const live = window.AudioContext;
        window.AudioContext = function () {
          return context;
        };
        // Its cleanup timer disconnects the graph in wall clock time; the render needs it whole.
        const timeout = window.setTimeout;
        window.setTimeout = () => 0;
        try {
          // A fresh engine module per cue: it keeps one shared context and output.
          const engine = await import(`/dist/audio/engine.js?cue=${name}`);
          engine.play(name);
        } finally {
          window.setTimeout = timeout;
          window.AudioContext = live;
          Math.random = random;
        }
        const buffer = await context.startRendering();
        return Array.from(buffer.getChannelData(0));
      },
      { name, rate: SAMPLE_RATE, seconds: RENDER_SECONDS },
    );
    const kept = trim(samples, SAMPLE_RATE);
    const peak = kept.reduce((m, s) => Math.max(m, Math.abs(s)), 0);
    const rms = Math.sqrt(kept.reduce((sum, s) => sum + s * s, 0) / kept.length);
    const gain = 10 ** (PEAK_DBFS / 20) / peak;
    for (let i = 0; i < kept.length; i++) kept[i] *= gain;
    const wavPath = join(work, `${name}.wav`);
    writeFileSync(wavPath, wav(kept, SAMPLE_RATE));
    const cafPath = join(out, `${name}.caf`);
    execFileSync("/usr/bin/afconvert", ["-f", "caff", "-d", "aac", "-b", String(AAC_BITRATE), wavPath, cafPath]);
    rows.push({
      name,
      ms: Math.round((kept.length / SAMPLE_RATE) * 1000),
      rms: (20 * Math.log10(rms)).toFixed(1),
      peak: (20 * Math.log10(peak)).toFixed(1),
      gain: (20 * Math.log10(gain)).toFixed(1),
      bytes: statSync(cafPath).size,
    });
  }
} finally {
  await browser.close();
  rmSync(work, { recursive: true, force: true });
}

copyFileSync(join(pkg, "LICENSE"), join(out, "LICENSE"));
console.log(`cuelume ${version}, ${SAMPLE_RATE} Hz mono, AAC ${AAC_BITRATE / 1000} kbps, into ${out}`);
for (const r of rows) {
  console.log(`${r.name.padEnd(8)} ${String(r.ms).padStart(5)} ms  rendered rms ${r.rms.padStart(6)} dBFS, peak ${r.peak.padStart(6)} dBFS, gain +${r.gain} dB  ${String(r.bytes).padStart(6)} bytes`);
}
console.log(`${rows.length} cues, ${rows.reduce((s, r) => s + r.bytes, 0)} bytes`);
