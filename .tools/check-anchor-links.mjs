#!/usr/bin/env node
/**
 * 校验 Markdown 内部锚点链接：`文件.md#锚点` 是否真的能跳准。
 *
 * 做法：把目标文件的标题按 **GitHub/VS Code 的 slug 规则**转成锚点，再和链接里的锚点逐字比对。
 *   slug 规则（已用官方 github-slugger 在 docs/ 全部 355 个标题上逐字比对，差异 0 条）：
 *     去 markdown 装饰 → 小写 → **只保留 字母 \p{L} / 十进制数字 \p{Nd} / 组合符 \p{M} / `-` / `_` /空格**
 *     → 空格替换成 `-`（不合并连续空格）→ 重名标题追加 `-1`、`-2`
 *   ⚠️ 两个容易踩的点：① 像 `①`（\p{No}）这种“其它数字”会被删（不跟 \p{N} 走）
 *      ② 变体选择符 U+FE0F 这类组合符**要保留**（GitHub 会保留），所以不能一刀切删 \p{M}
 *   ⚠️ 代码块里的 `# 注释` 不算标题（本仓库 04 里有这种情况）
 *
 * 用法：
 *   node .tools/check-anchor-links.mjs                     # 默认校验 docs/00-知识点索引.md
 *   node .tools/check-anchor-links.mjs docs docs/00-知识点索引.md
 *   node .tools/check-anchor-links.mjs docs                # 第二个参数省略时，扫该目录下所有 md 文件的内部锚点
 */

import fs from 'node:fs';
import path from 'node:path';

const argRoot = process.argv[2] ?? 'docs';
const argIndexFiles = process.argv.slice(3);
const root = path.resolve(argRoot);

// ---------- slug ----------
function slugify(text) {
  return text
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1') // [文字](链接) -> 文字
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{Nd}\p{M}\-_ ]/gu, '') // 标点/符号/emoji/圈号全去掉，- _ 与空格留下
    .replace(/ /g, '-');
}

// ---------- 标题提取（跳过代码块）----------
const headingCache = new Map();
function headingsOf(absFile) {
  if (headingCache.has(absFile)) return headingCache.get(absFile);
  const lines = fs.readFileSync(absFile, 'utf8').split(/\r?\n/);
  const list = [];
  let fenceChar = null;
  lines.forEach((line, i) => {
    const fence = line.match(/^\s*(`{3,}|~{3,})/);
    if (fence) {
      const c = fence[1][0];
      if (!fenceChar) fenceChar = c;
      else if (c === fenceChar) fenceChar = null;
      return;
    }
    if (fenceChar) return;
    const m = line.match(/^(#{1,6})\s+(.+?)\s*$/);
    if (m) list.push({ line: i + 1, text: m[2] });
  });
  const seen = new Map();
  for (const h of list) {
    let s = slugify(h.text);
    if (seen.has(s)) {
      const n = seen.get(s) + 1;
      seen.set(s, n);
      s = `${s}-${n}`;
    } else {
      seen.set(s, 0);
    }
    h.slug = s;
  }
  headingCache.set(absFile, list);
  return list;
}

// ---------- 收集待校验的链接 ----------
function mdFilesIn(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...mdFilesIn(p));
    else if (e.isFile() && e.name.endsWith('.md')) out.push(p);
  }
  return out;
}

const targets = argIndexFiles.length
  ? argIndexFiles.map((f) => path.resolve(f))
  : mdFilesIn(root);

const linkRe = /\[[^\]]*\]\(([^)\s]+)\)/g;
let total = 0;
const oks = [];
const misses = [];
const skipped = [];

for (const src of targets) {
  if (!fs.existsSync(src)) {
    misses.push({ src, line: 0, link: src, why: '源文件不存在' });
    continue;
  }
  const lines = fs.readFileSync(src, 'utf8').split(/\r?\n/);
  lines.forEach((line, i) => {
    for (const m of line.matchAll(linkRe)) {
      const link = m[1];
      if (!link.includes('#')) continue;
      const [filePart, anchorRaw] = link.split('#');
      const anchor = decodeURIComponent(anchorRaw);
      let absTarget;
      if (!filePart) absTarget = src;
      else if (filePart.startsWith('http')) { skipped.push(link); continue; }
      else absTarget = path.resolve(path.dirname(src), filePart);

      if (!fs.existsSync(absTarget)) {
        misses.push({ src, line: i + 1, link, why: '目标文件不存在', absTarget });
        continue;
      }
      total++;
      const hs = headingsOf(absTarget);
      if (hs.some((h) => h.slug === anchor)) {
        oks.push({ src, line: i + 1, link });
      } else {
        misses.push({ src, line: i + 1, link, absTarget, hs, anchor });
      }
    }
  });
}

// ---------- 就近猜测 ----------
function levenshtein(a, b) {
  const dp = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 0; j <= b.length; j++) dp[0][j] = j;
  for (let i = 1; i <= a.length; i++)
    for (let j = 1; j <= b.length; j++)
      dp[i][j] = Math.min(
        dp[i - 1][j] + 1,
        dp[i][j - 1] + 1,
        dp[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)
      );
  return dp[a.length][b.length];
}

const rel = (p) => path.relative(process.cwd(), p);

console.log(`校验文件：${targets.length} 个 · 带锚点的链接：${total} 条`);
console.log(`✅ 命中：${oks.length}    ❌ 未命中：${misses.length}    ⏭ 跳过(外链)：${skipped.length}`);
console.log('');

if (misses.length) {
  console.log('— 未命中明细 —');
  for (const m of misses) {
    console.log(`❌ ${rel(m.src)}:${m.line}`);
    console.log(`   链接   : ${m.link}`);
    if (m.why) {
      console.log(`   原因   : ${m.why}`);
      continue;
    }
    const best = m.hs
      .map((h) => ({ h, d: levenshtein(m.anchor, h.slug) }))
      .sort((x, y) => x.d - y.d)
      .slice(0, 2);
    for (const b of best) {
      console.log(`   想找的是? (差异${b.d}) ${b.h.slug}   ← 行 ${b.h.line} 「${b.h.text}」`);
    }
  }
  console.log('');
}

// ---------- 反向：哪些标题还没被索引收录 ----------
const referenced = new Set();
for (const o of oks) {
  const [filePart, anchor] = o.link.split('#');
  referenced.add(`${path.resolve(path.dirname(o.src), filePart)}#${decodeURIComponent(anchor)}`);
}

const coveredFiles = new Set([...referenced].map((r) => r.split('#')[0]));
const uncovered = [];
for (const f of new Set([...coveredFiles])) {
  if (!fs.existsSync(f)) continue;
  for (const h of headingsOf(f)) {
    if (h.slug === '') continue;
    if (!referenced.has(`${f}#${h.slug}`)) uncovered.push({ f, h });
  }
}

if (uncovered.length) {
  console.log(`— 讲义里有、但索引没收录的小节（${uncovered.length} 个，按需补）—`);
  for (const { f, h } of uncovered) console.log(`   ${rel(f)}:${h.line}  ${h.text}`);
  console.log('');
}
console.log(`小计：锚点校验 ${oks.length} 通过 / ${misses.length} 失败 · 未收录小节 ${uncovered.length} 个`);
process.exit(misses.length ? 1 : 0);
