import http from 'k6/http';
import { check, sleep } from 'k6';

import { data, getWithCheckoutCookie, pick, storefrontUrl } from './common.js';

const quickMode = __ENV.STORE_K6_QUICK === '1';
const warmupMs = parseOptionalInt(__ENV.STORE_K6_WARMUP_MS);
const measureMs = parseOptionalInt(__ENV.STORE_K6_MEASURE_MS);
const cooldownMs = parseOptionalInt(__ENV.STORE_K6_COOLDOWN_MS);
const phase308Mode = warmupMs !== null && measureMs !== null && cooldownMs !== null;

export const options = {
  scenarios: {
    storefront: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 200,
      stages: phase308Mode ? customStages() : quickMode ? quickStages() : defaultStages()
    }
  },
  thresholds: {
    http_req_failed: ['rate<0.02'],
    'http_req_duration{route:shop_index}': ['p(95)<500'],
    'http_req_duration{route:shop_show}': ['p(95)<500'],
    'http_req_duration{route:cart}': ['p(95)<700'],
    'http_req_duration{route:checkout}': ['p(95)<900']
  }
};

export default function () {
  const roll = Math.random();

  if (roll < 0.35) {
    const response = http.get(storefrontUrl('/shop'), { tags: { route: 'shop_index' } });
    check(response, { 'shop index ok': (r) => r.status === 200 });
  } else if (roll < 0.70) {
    const slug = pick(data.storefront.hot_slugs.concat([data.storefront.flash_sale_slug]));
    const response = http.get(storefrontUrl(`/shop/${slug}`), { tags: { route: 'shop_show' } });
    check(response, { 'shop show ok': (r) => r.status === 200 });
  } else if (roll < 0.85) {
    const response = http.get(storefrontUrl('/cart'), { tags: { route: 'cart' } });
    check(response, { 'cart ok': (r) => r.status === 200 });
  } else {
    const checkout = pick(data.checkout.prepared_paths);
    const response = getWithCheckoutCookie(checkout.path, checkout.cart_token, {
      route: 'checkout'
    });
    check(response, { 'checkout ok': (r) => r.status === 200 });
  }

  sleep(1);
}

function defaultStages() {
  return [
    { target: 25, duration: '1m' },
    { target: 100, duration: '3m' },
    { target: 100, duration: '5m' },
    { target: 0, duration: '1m' }
  ];
}

function quickStages() {
  return [
    { target: 10, duration: '20s' },
    { target: 30, duration: '40s' },
    { target: 30, duration: '40s' },
    { target: 0, duration: '20s' }
  ];
}

function customStages() {
  const peakTarget = quickMode ? 30 : 100;
  const warmupTarget = quickMode ? 10 : 25;

  return [
    { target: warmupTarget, duration: durationString(warmupMs) },
    { target: peakTarget, duration: durationString(measureMs) },
    { target: 0, duration: durationString(cooldownMs) }
  ];
}

function durationString(ms) {
  return `${Math.max(Math.round(ms / 1000), 1)}s`;
}

function parseOptionalInt(value) {
  if (!value) {
    return null;
  }

  const parsed = parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}
