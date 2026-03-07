import http from 'k6/http';
import { check, sleep } from 'k6';

import { data, storefrontUrl } from './common.js';

export const options = {
  scenarios: {
    webhook_ingress: {
      executor: 'constant-arrival-rate',
      rate: 20,
      timeUnit: '1s',
      duration: '3m',
      preAllocatedVUs: 20,
      maxVUs: 80
    }
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{route:webhook}': ['p(95)<700'],
    'http_req_duration{route:callback}': ['p(95)<700']
  }
};

export default function () {
  const useWebhook = Math.random() < 0.5;
  const fixture = useWebhook ? data.webhook_ingress.webhook : data.webhook_ingress.callback;
  const route = useWebhook ? 'webhook' : 'callback';

  const response = http.post(storefrontUrl(fixture.path), fixture.body, {
    headers: fixture.headers,
    tags: { route }
  });

  check(response, { 'accepted': (r) => r.status === 202 });
  sleep(1);
}
