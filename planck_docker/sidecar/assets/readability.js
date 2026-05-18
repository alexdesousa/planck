#!/usr/bin/env node
"use strict";

const { Readability } = require("@mozilla/readability");
const { JSDOM } = require("jsdom");
const TurndownService = require("turndown");

const url = process.argv[2];

if (!url) {
  process.stderr.write("Usage: readability.js <url>\n");
  process.exit(1);
}

(async () => {
  try {
    const res = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0 (compatible; Planck/1.0)" },
      signal: AbortSignal.timeout(10_000),
    });

    if (!res.ok) {
      process.stderr.write(`HTTP ${res.status} for ${url}\n`);
      process.exit(1);
    }

    const html = await res.text();
    const dom = new JSDOM(html, { url });
    const reader = new Readability(dom.window.document);
    const article = reader.parse();

    if (!article) {
      process.stderr.write(`Could not parse content from ${url}\n`);
      process.exit(1);
    }

    const td = new TurndownService({ headingStyle: "atx", bulletListMarker: "-" });
    const markdown = td.turndown(article.content);

    process.stdout.write(`# ${article.title}\n\n${markdown}\n`);
  } catch (err) {
    process.stderr.write(`Error fetching ${url}: ${err.message}\n`);
    process.exit(1);
  }
})();
