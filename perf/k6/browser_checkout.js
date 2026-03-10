import { browser } from 'k6/browser';
import { check } from 'k6';

import { chaosThinkTimeSeconds, data, installLiveSocketLatencySim, storefrontUrl } from './common.js';

export const options = {
  scenarios: {
    browser_checkout: {
      executor: 'shared-iterations',
      vus: 5,
      iterations: 25,
      options: {
        browser: {
          type: 'chromium'
        }
      }
    }
  },
  thresholds: {
    checks: ['rate>0.99']
  }
};

export default async function () {
  const page = await browser.newPage();

  try {
    await installLiveSocketLatencySim(page);
    const slug = data.checkout.browser_ready_checkout.product_slug;
    await page.goto(storefrontUrl(`/shop/${slug}`));
    await pause(page, 'shop_show');
    await page.locator('#add-to-cart-handoff').click();
    await page.waitForURL(/\/cart$/);
    await pause(page, 'cart');
    await page.locator('#start-checkout').click();
    await page.waitForURL(/\/checkout\?checkout_key=/);

    // The current checkout LiveView requires server-generated quote options.
    // Use a browser-ready checkout fixture to exercise the payment-facing half
    // of the real UI without inventing a synthetic HTTP checkout API.
    await page.context().clearCookies();
    await page.context().addCookies([
      {
        name: 'cart_token',
        value: data.checkout.browser_ready_checkout.cart_token,
        domain: '127.0.0.1',
        path: '/'
      }
    ]);

    await page.goto(storefrontUrl(data.checkout.browser_ready_checkout.checkout_path));
    await pause(page, 'checkout_load');
    await page.locator('#finalize-totals').click();
    await page.waitForTimeout(300);
    await pause(page, 'finalize_totals');

    const payNow = page.locator('#pay-now');
    await check(payNow, {
      'pay button enabled': async (locator) => !(await locator.isDisabled())
    });

    await payNow.click();
    await page.waitForTimeout(300);
    await pause(page, 'pay_now');

    await check(page, {
      'payment intent rendered or redirected':
        async (currentPage) =>
          /checkout\.stripe\.example/.test(currentPage.url()) ||
          (await currentPage.locator('body').textContent()).includes('Payment intent:')
    });
  } finally {
    await page.close();
  }
}

async function pause(page, label) {
  const waitMs = Math.round(chaosThinkTimeSeconds(`browser_checkout:${label}`, 0) * 1000);

  if (waitMs > 0) {
    await page.waitForTimeout(waitMs);
  }
}
