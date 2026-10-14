import { describe, expect, test } from "bun:test";
import { ompSessionWire } from "../../src/dev/fixtures/omp-fixtures.ts";
import { type OmpSession, parseOmpSession } from "../../src/protocol/omp.ts";
import { OMP_STORE_LIMIT, OmpStore } from "../../src/store/omp-store.ts";

function session(overrides: Record<string, unknown> = {}): OmpSession {
	const parsed = parseOmpSession(ompSessionWire(overrides));
	if (!parsed) throw new Error("fixture did not parse");
	return parsed;
}

describe("OmpStore", () => {
	test("upserts by id and emits changes", () => {
		const store = new OmpStore();
		let changes = 0;
		store.events.on("changed", () => {
			changes += 1;
		});
		store.upsert(session({ id: "omp_a", updatedAt: 10 }));
		store.upsert(session({ id: "omp_a", updatedAt: 20, activity: "editing" }));
		expect(store.size).toBe(1);
		expect(store.get("omp_a")?.activity).toBe("editing");
		expect(changes).toBe(2);
	});

	test("a late snapshot never rewinds a newer one", () => {
		const store = new OmpStore();
		store.upsert(session({ id: "omp_a", updatedAt: 20, status: "idle" }));
		expect(store.upsert(session({ id: "omp_a", updatedAt: 10, status: "running" }))).toBe(false);
		expect(store.get("omp_a")?.status).toBe("idle");
	});

	test("ended sessions are kept after exit; live ones sort first, newest first", () => {
		const store = new OmpStore();
		store.upsert(session({ id: "omp_old", status: "running", updatedAt: 1 }));
		store.upsert(session({ id: "omp_new", status: "idle", updatedAt: 5 }));
		store.upsert(session({ id: "omp_done", status: "closed", updatedAt: 9 }));
		expect(store.sessions().map((s) => s.id)).toEqual(["omp_new", "omp_old", "omp_done"]);
		expect(store.busyCount()).toBe(1);
		store.upsert(session({ id: "omp_old", status: "closed", updatedAt: 6 }));
		expect(store.size).toBe(3);
		expect(store.busyCount()).toBe(0);
	});

	test("a complete list drops live rows it omits but keeps ended history", () => {
		const store = new OmpStore();
		store.upsert(session({ id: "omp_gone", status: "running", updatedAt: 1 }));
		store.upsert(session({ id: "omp_ended", status: "failed", updatedAt: 1 }));
		store.applyList([session({ id: "omp_now", status: "running", updatedAt: 2 })], false);
		expect(store.get("omp_gone")).toBeDefined();
		store.applyList([session({ id: "omp_now", status: "running", updatedAt: 3 })], true);
		expect(store.get("omp_gone")).toBeUndefined();
		expect(store.get("omp_ended")).toBeDefined();
		expect(store.get("omp_now")?.updatedAt).toBe(3);
	});

	test("bounded: evicts the oldest ended sessions first", () => {
		const store = new OmpStore();
		store.upsert(session({ id: "omp_live_oldest", status: "running", updatedAt: 0 }));
		for (let index = 0; index < OMP_STORE_LIMIT + 5; index++) {
			store.upsert(session({ id: `omp_${index}`, status: "closed", updatedAt: 100 + index }));
		}
		expect(store.size).toBe(OMP_STORE_LIMIT);
		expect(store.get("omp_live_oldest")).toBeDefined();
		for (let index = 0; index < 6; index++) expect(store.get(`omp_${index}`)).toBeUndefined();
		expect(store.get(`omp_${OMP_STORE_LIMIT + 4}`)).toBeDefined();
	});

	test("status is recorded", () => {
		const store = new OmpStore();
		store.setStatus({
			available: false,
			version: null,
			reason: "not_installed",
			live: 0,
			maxSessions: null,
		});
		expect(store.status?.available).toBe(false);
	});
});
