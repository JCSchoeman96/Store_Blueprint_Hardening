import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { test, expect, chromium } from 'playwright/test';

const MODE = process.env.STORE_LIVE_JOIN_MODE || 'quick';
const QUICK_USERS = 20;
const FULL_USERS = 100;
const RAMP_PER_SECOND = 5;
const HOLD_MS = intEnv('STORE_LIVE_JOIN_HOLD_MS', 3000);
const WAVES = intEnv('STORE_LIVE_JOIN_WAVES', 1);
const USER_COUNT = intEnv('STORE_LIVE_JOIN_USERS', MODE === 'quick' ? QUICK_USERS : FULL_USERS);
const DATA_PATH = process.env.STORE_BENCHMARK_DATA_PATH || 'tmp/perf/benchmark_data.json';
const RESULT_PATH =
  process.env.STORE_PLAYWRIGHT_RESULT_PATH || 'tmp/perf/playwright_product_detail_live_join.json';
const PID_PATH =
  process.env.STORE_PLAYWRIGHT_PID_PATH || 'tmp/perf/playwright_product_detail_live_join.pids.json';
const CPU_THRESHOLD = floatEnv('STORE_LIVE_JOIN_CPU_THRESHOLD', 90.0);
const MIN_FREE_MEM_BYTES = intEnv('STORE_LIVE_JOIN_MIN_FREE_MEM_BYTES', 512 * 1024 * 1024);

test.setTimeout(10 * 60 * 1000);

test('product detail live join attribution', async () => {
  if (!['quick', 'full'].includes(MODE)) {
    throw new Error(`unsupported STORE_LIVE_JOIN_MODE=${MODE}`);
  }

  ensureTmpDir();
  cleanupTrackedChromiumPids();
  ensureBenchmarkServerReady();
  ensurePlaywrightBrowser();

  const benchmarkData = JSON.parse(fs.readFileSync(DATA_PATH, 'utf8'));
  const baseUrl = (process.env.STORE_BENCHMARK_BASE_URL || benchmarkData.base_url).replace(/\/$/, '');
  const slugs = benchmarkData.storefront.hot_slugs;

  expect(Array.isArray(slugs) && slugs.length > 0).toBeTruthy();

  const hostSampler = createHostSampler();
  const chromiumBefore = listChromiumPids();
  const browser = await chromium.launch({ headless: true });
  const chromiumAfter = listChromiumPids();
  persistPidFile(diffPids(chromiumBefore, chromiumAfter));
  hostSampler.start();

  try {
    const startedAt = Date.now();
    const results = [];

    for (let wave = 0; wave < WAVES; wave += 1) {
      const waveResults = await runWave(browser, wave, slugs, baseUrl);
      results.push(...waveResults);
    }

    const host = hostSampler.stop();
    const aggregate = aggregateResults(results);
    const invalidClientSaturated =
      host.max_cpu_percent > CPU_THRESHOLD || host.min_free_mem_bytes < MIN_FREE_MEM_BYTES;

    const output = {
      generated_at: new Date().toISOString(),
      mode: MODE,
      base_url: baseUrl,
      input_path: DATA_PATH,
      user_count: USER_COUNT,
      ramp_per_second: RAMP_PER_SECOND,
      hold_ms: HOLD_MS,
      waves: WAVES,
      invalid_client_saturated: invalidClientSaturated,
      thresholds: {
        cpu_percent: CPU_THRESHOLD,
        min_free_mem_bytes: MIN_FREE_MEM_BYTES
      },
      host,
      aggregate,
      results,
      duration_ms: Date.now() - startedAt
    };

    fs.writeFileSync(RESULT_PATH, JSON.stringify(output, null, 2));
    console.log(`Wrote Playwright live-join results to ${RESULT_PATH}`);
    console.log(
      JSON.stringify(
        {
          mode: MODE,
          invalid_client_saturated: invalidClientSaturated,
          aggregate
        },
        null,
        2
      )
    );

    expect(results.length).toBe(USER_COUNT * WAVES);
    expect(aggregate.successful).toBeGreaterThan(0);
  } finally {
    await browser.close().catch(() => {});
    persistPidFile([]);
  }
});

async function runWave(browser, wave, slugs, baseUrl) {
  const tasks = Array.from({ length: USER_COUNT }, (_, index) => {
    const delayMs = Math.floor((index * 1000) / RAMP_PER_SECOND);
    return sleep(delayMs).then(() => runJoin(browser, wave, index, slugs, baseUrl));
  });

  return Promise.all(tasks);
}

