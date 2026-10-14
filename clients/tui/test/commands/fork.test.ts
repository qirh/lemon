import { afterEach, expect, test } from "bun:test";
import type { CommandHost } from "../../src/commands/registry.ts";
import { NotConnectedError } from "../../src/protocol/errors.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let harness: Harness | undefined;
afterEach(() => harness?.stop());

async function forkHarness() {
	harness = await createHarness({
		methods: ["sessions.fork"],
		sessionKey: "tui-source",
		cwd: "/work/project with spaces",
	});
	harness.server.respondWith("sessions.fork", {
		sessionKey: "tui-child",
		sourceSessionKey: "tui-source",
	});
	return harness;
}

test("/fork clones through the real typed consumer before opening, preserving source and draft", async () => {
	const h = await forkHarness();
	const opened: string[] = [];
	(h.host as CommandHost).openFork = async (key) => {
		expect(h.server.requestsFor("sessions.fork")).toHaveLength(1);
		opened.push(key);
	};
	h.host.draft = "unfinished draft";
	const source = h.store.focused;
	await h.run("/fork");
	expect(h.server.requestsFor("sessions.fork")[0]?.params).toEqual({
		sessionKey: "tui-source",
		cwd: "/work/project with spaces",
	});
	expect(opened).toEqual(["tui-child"]);
	expect(h.store.focused).toBe(source);
	expect(h.host.draft).toBe("unfinished draft");
	expect(h.host.text).toContain("fork created: tui-child");
	expect(h.server.requestsFor("sessions.delete")).toHaveLength(0);
});

test("split failure reports the durable child recovery command without raw errors", async () => {
	const h = await forkHarness();
	(h.host as CommandHost).openFork = async () => {
		throw new Error("secret token and /private/path");
	};
	await h.run("/fork");
	expect(h.host.text).toContain("/session open tui-child");
	expect(h.host.text).toContain("preserved");
	expect(h.host.text).not.toContain("secret token");
	expect(h.server.requestsFor("sessions.delete")).toHaveLength(0);
});

test("unsupported capability and unexpected arguments do not clone", async () => {
	const h = await forkHarness();
	(h.host as CommandHost).openFork = async () => {};
	await h.run("/fork extra");
	expect(h.server.requestsFor("sessions.fork")).toHaveLength(0);
	h.stop();
	harness = await createHarness({ methods: [] });
	(harness.host as CommandHost).openFork = async () => {};
	await harness.run("/fork");
	expect(harness.server.requestsFor("sessions.fork")).toHaveLength(0);
});

test("fork cannot be queued offline even when the caller requests queueing", async () => {
	const h = await forkHarness();
	h.client.close();
	await expect(
		h.methods.sessionsFork({ sessionKey: "tui-source", cwd: "/work" }, { queueIfOffline: true }),
	).rejects.toBeInstanceOf(NotConnectedError);
	expect(h.server.requestsFor("sessions.fork")).toHaveLength(0);
});
