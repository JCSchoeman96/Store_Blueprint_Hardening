import crypto from 'k6/crypto';
import http from 'k6/http';

const rawData = open(__ENV.STORE_BENCHMARK_DATA_PATH || '../../tmp/perf/benchmark_data.json');
const benchmarkData = JSON.parse(rawData);

export const baseUrl = (__ENV.STORE_BENCHMARK_BASE_URL || benchmarkData.base_url).replace(/\/$/, '');
export const data = benchmarkData;
export const webhookMode = __ENV.STORE_WEBHOOK_MODE || 'unique_ingress';
export const chaosProfile = __ENV.STORE_PERF_CHAOS_PROFILE || 'baseline';
export const chaosSeed = __ENV.STORE_PERF_CHAOS_SEED || 'store-perf-chaos';

export function storefrontUrl(path) {
  return `${baseUrl}${path}`;
}

export function pick(list) {
  return list[Math.floor(Math.random() * list.length)];
}

export function preparedCheckoutEntry() {
  return pick(data.checkout.prepared_paths);
}

export function checkoutCookieParams() {
  return { domain: '127.0.0.1', path: '/' };
}

export function getWithCheckoutCookie(path, cartToken, tags = {}) {
  const jar = http.cookieJar();
  jar.set(baseUrl, 'cart_token', cartToken, checkoutCookieParams());
  return http.get(storefrontUrl(path), { tags });
}

export function buildWebhookRequest(route, mode = webhookMode) {
  const fixture = route === 'webhook' ? data.webhook_ingress.webhook : data.webhook_ingress.callback;
  const payload = buildStripePayload(fixture.payload_template, mode);
  const body = JSON.stringify(payload);
  const timestamp = Math.floor(Date.now() / 1000);

  return {
    path: fixture.path,
    body,
    headers: {
      'content-type': 'application/json',
      'stripe-signature': stripeSignature(body, timestamp, data.webhook_ingress.signing_secret)
    }
  };
}

export function chaosThinkTimeSeconds(label, fallbackSeconds = 1) {
  if (chaosProfile === 'baseline') {
    return fallbackSeconds;
  }

  const ranges =
    chaosProfile === 'provider_incident'
      ? [
          [2000, 3500],
          [3500, 5000],
          [5000, 6500]
        ]
      : [
          [1000, 2000],
          [2000, 3500],
          [3500, 5000]
        ];

  return deterministicRangeMs(`think:${label}`, ranges) / 1000;
}

export function liveSocketLatencyMs() {
  switch (chaosProfile) {
    case 'mobile_realistic':
      return 400;
    case 'provider_incident':
      return 700;
    default:
      return 0;
  }
}

export async function installLiveSocketLatencySim(target) {
  const latencyMs = liveSocketLatencyMs();

  if (latencyMs <= 0 || typeof target.addInitScript !== 'function') {
    return latencyMs;
  }

  await target.addInitScript((ms) => {
    const install = () => {
      if (window.liveSocket && typeof window.liveSocket.enableLatencySim === 'function') {
        window.liveSocket.enableLatencySim(ms);
        return;
      }

      window.setTimeout(install, 5);
    };

    install();
  }, latencyMs);

  return latencyMs;
}

function buildStripePayload(template, mode) {
  const payload = clone(template);

  if (mode === 'duplicate_replay') {
    return payload;
  }

  if (mode !== 'unique_ingress') {
    throw new Error(`Unsupported STORE_WEBHOOK_MODE=${mode}`);
  }

  const uniqueSuffix = `${Date.now()}-${__VU}-${__ITER}`;
  const object = payload.data.object;
  const metadata = object.metadata || {};

  payload.id = `evt_${uniqueSuffix}`;
  object.id = `pi_${uniqueSuffix}`;
  object.checkout_session_id = `cs_${uniqueSuffix}`;
  metadata.order_ref = `P30-ORDER-${uniqueSuffix}`;
  metadata.idempotency_key = `pi-key-${uniqueSuffix}`;
  object.metadata = metadata;

  return payload;
}

function stripeSignature(body, timestamp, secret) {
  const digest = crypto.hmac('sha256', secret, `${timestamp}.${body}`, 'hex');
  return `t=${timestamp},v1=${digest}`;
}

function deterministicRangeMs(label, ranges) {
  const rangeIndex = deterministicInt(`${label}:range`, ranges.length);
  const [minMs, maxMs] = ranges[rangeIndex];
  const span = Math.max(maxMs - minMs + 1, 1);

  return minMs + deterministicInt(`${label}:offset`, span);
}

function deterministicInt(label, modulus) {
  if (!Number.isFinite(modulus) || modulus <= 0) {
    return 0;
  }

  const digest = crypto.sha256(`${chaosSeed}:${chaosProfile}:${label}:${__VU}:${__ITER}`, 'hex');
  const value = Number.parseInt(digest.slice(0, 8), 16);
  return value % modulus;
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}
