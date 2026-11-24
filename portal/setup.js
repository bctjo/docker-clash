const sessionKey = 'portalAdminSession';
const previousSessionKey = 'portalAdminKey';
const byId = (id) => document.getElementById(id);
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function basicAuth(username, password) {
  const encoded = new TextEncoder().encode(`${username}:${password}`);
  return { Authorization: `Basic ${btoa(String.fromCharCode(...encoded))}` };
}

export async function readYamlUpload(file) {
  if (!file || !/\.ya?ml$/i.test(file.name)) throw new Error('请选择 .yaml 或 .yml 文件。');
  if (!file.size || file.size > 16 * 1024 * 1024) throw new Error('YAML 文件须为 1 字节至 16 MiB。');
  const content = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result.split(',', 2)[1]);
    reader.onerror = () => reject(new Error('无法读取本地 YAML 文件。'));
    reader.onabort = reader.onerror;
    reader.readAsDataURL(file);
  });
  return { name: file.name, content };
}

export function createAccess() {
  const app = byId('app');
  const screen = byId('access-screen');
  const title = byId('access-title');
  const description = byId('access-description');
  const steps = byId('access-steps');
  const setup = byId('setup-form');
  const login = byId('login-form');
  const setupResult = byId('setup-feedback');
  const loginError = byId('admin-error');
  const account = byId('setup-account');
  const existing = byId('setup-existing');
  const subscription = byId('setup-subscription');
  const setupUrl = byId('setup-url');
  const setupFile = byId('setup-file');
  const setupFileMode = byId('setup-source-file');
  const submitSetup = byId('setup-submit');
  const setupButtonText = submitSetup.firstElementChild;
  const submitLogin = byId('admin-confirm');
  let status = null;
  let busy = false;
  let loginPromise;
  let resolveLogin;

  function updateSourceFields() {
    for (const [input, visible] of [[setupUrl, !setupFileMode.checked], [setupFile, setupFileMode.checked]]) {
      input.closest('label').hidden = !visible;
      input.disabled = !visible;
      input.required = visible;
    }
  }

  for (const radio of subscription.querySelectorAll('input[name="setup-source"]')) {
    radio.addEventListener('change', updateSourceFields);
  }

  function readSession() {
    try {
      const stored = JSON.parse(sessionStorage.getItem(sessionKey));
      if (typeof stored?.username === 'string' && typeof stored?.password === 'string') return stored;
      const previous = sessionStorage.getItem(previousSessionKey);
      if (previous) return { username: 'admin', password: previous };
    } catch { /* Invalid session data is replaced at sign-in. */ }
    return null;
  }

  function remember(username, password) {
    sessionStorage.setItem(sessionKey, JSON.stringify({ username, password }));
    sessionStorage.removeItem(previousSessionKey);
  }

  function clearSession() {
    sessionStorage.removeItem(sessionKey);
    sessionStorage.removeItem(previousSessionKey);
  }

  function headers() {
    const credentials = readSession();
    return credentials ? basicAuth(credentials.username, credentials.password) : {};
  }

  function feedback(element, text = '', error = false) {
    element.textContent = text;
    element.dataset.error = String(error);
    element.hidden = !text;
  }

  function showApp() {
    screen.hidden = true;
    app.hidden = false;
  }

  function display(view, heading, copy) {
    app.hidden = true;
    screen.hidden = false;
    setup.hidden = view !== 'setup';
    login.hidden = view !== 'login';
    steps.hidden = view === 'login';
    title.textContent = heading;
    description.textContent = copy;
  }

  function renderSetup(next) {
    if (next.state !== 'pending') {
      display('loading', '正在启动 Clash Portal', '服务将在订阅配置生效后开放。');
      return;
    }
    if (next.needsAccount && !status?.needsAccount) clearSession();

    let description = '登录管理账号并导入有效订阅，即可进入控制台。';
    if (next.needsAccount) {
      description = next.needsSubscription
        ? '请先设置管理密码并导入订阅，再进入控制台。'
        : '请先设置管理密码。已有订阅将继续使用。';
    }
    display('setup', '初始化 Clash Portal', description);
    setupButtonText.textContent = next.needsSubscription ? '校验并启用' : '设置密码并启用';
    for (const [group, visible] of [[account, next.needsAccount],
      [existing, !next.needsAccount], [subscription, next.needsSubscription]]) {
      group.hidden = !visible;
      group.disabled = !visible;
    }
    if (next.needsSubscription && !status?.needsSubscription) byId('setup-builtin').checked = next.builtinEnabled === true;
    for (const [name, complete] of [['account', !next.needsAccount], ['subscription', !next.needsSubscription]]) {
      byId(`setup-step-${name}`).dataset.complete = String(complete);
      byId(`setup-step-${name}-state`).textContent = complete ? '已配置' : '待配置';
    }
    if (!setupResult.textContent && next.message) feedback(setupResult, next.message, true);
  }

  async function waitForSetup() {
    while (true) {
      try {
        const response = await fetch('/setup/status.json', { cache: 'no-store' });
        if (response.ok) {
          const next = await response.json();
          if (!busy && next.state === 'ready') return;
          if (!busy && (next.state !== status?.state || next.needsAccount !== status?.needsAccount
              || next.needsSubscription !== status?.needsSubscription || next.message !== status?.message)) {
            renderSetup(next);
            status = next;
          }
        }
      } catch {
        if (!status && !busy) display('loading', '正在连接 Clash Portal', '服务暂不可用，正在重新连接。');
      }
      await delay(1000);
    }
  }

  function requestId() {
    return Array.from(crypto.getRandomValues(new Uint8Array(16)), byte => byte.toString(16).padStart(2, '0')).join('');
  }

  async function awaitSetupResult(id, auth, timeoutSeconds) {
    const deadline = Date.now() + timeoutSeconds * 1000;
    while (Date.now() < deadline) {
      await delay(1000);
      try {
        const response = await fetch(`/setup/results/${id}.json`, { headers: auth, cache: 'no-store' });
        if (!response.ok) {
          const state = await fetch('/setup/status.json', { cache: 'no-store' });
          if (state.ok && (await state.json()).state === 'ready') return;
          continue;
        }
        const result = await response.json();
        if (result.state === 'failed') return result.message;
        if (result.state === 'success') return;
        if (result.message) feedback(setupResult, result.message);
      } catch { /* The service may briefly be unavailable while starting. */ }
    }
    return '等待初始化结果超时。请检查订阅链接并刷新页面确认状态。';
  }

  setup.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (busy || status?.state !== 'pending') return;
    const needsAccount = status.needsAccount;
    const username = byId(needsAccount ? 'setup-username' : 'setup-existing-username').value.trim();
    const password = byId(needsAccount ? 'setup-password' : 'setup-existing-password').value;
    const payload = {};
    if (needsAccount) {
      const confirmation = byId('setup-confirmation').value;
      if (password !== confirmation) {
        feedback(setupResult, '两次输入的密码不一致。', true);
        return;
      }
      Object.assign(payload, { username, password, confirmation });
    }
    if (status.needsSubscription) {
      if (!setupFileMode.checked) payload.url = setupUrl.value.trim();
      if (!setupFileMode.checked && !/^https?:\/\//.test(payload.url)) {
        feedback(setupResult, '请输入以 http:// 或 https:// 开头的订阅链接。', true);
        return;
      }
      payload.builtinEnabled = byId('setup-builtin').checked;
    }

    const auth = needsAccount ? {} : basicAuth(username, password);
    const id = requestId();
    const idleButtonText = setupButtonText.textContent;
    busy = true;
    submitSetup.disabled = true;
    setupButtonText.textContent = '正在初始化';
    setup.setAttribute('aria-busy', 'true');
    feedback(setupResult, '正在提交配置…');
    try {
      if (status.needsSubscription && setupFileMode.checked) payload.upload = await readYamlUpload(setupFile.files[0]);
      const response = await fetch(`/setup/requests/${id}`, {
        method: 'PUT', headers: { ...auth, 'Content-Type': 'application/json' }, body: JSON.stringify(payload)
      });
      if (response.status === 409) {
        feedback(setupResult, '初始化已完成，正在打开登录页…');
        return;
      }
      if (response.status === 403 || response.status === 401) {
        throw new Error(needsAccount ? '初始化请求被拒绝，请刷新页面后重试。' : '用户名或密码错误，请重试。');
      }
      if (!response.ok) throw new Error('无法提交配置，请重试。');
      const error = await awaitSetupResult(id, auth, status.timeoutSeconds || 600);
      if (error) throw new Error(error);
      remember(username, password);
      setup.reset();
      updateSourceFields();
      feedback(setupResult, '初始化完成，正在打开控制台…');
    } catch (error) {
      feedback(setupResult, error.message || '初始化失败，请重试。', true);
    } finally {
      busy = false;
      submitSetup.disabled = false;
      setupButtonText.textContent = idleButtonText;
      setup.removeAttribute('aria-busy');
    }
  });

  function requireLogin(error = '') {
    if (loginPromise) return loginPromise;
    const appWasVisible = !app.hidden;
    display('login', '登录 Clash Portal', '使用管理账号进入控制台。');
    feedback(loginError, error, Boolean(error));
    byId('admin-username').value = readSession()?.username || '';
    byId('admin-key').value = '';
    byId('admin-username').focus();
    loginPromise = new Promise((resolve) => {
      resolveLogin = () => {
        if (appWasVisible) showApp();
        loginPromise = undefined;
        resolve();
      };
    });
    return loginPromise;
  }

  login.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (submitLogin.disabled || !resolveLogin) return;
    submitLogin.disabled = true;
    feedback(loginError);
    const username = byId('admin-username').value.trim();
    const password = byId('admin-key').value;
    try {
      const response = await fetch('/connection.json', { headers: basicAuth(username, password), cache: 'no-store' });
      if (response.status === 401 || response.status === 403) throw new Error('用户名或密码错误，请重试。');
      if (!response.ok) throw new Error('暂时无法登录，请重试。');
      remember(username, password);
      login.reset();
      resolveLogin();
      resolveLogin = undefined;
    } catch (error) {
      feedback(loginError, error.message, true);
    } finally {
      submitLogin.disabled = false;
    }
  });

  return { waitForSetup, showApp, requireLogin, readSession, clearSession, remember, headers };
}
