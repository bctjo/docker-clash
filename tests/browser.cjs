// Optional browser regression test: requires Playwright and Chromium.
const assert = require('node:assert/strict');
const path = require('node:path');
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.PLAYWRIGHT_EXECUTABLE_PATH || chromium.executablePath() });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 960 }, colorScheme: 'light' });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    const username = process.env.PORTAL_USERNAME || 'admin';
    const password = process.env.PORTAL_PASSWORD;
    const subscription = process.env.PORTAL_SUBSCRIPTION;
    const yamlPath = process.env.PORTAL_SETUP_YAML;
    const accountOnly = process.env.PORTAL_SETUP_ACCOUNT_ONLY === '1';
    const needsSetup = accountOnly || Boolean(subscription || yamlPath);
    if (accountOnly) {
      await page.goto(new URL('/setup/status.json', process.env.PORTAL_URL).href);
      await page.evaluate(() => {
        sessionStorage.setItem('portalAdminSession', JSON.stringify({ username: 'admin', password: 'old-password' }));
        sessionStorage.setItem('portalAdminKey', 'legacy-session');
      });
    }
    await page.goto(process.env.PORTAL_URL);
    if (needsSetup) {
      await page.locator('#setup-form').waitFor();
      assert.equal(await page.locator('#app').isVisible(), false);
      assert.equal(await page.locator('#login-form').isVisible(), false);
      assert.equal(await page.getByText('稍后配置', { exact: true }).count(), 0);
      assert.equal(await page.locator('[role="dialog"]:visible, .modal:visible').count(), 0);
      assert.equal(await page.locator('#setup-subscription').isVisible(), !accountOnly);
      if (accountOnly) {
        assert.equal(await page.locator('#access-title').textContent(), '初始化 Clash Portal');
        assert.match(await page.locator('#access-description').textContent(), /设置管理密码.*已有订阅/);
        assert.equal(await page.getByRole('button', { name: '设置密码并启用', exact: true }).count(), 1);
        assert.deepEqual(await page.evaluate(() => [
          sessionStorage.getItem('portalAdminSession'), sessionStorage.getItem('portalAdminKey')
        ]), [null, null]);
        await page.locator('#setup-submit').click();
        assert.equal(await page.locator('#setup-password').evaluate(input => input.validity.valueMissing), true);
        assert.equal(await page.locator('#app').isVisible(), false);
      }
      const screenshots = process.env.SETUP_SCREENSHOT_DIR;
      if (screenshots) await page.screenshot({ path: path.join(screenshots, 'setup-desktop.png'), fullPage: true });
      await page.setViewportSize({ width: 390, height: 844 });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), 390);
      if (screenshots) await page.screenshot({ path: path.join(screenshots, 'setup-mobile.png'), fullPage: true });
      await page.locator('#access-theme-toggle').click();
      assert.equal(await page.locator('html').getAttribute('data-theme'), 'dark');
      assert.equal(await page.locator('#setup-username').evaluate(input => getComputedStyle(input).backgroundColor), 'rgb(15, 23, 42)');
      if (screenshots) await page.screenshot({ path: path.join(screenshots, 'setup-dark-mobile.png'), fullPage: true });
      await page.locator('#setup-username').fill(username);
      await page.locator('#setup-password').fill(password);
      await page.locator('#setup-confirmation').fill('does-not-match');
      if (yamlPath) {
        await page.locator('#setup-source-file').check();
        await page.locator('#setup-file').setInputFiles(yamlPath);
        assert.equal(await page.locator('#setup-url').isVisible(), false);
      } else if (subscription) {
        await page.locator('#setup-url').fill(subscription);
      }
      await page.locator('#setup-submit').click();
      await page.locator('#setup-feedback').filter({ hasText: '不一致' }).waitFor();
      assert.equal(await page.locator('#app').isVisible(), false);
      await page.locator('#setup-confirmation').fill(password);
      await page.locator('#setup-submit').click();
      await page.locator('#info').filter({ hasText: 'HTTP' }).waitFor({ timeout: 60000 });
      assert.equal(await page.locator('#access-screen').isVisible(), false);
      assert.equal(await page.locator('html').getAttribute('data-theme'), 'dark');
      if (yamlPath) {
        await page.locator('#open-subs').click();
        const list = page.locator('#subs-list');
        await list.getByText(path.basename(yamlPath), { exact: true }).waitFor();
        await page.locator('#subs-file').setInputFiles({
          name: '替换测试.yml', mimeType: 'application/yaml',
          buffer: Buffer.from('mode: global\nproxies: [{name: Browser, type: http, server: 127.0.0.1, port: 10001}]\n')
        });
        await page.locator('#upload-sub').click();
        const row = list.getByText('替换测试.yml', { exact: true }).locator('../..');
        await row.getByRole('button', { name: '设为当前' }).click();
        await page.locator('#save-subs').click();
        await page.locator('#subs-modal').waitFor({ state: 'hidden', timeout: 30000 });
      }
      await page.reload();
      await page.locator('#info').filter({ hasText: 'HTTP' }).waitFor();
      await page.evaluate(() => sessionStorage.clear());
      await page.reload();
      console.log('PASS: full-screen responsive setup, required fields, password confirmation and automatic sign-in');
    }

    await page.locator('#login-form').waitFor();
    assert.equal(await page.locator('#app').isVisible(), false);
    await page.locator('#admin-username').fill(username);
    await page.locator('#admin-key').fill('wrong-password');
    await page.locator('#admin-confirm').click();
    await page.locator('#admin-error').filter({ hasText: '错误' }).waitFor();
    await page.locator('#admin-key').fill(password);
    await page.locator('#admin-confirm').click();
    await page.locator('#info').filter({ hasText: 'HTTP' }).waitFor();
    assert.equal(await page.locator('#login-form').isVisible(), false);
    if (!needsSetup) {
      await page.locator('#open-settings').click();
      await page.locator('#settings-modal.open').waitFor();
      assert.equal(await page.locator('#builtin-enabled').isChecked(), false);
      await page.locator('#save-settings').click();
      await page.locator('#settings-modal.open').waitFor({ state: 'hidden', timeout: 30000 });
      await page.locator('#update-sub').click();
      await page.waitForFunction(() => !document.querySelector('#update-sub').disabled, { timeout: 30000 });
      assert.match(await page.locator('#update-sub').getAttribute('title'), /成功|应用/);
    }
    await page.reload();
    await page.locator('#info').filter({ hasText: 'HTTP' }).waitFor();

    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), 390);
    await page.locator('#theme-toggle').click();
    const theme = await page.locator('html').getAttribute('data-theme');
    await page.evaluate(() => sessionStorage.setItem('portalAdminKey', 'legacy-session'));
    await page.getByRole('button', { name: '退出登录' }).click();
    await page.locator('#login-form').waitFor();
    assert.equal(await page.locator('#app').isVisible(), false);
    assert.equal(await page.locator('#link-metacubexd').getAttribute('href'), null);
    assert.deepEqual(await page.evaluate(() => [
      sessionStorage.getItem('portalAdminSession'), sessionStorage.getItem('portalAdminKey')
    ]), [null, null]);
    assert.equal(await page.locator('html').getAttribute('data-theme'), theme);

    await page.reload();
    await page.locator('#login-form').waitFor();
    assert.equal(await page.locator('#app').isVisible(), false);
    await page.locator('#admin-username').fill(username);
    await page.locator('#admin-key').fill(password);
    await page.locator('#admin-confirm').click();
    await page.locator('#info').filter({ hasText: 'HTTP' }).waitFor();
    assert.deepEqual(errors, []);
    console.log('PASS: full-screen login, invalid credentials, session reuse, logout and sign-in again');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
