import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

const TEXT_EXTENSIONS = new Set([
  ".css", ".csv", ".html", ".js", ".json", ".md", ".mjs", ".ps1", ".py", ".sql",
  ".svg", ".ts", ".tsx", ".txt", ".webmanifest", ".xml", ".yaml", ".yml",
]);
const SKIP_DIRECTORIES = new Set([".git", ".deps", ".venv", "CacheStorage", "node_modules", "vendor"]);
const MOJIBAKE = /\uFFFD|[\u0080-\u009F]|(?:Ã|Â|Å|Ä|â)[\u0080-\u02FF\u2000-\u2122]/gu;
const MAX_FINDINGS = 50;

function hasMojibake(value) {
  MOJIBAKE.lastIndex = 0;
  return MOJIBAKE.test(value);
}

function selfTest() {
  const clean = [
    "Połączenie · działa — właściciel",
    "Ångström and Änderung are legitimate text",
  ];
  const broken = [
    "po\u00c5\u201a\u00c4\u2026czenie",
    "System \u00c2\u00b7 FADEWELL HQ",
    "STATUS NIEDOST\u00c4\u02dcPNY",
    "bad" + String.fromCharCode(0x81) + "control",
    String.fromCharCode(0xfffd),
  ];

  for (const sample of clean) {
    if (hasMojibake(sample)) {
      throw new Error("Mojibake detector false positive: " + JSON.stringify(sample));
    }
  }
  for (const sample of broken) {
    if (!hasMojibake(sample)) {
      throw new Error("Mojibake detector false negative: " + JSON.stringify(sample));
    }
  }
}

async function walk(root) {
  const entries = await readdir(root, { withFileTypes: true });
  const files = [];
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.isDirectory() && SKIP_DIRECTORIES.has(entry.name)) continue;
    const target = path.join(root, entry.name);
    if (entry.isDirectory()) files.push(...await walk(target));
    else if (entry.isFile()) files.push(target);
  }
  return files;
}

function relativeFile(file) {
  return path.relative(process.cwd(), file).split(path.sep).join("/");
}

function snippet(line) {
  return line.trim().replace(/\s+/g, " ").slice(0, 160);
}

async function scan(root) {
  const allFiles = await walk(root);
  const files = allFiles.filter((file) => TEXT_EXTENSIONS.has(path.extname(file).toLowerCase()));
  const findings = [];

  for (const file of files) {
    let text;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(await readFile(file));
    } catch (error) {
      findings.push({
        file: relativeFile(file),
        line: 0,
        column: 0,
        kind: "invalid UTF-8",
        snippet: error instanceof Error ? error.message : String(error),
      });
      continue;
    }

    const lines = text.split(/\r?\n/);
    for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
      MOJIBAKE.lastIndex = 0;
      for (const match of lines[lineIndex].matchAll(MOJIBAKE)) {
        findings.push({
          file: relativeFile(file),
          line: lineIndex + 1,
          column: (match.index ?? 0) + 1,
          kind: "mojibake signature " + JSON.stringify(match[0]),
          snippet: snippet(lines[lineIndex]),
        });
        if (findings.length >= MAX_FINDINGS) {
          return { files, findings, truncated: true };
        }
      }
    }
  }

  return { files, findings, truncated: false };
}

async function main() {
  selfTest();
  const root = path.resolve(process.argv[2] || "web");
  const result = await scan(root);

  if (result.findings.length > 0) {
    console.error("FAIL: malformed UTF-8 or mojibake detected before Pages deployment.");
    for (const finding of result.findings) {
      const location = finding.line > 0
        ? finding.file + ":" + finding.line + ":" + finding.column
        : finding.file;
      console.error("- " + location + " — " + finding.kind);
      if (finding.snippet) console.error("  " + finding.snippet);
    }
    if (result.truncated) console.error("Only the first " + MAX_FINDINGS + " findings are shown.");
    process.exitCode = 1;
    return;
  }

  console.log(
    "PASS: checked " + result.files.length + " text asset(s) under " + root +
    "; UTF-8 is valid and no mojibake signatures were found.",
  );
}

await main();
