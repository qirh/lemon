/**
 * Recorded-shape `tool_use` payloads, one per tool the gallery renders.
 *
 * Every `detail` here is what the native engine's
 * `CodingAgent.Session.RunTranslator` emits and the control plane's event
 * bridge forwards to operator clients:
 *
 *   started    `{name, args}`
 *   updated    `{name, args, partial_result: {content, details}}`
 *   completed  `{name, args, result, details?, result_meta?}` — `result` is the
 *              bounded full text, `details` the tool's structured details
 *
 * Blocks are produced by replaying the fixture's phases through a real
 * {@link SessionStore}, so the gallery exercises the same upsert path the live
 * client does rather than hand-rolling a ToolBlock.
 */

import type { AgentAction } from "../../protocol/types.ts";
import { SessionStore } from "../../store/session-store.ts";
import type { ReasoningBlock, ToolBlock } from "../../store/transcript-model.ts";
import { toToolPhase } from "../../store/transcript-model.ts";
import type { ToolCardState } from "../../ui/tool-view.ts";
import { ompSessionWire } from "./omp-fixtures.ts";

export interface ToolFixture {
	/** Gallery key, matched by `--tool`. */
	name: string;
	kind: string;
	title: string;
	/** `detail` at `started`. */
	started: Record<string, unknown>;
	/** `detail` at `updated`, when the tool streams progress. */
	updated?: Record<string, unknown>;
	/** `detail` at a successful `completed`. */
	completed: Record<string, unknown>;
	/** `detail` at a failed `completed`. */
	failed: Record<string, unknown>;
	/** `event.message` on the failure. */
	failedMessage?: string;
}

const EDIT_PATH = "clients/tui/src/store/transcript-model.ts";

const EDIT_OLD = `	const title = action?.title?.trim();
	if (title) return title;
	return "tool";`;

const EDIT_NEW = `	const title = action?.title?.trim();
	if (title) return title;
	const kind = action?.kind?.trim();
	if (kind) return kind;
	return "tool";`;

/** The edit tool's own diff: real line numbers, tab-separated, `...` between hunks. */
const EDIT_DIFF = [
	" 118\texport function toolTitle(action: AgentAction | undefined): string {",
	" 119\t\tconst title = action?.title?.trim();",
	" 120\t\tif (title) return title;",
	"+121\t\tconst kind = action?.kind?.trim();",
	"+122\t\tif (kind) return kind;",
	' 121\t\treturn "tool";',
	" 122\t}",
].join("\n");

const PATCH_TEXT = `*** Begin Patch
*** Update File: apps/lemon_gateway/lib/lemon_gateway/run.ex
@@
   def start(job) do
-    {:ok, pid} = Runner.start_link(job)
+    {:ok, pid} = Runner.start_link(job, timeout: :infinity)
     Registry.register(job.id, pid)
   end
*** End Patch`;

const TODOS = [
	{ id: "1", content: "port the formatters", status: "completed", priority: "high" },
	{ id: "2", content: "render server diffs", status: "in_progress", priority: "high" },
	{ id: "3", content: "wire the expand key", status: "pending", priority: "medium" },
];

