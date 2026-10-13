import { afterEach, beforeEach, expect, test } from "bun:test";
import type { AgentToolUseEvent } from "../../src/protocol/types.ts";
import { SessionStore } from "../../src/store/session-store.ts";
import { ToolShelfComponent } from "../../src/ui/components/tool-shelf.ts";
import { taskProgressEvent } from "../../src/ui/task-progress.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";

beforeEach(() => initTheme({ colorLevel: 0 }));
afterEach(() => resetTheme());

function progress(taskId: string, status: string): AgentToolUseEvent {
	return {
		type: "tool_use",
		runId: "parent-run",
		sessionKey: "session",
		phase: "updated",
		action: {
			id: "launch",
			kind: "subagent",
			title: "Launch tasks",
			detail: {
				name: "task",
				partial_result: {
					content: [{ type: "text", text: "Visible child output" }],
					details: { task_id: taskId, description: `Child ${taskId}`, status },
				},
			},
		},
	};
}

test("child updates have independent identities and never reopen the launch receipt", () => {
	const session = new SessionStore("session");
	const receipt = session.upsertTool(
		{ id: "launch", kind: "subagent", title: "Launch", detail: { name: "task" } },
		"completed",
	);
	const one = taskProgressEvent(progress("one", "running"))!;
	const two = taskProgressEvent(progress("two", "running"))!;
	const child = session.upsertTool(one.action, "updated");
	session.upsertTool(two.action, "updated");
	expect(one.action.id).not.toBe(two.action.id);
	expect(receipt.phase).toBe("completed");
	expect(session.blocks).toHaveLength(3);
	const shelf = new ToolShelfComponent();
	shelf.add(child);
	shelf.seal();
	expect(shelf.isTranscriptBlockFinalized()).toBe(false);

	const final = taskProgressEvent(progress("one", "completed"))!;
	expect(final.phase).toBe("completed");
	shelf.update(session.upsertTool(final.action, "completed", { ok: final.ok }));
	expect(shelf.isTranscriptBlockFinalized()).toBe(true);
	expect(shelf.render(100).join("\n")).toContain("completed");
	shelf.dispose();
});

test("child failures settle as errors and stale running updates stay settled", () => {
	const session = new SessionStore("session");
	const failed = taskProgressEvent(progress("one", "error"))!;
	const child = session.upsertTool(failed.action, "completed", { ok: failed.ok });
	expect(child.ok).toBe(false);
	session.upsertTool(taskProgressEvent(progress("one", "running"))!.action, "updated");
	expect(child.phase).toBe("completed");
});
