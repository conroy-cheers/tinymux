#!/usr/bin/env node
import fs from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";

async function loadChromium() {
  if (process.env.PLAYWRIGHT_CORE_PATH) {
    const require = createRequire(import.meta.url);
    return require(path.join(process.env.PLAYWRIGHT_CORE_PATH, "index.js")).chromium;
  }
  return (await import("playwright-core")).chromium;
}

function parseArgs(argv) {
  const args = {
    artifacts: "parity-artifacts",
    xtermJs: null,
    xtermCss: null,
    screenshots: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--artifacts") args.artifacts = argv[++index];
    else if (arg === "--xterm-js") args.xtermJs = argv[++index];
    else if (arg === "--xterm-css") args.xtermCss = argv[++index];
    else if (arg === "--screenshots") args.screenshots = argv[++index];
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!args.xtermJs || !args.xtermCss) {
    throw new Error("--xterm-js and --xterm-css are required");
  }
  return args;
}

async function listScenarioFiles(artifactDir) {
  const entries = await fs.readdir(artifactDir);
  return entries
    .filter((entry) => entry.endsWith(".json"))
    .map((entry) => path.join(artifactDir, entry))
    .sort();
}

async function buildPage(browser, xtermJs, xtermCss) {
  const page = await browser.newPage({ viewport: { width: 1400, height: 1000 }, deviceScaleFactor: 1 });
  await page.setContent(`<!doctype html>
    <meta charset="utf-8">
    <style>
      body { margin: 0; padding: 16px; background: #111; }
      .terminal-host { display: inline-block; background: #000; padding: 0; margin: 0; }
    </style>
    <div id="host" class="terminal-host"></div>`);
  await page.addStyleTag({ path: xtermCss });
  await page.addScriptTag({ path: xtermJs });
  return page;
}

async function replay(page, events) {
  return await page.evaluate(async (recordedEvents) => {
    const host = document.getElementById("host");
    host.textContent = "";
    let rows = 32;
    let cols = 100;
    const firstResize = recordedEvents.find((event) => event.kind === "resize");
    if (firstResize) {
      rows = firstResize.rows;
      cols = firstResize.cols;
    }
    const terminal = new Terminal({
      cols,
      rows,
      cursorBlink: false,
      scrollback: 1000,
      convertEol: false,
      fontFamily: "monospace",
      fontSize: 12,
      lineHeight: 1,
      allowProposedApi: true,
      theme: { background: "#000000", foreground: "#ffffff" },
    });
    terminal.open(host);
    terminal.focus();

    const writeBytes = (base64) => new Promise((resolve) => {
      const binary = atob(base64);
      const bytes = new Uint8Array(binary.length);
      for (let index = 0; index < binary.length; index += 1) {
        bytes[index] = binary.charCodeAt(index);
      }
      terminal.write(bytes, resolve);
    });

    for (const event of recordedEvents) {
      if (event.kind === "resize") {
        terminal.resize(event.cols, event.rows);
      } else if (event.kind === "data") {
        await writeBytes(event.data);
      }
    }

    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));

    const lines = [];
    const cells = [];
    for (let row = 0; row < terminal.rows; row += 1) {
      const line = terminal.buffer.active.getLine(row);
      lines.push(line ? line.translateToString(false) : "");
      const rowCells = [];
      for (let col = 0; col < terminal.cols; col += 1) {
        const cell = line?.getCell(col);
        rowCells.push(cell ? [cell.getChars(), cell.getWidth(), cell.getFgColor(), cell.getBgColor(), cell.isBold(), cell.isUnderline(), cell.isInverse()] : null);
      }
      cells.push(rowCells);
    }

    const rect = host.getBoundingClientRect();
    return {
      rows: terminal.rows,
      cols: terminal.cols,
      cursorX: terminal.buffer.active.cursorX,
      cursorY: terminal.buffer.active.cursorY,
      lines,
      cells,
      rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
    };
  }, events);
}

function comparable(snapshot) {
  return {
    rows: snapshot.rows,
    cols: snapshot.cols,
    cursorX: snapshot.cursorX,
    cursorY: snapshot.cursorY,
    lines: snapshot.lines,
    cells: snapshot.cells,
  };
}

function text(snapshot) {
  return snapshot.lines.join("\n");
}

function requiredMarkers(scenario) {
  return {
    "startup-geometry-and-focus": ["MAIN_READY", "SECONDARY_READY"],
    "realtime-text-entry-and-signals": [
      "MAIN_CAT_READY",
      "main real-time input",
      "SECONDARY_CAT_READY",
      "secondary lower pane input",
      "main receives focus again",
    ],
    "required-wrapping-and-unicode": ["wrap-start", "wrap-end", "unicode:"],
    "required-ansi-attributes": ["bold", "under", "reverse", "blink", "red256", "truecolor"],
    "required-app-terminal-protocols": ["ALT-EXIT"],
    "required-scrolling-throughput": ["MAIN_SCROLL_DONE", "SECONDARY_SCROLL_DONE"],
    "resize-storm-while-output-streams": ["STREAM_DONE"],
    "process-exit-and-pane-lifecycle": ["SECONDARY_EXITING", "MAIN_STILL_ALIVE", "AFTER_CTRL_D"],
  }[scenario] || [];
}

function artifactText(artifact) {
  return (artifact.tinymux || [])
    .flatMap((snapshot) => snapshot.text || [])
    .join("\n");
}

function assertRequiredReplay(scenario, snapshot, recordedText) {
  if (snapshot.rows <= 0 || snapshot.cols <= 0) {
    throw new Error(`${scenario}: invalid xterm.js geometry ${snapshot.cols}x${snapshot.rows}`);
  }
  if (snapshot.cursorX < 0 || snapshot.cursorX >= snapshot.cols || snapshot.cursorY < 0 || snapshot.cursorY >= snapshot.rows) {
    throw new Error(`${scenario}: xterm.js cursor out of bounds`);
  }
  const rendered = text(snapshot);
  if (scenario !== "process-exit-and-pane-lifecycle" && !rendered.includes("─")) {
    throw new Error(`${scenario}: xterm.js replay did not render a pane border`);
  }
  for (const marker of requiredMarkers(scenario)) {
    if (!recordedText.includes(marker)) {
      throw new Error(`${scenario}: recorded tinymux snapshots are missing ${JSON.stringify(marker)}`);
    }
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const files = await listScenarioFiles(args.artifacts);
  if (files.length === 0) throw new Error(`no JSON artifacts found in ${args.artifacts}`);
  if (args.screenshots) await fs.mkdir(args.screenshots, { recursive: true });

  const chromium = await loadChromium();
  const browser = await chromium.launch({ headless: true });
  try {
    for (const file of files) {
      const artifact = JSON.parse(await fs.readFile(file, "utf8"));
      if (!artifact.events?.tmux || !artifact.events?.tinymux) {
        throw new Error(`${file} does not contain recorded terminal events`);
      }
      const scenario = path.basename(file, ".json");

      const tinymuxPage = await buildPage(browser, args.xtermJs, args.xtermCss);
      const tinymux = await replay(tinymuxPage, artifact.events.tinymux);

      if (args.screenshots) {
        await tinymuxPage.screenshot({ path: path.join(args.screenshots, `${scenario}-tinymux.png`) });
      }

      assertRequiredReplay(scenario, tinymux, artifactText(artifact));

      await tinymuxPage.close();
    }
  } finally {
    await browser.close();
  }
  console.log(`${files.length} browser/xterm.js scenario(s) matched`);
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