export const TOOL_FIXTURES: ToolFixture[] = [
	{
		name: "bash",
		kind: "command",
		title: "`ls -la clients/tui`",
		started: { name: "bash", args: { command: "ls -la clients/tui" } },
		updated: {
			name: "bash",
			args: { command: "ls -la clients/tui" },
			partial_result: { content: [{ type: "text", text: "total 96\n" }], details: {} },
		},
		completed: {
			name: "bash",
			args: { command: "ls -la clients/tui" },
			result:
				"total 96\ndrwxr-xr-x 6 z80 z80  4096 Aug 17 00:57 .\ndrwxr-xr-x 9 z80 z80  4096 Aug 16 23:04 ..\n-rw-r--r-- 1 z80 z80   451 Aug 16 23:04 biome.json\n-rw-r--r-- 1 z80 z80  5642 Aug 16 23:04 bun.lock\ndrwxr-xr-x 8 z80 z80  4096 Aug 17 00:57 src",
			details: { exit_code: 0, truncated: false },
		},
		failed: {
			name: "bash",
			args: { command: "ls -la clients/tui" },
			result: "ls: cannot access 'clients/tui': No such file or directory",
			details: { exit_code: 2, truncated: false },
			result_meta: {
				error_type: "command_exit",
				tool_name: "bash",
				exit_code: 2,
				message: "Command exited with code 2",
			},
		},
		failedMessage: "Command exited with code 2",
	},
	{
		name: "bash-background",
		kind: "command",
		title: "`bun test --watch` (background)",
		started: { name: "bash", args: { command: "bun test --watch", run_in_background: true } },
		completed: {
			name: "bash",
			args: { command: "bun test --watch", run_in_background: true },
			result: "Started background process proc_7f2",
			details: { process_id: "proc_7f2", status: "running" },
		},
		failed: {
			name: "bash",
			args: { command: "bun test --watch", run_in_background: true },
			result: "too many background processes",
			result_meta: { error_type: "limit", tool_name: "bash" },
		},
	},
	{
		name: "bash_output",
		kind: "command",
		title: "bash output: proc_7f2",
		started: { name: "bash_output", args: { process_id: "proc_7f2" } },
		completed: {
			name: "bash_output",
			args: { process_id: "proc_7f2" },
			result: "bun test v1.3.14\n 212 pass\n 0 fail",
			details: { process_id: "proc_7f2", status: "completed", exit_code: 0 },
		},
		failed: {
			name: "bash_output",
			args: { process_id: "proc_99" },
			result: "unknown process proc_99",
			result_meta: { error_type: "not_found", tool_name: "bash_output" },
		},
	},
	{
		name: "read",
		kind: "tool",
		title: "read: `src/app.ts`",
		started: { name: "read", args: { path: "clients/tui/src/app.ts", limit: 4 } },
		completed: {
			name: "read",
			args: { path: "clients/tui/src/app.ts", limit: 4 },
			result:
				'     1\timport { Editor } from "@oh-my-pi/pi-tui/components/editor";\n     2\timport { Text } from "@oh-my-pi/pi-tui/components/text";\n     3\t\n     4\texport class AppShell {',
			details: {
				path: "clients/tui/src/app.ts",
				total_lines: 982,
				start_line: 1,
				lines_shown: 4,
				truncation: null,
			},
		},
		failed: {
			name: "read",
			args: { path: "clients/tui/src/missing.ts" },
			result: "File not found: clients/tui/src/missing.ts",
			result_meta: { error_type: "enoent", tool_name: "read" },
		},
		failedMessage: "file not found",
	},
	{
		name: "edit",
		kind: "file_change",
		title: "edit: `store/transcript-model.ts`",
		started: { name: "edit", args: { path: EDIT_PATH, old_text: EDIT_OLD, new_text: EDIT_NEW } },
		completed: {
			name: "edit",
			args: { path: EDIT_PATH, old_text: EDIT_OLD, new_text: EDIT_NEW },
			result: `Successfully replaced text in ${EDIT_PATH}.\n\n${EDIT_DIFF}`,
			details: { diff: EDIT_DIFF, first_changed_line: 121 },
		},
		failed: {
			name: "edit",
			args: { path: EDIT_PATH, old_text: EDIT_OLD, new_text: EDIT_NEW },
			result: "Could not find the exact text to replace. The text must match exactly.",
			result_meta: { error_type: "tool_error", tool_name: "edit" },
		},
		failedMessage: "no match",
	},
	{
		name: "write",
		kind: "file_change",
		title: "write: `components/accordion.ts`",
		started: {
			name: "write",
			args: {
				path: "clients/tui/src/ui/components/accordion.ts",
				content:
					'export type AccordionState = "hidden" | "collapsed" | "expanded";\n\nexport function resolveAccordionState(kind) {\n\treturn KIND_DEFAULTS[kind] ?? "expanded";\n}\n',
			},
		},
		completed: {
			name: "write",
			args: {
				path: "clients/tui/src/ui/components/accordion.ts",
				content:
					'export type AccordionState = "hidden" | "collapsed" | "expanded";\n\nexport function resolveAccordionState(kind) {\n\treturn KIND_DEFAULTS[kind] ?? "expanded";\n}\n',
			},
			result: "Successfully wrote 148 bytes to clients/tui/src/ui/components/accordion.ts",
			details: {
				path: "clients/tui/src/ui/components/accordion.ts",
				bytes_written: 148,
				formatted: false,
			},
		},
		failed: {
			name: "write",
			args: { path: "/read-only/accordion.ts", content: "x" },
			result: "Permission denied: /read-only/accordion.ts",
			result_meta: { error_type: "eacces", tool_name: "write" },
		},
		failedMessage: "permission denied",
	},
	{
		name: "grep",
		kind: "tool",
		title: "grep: `upsertTool` in clients/tui/src",
		started: {
			name: "grep",
			args: { pattern: "upsertTool", path: "clients/tui/src", context_lines: 1 },
		},
		completed: {
			name: "grep",
			args: { pattern: "upsertTool", path: "clients/tui/src", context_lines: 1 },
			result:
				"Found 2 matches.\n\nclients/tui/src/store/session-store.ts:292:\tupsertTool(\nclients/tui/src/ui/controllers/event-controller.ts:300:\t\t\t\tconst block = session.upsertTool(tool.action, toToolPhase(tool.phase), {",
			details: { match_count: 2, truncated: false },
		},
		failed: {
			name: "grep",
			args: { pattern: "upsertTool(", path: "clients/tui/src" },
			result: "regex parse error: unclosed group",
			result_meta: { error_type: "invalid_pattern", tool_name: "grep" },
		},
		failedMessage: "invalid regular expression",
	},
	{
		name: "patch",
		kind: "file_change",
		title: "patch",
		started: { name: "patch", args: { patch_text: PATCH_TEXT } },
		completed: {
			name: "patch",
			args: { patch_text: PATCH_TEXT },
			result: "Patch applied successfully. 1 files changed, 1 additions, 1 removals",
			details: {
				changed: ["apps/lemon_gateway/lib/lemon_gateway/run.ex"],
				additions: 1,
				removals: 1,
			},
		},
		failed: {
			name: "patch",
			args: { patch_text: PATCH_TEXT },
			result: "Hunk did not match apps/lemon_gateway/lib/lemon_gateway/run.ex",
			result_meta: { error_type: "tool_error", tool_name: "patch" },
		},
		failedMessage: "patch does not apply",
	},
	{
		name: "find",
		kind: "tool",
		title: "find: `*.test.ts`",
		started: {
			name: "find",
			args: { pattern: "*.test.ts", path: "clients/tui/test", type: "file" },
		},
		completed: {
			name: "find",
			args: { pattern: "*.test.ts", path: "clients/tui/test", type: "file" },
			result:
				"clients/tui/test/ui/transcript-blocks.test.ts\nclients/tui/test/ui/tool-card.test.ts\nclients/tui/test/store/session-store.test.ts\nclients/tui/test/protocol/client.test.ts",
			details: {
				count: 4,
				truncated: false,
				max_results: 1000,
				files: [
					"clients/tui/test/ui/transcript-blocks.test.ts",
					"clients/tui/test/ui/tool-card.test.ts",
					"clients/tui/test/store/session-store.test.ts",
					"clients/tui/test/protocol/client.test.ts",
				],
			},
		},
		failed: {
			name: "find",
			args: { pattern: "*.test.ts", path: "/nope" },
			result: "Directory not found: /nope",
			result_meta: { error_type: "enoent", tool_name: "find" },
		},
	},
	{
		name: "websearch",
		kind: "web_search",
		title: "search: pi-tui differential rendering",
		started: { name: "websearch", args: { query: "pi-tui differential rendering" } },
		completed: {
			name: "websearch",
			args: { query: "pi-tui differential rendering" },
			result:
				"1. oh-my-pi/pi-tui — differential terminal renderer (github.com)\n2. Terminal UI rendering strategies (blog.example.com)",
		},
		failed: {
			name: "websearch",
			args: { query: "pi-tui differential rendering" },
			result: "search provider returned 429",
			result_meta: { error_type: "rate_limited", tool_name: "websearch" },
		},
		failedMessage: "rate limited",
	},
	{
		name: "webfetch",
		kind: "web_search",
		title: "fetch: https://omp.sh/docs/tui",
		started: { name: "webfetch", args: { url: "https://omp.sh/docs/tui", format: "markdown" } },
		completed: {
			name: "webfetch",
			args: { url: "https://omp.sh/docs/tui", format: "markdown" },
			result: "# pi-tui\n\nA differential-rendering terminal UI library for Bun.",
		},
		failed: {
			name: "webfetch",
			args: { url: "https://omp.sh/docs/tui" },
			result: "request timed out after 30000ms",
			result_meta: { error_type: "timeout", timeout_ms: 30000, tool_name: "webfetch" },
		},
	},
	{
		name: "todo",
		kind: "tool",
		title: "todo",
		started: { name: "todo", args: { action: "write", todos: TODOS } },
		completed: {
			name: "todo",
			args: { action: "write", todos: TODOS },
			result: JSON.stringify(TODOS, null, 2),
		},
		failed: {
			name: "todo",
			args: { action: "write", todos: [] },
			result: "todos must be a non-empty list",
			result_meta: { error_type: "tool_error", tool_name: "todo" },
		},
	},
	{
		name: "task",
		kind: "subagent",
		title: "task: audit the render contract",
		started: {
			name: "task",
			args: {
				description: "audit the render contract",
				prompt: "Check every component against the settled-rows rules.",
			},
		},
		updated: {
			name: "task",
			args: { description: "audit the render contract" },
			partial_result: {
				content: [{ type: "text", text: "reading transcript-container.ts" }],
				details: {
					current_action: {
						title: "read: transcript-container.ts",
						kind: "tool",
						phase: "started",
					},
				},
			},
		},
		completed: {
			name: "task",
			args: { description: "audit the render contract" },
			result: "No over-declared settled rows found. One risk noted in tool-shelf.ts.",
			details: { task_id: "task_7f2", status: "completed" },
			result_meta: { task_id: "task_7f2", status: "completed" },
		},
		failed: {
			name: "task",
			args: { description: "audit the render contract" },
			result: "subagent aborted",
			result_meta: { task_id: "task_7f2", error_type: "aborted", tool_name: "task" },
		},
		failedMessage: "subagent aborted",
	},
	{
		name: "browser_navigate",
		kind: "tool",
		title: "browser: https://omp.sh",
		started: { name: "browser_navigate", args: { url: "https://omp.sh" } },
		completed: {
			name: "browser_navigate",
			args: { url: "https://omp.sh" },
			result: "Navigated to https://omp.sh (title: oh-my-pi)",
		},
		failed: {
			name: "browser_navigate",
			args: { url: "https://omp.sh" },
			result: "browser driver not running",
			result_meta: { error_type: "unavailable", tool_name: "browser_navigate" },
		},
	},
	{
		name: "omp",
		kind: "tool",
		title: "omp",
		started: {
			name: "omp",
			args: { action: "start", prompt: "Fix the flaky reconnect test", wait: true },
		},
		updated: {
			name: "omp",
			args: { action: "start", prompt: "Fix the flaky reconnect test", wait: true },
			partial_result: {
				content: [{ type: "text", text: "omp omp_3f9a1c2b7d4e: running (todos 2/4)" }],
				details: { action: "start", session: ompSessionWire() },
			},
		},
		completed: {
			name: "omp",
			args: { action: "start", prompt: "Fix the flaky reconnect test", wait: true },
			result: "omp omp_3f9a1c2b7d4e idle (completed) after 4 turns.",
			details: {
				action: "start",
				session: ompSessionWire({
					status: "idle",
					lastTurn: "completed",
					activity: null,
					activeTools: [],
					turns: 4,
					todos: [
						{ phase: "Fix", content: "Make the watchdog deterministic", status: "completed" },
						{ phase: "Fix", content: "Run the suite 20 times", status: "completed" },
					],
					result:
						"The watchdog now arms after the handshake.\nThe reconnect suite passed 20 consecutive runs.",
				}),
			},
		},
		failed: {
			name: "omp",
			args: { action: "start", prompt: "Fix the flaky reconnect test" },
			result: "omp start failed: omp is not installed on this host.",
			details: { action: "start", error: "not_installed" },
			result_meta: { error_type: "tool_error", tool_name: "omp" },
		},
		failedMessage: "omp is not installed",
	},
	{
		name: "unknown",
		kind: "tool",
		// A tool nothing has a formatter for: the generic card path.
		title: "custom_search",
		started: { name: "custom_search", args: { query: "render contract", limit: 5 } },
		completed: {
			name: "custom_search",
			args: { query: "render contract", limit: 5 },
			result: "3 sessions matched: tui-1755, tui-1760, tui-1771",
		},
		failed: {
			name: "custom_search",
			args: { query: "render contract" },
			result: "session index unavailable",
			result_meta: { error_type: "unavailable", tool_name: "custom_search" },
		},
	},
];

