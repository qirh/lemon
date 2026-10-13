import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import type { ChatHistoryMessage } from "../../src/protocol/types.ts";
import { SessionStore } from "../../src/store/session-store.ts";
import type { ToolBlock } from "../../src/store/transcript-model.ts";
import { accordionSettings } from "../../src/ui/components/accordion.ts";
import { ToolCardComponent } from "../../src/ui/components/tool-card.ts";
import { synthesizeHistory } from "../../src/ui/controllers/session-controller.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { buildToolView } from "../../src/ui/tool-view.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";

const teardown: Array<() => void> = [];

beforeEach(() => {
	accordionSettings.reset();
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	accordionSettings.reset();
	resetTheme();
	invalidateThemeAdapters();
});

function call(overrides: Partial<ChatHistoryMessage> = {}): ChatHistoryMessage {
	return {
		id: "native-call-row",
		role: "tool_use",
		content: "",
		timestampMs: 1000,
		toolCallId: "native-call-id",
		toolName: "bash",
		title: "Long shell command",
		arguments: { command: "printf 'STARTED\\n'; sleep 120" },
		phase: "started",
		ok: null,
		cancelled: false,
		...overrides,
	};
}

function cancelled(overrides: Partial<ChatHistoryMessage> = {}): ChatHistoryMessage {
	return {
		id: "native-result-row",
		role: "tool_result",
		content: "STARTED\n",
		timestampMs: 2000,
		toolCallId: "native-call-id",
		toolName: "bash",
		phase: "completed",
		ok: false,
		cancelled: true,
		details: { cancelled: true, outcome: "unknown", started: true, partial: true },
		...overrides,
	};
}

function hydrate(rows: ChatHistoryMessage[]): { session: SessionStore; block: ToolBlock } {
	const session = new SessionStore("history-tools");
	synthesizeHistory(session, rows);
	const block = session.blocks.find((entry) => entry.kind === "tool");
	if (block?.kind !== "tool") throw new Error("missing hydrated tool");
	return { session, block };
}

function card(block: ToolBlock, now = () => 121_000): ToolCardComponent {
	const component = new ToolCardComponent(block, { now, accordion: "expanded" });
	teardown.push(() => component.dispose());
	return component;
}

