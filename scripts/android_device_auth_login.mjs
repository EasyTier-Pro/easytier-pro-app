#!/usr/bin/env node

import {execFileSync} from 'node:child_process';

const defaults = {
  packageName: 'net.easytier.pro',
  serial: process.env.ANDROID_SERIAL || 'localhost:5555',
  devtoolsPort: Number(process.env.CHROME_DEVTOOLS_PORT || '9222'),
  timeoutMs: Number(process.env.ANDROID_AUTH_TIMEOUT_MS || '180000'),
};

const args = parseArgs(process.argv.slice(2));
const config = {
  packageName: args.packageName || defaults.packageName,
  serial: args.serial || defaults.serial,
  devtoolsPort: args.devtoolsPort
    ? Number(args.devtoolsPort)
    : defaults.devtoolsPort,
  timeoutMs: args.timeoutMs ? Number(args.timeoutMs) : defaults.timeoutMs,
  skipTap: args.skipTap,
};

const username =
  process.env.EASYTIER_E2E_USERNAME || process.env.EASYTIER_USERNAME;
const password =
  process.env.EASYTIER_E2E_PASSWORD || process.env.EASYTIER_PASSWORD;

if (!username || !password) {
  fail(
    'Set EASYTIER_E2E_USERNAME and EASYTIER_E2E_PASSWORD before running this script.',
  );
}

if (!Number.isFinite(config.devtoolsPort) || config.devtoolsPort <= 0) {
  fail('Invalid Chrome DevTools port.');
}

if (!Number.isFinite(config.timeoutMs) || config.timeoutMs <= 0) {
  fail('Invalid auth timeout.');
}

await main();

async function main() {
  const deadline = Date.now() + config.timeoutMs;
  log(`Using Android device ${config.serial}`);
  adb('wait-for-device');
  resetChromeDevtoolsForward(config.devtoolsPort);

  launchApp(config.packageName);
  await sleep(1500);

  let expectedDeviceCode = '';
  if (!config.skipTap) {
    for (let attempt = 0; attempt < 4; attempt += 1) {
      const xml = dumpUiXml();
      expectedDeviceCode = deviceCodeFromUiXml(xml) || expectedDeviceCode;
      const tapped = tapFlutterButtonByDescription(
        ['登录 EasyTier Pro', '重新尝试登录', '重新打开浏览器'],
        xml,
      );
      if (!tapped || expectedDeviceCode) {
        break;
      }
      await sleep(2500);
    }
  }

  const logMarker = latestLogLine(readLatestAppLog());
  const target = await waitForDeviceAuthTarget(deadline, expectedDeviceCode);
  log(`Approving device code ${deviceCodeFromUrl(target.url) || '<unknown>'}`);
  await approveDeviceAuthPage(target.webSocketDebuggerUrl, username, password);

  launchApp(config.packageName);
  await waitForAuthCompletion(deadline, logMarker);
  log('Device authorization completed.');
}

function parseArgs(argv) {
  const parsed = {
    serial: '',
    packageName: '',
    devtoolsPort: 0,
    timeoutMs: 0,
    skipTap: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) {
        fail(`Missing value for ${arg}`);
      }
      return argv[i];
    };

    switch (arg) {
      case '--serial':
        parsed.serial = next();
        break;
      case '--package':
        parsed.packageName = next();
        break;
      case '--devtools-port':
        parsed.devtoolsPort = Number(next());
        break;
      case '--timeout-ms':
        parsed.timeoutMs = Number(next());
        break;
      case '--skip-tap':
        parsed.skipTap = true;
        break;
      case '-h':
      case '--help':
        printUsage();
        process.exit(0);
        break;
      default:
        fail(`Unknown argument: ${arg}`);
    }
  }

  return parsed;
}

function printUsage() {
  console.log(`Usage:
  EASYTIER_E2E_USERNAME=... EASYTIER_E2E_PASSWORD=... \\
    node scripts/android_device_auth_login.mjs [options]

Options:
  --serial <adb-serial>        Android serial. Defaults to ANDROID_SERIAL or localhost:5555.
  --package <package-name>     Android package. Defaults to net.easytier.pro.
  --devtools-port <port>       Host Chrome DevTools port. Defaults to 9222.
  --timeout-ms <milliseconds>  Overall timeout. Defaults to 180000.
  --skip-tap                   Do not tap the app login/retry button first.
`);
}