export function fixtureByName(name: string): ToolFixture | undefined {
	return TOOL_FIXTURES.find((fixture) => fixture.name === name);
}

interface FixturePhase {
	detail: Record<string, unknown> | undefined;
	phase: string;
	ok?: boolean;
	message?: string;
}

/** The phase sequence a fixture replays to reach a given lifecycle state. */
export function fixturePhases(fixture: ToolFixture, state: ToolCardState): FixturePhase[] {
	const started: FixturePhase = { detail: fixture.started, phase: "started" };
	switch (state) {
		case "streaming":
			// The action is open and nothing about it is known yet — the window
			// between the tool being announced and its arguments arriving.
			return [{ detail: undefined, phase: "started" }];
		case "running":
			return fixture.updated ? [started, { detail: fixture.updated, phase: "updated" }] : [started];
		case "success":
			return [started, { detail: fixture.completed, phase: "completed", ok: true }];
		case "cancelled":
			return [
				started,
				{
					detail: { ...fixture.updated, details: { cancelled: true, outcome: "unknown" } },
					phase: "completed",
					ok: false,
				},
			];
		case "unknown":
			return [started];
		case "error":
			return [
				started,
				{
					detail: fixture.failed,
					phase: "completed",
					ok: false,
					message: fixture.failedMessage,
				},
			];
	}
}

