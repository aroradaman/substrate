#!/usr/bin/env node
// Render locally with an isolated browser profile. No remote rendering service.
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const book = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
function value(flag, fallback) {
  const i = args.indexOf(flag);
  return i < 0 ? fallback : args[i + 1];
}
const toolRoot = path.resolve(value('--tools', '/private/tmp/substrate-book-tools'));
const chrome = value('--chrome', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
const partial = args.includes('--partial');
const figuresOnly = args.includes('--figures-only');
const lifecycle = args.includes('--lifecycle');
const stem = lifecycle ? 'actor-lifecycle' : 'agent_substrate';
const figureDir = lifecycle ? 'lifecycle-figures' : 'figures';
const validationFile = lifecycle ? 'lifecycle-validation.json' : 'validation.json';
const renderFile = lifecycle ? 'lifecycle-render-validation.json' : 'render-validation.json';
const requireTools = createRequire(path.join(toolRoot, 'package.json'));
const puppeteer = requireTools('puppeteer');
const mermaidPath = path.join(toolRoot, 'node_modules/mermaid/dist/mermaid.min.js');
const mermaidVersion = JSON.parse(await fs.readFile(path.join(toolRoot, 'node_modules/mermaid/package.json'), 'utf8')).version;
const cliVersion = JSON.parse(await fs.readFile(path.join(toolRoot, 'node_modules/@mermaid-js/mermaid-cli/package.json'), 'utf8')).version;
const buildArgs = [path.join(book, 'build.py'), ...(partial ? ['--partial'] : []), ...(lifecycle ? ['--lifecycle'] : [])];
execFileSync('python3', buildArgs, { stdio: 'inherit' });
const manifest = JSON.parse(await fs.readFile(path.join(book, figureDir, 'manifest.json'), 'utf8'));
const old = await fs.readFile(path.join(book, renderFile), 'utf8').then(JSON.parse).catch(() => ({}));
const known = new Map((old.figures || []).map(f => [f.id, f]));
const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'substrate-book-browser-'));
const results = [];
// Markdown labels let Mermaid wrap long node text without changing graph edges.
function printLabels(source) {
  if (!/^\s*(flowchart|graph)\b/.test(source)) return source;
  return source.replace(/(\b[A-Za-z][\w-]*)\[([^\]\n]+)\]/g, (whole, id, label) => {
    if (label.length < 20 || /["`\[\]]/.test(label) || /^[([]/.test(label)) return whole;
    return `${id}["\`${label}\`"]`;
  });
}
// Sequence messages wrap to short lines so each label stays narrower than the gap between lifelines.
function wrapText(text, max = 14) {
  if (text.includes('<br')) return text;
  const lines = [];
  let current = '';
  for (const word of text.split(' ')) {
    const candidate = current ? current + ' ' + word : word;
    if (candidate.length <= max || !current) current = candidate;
    else { lines.push(current); current = word; }
  }
  lines.push(current);
  return lines.join('<br/>');
}
function wrapSequence(source) {
  if (!/^\s*sequenceDiagram\b/.test(source)) return source;
  return source.split('\n').map(line => {
    const match = line.match(/^(\s*(?:\w+\s*)?(?:-->>|->>|-->|->|--x|-x|--\)|-\))\s*\w+\s*:\s*)(.+)$/);
    return match ? match[1] + wrapText(match[2]) : line;
  }).join('\n');
}

