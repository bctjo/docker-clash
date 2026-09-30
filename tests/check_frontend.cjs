const fs = require('node:fs');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const html = fs.readFileSync('portal/index.html', 'utf8');
for (const [index, match] of [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)].entries()) {
  if (!match[2].trim()) continue;
  if (/type="module"/.test(match[1])) {
    const result = spawnSync(process.execPath, ['--check', '--input-type=module'], {input: match[2], encoding: 'utf8'});
    if (result.status !== 0) throw new Error(result.stderr);
  } else new vm.Script(match[2], {filename: `portal-script-${index}.js`});
}
console.log('Frontend scripts passed syntax checks');