/** Replay a fixture through a real SessionStore and return the tool block. */
export function fixtureBlock(
	fixture: ToolFixture,
	state: ToolCardState,
	options: { at?: number; completedAt?: number; runId?: string } = {},
): ToolBlock {
	const session = new SessionStore("gallery");
	const runId = options.runId ?? "run-gallery";
	let block: ToolBlock | undefined;
	for (const step of fixturePhases(fixture, state)) {
		const action: AgentAction = {
			id: `action-${fixture.name}`,
			kind: fixture.kind,
			title: fixture.title,
			detail: step.detail ?? null,
		};
		block = session.upsertTool(action, toToolPhase(step.phase), {
			runId,
			ok: step.ok ?? null,
			message: step.message ?? null,
		});
	}
	if (!block) throw new Error(`fixture ${fixture.name} produced no block`);
	// A deterministic clock override must replace both endpoints, not combine
	// a fixture start with the real clock used while replaying its phases.
	if (options.at !== undefined) {
		block.at = options.at;
		block.completedAt = undefined;
	}
	if (block.phase === "completed" && options.completedAt !== undefined) {
		block.completedAt = options.completedAt;
	}
	if (state === "unknown") block.historical = true;
	return block;
}

/** A completed `kind: "reasoning"` action, as the event bridge forwards it. */
export const REASONING_ACTION: AgentAction = {
	id: "lemon.reasoning.0.1",
	kind: "reasoning",
	title: "The shelf has to stay unsealed while its shape can still change",
	detail: {
		reasoning: {
			text: "The shelf has to stay unsealed while its shape can still change, because a row that reached native scrollback can never be rewritten.\n\nSo: pin the live region until the barrier, then seal once.",
			source: "lemon_reasoning",
		},
	},
};

/** Replay {@link REASONING_ACTION} through a real SessionStore. */
export function reasoningFixtureBlock(options: { at?: number } = {}): ReasoningBlock {
	const block = new SessionStore("gallery").upsertReasoning(REASONING_ACTION, "completed", {
		runId: "run-gallery",
	});
	if (options.at !== undefined) block.at = options.at;
	return block;
}
