#!/usr/bin/env node
/**
 * pdf2text.mjs —— 把 PDF 转成「带页码标记的纯文本」，供 AI agent 按行/按页精准读取。
 *
 * 用法:
 *   node .tools/pdf2text.mjs pdf/新书.pdf                 # 全本转换 -> text/新书.txt
 *   node .tools/pdf2text.mjs pdf/新书.pdf --pages 100-160  # 只转需要的页段
 *   node .tools/pdf2text.mjs pdf/新书.pdf -o text/x.txt    # 指定输出
 *
 * 省 token 的三个设计点:
 *   1) 一次转换永久复用 —— agent 之后只读 txt，永远不再解析几十 MB 的 PDF；
 *   2) 每页有 `=== PAGE n ===` 标记 —— 可 grep 定位后，只读命中处前后几十行；
 *   3) --pages 支持只转当前要学的那一段。
 *
 * 依赖: pdfjs-dist（纯 JS，无需 Python/poppler）
 */
import { createRequire } from 'node:module';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const require = createRequire(import.meta.url);
const PDFJS_PKG = 'pdfjs-dist';

// ---------- CLI ----------
const argv = process.argv.slice(2);
if (!argv.length || argv.includes('-h') || argv.includes('--help')) {
  console.log(`用法: node tools/pdf2text.mjs <input.pdf> [-o out.txt] [--pages 1-50]`);
  process.exit(argv.length ? 0 : 1);
}

const input = argv[0];
const outIdx = Math.max(argv.indexOf('-o'), argv.indexOf('--out'));
const defaultOut = path.join(
  'text',
  path.basename(input).replace(/\.pdf$/i, '') + '.txt',
);
const output = outIdx > 0 ? argv[outIdx + 1] : defaultOut;

let range = null;
const pIdx = argv.indexOf('--pages');
if (pIdx > 0) {
  const m = /^(\d+)\s*-\s*(\d+)$/.exec(argv[pIdx + 1] ?? '');
  if (!m) {
    console.error('--pages 格式应为 起页-止页，例如 100-160');
    process.exit(1);
  }
  range = [Number(m[1]), Number(m[2])];
}

// ---------- 加载 pdfjs（从任意位置解析出包根，兼容 exports 限制）----------
const entry = require.resolve(`${PDFJS_PKG}/legacy/build/pdf.mjs`);
const pkgRoot = entry.slice(0, entry.indexOf(PDFJS_PKG) + PDFJS_PKG.length);
const pdfjs = await import(entry);

// ---------- 转换 ----------
const data = new Uint8Array(await readFile(input));
const doc = await pdfjs.getDocument({
  data,
  // 中文 PDF 必须给 CMap，否则 CJK 会乱码或丢字
  cMapUrl: path.join(pkgRoot, 'cmaps') + path.sep,
  cMapPacked: true,
  standardFontDataUrl: path.join(pkgRoot, 'standard_fonts') + path.sep,
  useSystemFonts: true,
}).promise;

const total = doc.numPages;
const [from, to] = range ? [Math.max(1, range[0]), Math.min(total, range[1])] : [1, total];
console.log(`共 ${total} 页，转换 ${from}-${to} ...`);

/** 按 y 坐标变化还原换行（PDF 没有真正的"行"概念） */
function pageToText(textContent) {
  let out = '';
  let lastY = null;
  for (const item of textContent.items) {
    if (typeof item.str !== 'string') continue;
    const y = item.transform?.[5];
    if (lastY !== null && typeof y === 'number' && Math.abs(y - lastY) > 1.5) out += '\n';
    out += item.str;
    if (item.hasEOL) out += '\n';
    if (typeof y === 'number') lastY = y;
  }
  return out
    .split('\n')
    .map((l) => l.replace(/[ \t]+$/g, '').trimEnd())
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
    // 关键：PDF 提取出的中文常混入「康熙部首」(U+2F00–U+2FDF) 等兼容字符，
    // 例如「运⾏」的 ⾏ 是 U+2F8F 而非 U+884C，会导致 grep 搜不到。
    // NFKC 会把它们归一化成正常汉字，同时把全角英数转半角。
    .normalize('NFKC');
}

const chunks = [];
// 章节标题候选：中文章节 / 数字编号小节
const headingRe = /^(第\s*[0-9一二三四五六七八九十百]+\s*[章节]|[0-9]{1,2}\.[0-9]{1,2}(\.[0-9]{1,2})?\s+\S|Chapter\s+\d+)/;
const headings = [];

for (let p = from; p <= to; p++) {
  const page = await doc.getPage(p);
  const text = pageToText(await page.getTextContent());
  chunks.push(`=== PAGE ${p} ===\n${text}`);
  for (const line of text.split('\n')) {
    const t = line.trim();
    // 过滤掉目录导语那种整句话（含中文标点），只留真标题
    if (/[，。；：、？！]/.test(t)) continue;
    if (t.length >= 3 && t.length <= 60 && headingRe.test(t)) headings.push([p, t]);
  }
  page.cleanup();
  if (p % 50 === 0 || p === to) process.stdout.write(`\r  已处理 ${p}/${to} 页`);
}

await mkdir(path.dirname(output), { recursive: true });
await writeFile(output, chunks.join('\n\n') + '\n', 'utf8');

// 索引：让 agent 先读索引再定位，避免全本扫描
const indexFile = output.replace(/\.txt$/i, '') + '.index.md';
await writeFile(
  indexFile,
  `# 章节索引（自动生成，供定位用）\n\n源文件: ${path.basename(input)}　页码范围: ${from}-${to}\n\n| 页 | 标题 |\n|---|---|\n` +
    headings.map(([p, t]) => `| ${p} | ${t.replace(/\|/g, '\\|')} |`).join('\n') +
    '\n',
  'utf8',
);

const bytes = (await readFile(output)).length;
console.log(
  `\n完成 ✔\n  正文: ${output}  (${(bytes / 1024).toFixed(0)} KB)\n  索引: ${indexFile}  (${headings.length} 条标题)`,
);
