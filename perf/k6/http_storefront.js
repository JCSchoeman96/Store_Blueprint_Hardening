import http from 'k6/http';
import { check, sleep } from 'k6';

import { data, getWithCheckoutCookie, pick, storefrontUrl } from './common.js';

export const options = {
  scenarios: {
    storefront: {
      executor: 'ramping-arrival-rate',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 200,
      stages: [
        { target: 25, duration: '1m' },
        { target: 100, duration: '3m' },
        { target: 100, duration: '5m' },
        { target: 0, duration: '1m' }
      ]
    }
  },
  thresholds: {
    http_req_failed: ['rate<0.02'],
    'http_req_duration{route:shop_index}': ['p(95)<500'],
    'http_req_duration{route:shop_show}': ['p(95)<500'],
    'http_req_duration{route:cart}': ['p(95)<700'],
    'http_req_duration{route:checkout}': ['p(95)<900'],
    'http_req_duration{route:webhook}': ['p(95)<700'],
    'http_req_duration{route:callback}': ['p(95)<700']
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
  } else if (roll < 0.95) {
    const checkout = pick(data.checkout.prepared_paths);
    const response = getWithCheckoutCookie(checkout.path, checkout.cart_token, {
      route: 'checkout'
    });
    check(response, { 'checkout ok': (r) => r.status === 200 });
  } else {
    const routeName = Math.random() < 0.5 ? 'webhook' : 'callback';
    const fixture =
      routeName === 'webhook'
        ? data.webhook_ingress.webhook
        : data.webhook_ingress.callback;

    const response = http.post(storefrontUrl(fixture.path), fixture.body, {
      headers: fixture.headers,
      tags: { route: routeName }
    });

    check(response, { [`${routeName} accepted`]: (r) => r.status === 202 });
  }

  sleep(1);
}
