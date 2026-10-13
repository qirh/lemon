import { afterEach, beforeEach, expect, test } from "bun:test";
import type { PickerSpec } from "../../src/commands/registry.ts";
import { NotConnectedError } from "../../src/protocol/errors.ts";
import type { SessionsPlanResult } from "../../src/protocol/types.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let h: Harness;
const pending: SessionsPlanResult = {
	sessionKey: "s",
	plan: {
		mode: "plan",
		status: "pending",
		revision: "reviewed-revision",
		path: "/repo/.lemon/plans/reviewed-revision.md",
		content: "# Proposed changes\n\n1. Preserve the public API.\n2. Add a regression test.",
	},
};
const draft: SessionsPlanResult = {
	sessionKey: "s",
	plan: { mode: "plan", status: "draft", revision: null, path: null, content: null },
};

beforeEach(async () => {
	h = await createHarness({
		sessionKey: "s",
		cwd: "/repo",
		methods: ["sessions.plan", "sessions.compact"],
	});
	h.host.draft = "preserve my draft";
	h.server.respondWith("sessions.plan", pending);
});
afterEach(() => h.stop());

function picker(): PickerSpec {
	return h.host.pickers.at(-1)!;
}

async function choose(value: string): Promise<void> {
	await picker().onSelect(picker().items.find((item) => item.value === value)!);
}

function params(): unknown[] {
	return h.server.requestsFor("sessions.plan").map((request) => request.params);
}

test("plan status and show display the server artifact without changing mode", async () => {
	for (const command of ["/plan", "/plan status", "/plan show"]) await h.run(command);
	expect(params()).toEqual(Array(3).fill({ sessionKey: "s", cwd: "/repo", action: "status" }));
	expect(h.host.text).toContain(pending.plan.content!);
	expect(h.host.text).toContain(pending.plan.path!);
	expect(h.host.text).toContain(pending.plan.revision!);
	expect(h.host.text).toContain("pending");
	expect(h.host.pickers).toHaveLength(0);
	expect(h.host.deliveries).toEqual([]);
});

test("draft and approved states are displayed as returned by the daemon", async () => {
	for (const result of [
		draft,
		{ ...pending, plan: { ...pending.plan, mode: "code", status: "approved" } },
	]) {
		h.server.respondWith("sessions.plan", result);
		await h.run("/plan");
		expect(h.host.text).toContain(result.plan.status);
	}
	expect(h.host.deliveries).toEqual([]);
});

test("enter optionally sends the intact planning request only after mode is confirmed", async () => {
	h.server.respondWith("sessions.plan", draft);
	await h.run('/plan enter Review  the "API surface"\n  before editing');
	expect(params()).toEqual([{ sessionKey: "s", cwd: "/repo", action: "enter" }]);
	expect(h.host.deliveries).toEqual([
		{ text: 'Review  the "API surface"\n  before editing', mode: "queue" },
	]);
	expect(h.host.draft).toBe("preserve my draft");
});

test("enter without a request never invents or submits one", async () => {
	h.server.respondWith("sessions.plan", draft);
	await h.run("/plan enter");
	expect(params()).toEqual([{ sessionKey: "s", cwd: "/repo", action: "enter" }]);
	expect(h.host.deliveries).toEqual([]);
});

test("refused planning entry never delivers the requested prompt", async () => {
	h.server.failWith("sessions.plan", "FORBIDDEN", "private failure text");
	await h.run("/plan enter inspect the API");
	expect(h.host.last?.level).toBe("error");
	expect(h.host.text).not.toContain("private failure text");
	expect(h.host.deliveries).toEqual([]);
});

test("approval first shows the artifact and cancellation sends no mutation", async () => {
	await h.run("/plan approve");
	expect(h.host.text).toContain(pending.plan.content!);
	expect(picker().detail?.join("\n")).toContain(pending.plan.revision!);
	expect(picker().items[0].value).toBe("cancel");
	await choose("cancel");
	await choose("approve");
	expect(params()).toEqual([{ sessionKey: "s", cwd: "/repo", action: "status" }]);
	expect(h.host.draft).toBe("preserve my draft");
	expect(h.host.deliveries).toEqual([]);
});

test("Escape cancellation invalidates the review callback", async () => {
	await h.run("/plan approve");
	picker().onCancel?.();
	await choose("approve");
	expect(params()).toHaveLength(1);
});

