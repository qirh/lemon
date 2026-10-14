import { afterEach, beforeEach, expect, test } from "bun:test";
import type { PickerSpec } from "../../src/commands/registry.ts";
import { NotConnectedError } from "../../src/protocol/errors.ts";
import type { SessionsPlanParams, SessionsPlanResult } from "../../src/protocol/types.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let h: Harness;

const PATH = "/home/u/.lemon/plans/s/fix-api-plan.md";
const DRAFT = "# Fix the API\n\n1. Preserve the public API.\n2. Add a regression test.";

function receipt(
	mode: "plan" | "code",
	plan: Partial<SessionsPlanResult["plan"]> = {},
): SessionsPlanResult {
	return { sessionKey: "s", plan: { mode, path: null, content: null, ...plan } };
}

/**
 * A stateful daemon: `status` reports the mode, `enter`/`exit` move it. The
 * plan file survives an exit, as the native session keeps it.
 */
function daemon(initial: SessionsPlanResult["plan"]): void {
	const state = { ...initial };
	h.server.onMethod("sessions.plan", (params: SessionsPlanParams) => {
		if (params.action === "enter") state.mode = "plan";
		if (params.action === "exit") state.mode = "code";
		return { sessionKey: params.sessionKey, plan: { ...state } };
	});
}

beforeEach(async () => {
	h = await createHarness({
		sessionKey: "s",
		cwd: "/repo",
		methods: ["sessions.plan", "sessions.compact"],
	});
	h.host.draft = "preserve my draft";
	daemon(receipt("code").plan);
});
afterEach(() => h.stop());

function picker(): PickerSpec {
	return h.host.pickers.at(-1)!;
}

async function choose(value: string): Promise<void> {
	await picker().onSelect(picker().items.find((item) => item.value === value)!);
}

function actions(): string[] {
	return h.server
		.requestsFor("sessions.plan")
		.map((request) => (request.params as SessionsPlanParams).action);
}

test("/plan in code mode enters plan mode and records it for the status line", async () => {
	await h.run("/plan");
	expect(h.server.requestsFor("sessions.plan").map((request) => request.params)).toEqual([
		{ sessionKey: "s", cwd: "/repo", action: "status" },
		{ sessionKey: "s", cwd: "/repo", action: "enter" },
	]);
	expect(h.host.last).toEqual({
		text: "plan mode on — read-only; the agent will propose a plan for approval",
		level: "info",
	});
	expect(h.store.session("s").planMode).toBe("plan");
	expect(h.host.statusRefreshes).toBeGreaterThan(0);
	expect(h.host.deliveries).toEqual([]);
	expect(h.host.draft).toBe("preserve my draft");
});

test("entering names a known plan file", async () => {
	daemon(receipt("code", { path: PATH }).plan);
	await h.run("/plan");
	expect(h.host.last?.text).toContain(`(plan file: ${PATH})`);
	expect(h.store.session("s").planPath).toBe(PATH);
});

test("/plan in plan mode without a draft exits directly and approves nothing", async () => {
	daemon(receipt("plan").plan);
	await h.run("/plan");
	expect(actions()).toEqual(["status", "exit"]);
	expect(h.host.pickers).toHaveLength(0);
	expect(h.host.last).toEqual({
		text: "plan mode off; nothing was approved or executed",
		level: "info",
	});
	expect(h.store.session("s").planMode).toBe("code");
	expect(h.host.deliveries).toEqual([]);
});

test("a whitespace-only plan file counts as no draft", async () => {
	daemon(receipt("plan", { path: PATH, content: " \n\n" }).plan);
	await h.run("/plan");
	expect(actions()).toEqual(["status", "exit"]);
	expect(h.host.pickers).toHaveLength(0);
});

test("/plan with a draft plan asks first, with cancel as the default", async () => {
	daemon(receipt("plan", { path: PATH, content: DRAFT }).plan);
	await h.run("/plan");
	expect(actions()).toEqual(["status"]);
	expect(picker().title).toBe("Exit plan mode?");
	expect(picker().detail).toEqual([
		"This exits plan mode without approving a plan.",
		`Plan file: ${PATH}`,
	]);
	expect(picker().items.map((item) => item.value)).toEqual(["cancel", "exit"]);

	await choose("exit");
	expect(actions()).toEqual(["status", "exit"]);
	expect(h.host.last?.text).toBe("plan mode off; nothing was approved or executed");
	expect(h.store.session("s").planMode).toBe("code");
	expect(h.host.deliveries).toEqual([]);
});

test("cancelling the exit confirmation keeps plan mode on", async () => {
	daemon(receipt("plan", { path: PATH, content: DRAFT }).plan);
	await h.run("/plan");
	await choose("cancel");
	await choose("exit");
	expect(actions()).toEqual(["status"]);
	expect(h.store.session("s").planMode).toBe("plan");
});

test("Escape invalidates the confirmation callback", async () => {
	daemon(receipt("plan", { path: PATH, content: DRAFT }).plan);
	await h.run("/plan");
	picker().onCancel?.();
	await choose("exit");
	expect(actions()).toEqual(["status"]);
});