async function runJoin(browser, wave, index, slugs, baseUrl) {
  const context = await browser.newContext();
  const page = await context.newPage();
  const slug = slugs[(wave * USER_COUNT + index) % slugs.length];
  const route = `/shop/${slug}`;
  const timings = {
    slug,
    route,
    mode: MODE,
    wave,
    index,
    static_http_ms: null,
    ws_open_ms: null,
    join_ack_ms: null,
    post_join_hold_ms: HOLD_MS,
    http_request_timing: null,
    websocket_url: null,
    error: null
  };

  const joinSignals = createJoinSignals(page);

  try {
    const navStarted = performance.now();
    const response = await page.goto(`${baseUrl}${route}`, { waitUntil: 'domcontentloaded' });
    const navEnded = performance.now();
    timings.static_http_ms = navEnded - navStarted;
    timings.http_request_timing = response?.request()?.timing?.() ?? null;

    const joined = await waitForJoin(joinSignals);
    timings.websocket_url = joined.websocket_url;
    timings.ws_open_ms = joined.ws_open_ms;
    timings.join_ack_ms = joined.join_ack_ms;

    await page.waitForTimeout(HOLD_MS);
    return timings;
  } catch (error) {
    timings.error = String(error?.message || error);
    return timings;
  } finally {
    await context.close().catch(() => {});
  }
}

function createJoinSignals(page) {
  let wsRequestSentMs = null;
  let wsOpenMs = null;
  let joinSentMs = null;
  let joinAckMs = null;
  let websocketUrl = null;
  let websocketRequestId = null;
  let resolveJoin;
  let rejectJoin;

  const joinPromise = new Promise((resolve, reject) => {
    resolveJoin = resolve;
    rejectJoin = reject;
  });

  page.context()
    .newCDPSession(page)
    .then(async (session) => {
      await session.send('Network.enable');

      session.on('Network.webSocketCreated', (event) => {
        if (event.url.includes('/live/websocket')) {
          websocketUrl = event.url;
          websocketRequestId = event.requestId;
        }
      });

      session.on('Network.webSocketWillSendHandshakeRequest', (event) => {
        const requestUrl = event.request?.url || event.url || websocketUrl;

        if (requestUrl?.includes('/live/websocket')) {
          websocketUrl = requestUrl;
          websocketRequestId = event.requestId;
          wsRequestSentMs = event.timestamp * 1000;
        }
      });

      session.on('Network.webSocketHandshakeResponseReceived', (event) => {
        if (event.requestId === websocketRequestId) {
          wsOpenMs = event.timestamp * 1000;
        }
      });

      session.on('Network.webSocketFrameSent', (event) => {
        if (event.requestId !== websocketRequestId) return;
        if (!joinSentMs && String(event.response.payloadData || '').includes('phx_join')) {
          joinSentMs = event.timestamp * 1000;
        }
      });

      session.on('Network.webSocketFrameReceived', (event) => {
        if (event.requestId !== websocketRequestId) return;
        const payload = String(event.response.payloadData || '');

        if (!joinAckMs && payload.includes('phx_reply')) {
          joinAckMs = event.timestamp * 1000;
          resolveJoin({
            websocket_url: websocketUrl,
            ws_open_ms:
              wsOpenMs && wsRequestSentMs ? Math.max(wsOpenMs - wsRequestSentMs, 0) : null,
            join_ack_ms:
              joinSentMs && joinAckMs ? Math.max(joinAckMs - joinSentMs, 0) : null
          });
        }
      });
    })
    .catch(rejectJoin);

  page.on('pageerror', rejectJoin);
  page.on('crash', () => rejectJoin(new Error('page crashed during live join')));

  return joinPromise;
}

async function waitForJoin(joinPromise) {
  return Promise.race([
    joinPromise,
    sleep(15000).then(() => {
      throw new Error('timed out waiting for LiveView join ack');
    })
  ]);
}

function createHostSampler() {
  const samples = [];
  let previousCpu = readCpuSample();
  let timer = null;

  return {
    start() {
      samples.push(buildHostSample(0));
      timer = setInterval(() => {
        const nextCpu = readCpuSample();
        const cpuPercent = cpuBusyPercent(previousCpu, nextCpu);
        previousCpu = nextCpu;
        samples.push(buildHostSample(cpuPercent));
      }, 1000);
    },
    stop() {
      if (timer) clearInterval(timer);

      const cpuValues = samples.map((sample) => sample.cpu_percent);
      const freeMemValues = samples.map((sample) => sample.free_mem_bytes);

      return {
        sample_count: samples.length,
        max_cpu_percent: max(cpuValues),
        avg_cpu_percent: average(cpuValues),
        min_free_mem_bytes: min(freeMemValues),
        avg_free_mem_bytes: average(freeMemValues),
        max_loadavg_1m: max(samples.map((sample) => sample.loadavg_1m)),
        samples
      };
    }
  };
}

function buildHostSample(cpuPercent) {
  const [loadavg1, loadavg5, loadavg15] = os.loadavg();

  return {
    captured_at: new Date().toISOString(),
    cpu_percent: cpuPercent,
    loadavg_1m: loadavg1,
    loadavg_5m: loadavg5,
    loadavg_15m: loadavg15,
    free_mem_bytes: os.freemem(),
    total_mem_bytes: os.totalmem(),
    process_rss_bytes: process.memoryUsage().rss
  };
}

