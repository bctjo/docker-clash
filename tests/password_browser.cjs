const assert = require('node:assert/strict');
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH || chromium.executablePath() });
  try {
    const page = await browser.newPage({ viewport: { width: 390, height: 740 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(process.env.PORTAL_URL);
    await page.locator('#admin-modal.open').waitFor();
    await page.locator('#admin-key').fill(process.env.PORTAL_PASSWORD);
    await page.locator('#admin-confirm').click();
    await page.locator('#info').filter({ hasText: 'Secret' }).waitFor();
    await page.locator('#subs-modal.open').waitFor();
    await page.locator('#close-subs').click();
    await page.locator('#open-settings').click();
    await page.locator('#password-form').waitFor({ state: 'visible' });
    if (process.env.PASSWORD_SCREENSHOT) await page.screenshot({ path: process.env.PASSWORD_SCREENSHOT });
    await page.locator('#current-password').fill('wrong-password');
    await page.locator('#new-password').fill(process.env.PORTAL_NEW_PASSWORD);
    await page.locator('#confirm-password').fill(process.env.PORTAL_NEW_PASSWORD);
    await page.locator('#change-password').click();
    await page.locator('#password-result').filter({ hasText: '当前密码不正确' }).waitFor();
    await page.locator('#current-password').fill(process.env.PORTAL_PASSWORD);
    await page.locator('#confirm-password').fill('different-password');
    await page.locator('#change-password').click();
    await page.locator('#password-result').filter({ hasText: '不一致' }).waitFor();
    await page.locator('#confirm-password').fill(process.env.PORTAL_NEW_PASSWORD);
    await page.locator('#change-password').click();
    await page.locator('#password-result').filter({ hasText: '密码已修改并保存' }).waitFor({ timeout: 30000 });
    assert.equal(await page.evaluate(() => sessionStorage.getItem('portalAdminKey')), process.env.PORTAL_NEW_PASSWORD);
    assert.equal(await page.locator('#new-password').inputValue(), '');
    await page.reload();
    await page.locator('#info').filter({ hasText: 'Secret' }).waitFor();
    assert.equal(await page.locator('#admin-modal.open').count(), 0);
    assert.deepEqual(errors, []);
    console.log('PASS: browser password validation, rotation, mobile settings and session reuse');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