test("a focus switch or a new run after the confirmation opened prevents the exit", async () => {
	daemon(receipt("plan", { path: PATH, content: DRAFT }).plan);
	await h.run("/plan");
	h.store.setFocused("other");
	await choose("exit");
	h.store.setFocused("s");
	await h.run("/plan");
	h.store.focused.busy = true;
	await choose("exit");
	expect(actions()).toEqual(["status", "status"]);
	expect(h.host.last?.level).toBe("warning");
	expect(h.store.session("s").planMode).toBe("plan");
});

test("a busy session is refused locally without a request", async () => {
	h.store.focused.busy = true;
	await h.run("/plan");
	await h.run("/plan investigate the API");
	expect(actions()).toEqual([]);
	expect(h.host.notices).toEqual([
		{ text: "stop the current run before toggling plan mode", level: "warning" },
		{ text: "stop the current run before toggling plan mode", level: "warning" },
	]);
	expect(h.host.deliveries).toEqual([]);
});

test("a daemon busy conflict is a warning and leaves local state alone", async () => {
	await h.run("/plan");
	h.server.onMethod("sessions.plan", (params: SessionsPlanParams) =>
		params.action === "status"
			? receipt("plan")
			: { __fakeError: { code: "CONFLICT", message: "private", details: { reason: "busy" } } },
	);
	await h.run("/plan");
	expect(h.host.last).toEqual({
		text: "stop the current run before toggling plan mode",
		level: "warning",
	});
	expect(h.store.session("s").planMode).toBe("plan");
});

test("/plan <request> enters plan mode first, then delivers the request intact", async () => {
	await h.run('/plan Review  the "API surface"\n  before editing');
	expect(actions()).toEqual(["status", "enter"]);
	expect(h.host.deliveries).toEqual([
		{ text: 'Review  the "API surface"\n  before editing', mode: "queue" },
	]);
	expect(h.host.draft).toBe("preserve my draft");
});

test("/plan <request> while already planning only delivers the request", async () => {
	daemon(receipt("plan", { path: PATH, content: DRAFT }).plan);
	await h.run("/plan also cover the CLI");
	expect(actions()).toEqual(["status"]);
	expect(h.host.pickers).toHaveLength(0);
	expect(h.host.deliveries).toEqual([{ text: "also cover the CLI", mode: "queue" }]);
});

test("a refused or unconfirmed entry never delivers the request", async () => {
	h.server.failWith("sessions.plan", "FORBIDDEN", "private failure text");
	await h.run("/plan inspect the API");
	expect(h.host.last?.level).toBe("error");
	expect(h.host.text).not.toContain("private failure text");
	expect(h.host.deliveries).toEqual([]);

	// The daemon answered `enter` but did not actually enter plan mode.
	h.server.respondWith("sessions.plan", receipt("code"));
	await h.run("/plan inspect the API");
	expect(h.host.last?.level).toBe("error");
	expect(h.host.deliveries).toEqual([]);
	expect(h.store.session("s").planMode).toBe("code");
});

test("malformed or mismatched receipts change nothing", async () => {
	for (const result of [
		{ ...receipt("plan"), sessionKey: "other" },
		{ sessionKey: "s", plan: { mode: "draft", path: null, content: null } },
		{ sessionKey: "s", plan: { mode: "plan", path: 3, content: null } },
	]) {
		h.server.respondWith("sessions.plan", result);
		await h.run("/plan");
		expect(h.host.last?.level).toBe("error");
	}
	expect(actions()).toEqual(["status", "status", "status"]);
	expect(h.store.session("s").planMode).toBeUndefined();
});

test("without a prompt seam a request is refused before any mode change", async () => {
	const context = h.context({
		rest: "plan this",
		ui: Object.assign(h.host, { deliverPrompt: undefined }),
	});
	await h.registry.get("plan")!.run(context, ["plan", "this"]);
	expect(actions()).toEqual([]);
	expect(h.host.last?.level).toBe("warning");
});

test("an unsupported plan capability sends no requests", async () => {
	h.stop();
	h = await createHarness({ methods: ["chat.send"] });
	await h.run("/plan");
	expect(actions()).toEqual([]);
	expect(h.host.last?.level).toBe("warning");
});

test("planning and manual compaction cannot opt into the offline queue", async () => {
	h.client.close();
	await expect(
		h.methods.sessionsPlan(
			{ sessionKey: "s", cwd: "/repo", action: "enter" },
			{ queueIfOffline: true },
		),
	).rejects.toBeInstanceOf(NotConnectedError);
	await expect(
		h.methods.sessionsCompact(
			{ sessionKey: "s", cwd: "/repo", focus: "keep APIs", summary: "supported supplied summary" },
			{ queueIfOffline: true },
		),
	).rejects.toBeInstanceOf(NotConnectedError);
	expect(actions()).toEqual([]);
	expect(h.server.requestsFor("sessions.compact")).toEqual([]);
});