function adb(...adbArgs) {
  return execFileSync('adb', ['-s', config.serial, ...adbArgs], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function adbShell(command) {
  return adb('shell', command);
}

function resetChromeDevtoolsForward(port) {
  try {
    adb('forward', '--remove', `tcp:${port}`);
  } catch {
    // Existing forward may not be present.
  }
  adb('forward', `tcp:${port}`, 'localabstract:chrome_devtools_remote');
}

function launchApp(packageName) {
  adb(
    'shell',
    'monkey',
    '-p',
    packageName,
    '-c',
    'android.intent.category.LAUNCHER',
    '1',
  );
}

function tapFlutterButtonByDescription(descriptions, xml = dumpUiXml()) {
  for (const description of descriptions) {
    const bounds = boundsForDescription(xml, description);
    if (!bounds) {
      continue;
    }
    const x = Math.floor((bounds.left + bounds.right) / 2);
    const y = Math.floor((bounds.top + bounds.bottom) / 2);
    log(`Tapping "${description}" at ${x},${y}`);
    adb('shell', 'input', 'tap', String(x), String(y));
    return true;
  }
  return false;
}

function dumpUiXml() {
  adb('shell', 'uiautomator', 'dump', '/sdcard/window.xml');
  return adb('shell', 'cat', '/sdcard/window.xml');
}

function boundsForDescription(xml, description) {
  const escapedDescription = escapeRegExp(escapeXmlAttribute(description));
  const re = new RegExp(
    `content-desc="${escapedDescription}"[\\s\\S]*?bounds="\\[(\\d+),(\\d+)\\]\\[(\\d+),(\\d+)\\]"`,
  );
  const match = xml.match(re);
  if (!match) {
    return null;
  }
  return {
    left: Number(match[1]),
    top: Number(match[2]),
    right: Number(match[3]),
    bottom: Number(match[4]),
  };
}

function deviceCodeFromUiXml(xml) {
  const userCodeMatch = xml.match(/content-desc="用户代码：([^"]+)"/);
  if (userCodeMatch) {
    return userCodeMatch[1];
  }
  const urlMatch = xml.match(/\/login\/oauth\/device\/([^"&\s]+)/);
  return urlMatch?.[1] || '';
}

async function waitForDeviceAuthTarget(deadline, expectedDeviceCode) {
  let lastError = '';
  while (Date.now() < deadline) {
    try {
      const targets = await fetchJson(
        `http://127.0.0.1:${config.devtoolsPort}/json/list`,
      );
      const deviceTargets = targets.filter(
        (item) =>
          item.type === 'page' &&
          typeof item.url === 'string' &&
          /\/login\/oauth\/device\//.test(item.url),
      );
      const target = expectedDeviceCode
        ? deviceTargets.find((item) => item.url.includes(expectedDeviceCode))
        : newestChromeTarget(deviceTargets);
      if (target?.webSocketDebuggerUrl) {
        return target;
      }
    } catch (error) {
      lastError = error.message;
    }
    await sleep(1000);
  }
  fail(`Timed out waiting for Chrome device auth page. ${lastError}`);
}

function newestChromeTarget(targets) {
  return [...targets].sort((left, right) => {
    const leftId = Number(left.id);
    const rightId = Number(right.id);
    if (Number.isFinite(leftId) && Number.isFinite(rightId)) {
      return rightId - leftId;
    }
    return String(right.id).localeCompare(String(left.id));
  })[0];
}

async function approveDeviceAuthPage(webSocketDebuggerUrl, user, pass) {
  const cdp = await connectCdp(webSocketDebuggerUrl);
  try {
    await cdp.call('Runtime.enable');
    await cdp.call('Network.enable');

    let submit;
    try {
      submit = await cdp.call('Runtime.evaluate', {
        expression: deviceAuthSubmitExpression(user, pass),
        returnByValue: true,
        awaitPromise: true,
      });
    } catch (error) {
      if (!isCdpRuntimeTimeout(error)) {
        throw error;
      }
      log('Chrome page stopped responding after submit; waiting for app completion.');
      return;
    }
    const value = submit.result?.result?.value;
    if (!value?.ok) {
      fail(`Could not submit device auth page: ${value?.reason || 'unknown'}`);
    }

    try {
      await waitForPageText(cdp, /Logged in successfully/i, 20000);
    } catch (error) {
      if (!isCdpRuntimeTimeout(error)) {
        throw error;
      }
      log('Chrome success page timed out; waiting for app completion.');
    }
  } finally {
    cdp.close();
  }
}

function isCdpRuntimeTimeout(error) {
  return error instanceof Error && error.message === 'CDP timeout: Runtime.evaluate';
}

function deviceAuthSubmitExpression(user, pass) {
  return `(() => {
    if (/Logged in successfully/i.test(document.body.innerText)) {
      return {ok: true, already: true};
    }
    const username =
      document.querySelector('#input') ||
      document.querySelector('input[name="username"]') ||
      document.querySelector('input[type="text"]');
    const password =
      document.querySelector('#normal_login_password') ||
      document.querySelector('input[type="password"]');
    if (!username || !password) {
      return {
        ok: false,
        reason: 'inputs not found',
        text: document.body.innerText.slice(0, 500),
      };
    }
    const setNativeValue = (element, value) => {
      const prototype = element instanceof HTMLTextAreaElement
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(prototype, 'value').set.call(element, value);
      element.dispatchEvent(new Event('input', {bubbles: true}));
      element.dispatchEvent(new Event('change', {bubbles: true}));
    };
    setNativeValue(username, ${JSON.stringify(user)});
    setNativeValue(password, ${JSON.stringify(pass)});
    const form =
      username.closest('form') ||
      password.closest('form') ||
      document.forms[0];
    if (!form) {
      return {ok: false, reason: 'form not found'};
    }
    form.requestSubmit();
    return {ok: true, submitted: true};
  })()`;
}

async function connectCdp(webSocketDebuggerUrl) {
  const socket = new WebSocket(webSocketDebuggerUrl);
  let nextId = 0;
  const pending = new Map();

  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = reject;
  });

  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
  };

  return {
    call(method, params = {}, timeoutMs = 10000) {
      const id = ++nextId;
      socket.send(JSON.stringify({id, method, params}));
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`CDP timeout: ${method}`));
        }, timeoutMs);
        pending.set(id, (message) => {
          clearTimeout(timer);
          if (message.error) {
            reject(new Error(`${method}: ${message.error.message}`));
            return;
          }
          resolve(message);
        });
      });
    },
    close() {
      socket.close();
    },
  };
}

