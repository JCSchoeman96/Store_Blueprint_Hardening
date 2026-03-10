import http from 'k6/http';
import { check, sleep } from 'k6';

import { buildWebhookRequest, chaosThinkTimeSeconds, storefrontUrl, webhookMode } from './common.js';

const scenarioName = webhookMode === 'duplicate_replay' ? 'duplicate_replay' : 'unique_ingress';

export const options = {
  scenarios: {
    [scenarioName]: {
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
  const route = Math.random() < 0.5 ? 'webhook' : 'callback';
  const request = buildWebhookRequest(route, webhookMode);

  const response = http.post(storefrontUrl(request.path), request.body, {
    headers: request.headers,
    tags: { route, mode: webhookMode }
  });

  check(response, { 'accepted': (r) => r.status === 202 });
  sleep(chaosThinkTimeSeconds(`webhook:${route}:${webhookMode}`));
}