let browser;
try {
  browser = await puppeteer.launch({
    executablePath: chrome,
    headless: true,
    userDataDir: profile,
    args: ['--disable-background-networking', '--disable-component-update', '--disable-sync', '--no-first-run', '--no-default-browser-check'],
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 1440, height: 1050, deviceScaleFactor: 1 });
  await page.setRequestInterception(true);
  page.on('request', request => {
    const url = request.url();
    if (url.startsWith('http:') || url.startsWith('https:')) request.abort();
    else request.continue();
  });
  await page.setContent('<!doctype html><html><head><meta charset="utf-8"></head><body style="background:white"></body></html>');
  await page.addScriptTag({ path: mermaidPath });
  await page.evaluate(() => {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: 'base',
      fontFamily: 'Arial, Helvetica, sans-serif',
      themeVariables: { primaryColor: '#e6f3f1', primaryTextColor: '#153441', primaryBorderColor: '#287b7a', lineColor: '#56717f', secondaryColor: '#eef2f7', tertiaryColor: '#fff8e5', fontSize: '15px' },
      flowchart: { htmlLabels: false, curve: 'linear', padding: 12, nodeSpacing: 20, rankSpacing: 30, wrappingWidth: 135 },
      sequence: { useMaxWidth: true, wrap: true, width: 110, actorMargin: 22, messageMargin: 24, diagramMarginX: 15, noteMargin: 8, wrapPadding: 6, actorFontSize: 14, messageFontSize: 14, noteFontSize: 14 },
    });
  });
  for (const figure of manifest) {
    const previous = known.get(figure.id);
    const output = path.join(book, figure.output);
    const exists = await fs.access(output).then(() => true, () => false);
    if (previous?.sha256 === figure.sha256 && previous.ok && exists && old.mermaid_version === mermaidVersion && old.serialization_version === 4) {
      results.push({ ...figure, ok: true, cached: true });
      continue;
    }
    const source = await fs.readFile(path.join(book, figure.input), 'utf8');
    try {
      const svg = await page.evaluate(async ({ id, source, layoutSource }) => {
        await mermaid.parse(source);
        const result = await mermaid.render('figure-' + id, layoutSource);
        const holder = document.createElement('div');
      holder.style.cssText = 'position:absolute;left:0;top:0;visibility:hidden';
      holder.innerHTML = result.svg;
      document.body.appendChild(holder);
      const svgEl = holder.querySelector('svg');
      // Sequence labels get a white knockout so lifelines stop at the label instead of running through it.
      // Notes are left alone: their opaque box already covers the lifelines.
      if (svgEl.getAttribute('aria-roledescription') === 'sequence') {
        const ns = 'http://www.w3.org/2000/svg';
        const labels = [...svgEl.querySelectorAll('text.messageText, text.loopText, text.sectionTitle')];
        labels.forEach(t => {
          const b = t.getBBox();
          const r = document.createElementNS(ns, 'rect');
          r.setAttribute('class', 'label-knockout');
          r.setAttribute('x', b.x - 3); r.setAttribute('y', b.y - 2);
          r.setAttribute('width', b.width + 6); r.setAttribute('height', b.height + 4);
          r.setAttribute('fill', '#ffffff');
          t.parentNode.insertBefore(r, t);
        });
        // Paint every label after every knockout, so a later line's knockout cannot clip
        // the descenders of the line above it in a wrapped label.
        labels.forEach(t => t.parentNode.appendChild(t));
      }
      const out = new XMLSerializer().serializeToString(svgEl);
      holder.remove();
      return out;
      }, { id: figure.id, source, layoutSource: wrapSequence(printLabels(source)) });
      await fs.writeFile(output, svg);
      results.push({ ...figure, ok: true, cached: false });
    } catch (error) {
      results.push({ ...figure, ok: false, error: String(error) });
      console.error(`${figure.id}: ${String(error).slice(0, 500)}`);
    }
    if (results.length % 5 === 0) console.log(`Rendered ${results.length}/${manifest.length} figures`);
  }
  const report = { mermaid_version: mermaidVersion, mermaid_cli_version: cliVersion, serialization_version: 4,
    browser_version: await browser.version(), figures: results,
    failed_figures: results.filter(f => !f.ok).length, network_requests_allowed: false };
  await fs.writeFile(path.join(book, renderFile), JSON.stringify(report, null, 2) + '\n');
  execFileSync('python3', buildArgs, { stdio: 'inherit' });
  if (report.failed_figures) throw new Error(`${report.failed_figures} Mermaid figures failed validation`);
  if (!figuresOnly) {
    const inputValidation = JSON.parse(await fs.readFile(path.join(book, validationFile), 'utf8'));
    report.source_sha256 = inputValidation.source_sha256;
    const doc = await browser.newPage();
    await doc.setViewport({ width: 1440, height: 1050, deviceScaleFactor: 1 });
    await doc.setRequestInterception(true);
    doc.on('request', request => {
      const url = request.url();
      if (url.startsWith('http:') || url.startsWith('https:')) request.abort();
      else request.continue();
    });
    await doc.goto(pathToFileURL(path.join(book, stem + '.html')).href, { waitUntil: 'load', timeout: 60000 });
    await doc.evaluate(async () => {
      await document.fonts.ready;
      await Promise.all([...document.images].map(img => img.complete ? Promise.resolve() : new Promise(resolve => { img.onload = resolve; img.onerror = resolve; })));
    });
    report.html_checks = await doc.evaluate(() => {
      const ids = new Set([...document.querySelectorAll('[id]')].map(e => e.id));
      const brokenAnchors = [...document.querySelectorAll('a[href^="#"]')].filter(a => !ids.has(decodeURIComponent(a.getAttribute('href').slice(1)))).map(a => a.getAttribute('href'));
      const overflow = [...document.querySelectorAll('main pre, main table, main figure')].filter(e => e.scrollWidth > e.clientWidth + 3).map(e => ({ tag: e.tagName, text: e.textContent.slice(0, 120) }));
      const failed = [...document.images].filter(i => !i.complete || i.naturalWidth === 0);
      return { broken_anchors: [...new Set(brokenAnchors)], overflow_elements: overflow, failed_images: failed.length, failed_image_ids: failed.map(i => i.closest('figure')?.id) };
    });
    const previewDir = path.join(os.tmpdir(), lifecycle ? 'substrate-lifecycle-previews' : 'substrate-book-previews');
    await fs.mkdir(previewDir, { recursive: true });
    await doc.screenshot({ path: path.join(previewDir, 'cover.png') });
    await doc.pdf({
      path: path.join(book, stem + '.pdf'),
      printBackground: true,
      preferCSSPageSize: true,
      displayHeaderFooter: true,
      headerTemplate: '<div></div>',
      footerTemplate: '<div style="width:100%;font-family:Arial;font-size:8px;color:#64707a;padding:0 44px;display:flex;justify-content:space-between"><span>Agent Substrate</span><span class="pageNumber"></span></div>',
      timeout: 60000,
      tagged: true,
      outline: true,
    });
    const pdf = await fs.readFile(path.join(book, stem + '.pdf'));
    report.pdf_sha256 = createHash('sha256').update(pdf).digest('hex');
    report.pdf_pages = (pdf.toString('latin1').match(/\/Type\s*\/Page\b/g) || []).length;
    report.pdf_bytes = pdf.length;
    report.preview_directory = previewDir;
    report.changed_during_render = [];
    for (const [file, expected] of Object.entries(report.source_sha256 || {})) {
      const actual = createHash('sha256').update(await fs.readFile(path.join(book, file))).digest('hex');
      if (actual !== expected) report.changed_during_render.push(file);
    }
    console.log(`PDF: ${report.pdf_pages} pages, ${report.pdf_bytes} bytes`);
    await fs.writeFile(path.join(book, renderFile), JSON.stringify(report, null, 2) + '\n');
    execFileSync('python3', buildArgs, { stdio: 'inherit' });
    if (report.changed_during_render.length) throw new Error('Manuscript changed during rendering; rerun against the completed revision');
    if (report.html_checks.broken_anchors.length || report.html_checks.failed_images || report.html_checks.overflow_elements.length) {
      throw new Error('HTML layout/reference checks failed; inspect render-validation.json');
    }
  }
} finally {
  if (browser) await browser.close();
  await fs.rm(profile, { recursive: true, force: true });
}
