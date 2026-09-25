import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

// 加载项目根目录（src 或 dist 的上一级）的 .env 文件
// 已存在的环境变量优先，便于临时覆盖：LINK_SERVER=... npm run dev
const envPath = join(__dirname, '..', '.env');
if (existsSync(envPath)) {
  for (const line of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    if (process.env[m[1]] === undefined) {
      process.env[m[1]] = m[2].replace(/^['"]/, '').replace(/['"]$/, '');
    }
  }
}
