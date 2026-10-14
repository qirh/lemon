/**
 * The protocol → formatter adapter.
 *
 * `action.detail` is the native engine's shape (`name`, `args`, `result`,
 * `details`, `result_meta`, `partial_result`). These cases pin how it reaches
 * the formatters and the diff renderer — including the fallback for a server
 * that predates structured details and sends only a 500-char `result` preview.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { SessionStore } from "../../src/store/session-store.ts";
import type { ToolBlock } from "../../src/store/transcript-model.ts";
import { resetBlockIds, toToolPhase } from "../../src/store/transcript-model.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import {
	buildDiffText,
	buildToolView,
	extractToolDiff,
	isToolError,
	normalizeToolResult,
	resolveToolName,
	serverDiffToRows,
	stripUnifiedHeaders,
	toolArgs,
	toolCardState,
} from "../../src/ui/tool-view.ts";

beforeEach(() => {
	resetBlockIds();
	initTheme({ colorLevel: 0 });
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

/** Build a tool block the way the event controller does, through the store. */
function block(
	overrides: {
		kind?: string;
		title?: string;
		detail?: Record<string, unknown>;
		phase?: string;
		ok?: boolean | null;
		message?: string | null;
	} = {},
): ToolBlock {
	const session = new SessionStore("t");
	return session.upsertTool(
		{
			id: "a1",
			kind: overrides.kind ?? "tool",
			title: overrides.title ?? "a tool",
			detail: overrides.detail ?? null,
		},
		toToolPhase(overrides.phase ?? "started"),
		{ runId: "run-1", ok: overrides.ok ?? null, message: overrides.message ?? null },
	);
}

describe("tool name and arguments", () => {
	test("the tool name is detail.name, or the one an error path recorded", () => {
		expect(resolveToolName(block({ detail: { name: "bash" } }))).toBe("bash");
		expect(resolveToolName(block({ detail: { result_meta: { tool_name: "grep" } } }))).toBe("grep");
		expect(resolveToolName(block({ kind: "note" }))).toBeUndefined();
	});

	test("arguments are detail.args, passed through untouched", () => {
		expect(toolArgs(block({ detail: { args: { path: "a.ts", limit: 3 } } }))).toEqual({
			path: "a.ts",
			limit: 3,
		});
		expect(toolArgs(block({}))).toEqual({});
	});
});

describe("result extraction", () => {
	test("merges result_meta with the structured details the server sent", () => {
		const result = normalizeToolResult(
			block({
				detail: {
					name: "read",
					result: "done",
					result_meta: { error_type: "timeout" },
					details: { path: "a.ts", total_lines: 40 },
				},
				phase: "completed",
				ok: false,
			}),
			"read",
		) as { content: Array<{ text: string }>; details: Record<string, unknown>; is_error: boolean };
		expect(result.content[0]?.text).toBe("done");
		expect(result.details).toEqual({ error_type: "timeout", path: "a.ts", total_lines: 40 });
		expect(result.is_error).toBe(true);
	});

	test("mirrors the output onto stdout/stderr for the command formatters", () => {
		const ok = normalizeToolResult(
			block({ detail: { name: "bash", result: "hello" }, phase: "completed", ok: true }),
			"bash",
		) as { details: Record<string, unknown> };
		expect(ok.details.stdout).toBe("hello");

		const failed = normalizeToolResult(
			block({ detail: { name: "bash_output", result: "boom" }, phase: "completed", ok: false }),
			"bash_output",
		) as { details: Record<string, unknown> };
		expect(failed.details.stderr).toBe("boom");

		const read = normalizeToolResult(
			block({ detail: { name: "read", result: "text" }, phase: "completed", ok: true }),
			"read",
		) as { details: Record<string, unknown> };
		expect(read.details.stdout).toBeUndefined();
	});
});

describe("error detection and lifecycle", () => {
	test("an action failed when the event said so or the result carries an error type", () => {
		expect(isToolError(block({ phase: "completed", ok: false }))).toBe(true);
		expect(isToolError(block({ detail: { result_meta: { error_type: "timeout" } } }))).toBe(true);
		expect(isToolError(block({ detail: { result_meta: { error_type: null } } }))).toBe(false);
	});

	test("maps phase and ok onto the four card states", () => {
		expect(toolCardState(block({ phase: "started" }))).toBe("streaming");
		expect(
			toolCardState(block({ phase: "started", detail: { name: "bash", args: { command: "ls" } } })),
		).toBe("running");
		expect(toolCardState(block({ phase: "updated" }))).toBe("running");
		expect(toolCardState(block({ phase: "completed", ok: true }))).toBe("success");
		expect(toolCardState(block({ phase: "completed", ok: false }))).toBe("error");
	});
});

