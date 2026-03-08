export default {
  testDir: '.',
  testMatch: /product_detail_live_join\.mjs$/,
  reporter: 'list',
  workers: 1,
  use: {
    headless: true
  }
};
