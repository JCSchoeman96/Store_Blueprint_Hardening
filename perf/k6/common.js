import http from 'k6/http';

const rawData = open(__ENV.STORE_BENCHMARK_DATA_PATH || 'tmp/perf/benchmark_data.json');
const benchmarkData = JSON.parse(rawData);

export const baseUrl = (__ENV.STORE_BENCHMARK_BASE_URL || benchmarkData.base_url).replace(/\/$/, '');
export const data = benchmarkData;

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
