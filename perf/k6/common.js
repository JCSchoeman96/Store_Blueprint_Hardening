import crypto from 'k6/crypto';
import http from 'k6/http';

const rawData = open(__ENV.STORE_BENCHMARK_DATA_PATH || '../../tmp/perf/benchmark_data.json');
const benchmarkData = JSON.parse(rawData);

export const baseUrl = (__ENV.STORE_BENCHMARK_BASE_URL || benchmarkData.base_url).replace(/\/$/, '');
export const data = benchmarkData;
export const webhookMode = __ENV.STORE_WEBHOOK_MODE || 'unique_ingress';

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

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}
