// super-board-guards.ts — the six Claude hooks translated to an OMP extension.
//
// Loaded explicitly by super-board-lane.sh (`-e .omp/extensions/super-board-guards.ts`);
// the lane does not depend on extension discovery. The extension is a guard, not a
// sandbox: it blocks the same mistakes the Claude hooks block, and it narrows the
// tool allowlist of task subagents, which do not inherit the parent's --tools.
//
// Contract kept from hooks/*.py: a guard is a Python file reading the Claude hook
// payload on stdin and printing hookSpecificOutput. They are the one source of the
// policy, so this file maps OMP tools to theirs instead of duplicating regexes.
import { spawn } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import { join, sep } from "node:path";

const PROMPT_TO_TOOL = { bash: "Bash", read: "Read", grep: "Grep", write: "Write", edit: "Edit" };
const GUARDS = {
  Bash: ["guard-worktree-path.py", "guard-delete-outside.py", "guard-secrets.py",
         "guard-key-literals.py", "guard-protected-push.py"],
  Read: ["guard-secrets.py"],
  Grep: ["guard-secrets.py"],
  Write: ["guard-key-literals.py"],
  Edit: ["guard-key-literals.py"],
};
const MAIN_TOOLS = ["read", "bash", "edit", "write", "grep", "glob", "web_search"];
const SUB_TOOLS = ["read", "bash", "grep", "glob"];  // truth-check is read-only
const written = new Set();  // module state is shared by subagent sessions in one process
let project = null;

function projectDir(cwd) {
  if (process.env.CLAUDE_PROJECT_DIR) return process.env.CLAUDE_PROJECT_DIR;
  const marker = `${sep}.claude${sep}worktrees${sep}`;
  const at = cwd.indexOf(marker);
  return at === -1 ? cwd : cwd.slice(0, at);
}

function guardPath(name) {
  for (const dir of [".claude/hooks", ".agents/hooks"]) {
    const path = join(project, dir, name);
    if (existsSync(path)) return path;
  }
  return null;
}

function firstPath(text) {
  const match = /^\s*\[([^#\]]+)#[^\]]*\]/m.exec(text || "");
  return match ? match[1] : null;
}

function claudeInput(tool, input) {
  if (tool === "Bash") return { command: input.command || "" };
  if (tool === "Read") return { file_path: input.path || "" };
  if (tool === "Grep") return { path: input.path || "", glob: input.glob || "" };
  if (tool === "Write") return { file_path: input.path || "", content: input.content || "" };
  if (tool === "Edit") {
    return { file_path: firstPath(input.input) || input.path || "", new_string: input.input || "" };
  }
  return {};
}

function runGuard(name, payload) {
  const path = guardPath(name);
  if (!path) return Promise.resolve(null);
  const { promise, resolve } = Promise.withResolvers();
  let stdout = "";
  const child = spawn("python3", [path], {
    cwd: project, timeout: 5000,
    env: { ...process.env, CLAUDE_PROJECT_DIR: project },
  });
  child.stdout.on("data", chunk => { stdout += chunk; });
  child.on("error", () => resolve(null));  // a broken guard never blocks unrelated work
  child.on("close", code => {
    if (code !== 0) return resolve(null);
    try {
      resolve(JSON.parse(stdout || "{}").hookSpecificOutput || {});
    } catch { resolve(null); }
  });
  child.stdin.end(JSON.stringify(payload));
  return promise;
}

function payload(event, tool, hookEvent) {
  return {
    hook_event_name: hookEvent,
    tool_name: tool,
    tool_input: claudeInput(tool, event.input || {}),
    cwd: process.cwd(),
  };
}

async function enforceTools(pi, ctx) {
  const allow = ctx.agent && ctx.agent.kind === "sub"
    ? SUB_TOOLS
    : (process.env.SUPER_BOARD_LANE_TOOLS || MAIN_TOOLS.join(",")).split(",").map(x => x.trim()).filter(Boolean);
  const allowed = new Set(allow);
  const active = pi.getActiveTools();
  const keep = active.filter(name => allowed.has(name));
  if (keep.length !== active.length) await pi.setActiveTools(keep);
}

export default function superBoardGuards(pi) {
  pi.setLabel("super-board guards");

  pi.on("session_start", async (_event, ctx) => {
    project = projectDir(ctx.cwd || process.cwd());
    await enforceTools(pi, ctx);
    if (ctx.agent && ctx.agent.kind === "main") {
      const file = process.env.SUPER_BOARD_LANE_MODEL_FILE;
      if (file && !written.has(file)) {
        const model = ctx.models && ctx.models.current && ctx.models.current();
        const role = (process.env.SUPER_BOARD_LANE_ROLE || "").replace(/^@/, "") || null;
        try {
          writeFileSync(file, JSON.stringify({
            role,
            provider: model && (model.provider || model.providerId || null),
            model: model && (model.id || model.modelId || model.name || null),
            thinking: typeof pi.getThinkingLevel === "function" ? pi.getThinkingLevel() : null,
            tools: pi.getActiveTools(),
          }, null, 2));
          written.add(file);
        } catch { /* evidence never blocks the lane */ }
      }
      // cleanup-wt --auto: remove worktrees/branches already merged into a base.
      if (process.env.SUPER_BOARD_SKIP_CLEANUP !== "1") {
        const cleanup = guardPath("cleanup-wt.py");
        if (cleanup) {
          try {
            spawn("python3", [cleanup, "--auto"], {
              cwd: project, detached: true, stdio: "ignore",
              env: { ...process.env, CLAUDE_PROJECT_DIR: project },
            }).unref();
          } catch { /* cleanup is best effort */ }
        }
      }
    }
  });

  pi.on("before_agent_start", async (_event, ctx) => {
    await enforceTools(pi, ctx);
  });

  pi.on("tool_call", async event => {
    const tool = PROMPT_TO_TOOL[event.toolName];
    if (!tool) return undefined;
    for (const name of GUARDS[tool] || []) {
      const output = await runGuard(name, payload(event, tool, "PreToolUse"));
      if (!output) continue;
      if (output.permissionDecision === "deny") {
        return { block: true, reason: output.permissionDecisionReason || `${name} denied this call` };
      }
    }
    return undefined;
  });

  pi.on("tool_result", async event => {
    if (event.toolName !== "write" && event.toolName !== "edit") return undefined;
    const output = await runGuard("guard-key-literals.py", payload(event, PROMPT_TO_TOOL[event.toolName], "PostToolUse"));
    if (output && output.additionalContext) return { additionalContext: output.additionalContext };
    return undefined;
  });
}
