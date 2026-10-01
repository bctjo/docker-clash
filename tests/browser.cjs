// Optional browser regression test: requires Playwright and its Chromium binary.
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH || chromium.executablePath() });
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(process.env.PORTAL_URL);
    if (process.env.BROWSER_NO_AUTH !== '1') {
      await page.locator('#admin-modal.open').waitFor();
      await page.locator('#admin-key').fill('wrong-password');
      await page.locator('#admin-confirm').click();
      await page.locator('#admin-error').filter({hasText: '错误'}).waitFor();
      await page.locator('#admin-key').fill(process.env.PORTAL_PASSWORD);
      await page.locator('#admin-confirm').click();
    }
    await page.locator('#info').filter({hasText: 'Secret'}).waitFor();
    assert.equal(await page.locator('#admin-modal.open').count(), 0);
    if (process.env.BROWSER_SETUP_ONLY === '1') {
      await page.locator('#subs-modal.open').waitFor();
      await page.locator('#close-subs').click();
      for (const expected of [true, false]) {
        await page.locator('#open-settings').click();
        await page.locator('#settings-modal.open').waitFor();
        await page.locator('label.toggle').filter({hasText: '使用内置规则'}).click();
        assert.equal(await page.locator('#builtin-enabled').isChecked(), expected);
        await page.locator('#save-settings').click();
        await page.locator('#settings-modal.open').waitFor({state: 'hidden', timeout: 30000});
      }
      assert.deepEqual(errors, []);
      console.log('PASS: first-time setup can open settings and change template before importing nodes');
      return;
    }
    await page.locator('#open-settings').click();
    await page.locator('#settings-modal.open').waitFor();
    assert.equal(await page.locator('#builtin-enabled').isChecked(), false);
    await page.locator('#save-settings').click();
    await page.locator('#settings-modal.open').waitFor({state: 'hidden', timeout: 30000});
    await page.locator('#update-sub').click();
    await page.waitForFunction(() => !document.querySelector('#update-sub').disabled, {timeout: 30000});
    assert.match(await page.locator('#update-sub').getAttribute('title'), /成功|应用/);
    await page.reload();
    await page.locator('#info').filter({hasText: 'Secret'}).waitFor();
    assert.deepEqual(errors, []);
    console.log('PASS: browser login, wrong password, default settings, saving, update completion, session reuse');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
