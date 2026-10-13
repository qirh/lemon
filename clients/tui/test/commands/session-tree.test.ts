import { afterEach, beforeEach, expect, test } from "bun:test";
import type { PickerSpec } from "../../src/commands/registry.ts";
import type { SessionTreeResult } from "../../src/protocol/session-tree.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let h: Harness;
let resets: string[];
let reloads: string[];
const tree: SessionTreeResult = {
	sessionKey: "s",
	sessionId: "native-s",
	leafId: "a2",
	offset: 0,
	totalEntries: 4,
	hasMore: false,
	branches: [
		{ leafId: "a2", active: true },
		{ leafId: "old", active: false },
	],
	entries: [
		{
			id: "u1",
			parentId: null,
			type: "message",
			role: "user",
			text: "first prompt",
			isActive: true,
			isLeaf: false,
			rewindable: true,
		},
		{
			id: "a1",
			parentId: "u1",
			type: "message",
			role: "assistant",
			text: "first answer",
			isActive: true,
			isLeaf: false,
			rewindable: false,
		},
		{
			id: "u2",
			parentId: "a1",
			type: "message",
			role: "user",
			text: "second prompt",
			isActive: true,
			isLeaf: false,
			rewindable: true,
		},
		{
			id: "old",
			parentId: "a1",
			type: "message",
			role: "user",
			text: "abandoned prompt",
			isActive: false,
			isLeaf: true,
			rewindable: false,
		},
	],
};
const preview = {
	sessionKey: "s",
	sessionId: "native-s",
	entryId: "u2",
	confirmationToken: "snapshot-bound-token",
	prompt: "second prompt",
	discardedMessages: 2,
	restorePaths: ["/repo/file.ts"],
	unrestorableTools: [],
};

beforeEach(async () => {
	h = await createHarness({
		sessionKey: "s",
		cwd: "/repo",
		methods: ["chat.history", "sessions.tree", "sessions.rewind", "sessions.metadata.patch"],
	});
	resets = [];
	reloads = [];
	Object.assign(h.host, {
		resetSession: (key: string) => {
			resets.push(key);
		},
		reloadSession: async (key: string) => {
			reloads.push(key);
		},
	});
	h.host.draft = "keep my draft";
	h.server.respondWith("sessions.tree", tree);
	h.server.respondWith("sessions.rewind", preview);
});
afterEach(() => h.stop());

function picker(): PickerSpec {
	return h.host.pickers.at(-1)!;
}
async function chooseUser(): Promise<void> {
	await picker().onSelect(picker().items.find((item) => item.value === "u2")!);
}

test("tree includes preserved branches, but rewind only offers active user entries", async () => {
	await h.run("/tree");
	expect(picker().items.map((item) => item.value)).toContain("old");
	await h.run("/rewind");
	expect(picker().items.map((item) => item.value)).toEqual(["u1", "u2"]);
	expect(h.server.requestsFor("sessions.tree")[0].params).toMatchObject({
		sessionKey: "s",
		cwd: "/repo",
	});
});

test("preview cancellation preserves the draft and sends no mutating request", async () => {
	await h.run("/rewind");
	await chooseUser();
	expect(picker().items[0].value).toBe("cancel");
	await picker().onSelect(picker().items[0]);
	expect(h.server.requestsFor("sessions.rewind").map((request) => request.params)).toEqual([
		{ sessionKey: "s", cwd: "/repo", entryId: "u2", restoreFiles: false, dryRun: true },
	]);
	expect(h.host.draft).toBe("keep my draft");
	expect(resets).toEqual([]);
});

test("confirmation repeats the exact preview target, restores the prompt and reloads only after success", async () => {
	await h.run("/rewind --files");
	await chooseUser();
	h.server.respondWith("sessions.rewind", {
		...preview,
		leafId: "a1",
		restoredPaths: ["/repo/file.ts"],
	});
	await picker().onSelect(picker().items.find((item) => item.value === "confirm")!);
	const requests = h.server.requestsFor("sessions.rewind");
	expect(requests[0].params).toEqual({
		sessionKey: "s",
		cwd: "/repo",
		entryId: "u2",
		restoreFiles: true,
		dryRun: true,
	});
	expect(requests[1].params).toEqual({
		sessionKey: "s",
		cwd: "/repo",
		entryId: "u2",
		restoreFiles: true,
		dryRun: false,
		confirmationToken: preview.confirmationToken,
	});
	expect(h.host.draft).toBe("second prompt");
	expect(resets).toEqual(["s"]);
	expect(reloads).toEqual(["s"]);
	expect(h.host.deliveries).toEqual([]);
});

test("stale confirmation never clears the local transcript or draft", async () => {
	await h.run("/rewind");
	await chooseUser();
	h.server.failWith("sessions.rewind", "STALE_CONFIRMATION", "preview no longer matches");
	await picker().onSelect(picker().items.find((item) => item.value === "confirm")!);
	expect(h.host.draft).toBe("keep my draft");
	expect(resets).toEqual([]);
	expect(reloads).toEqual([]);
	expect(h.host.text).toContain("STALE_CONFIRMATION");
});

test("switching sessions after preview cannot confirm a stale modal against the new focus", async () => {
	await h.run("/rewind");
	await chooseUser();
	h.store.setFocused("other");
	await picker().onSelect(picker().items.find((item) => item.value === "confirm")!);
	expect(h.server.requestsFor("sessions.rewind")).toHaveLength(1);
	expect(resets).toEqual([]);
});

test("name persists server metadata and mirrors the confirmed title", async () => {
	h.server.respondWith("sessions.metadata.patch", { success: true, metadata: { titleBytes: 12 } });
	await h.run("/name Review parser");
	expect(h.server.requestsFor("sessions.metadata.patch")[0].params).toEqual({
		sessionKey: "s",
		title: "Review parser",
	});
	expect(h.store.focused.title).toBe("Review parser");
	h.server.failWith("sessions.metadata.patch", "FORBIDDEN", "denied");
	await h.run("/name Not accepted");
	expect(h.store.focused.title).toBe("Review parser");
});