describe("diff extraction", () => {
	test("an edit renders the tool's own diff with its real line numbers", () => {
		const diff =
			" 118\tfunction a() {\n-119\t\treturn 1;\n+119\t\treturn 2;\n 120\t}\n...\n 300\tend";
		const edit = block({
			detail: {
				name: "edit",
				args: { path: "lib/a.ts", old_text: "\treturn 1;", new_text: "\treturn 2;" },
				result: "Successfully replaced text in lib/a.ts.",
				details: { diff, first_changed_line: 119 },
			},
			phase: "completed",
			ok: true,
		});
		const view = buildToolView(edit);
		expect(view.diff?.path).toBe("lib/a.ts");
		expect(view.diff?.text.split("\n")).toEqual([
			" 118|function a() {",
			"-119|\treturn 1;",
			"+119|\treturn 2;",
			" 120|}",
			"...",
			" 300|end",
		]);
	});

	test("without a server diff, first_changed_line anchors the old/new pair", () => {
		const edit = block({
			detail: {
				name: "edit",
				args: { path: "a.ts", old_text: "keep\nold", new_text: "keep\nnew" },
				details: { first_changed_line: 41 },
			},
			phase: "completed",
			ok: true,
		});
		expect(extractToolDiff(edit, toolArgs(edit), "edit")?.text).toBe(" 40|keep\n-41|old\n+41|new");
	});

	test("a server with no structured details gets an unnumbered diff, never a fake line 1", () => {
		const edit = block({
			detail: {
				name: "edit",
				args: { path: "a.ts", old_text: "one", new_text: "two" },
				result: "Successfully replaced text in a.ts.",
			},
			phase: "completed",
			ok: true,
		});
		expect(extractToolDiff(edit, toolArgs(edit), "edit")?.text).toBe("-one\n+two");
	});

	test("buildDiffText numbers removals against the old text and additions against the new", () => {
		expect(buildDiffText("a\nb", "A\nb", 10)).toBe("-10|a\n+10|A\n 11|b");
		expect(buildDiffText("a\nb", "a\nx\nb", 1)).toBe(" 1|a\n+2|x\n 3|b");
	});

	test("serverDiffToRows leaves hunk separators and foreign rows alone", () => {
		expect(serverDiffToRows("+5\tx\n...\n-9\ty")).toBe("+5|x\n...\n-9|y");
	});

	test("a write's content renders as an all-addition diff from line 1", () => {
		const write = block({ detail: { name: "write", args: { path: "a.ts", content: "x\ny" } } });
		expect(extractToolDiff(write, toolArgs(write), "write")?.text).toBe("+1|x\n+2|y");
		expect(extractToolDiff(block({}), { content: "x" }, "read")).toBeUndefined();
	});

	test("a patch keeps its hunks and loses its envelope and headers", () => {
		const patch =
			"*** Begin Patch\n*** Update File: x.ex\n@@\n-old\n+new\n*** End Patch\n--- a/x\n+++ b/x";
		expect(stripUnifiedHeaders(patch)).toBe("*** Update File: x.ex\n-old\n+new");
		const view = buildToolView(block({ detail: { name: "patch", args: { patch_text: patch } } }));
		expect(view.diff?.text).toBe("*** Update File: x.ex\n-old\n+new");
	});

	test("a failed edit shows no diff: nothing changed", () => {
		const view = buildToolView(
			block({
				detail: {
					name: "edit",
					args: { path: "a.ts", old_text: "x", new_text: "y" },
					result: "Could not find the exact text to replace.",
				},
				phase: "completed",
				ok: false,
			}),
		);
		expect(view.diff).toBeUndefined();
		expect(view.isError).toBe(true);
	});
});

describe("buildToolView", () => {
	test("renders the bounded full result, not just the first 500 characters", () => {
		const lines = Array.from({ length: 40 }, (_, i) => `line ${i + 1} ${"x".repeat(55)}`);
		const view = buildToolView(
			block({
				detail: {
					name: "bash",
					args: { command: "seq 40" },
					result: lines.join("\n"),
					details: { exit_code: 0 },
				},
				phase: "completed",
				ok: true,
			}),
		);
		// Line 10 starts past byte 500 of the output: a preview-only card never had it.
		expect(lines.slice(0, 9).join("\n").length).toBeGreaterThan(500);
		expect(view.body.join("\n")).toContain("line 10 ");
	});

	test("an unknown tool falls back to the generic formatter, not an empty card", () => {
		const view = buildToolView(
			block({
				title: "custom_search",
				detail: { name: "custom_search", args: { query: "x" }, result: "3 sessions" },
				phase: "completed",
				ok: true,
			}),
		);
		expect(view.generic).toBe(true);
		expect(view.summary).toContain("3 sessions");
	});

	test("the streaming state renders no body at all", () => {
		const view = buildToolView(block({ phase: "started" }));
		expect(view.state).toBe("streaming");
		expect(view.summary).toBe("");
		expect(view.body).toEqual([]);
	});

	test("a failing event overrides a formatter that read success out of the args", () => {
		const view = buildToolView(
			block({
				detail: {
					name: "write",
					args: { path: "/ro/a.ts", content: "x" },
					result: "Permission denied: /ro/a.ts",
				},
				phase: "completed",
				ok: false,
			}),
		);
		expect(view.isError).toBe(true);
		expect(view.summary).toContain("Permission denied");
	});

	test("the daemon's message reaches the body when no formatter mentioned it", () => {
		const view = buildToolView(
			block({
				detail: { name: "read", args: { path: "a.ts" }, result: "x" },
				phase: "completed",
				ok: false,
				message: "session expired",
			}),
		);
		expect(view.body.join("\n")).toContain("session expired");
	});

	test("summaries are always a single line", () => {
		const view = buildToolView(
			block({
				detail: { name: "bash", args: { command: "ls" }, result: "a\nb\nc" },
				phase: "completed",
				ok: true,
			}),
		);
		expect(view.summary).not.toContain("\n");
	});
});
