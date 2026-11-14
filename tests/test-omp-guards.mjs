// Offline probe for extensions/super-board-guards.ts. Run from test-omp-guards.sh.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import superBoardGuards from "../extensions/super-board-guards.ts";

const KIT = new URL("..", import.meta.url).pathname;
const root = process.env.SB_GUARD_ROOT;
mkdirSync(join(root, ".claude/hooks"), { recursive: true });
for (const name of ["guard-worktree-path.py", "guard-delete-outside.py", "guard-secrets.py",
                    "guard-key-literals.py", "guard-protected-push.py"]) {
  cpSync(join(KIT, "hooks", name), join(root, ".claude/hooks", name));
}
writeFileSync(join(root, ".claude/hooks/cleanup-wt.py"),
  "from pathlib import Path\nPath(__file__).with_name('cleanup-ran').write_text('yes')\n");

process.env.CLAUDE_PROJECT_DIR = root;
process.env.SUPER_BOARD_LANE_TOOLS = "read,bash,write";
process.env.SUPER_BOARD_LANE_ROLE = "@medium";
process.env.SUPER_BOARD_LANE_MODEL_FILE = join(root, "model.json");
process.env.SUPER_BOARD_RUN = "1";
process.chdir(root);

function runtime(kind = "main") {
  const handlers = {}, calls = { tools: null };
  let active = ["read", "bash", "edit", "write", "grep", "glob", "web_search",
                "eval", "github", "ast_edit", "debug", "wait", "task"];
  return {
    handlers, calls,
    setLabel() {},
    on(name, handler) { handlers[name] = handler; },
    getActiveTools() { return [...active]; },
    async setActiveTools(names) { calls.tools = names; active = [...names]; },
    getThinkingLevel() { return "max"; },
    _ctx: {
      cwd: root,
      agent: { kind, id: kind, name: kind, depth: kind === "sub" ? 1 : 0 },
      models: { current: () => ({ provider: "fake", id: "model-1" }) },
    },
  };
}

const main = runtime("main");
superBoardGuards(main);
await main.handlers.session_start({}, main._ctx);
assert.deepEqual(main.calls.tools, ["read", "bash", "write"]);
const evidence = JSON.parse(readFileSync(join(root, "model.json"), "utf8"));
assert.deepEqual(evidence, { role: "medium", provider: "fake", model: "model-1", thinking: "max",
                             tools: ["read", "bash", "write"] });
for (let i = 0; i < 50 && !existsSync(join(root, ".claude/hooks/cleanup-ran")); i++) {
  await new Promise(resolve => setTimeout(resolve, 20));
}
assert.ok(existsSync(join(root, ".claude/hooks/cleanup-ran")), "main session must run cleanup-wt --auto");

// A task child gets the read-only set; it never overwrites the lane's evidence file.
writeFileSync(join(root, "model.json"), "main-evidence");
const sub = runtime("sub");
superBoardGuards(sub);
await sub.handlers.session_start({}, sub._ctx);
assert.deepEqual(sub.calls.tools, ["read", "bash", "grep", "glob"]);
assert.equal(readFileSync(join(root, "model.json"), "utf8"), "main-evidence");

const call = async (toolName, input) => main.handlers.tool_call({ toolName, input });

// worktree path: denied outside .claude/worktrees/.
let blocked = await call("bash", { command: "git worktree add ../outside -b feature" });
assert.equal(blocked?.block, true, "worktree outside .claude/worktrees must block");
assert.match(blocked.reason, /outside .*\.claude\/worktrees/);

// delete outside: the filesystem root is never a deletion target.
blocked = await call("bash", { command: "rm -rf /" });
assert.equal(blocked?.block, true, "rm / must block");

// secrets: dotenv reads are denied through read and grep, and through bash.
for (const [tool, input] of [["read", { path: ".env" }], ["grep", { path: ".env", glob: "KEY" }],
                             ["bash", { command: "cat .env" }]]) {
  blocked = await call(tool, input);
  assert.equal(blocked?.block, true, `${tool} .env must block`);
  assert.match(blocked.reason, /secret file/);
}

// protected push: direct push to main.
blocked = await call("bash", { command: "git push origin main" });
assert.equal(blocked?.block, true, "git push origin main must block");
assert.match(blocked.reason, /protected branch main/);

// key literals: write, edit and bash are denied before the key reaches disk.
const key = "sk-" + "a".repeat(28);
blocked = await call("write", { path: "src/config.ts", content: `const key = "${key}";` });
assert.equal(blocked?.block, true, "a live-looking key in write must block");
assert.match(blocked.reason, /Possible live credential/);
blocked = await call("edit", { input: `[src/config.ts#ABCD]\nPUT 1.=1:\n+const key = "${key}";` });
assert.equal(blocked?.block, true, "a live-looking key in edit must block");
blocked = await call("bash", { command: `printf '%s\\n' 'const key = "${key}"' > src/config.ts` });
assert.equal(blocked?.block, true, "a live-looking key written through bash must block");

// A plain call is not blocked.
assert.equal(await call("bash", { command: "echo hello" }), undefined);
assert.equal(await call("read", { path: "README.md" }), undefined);

// Post-write key detection still reports what reached disk through another path.
const leaked = join(root, "leaked.ts");
writeFileSync(leaked, `const key = "${key}";\n`);
const post = await main.handlers.tool_result({ toolName: "write", input: { path: leaked } });
assert.match(post?.additionalContext || "", /Possible live credential/);
assert.equal(await main.handlers.tool_result({ toolName: "read", input: { path: leaked } }), undefined);

console.log("PASS: test-omp-guards (allowlist, evidence, cleanup, tool mapping, deny/allow)");