describe("native history tool receipts", () => {
	test("pairs different native row IDs into one cancelled receipt with real partial stdout", () => {
		const { session, block } = hydrate([call(), cancelled()]);
		expect(session.blocks).toHaveLength(1);
		expect(session.byActionId.get("native-call-id")).toBe(block);
		expect(block).toMatchObject({
			actionId: "native-call-id",
			title: "Long shell command",
			phase: "completed",
			ok: false,
			cancelled: true,
			historical: true,
			at: 1000,
			detail: {
				name: "bash",
				args: call().arguments,
				result: "STARTED\n",
				details: cancelled().details,
			},
		});
		const component = card(block);
		expect(component.view.state).toBe("cancelled");
		expect(component.view.isError).toBe(false);
		expect(component.isTranscriptBlockFinalized()).toBe(true);
		const text = renderPlain(component.render(120));
		expect(text).toContain("[cancelled]");
		expect(text).toContain("Cancelled · outcome unknown");
		expect(text).toContain("STARTED");
		expect(text).not.toContain("Failed");
		expect(text).not.toContain("Success");
		expect(text).not.toMatch(/\d+(?:\.\d+)?(?:ms|s|m)\s*$/m);
	});

	test("reversed rows, repeat hydration and stale live starts cannot reopen the receipt", () => {
		const { session, block } = hydrate([cancelled(), call()]);
		expect(block.detail?.args).toEqual(call().arguments);
		const component = card(block);
		const before = renderPlain(component.render(120));
		synthesizeHistory(session, [call(), cancelled(), call()]);
		session.upsertTool(
			{ id: "native-call-id", kind: "tool", title: "stale start", detail: undefined },
			"started",
		);
		component.update(block);
		component.update({ ...block, phase: "started", detail: undefined });
		expect(session.blocks).toHaveLength(1);
		expect(block.phase).toBe("completed");
		expect(component.view.state).toBe("cancelled");
		expect(renderPlain(component.render(120))).toBe(before);
		expect(renderPlain(card(block).render(120))).toBe(before);
	});

	test("does not merge two different call IDs with the same tool name", () => {
		const { session } = hydrate([
			call(),
			call({ id: "call-2-row", toolCallId: "call-2" }),
			cancelled(),
			cancelled({ id: "result-2-row", toolCallId: "call-2", content: "second output" }),
		]);
		expect(session.blocks).toHaveLength(2);
		expect(session.byActionId.get("native-call-id")?.detail?.result).toBe("STARTED\n");
		expect(session.byActionId.get("call-2")?.detail?.result).toBe("second output");
	});

	test("preserves ordinary completed and failed outcomes", () => {
		for (const ok of [true, false]) {
			const { block } = hydrate([
				call(),
				cancelled({
					cancelled: false,
					ok,
					content: ok ? "finished" : "command error",
					details: { exit_code: ok ? 0 : 1 },
				}),
			]);
			expect(buildToolView(block).state).toBe(ok ? "success" : "error");
			expect(renderPlain(card(block).render(120))).toContain(ok ? "finished" : "command error");
		}
	});

	test("bare calls retain unknown outcome without pretending to run or succeed", () => {
		const { block } = hydrate([call({ details: { cancelled: true } })]);
		expect(block.phase).toBe("started");
		expect(block.ok).toBeUndefined();
		expect(block.cancelled).toBe(false);
		expect(block.detail?.result).toBeUndefined();
		const component = card(block);
		expect(component.view.state).toBe("unknown");
		expect(component.isTranscriptBlockFinalized()).toBe(true);
		expect(renderPlain(component.render(120))).toContain("[outcome unknown]");
	});

	test("aborted real results and queued cancellations retain their specific outcomes", () => {
		const { block } = hydrate([
			call(),
			cancelled({
				cancelled: false,
				content: "",
				details: { error_type: "aborted", outcome: "not_started" },
			}),
		]);
		expect(buildToolView(block).state).toBe("cancelled");
		expect(renderPlain(card(block).render(120))).toContain("Cancelled · not started");
		expect(buildToolView(block).body).toEqual([]);
	});

	test("saved durations are explicit, fixed across rebuilds, and never synthesized from row clocks", () => {
		for (const durationMs of [undefined, null, -1, Number.NaN, Number.POSITIVE_INFINITY, 0, 1250]) {
			const { block } = hydrate([call({ timestampMs: null }), cancelled({ durationMs })]);
			let clock = 121_000;
			const component = card(block, () => clock);
			const before = renderPlain(component.render(120));
			clock += 600_000;
			component.invalidate();
			expect(renderPlain(component.render(120))).toBe(before);
			expect(renderPlain(card(block, () => clock).render(120))).toBe(before);
			if (durationMs === 0) expect(before).toContain("0ms");
			else if (durationMs === 1250) expect(before).toContain("1.3s");
			else {
				expect(block.durationMs).toBeUndefined();
				expect(before).not.toMatch(/\d+(?:\.\d+)?(?:ms|s|m)\s*$/m);
			}
		}
	});

	test("history cards never schedule live spinner ticks", () => {
		const intervals = spyOn(globalThis, "setInterval");
		try {
			for (const rows of [[call()], [call(), cancelled()]]) {
				const { block } = hydrate(rows);
				const component = new ToolCardComponent(block, {
					requestRender: () => {
						throw new Error("history requested an animation frame");
					},
				});
				teardown.push(() => component.dispose());
				expect(intervals).not.toHaveBeenCalled();
			}
		} finally {
			intervals.mockRestore();
		}
	});
});

test("cold session switching and transcript rebuild keep cancelled output expandable", async () => {
	const server = await FakeControlPlane.start();
	teardown.push(() => server.stop());
	server.respondWith("chat.history", {
		messages: [
			{ id: "u", role: "user", content: "run the command", timestampMs: 500 },
			call(),
			cancelled(),
			{ id: "a", role: "assistant", content: "Stopped as requested.", timestampMs: 3000 },
		],
	});
	server.respondWith("sessions.list", { sessions: [] });
	server.respondWith("sessions.active.list", { sessions: [] });
	server.respondWith("exec.approvals.get", { approvals: [] });
	const app = new AppShell({
		url: server.url,
		sessionKey: "initial",
		version: "test",
		client: new ControlPlaneClient({ url: server.url }),
		terminal: new MemoryTerminal(),
		smoothStreaming: false,
	});
	teardown.push(() => app.stop());
	await app.start();
	await app.sessions.switch("stored-cancelled");
	for (let rebuild = 0; rebuild < 2; rebuild++) {
		if (rebuild > 0) app.events.rebuildFocused();
		expect(app.events.toggleLatestBlock()).toBe(true);
		expect(renderPlain(app.chatContainer.render(120))).not.toContain("STARTED");
		expect(app.events.toggleLatestBlock()).toBe(true);
		const text = renderPlain(app.chatContainer.render(120));
		expect(text).toContain("STARTED");
		expect(text).toContain("[cancelled]");
		expect(text).toContain("run the command");
		expect(text).toContain("Stopped as requested.");
		expect(app.store.focused.blocks.filter((block) => block.kind === "tool")).toHaveLength(1);
	}
});
