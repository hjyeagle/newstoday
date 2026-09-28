#!/usr/bin/env node
// 네이버 블로그(동방예술관) RSS를 읽어 index.html의 blogData 배열(08번 섹션)을
// 자동으로 갱신하는 스크립트. GitHub Actions(.github/workflows/sync-naver-blog.yml)가
// 주기적으로 이 스크립트를 실행하고, 변경이 있으면 커밋·푸시한다.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const RSS_URL = "https://rss.blog.naver.com/dongbang_artmuseum.xml";
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const INDEX_PATH = path.join(__dirname, "..", "index.html");
const MAX_ITEMS = 300;

function extractAll(re, str) {
  const out = [];
  let m;
  while ((m = re.exec(str)) !== null) out.push(m[1]);
  return out;
}

function unwrapCdata(s) {
  const m = /<!\[CDATA\[([\s\S]*?)\]\]>/.exec(s || "");
  return (m ? m[1] : s || "").trim();
}

function cleanUrl(url) {
  return url.split("?")[0];
}

function escapeJsString(s) {
  return s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function formatDate(pubDate) {
  const d = new Date(pubDate);
  if (Number.isNaN(d.getTime())) return "";
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Seoul",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(d);
  const get = (t) => parts.find((p) => p.type === t).value;
  return `${get("year")}.${get("month")}.${get("day")}`;
}

function dateToKey(dateStr) {
  const t = new Date(dateStr.replace(/\./g, "-")).getTime();
  return Number.isNaN(t) ? 0 : t;
}

async function fetchRssItems() {
  const res = await fetch(RSS_URL, {
    headers: { "User-Agent": "newstoday-sync-bot/1.0" },
  });
  if (!res.ok) throw new Error(`RSS fetch failed: ${res.status} ${res.statusText}`);
  const xml = await res.text();
  const itemBlocks = extractAll(/<item>([\s\S]*?)<\/item>/g, xml);

  return itemBlocks.map((block) => {
    const title = unwrapCdata(/<title>([\s\S]*?)<\/title>/.exec(block)?.[1] ?? "");
    const category = unwrapCdata(/<category>([\s\S]*?)<\/category>/.exec(block)?.[1] ?? "");
    const link = unwrapCdata(/<link>([\s\S]*?)<\/link>/.exec(block)?.[1] ?? "");
    const rawGuid = unwrapCdata(/<guid[^>]*>([\s\S]*?)<\/guid>/.exec(block)?.[1] ?? "");
    const guid = rawGuid || cleanUrl(link);
    const pubDate = (/<pubDate>([\s\S]*?)<\/pubDate>/.exec(block)?.[1] ?? "").trim();
    return {
      date: formatDate(pubDate),
      category,
      title,
      url: cleanUrl(link),
      guid,
      _sortKey: dateToKey(formatDate(pubDate)) || new Date(pubDate).getTime() || 0,
    };
  }).filter((item) => item.title && item.url && item.guid);
}

function parseExistingItems(html) {
  const blockMatch = /const blogData = \[([\s\S]*?)\n\];/.exec(html);
  if (!blockMatch) return { existing: null };
  const body = blockMatch[1];
  const entries = extractAll(/\{([\s\S]*?)\}/g, body);
  const existing = entries.map((entry) => {
    const get = (key) => {
      const m = new RegExp(`${key}:\\s*"((?:[^"\\\\]|\\\\.)*)"`).exec(entry);
      return m ? m[1].replace(/\\"/g, '"').replace(/\\\\/g, "\\") : "";
    };
    const date = get("date");
    return {
      date,
      category: get("category"),
      title: get("title"),
      url: get("url"),
      guid: get("guid"),
      _sortKey: dateToKey(date),
    };
  });
  return { existing };
}

function buildBlockText(items) {
  if (items.length === 0) return "const blogData = [\n];";
  const lines = items.map((item) => (
    `{ date: "${item.date}", category: "${escapeJsString(item.category)}", ` +
    `title: "${escapeJsString(item.title)}", url: "${item.url}", guid: "${item.guid}" }`
  ));
  return `const blogData = [\n${lines.join(",\n")}\n];`;
}

async function main() {
  const html = readFileSync(INDEX_PATH, "utf8");
  const { existing } = parseExistingItems(html);
  if (existing === null) {
    console.error("index.html에서 blogData 배열을 찾을 수 없습니다. 08번 섹션이 먼저 있어야 합니다.");
    process.exit(1);
  }

  const fetched = await fetchRssItems();

  const byGuid = new Map();
  for (const item of existing) byGuid.set(item.guid, item);
  for (const item of fetched) byGuid.set(item.guid, item);

  const merged = [...byGuid.values()]
    .sort((a, b) => b._sortKey - a._sortKey)
    .slice(0, MAX_ITEMS)
    .map(({ _sortKey, ...rest }) => rest);

  const newBlock = buildBlockText(merged);
  const updatedHtml = html.replace(/const blogData = \[[\s\S]*?\n\];/, newBlock);

  if (updatedHtml === html) {
    console.log("변경 사항 없음 — 신규 게시글이 없습니다.");
    return;
  }

  writeFileSync(INDEX_PATH, updatedHtml, "utf8");
  console.log(`blogData 갱신 완료 — 총 ${merged.length}건 (기존 ${existing.length}건 + RSS ${fetched.length}건 병합).`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