test("explicit approval is bound to the shown revision and never starts execution", async () => {
	await h.run("/plan approve");
	h.server.respondWith("sessions.plan", {
		...pending,
		plan: { ...pending.plan, mode: "code", status: "approved" },
	});
	await choose("approve");
	await choose("approve");
	expect(params()).toEqual([
		{ sessionKey: "s", cwd: "/repo", action: "status" },
		{ sessionKey: "s", cwd: "/repo", action: "approve", revision: pending.plan.revision },
	]);
	expect(h.host.last?.level).toBe("info");
	expect(h.host.deliveries).toEqual([]);
	expect(h.host.draft).toBe("preserve my draft");
});

test("a stale revision refusal preserves the draft and requires a new review", async () => {
	await h.run("/plan approve");
	h.server.failWith("sessions.plan", "STALE_REVISION", "private artifact content");
	await choose("approve");
	expect(params().at(-1)).toEqual({
		sessionKey: "s",
		cwd: "/repo",
		action: "approve",
		revision: pending.plan.revision,
	});
	expect(h.host.last?.level).toBe("error");
	expect(h.host.text).not.toContain("private artifact content");
	expect(h.host.deliveries).toEqual([]);
	expect(h.host.draft).toBe("preserve my draft");
	h.server.respondWith("sessions.plan", {
		...pending,
		plan: { ...pending.plan, revision: "new-revision", content: "# Changed plan" },
	});
	await h.run("/plan approve");
	expect(picker().detail?.join("\n")).toContain("new-revision");
	expect(h.host.text).toContain("# Changed plan");
});

test("switching sessions after review prevents approval", async () => {
	await h.run("/plan approve");
	h.store.setFocused("other");
	await choose("approve");
	expect(params()).toHaveLength(1);
	expect(h.host.deliveries).toEqual([]);
});

test("draft, missing artifact and mismatched session cannot open approval", async () => {
	for (const result of [
		draft,
		{ ...pending, plan: { ...pending.plan, content: null } },
		{ ...pending, sessionKey: "other" },
	]) {
		h.server.respondWith("sessions.plan", result);
		await h.run("/plan approve");
	}
	expect(h.host.pickers).toHaveLength(0);
	expect(params()).toEqual(Array(3).fill({ sessionKey: "s", cwd: "/repo", action: "status" }));
});

test("an unexpected approval revision is not reported as successful", async () => {
	await h.run("/plan approve");
	h.server.respondWith("sessions.plan", {
		...pending,
		plan: { ...pending.plan, mode: "code", status: "approved", revision: "unreviewed" },
	});
	await choose("approve");
	expect(h.host.last?.level).toBe("error");
	expect(h.host.deliveries).toEqual([]);
});

test("discard explicitly exits planning without approving or submitting a prompt", async () => {
	h.server.respondWith("sessions.plan", {
		...draft,
		plan: { ...draft.plan, mode: "code", status: "none" },
	});
	await h.run("/plan discard");
	expect(params()).toEqual([{ sessionKey: "s", cwd: "/repo", action: "discard" }]);
	expect(h.host.last?.level).toBe("info");
	expect(h.host.deliveries).toEqual([]);
	expect(h.host.draft).toBe("preserve my draft");
});

test("unsupported plan capability and invalid arguments send no requests", async () => {
	await h.run("/plan approve --yes");
	expect(params()).toEqual([]);
	h.stop();
	h = await createHarness({ methods: ["chat.send"] });
	await h.run("/plan enter");
	expect(params()).toEqual([]);
	expect(h.host.last?.level).toBe("warning");
});

test("planning and manual compaction cannot opt into the offline queue", async () => {
	h.client.close();
	await expect(
		h.methods.sessionsPlan(
			{ sessionKey: "s", cwd: "/repo", action: "approve", revision: "reviewed" },
			{ queueIfOffline: true },
		),
	).rejects.toBeInstanceOf(NotConnectedError);
	await expect(
		h.methods.sessionsCompact(
			{ sessionKey: "s", cwd: "/repo", focus: "keep APIs", summary: "supported supplied summary" },
			{ queueIfOffline: true },
		),
	).rejects.toBeInstanceOf(NotConnectedError);
	expect(params()).toEqual([]);
	expect(h.server.requestsFor("sessions.compact")).toEqual([]);
});
