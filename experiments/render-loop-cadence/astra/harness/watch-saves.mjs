import { statSync, appendFileSync, readdirSync, existsSync } from "node:fs";
const root = "/tmp/weaver-exp-astra/runs";
const seen = new Map();
setInterval(() => {
  if (!existsSync(root)) return;
  for (const run of readdirSync(root)) {
    const f = `${root}/${run}/widget.tsx`;
    let st; try { st = statSync(f); } catch { continue; }
    const key = `${st.mtimeMs}:${st.size}`;
    if (seen.get(run) !== key) {
      seen.set(run, key);
      appendFileSync("/tmp/weaver-exp-astra/saves.log", `${new Date().toISOString()}\t${run}\t${st.size}\n`);
    }
  }
}, 500);