async function waitForPageText(cdp, pattern, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const state = await cdp.call('Runtime.evaluate', {
      expression: 'document.body.innerText',
      returnByValue: true,
    });
    const text = state.result?.result?.value || '';
    if (pattern.test(text)) {
      return;
    }
    await sleep(1000);
  }
  fail('Timed out waiting for browser approval success text.');
}

async function waitForAuthCompletion(deadline, logMarker) {
  let lastLog = '';
  while (Date.now() < deadline) {
    const logText = readLatestAppLog();
    const relevantLog = logAfterMarker(logText, logMarker);
    lastLog = relevantLog.slice(-4000);
    if (
      relevantLog.includes('"Device authorization completed"') ||
      relevantLog.includes('"Session established"')
    ) {
      return;
    }
    if (
      relevantLog.includes('"Authorization completion failed"') ||
      relevantLog.includes('登录验证码已过期')
    ) {
      fail(`Device authorization failed. Recent log:\n${lastLog}`);
    }
    await sleep(2000);
  }
  fail(`Timed out waiting for app auth completion. Recent log:\n${lastLog}`);
}

function latestLogLine(logText) {
  const lines = logText.trim().split('\n').filter(Boolean);
  return lines.at(-1) || '';
}

function logAfterMarker(logText, marker) {
  if (!marker) {
    return logText;
  }
  const index = logText.indexOf(marker);
  if (index < 0) {
    return logText;
  }
  return logText.slice(index + marker.length);
}

function readLatestAppLog() {
  const script = [
    'latest=$(ls -1t',
    `/data/data/${config.packageName}/code_cache/easytier-pro-app/logs/gui-*.log`,
    '2>/dev/null | head -n 1);',
    '[ -n "$latest" ] && tail -n 240 "$latest"',
  ].join(' ');
  try {
    return adbShell(`run-as ${config.packageName} sh -c '${script}'`);
  } catch {
    return '';
  }
}

async function fetchJson(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`${url} returned ${response.status}`);
  }
  return response.json();
}

function deviceCodeFromUrl(url) {
  const match = url.match(/\/login\/oauth\/device\/([^/?#]+)/);
  return match?.[1] || '';
}

function escapeXmlAttribute(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function log(message) {
  console.log(`[android-auth] ${message}`);
}

function fail(message) {
  console.error(`[android-auth] ${message}`);
  process.exit(1);
}
