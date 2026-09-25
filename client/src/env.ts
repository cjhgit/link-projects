import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

// 加载顺序（先到先得，已存在的环境变量优先，便于临时覆盖：LINK_SERVER=... npm run dev）：
//   1. 进程环境变量
//   2. 项目根目录（src 或 dist 的上一级）的 .env
//   3. 全局 ~/.link-projects/client.env
function loadEnvFile(path: string) {
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    if (process.env[m[1]] === undefined) {
      process.env[m[1]] = m[2].replace(/^['"]/, '').replace(/['"]$/, '');
    }
  }
}

loadEnvFile(join(__dirname, '..', '.env'));
loadEnvFile(join(homedir(), '.link-projects', 'client.env'));
