import http from 'k6/http';
import { check, sleep } from 'k6';

import { data, pick, storefrontUrl } from './common.js';

const quickMode = __ENV.STORE_K6_QUICK === '1';

export const options = {
  scenarios: {
    shop_detail: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: 25,
      maxVUs: 150,
      stages: quickMode ? quickStages() : defaultStages()
    }
  },
  thresholds: {
    http_req_failed: ['rate<0.02'],
    'http_req_duration{route:shop_show}': ['p(95)<500']
  }
};

export default function () {
  const slug = pick(data.storefront.hot_slugs.concat([data.storefront.flash_sale_slug]));
  const response = http.get(storefrontUrl(`/shop/${slug}`), { tags: { route: 'shop_show' } });

  check(response, { 'shop show ok': (r) => r.status === 200 });

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
