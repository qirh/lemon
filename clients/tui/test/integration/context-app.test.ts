/**
 * `/context` and the gauge seed through the real shell and fake control plane.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { AppShell } from "../../src/app.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { reportedContextFixture } from "../../src/dev/fixtures/context-fixtures.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { ContextPanelComponent } from "../../src/ui/components/context-panel.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain, stripAnsi } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const teardown: Array<() => void> = [];

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

const HISTORY = [
	{ id: "m1", role: "user", content: "what is the plan?", timestampMs: 1000 },
	{ id: "m2", role: "assistant", content: "ship it", timestampMs: 2000 },
];

async function bootApp(options: { methods?: string[]; withHistory?: string[] } = {}) {
	const server = await FakeControlPlane.start(options.methods ? { methods: options.methods } : {});
	teardown.push(() => server.stop());
	const withHistory = new Set(options.withHistory ?? []);
	server.onMethod("chat.history", (params: { sessionKey: string }) => ({
		messages: withHistory.has(params.sessionKey) ? HISTORY : [],
	}));
	server.respondWith("sessions.active.list", { sessions: [] });
	server.respondWith("exec.approvals.get", { approvals: [] });
	server.respondWith("usage.status", { summary: { totalTokens: 48_000 } });
	server.serveSessionContext({
		"tui-a": reportedContextFixture("tui-a"),
		"tui-b": reportedContextFixture("tui-b"),
	});

	const terminal = new MemoryTerminal();
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		sessionKey: "tui-a",
		version: "test",
		client,
		terminal,
		cwd: "/work/project",
		readBranch: async () => "main",
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, server };
}

const statusLine = (app: AppShell) => stripAnsi(app.statusBar.render(160)[0] ?? "");
/**
 * Requests are written to the socket synchronously and answered in order, so a
 * later round trip proves any seed request already reached the server and had
 * its answer applied.
 */
const settle = (app: AppShell) => app.methods.sessionsActiveList();

describe("/context in the app", () => {
	test("opens the panel overlay, width-bounded, and feeds the gauge", async () => {
		const { app, server } = await bootApp();
		await app.submit("/context");
		expect(server.requestsFor("sessions.context").at(-1)?.params).toEqual({
			sessionKey: "tui-a",
			cwd: "/work/project",
		});
		const panel = app.selectors.current;
		if (!(panel instanceof ContextPanelComponent)) throw new Error("context panel is not open");
		for (const width of [40, 100]) {
			for (const row of panel.render(width)) {
				expect(visibleWidth(row)).toBeLessThanOrEqual(width);
			}
		}
		expect(renderPlain(panel.render(100))).toContain("Free space");
		expect(statusLine(app)).toContain("45k/200k");
		expect(statusLine(app)).toContain("23%");

		panel.handleInput("\x1b");
		expect(app.selectors.isOpen).toBe(false);
	});

	test("the Tern composer's context meter reads the same measurement and opens /context", async () => {
		const { app, server } = await bootApp();
		expect(app.statusBar.describeComposerFacts().context).toBeUndefined();
		await app.submit("/context");
		app.selectors.close();
		const meter = app.statusBar.describeComposerFacts().context;
		expect(meter?.k === "meter" ? meter.p : undefined).toMatchObject({
			value: 45_210 / 200_000,
			label: "23%",
			total: "200k",
		});

		app.statusBar.handleNativeEvent({
			type: "action",
			key: "context",
			act: "status.context",
			mods: [],
		});
		await waitFor(() => app.selectors.current instanceof ContextPanelComponent, {
			what: "context panel from the composer meter",
		});
		expect(server.requestsFor("sessions.context")).toHaveLength(2);
	});

	test("not_found becomes a transcript notice, not a panel", async () => {
		const { app, server } = await bootApp();
		server.serveSessionContext({});
		await app.submit("/context");
		expect(app.selectors.isOpen).toBe(false);
		expect(renderPlain(app.chatContainer.render(100))).toContain(
			"No context recorded yet — send a prompt first.",
		);
	});
});

describe("gauge seeding", () => {
	test("a focused session with history but no run usage is measured once", async () => {
		const { app, server } = await bootApp({ withHistory: ["tui-b"] });
		await app.sessions.switch("tui-b");
		await waitFor(() => statusLine(app).includes("45k/200k"), { what: "seeded gauge" });
		expect(server.requestsFor("sessions.context")).toHaveLength(1);

		await app.sessions.switch("tui-a");
		await app.sessions.switch("tui-b");
		await settle(app);
		expect(server.requestsFor("sessions.context")).toHaveLength(1);
	});

	test("a session without durable history is not asked", async () => {
		const { app, server } = await bootApp();
		await app.sessions.switch("tui-c");
		await settle(app);
		expect(server.requestsFor("sessions.context")).toHaveLength(0);
		expect(statusLine(app)).not.toContain("/200k");
	});

	test("not_found while seeding is silent", async () => {
		const { app, server } = await bootApp({ withHistory: ["tui-d"] });
		await app.sessions.switch("tui-d");
		await server.waitForRequest("sessions.context");
		await settle(app);
		expect(renderPlain(app.chatContainer.render(100))).not.toContain("No context recorded");
		expect(app.store.focused.contextMeasurement).toBeUndefined();
	});

	test("a daemon without sessions.context is never asked", async () => {
		const { app, server } = await bootApp({
			methods: ["chat.send", "chat.history", "sessions.active.list", "exec.approvals.get"],
			withHistory: ["tui-b"],
		});
		await app.sessions.switch("tui-b");
		await settle(app);
		expect(server.requestsFor("sessions.context")).toHaveLength(0);
	});
});
