import { expect, test } from "bun:test";
import { TaskStore, taskElapsedMs } from "../../src/store/task-store.ts";

test("three concurrent children retain keyed identities through interleaved updates", () => {
	const store = new TaskStore();
	store.upsert(
		"chat",
		[
			{ taskId: "one", status: "running", progress: "reading one" },
			{ taskId: "two", status: "running", progress: "reading two" },
			{ taskId: "three", status: "running", progress: "reading three" },
		],
		1000,
	);
	store.upsert("chat", [{ taskId: "two", status: "running", progress: "editing two" }], 2000);
	store.upsert("chat", [{ taskId: "one", status: "completed", progress: "one done" }], 3000);
	store.upsert("chat", [{ taskId: "three", status: "running", progress: "testing three" }], 4000);
	expect(store.items("chat").map((task) => task.taskId)).toEqual(["one", "two", "three"]);
	expect(store.find("chat", "two")?.progress).toBe("editing two");
	expect(store.find("chat", "three")?.progress).toBe("testing three");
	expect(taskElapsedMs(store.find("chat", "one")!, 9000)).toBe(2000);
	expect(taskElapsedMs(store.find("chat", "three")!, 9000)).toBe(8000);
});

test("terminal results freeze elapsed time and ignore stale running or untyped progress", () => {
	const store = new TaskStore();
	store.upsert("chat", [{ taskId: "child", status: "running" }], 1000);
	store.upsert("chat", [{ taskId: "child", status: "error", progress: "compile failed" }], 6000);
	store.upsert("chat", [{ taskId: "child", status: "running", progress: "compiling" }], 8000);
	store.upsert("chat", [{ taskId: "child", parentRunId: "parent", progress: "old" }], 9000);
	const child = store.find("chat", "child")!;
	expect(child.status).toBe("error");
	expect(child.progress).toBe("compile failed");
	expect(child.parentRunId).toBe("parent");
	expect(child.updatedAt).toBe(6000);
	expect(taskElapsedMs(child, 20000)).toBe(5000);
});

test("nested opaque IDs attach through emitted run relationships even when the parent arrives late", () => {
	const store = new TaskStore();
	store.upsert(
		"chat",
		[{ taskId: "opaque.child.7", runId: "leaf-run", parentRunId: "middle-run", status: "running" }],
		0,
	);
	store.upsert(
		"chat",
		[{ taskId: "not-a-prefix", runId: "middle-run", parentRunId: "root-run", status: "running" }],
		1,
	);
	store.upsert("chat", [{ taskId: "root", runId: "root-run", status: "running" }], 2);
	expect(
		store.tree("chat").map(({ task, depth, parentTaskId }) => [task.taskId, depth, parentTaskId]),
	).toEqual([
		["root", 0, undefined],
		["not-a-prefix", 1, "root"],
		["opaque.child.7", 2, "not-a-prefix"],
	]);
	store.upsert("chat", [{ taskId: "root.fake-dot-child", status: "running" }], 3);
	expect(store.tree("chat").at(-1)?.depth).toBe(0);
});

test("native session parent metadata works without run IDs and cycles remain visible", () => {
	const store = new TaskStore();
	store.upsert(
		"chat",
		[
			{ taskId: "parent", sessionId: "native-parent", status: "running" },
			{ taskId: "child", parentSessionId: "native-parent", status: "running" },
			{ taskId: "cycle-a", runId: "a", parentRunId: "b" },
			{ taskId: "cycle-b", runId: "b", parentRunId: "a" },
		],
		1000,
	);
	const rows = store.tree("chat");
	expect(rows).toHaveLength(4);
	expect(rows[1]?.parentTaskId).toBe("parent");
	expect(rows[1]?.depth).toBe(1);
	expect(new Set(rows.map((row) => row.task.taskId)).size).toBe(4);
});

test("task IDs and parent run IDs never cross session ownership", () => {
	const store = new TaskStore();
	store.upsert(
		"first",
		[{ taskId: "same", runId: "parent-run", status: "running", progress: "first only" }],
		0,
	);
	store.upsert(
		"second",
		[{ taskId: "same", parentRunId: "parent-run", status: "aborted", progress: "second only" }],
		1,
	);
	expect(store.find("first", "same")?.progress).toBe("first only");
	expect(store.find("second", "same")?.status).toBe("aborted");
	expect(store.tree("second")[0]?.depth).toBe(0);
	store.clear("first");
	expect(store.items("first")).toEqual([]);
	expect(store.items("second")).toHaveLength(1);
});

test("elapsed duration is observed locally and does not invent missing history", () => {
	const store = new TaskStore();
	store.upsert("chat", [{ taskId: "already-done", status: "completed" }], 9000);
	expect(taskElapsedMs(store.find("chat", "already-done")!, 100000)).toBe(0);
	store.upsert("chat", [{ taskId: "active", status: "running" }], 10000);
	expect(taskElapsedMs(store.find("chat", "active")!, 9999)).toBe(0);
});