function readCpuSample() {
  const line = fs.readFileSync('/proc/stat', 'utf8').split('\n')[0];
  const fields = line.trim().split(/\s+/).slice(1).map(Number);
  const idle = fields[3] + (fields[4] || 0);
  const total = fields.reduce((sum, value) => sum + value, 0);
  return { idle, total };
}

function cpuBusyPercent(previous, current) {
  const total = current.total - previous.total;
  const idle = current.idle - previous.idle;

  if (total <= 0) return 0;
  return ((total - idle) / total) * 100;
}

function ensurePlaywrightBrowser() {
  const install = spawnSync('npx', ['playwright', 'install', 'chromium'], {
    stdio: 'inherit'
  });

  if (install.status !== 0) {
    throw new Error('unable to install Playwright Chromium runtime');
  }
}

function ensureBenchmarkServerReady() {
  const url =
    process.env.STORE_BENCHMARK_BASE_URL || JSON.parse(fs.readFileSync(DATA_PATH, 'utf8')).base_url;
  const probe = spawnSync('node', [
    '-e',
    `
      const http = require('http');
      const req = http.get(${JSON.stringify(`${url.replace(/\/$/, '')}/shop`)}, (res) => {
        process.exit(res.statusCode >= 200 && res.statusCode < 400 ? 0 : 1);
      });
      req.on('error', () => process.exit(1));
      req.setTimeout(2000, () => process.exit(1));
    `
  ]);

  if (probe.status !== 0) {
    throw new Error(`benchmark endpoint ${url}/shop is not ready`);
  }
}

function cleanupTrackedChromiumPids() {
  if (!fs.existsSync(PID_PATH)) {
    return;
  }

  try {
    const pids = JSON.parse(fs.readFileSync(PID_PATH, 'utf8'));

    for (const pid of Array.isArray(pids) ? pids : []) {
      if (!Number.isInteger(pid)) continue;

      try {
        process.kill(pid, 'SIGTERM');
      } catch (_error) {
        // already gone
      }
    }
  } finally {
    persistPidFile([]);
  }
}

function listChromiumPids() {
  const result = spawnSync('bash', ['-lc', "pgrep -f 'chrome|chromium|chrome-linux|headless_shell' || true"], {
    encoding: 'utf8'
  });

  return new Set(
    String(result.stdout || '')
      .split('\n')
      .map((value) => value.trim())
      .filter(Boolean)
      .map((value) => Number.parseInt(value, 10))
      .filter(Number.isInteger)
  );
}

function diffPids(before, after) {
  return Array.from(after).filter((pid) => !before.has(pid));
}

function persistPidFile(pids) {
  ensureTmpDir();
  fs.writeFileSync(PID_PATH, JSON.stringify(pids, null, 2));
}

function aggregateResults(results) {
  const successful = results.filter((row) => !row.error);

  return {
    total: results.length,
    successful: successful.length,
    failed: results.length - successful.length,
    avg_static_http_ms: average(successful.map((row) => row.static_http_ms)),
    p95_static_http_ms: percentile(successful.map((row) => row.static_http_ms), 0.95),
    avg_ws_open_ms: average(successful.map((row) => row.ws_open_ms)),
    p95_ws_open_ms: percentile(successful.map((row) => row.ws_open_ms), 0.95),
    avg_join_ack_ms: average(successful.map((row) => row.join_ack_ms)),
    p95_join_ack_ms: percentile(successful.map((row) => row.join_ack_ms), 0.95),
    avg_post_join_hold_ms: average(successful.map((row) => row.post_join_hold_ms))
  };
}

function average(values) {
  const usable = values.filter((value) => Number.isFinite(value));
  if (usable.length === 0) return null;
  return usable.reduce((sum, value) => sum + value, 0) / usable.length;
}

function percentile(values, p) {
  const usable = values.filter((value) => Number.isFinite(value)).sort((a, b) => a - b);
  if (usable.length === 0) return null;
  const index = Math.min(usable.length - 1, Math.floor(usable.length * p));
  return usable[index];
}

function max(values) {
  const usable = values.filter((value) => Number.isFinite(value));
  return usable.length === 0 ? 0 : Math.max(...usable);
}

function min(values) {
  const usable = values.filter((value) => Number.isFinite(value));
  return usable.length === 0 ? 0 : Math.min(...usable);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function intEnv(name, fallback) {
  const value = process.env[name];
  if (!value) return fallback;
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function floatEnv(name, fallback) {
  const value = process.env[name];
  if (!value) return fallback;
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function ensureTmpDir() {
  fs.mkdirSync(path.dirname(RESULT_PATH), { recursive: true });
  fs.mkdirSync(path.dirname(PID_PATH), { recursive: true });
}
