// Bundle src/index.js into ../ios/App/Resources/analytics.js (IIFE defining globalThis.I20Analytics).
import { build } from "esbuild";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const outfile = path.join(here, "..", "ios", "App", "Resources", "analytics.js");

export async function buildBundle() {
  await build({
    entryPoints: [path.join(here, "src", "index.js")],
    bundle: true,
    format: "iife",
    globalName: "__i20",
    footer: { js: "globalThis.I20Analytics = { runAll: __i20.runAll };" },
    platform: "neutral",
    target: "es2020",
    outfile,
    legalComments: "none",
  });
  return outfile;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) console.log("wrote", await buildBundle());
