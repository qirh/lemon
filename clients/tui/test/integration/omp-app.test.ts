/**
 * The omp surfaces through the real shell: handshake sync, the status badge,
 * Alt+M and `/omp`, all against the fake control plane's omp fixtures.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import {
	FakeControlPlane,
	installOmpFixtures,
	OMP_FAKE_EVENTS,
	OMP_FAKE_METHODS,
} from "../../src/dev/fake-server.ts";
import { ompSessionWire } from "../../src/dev/fixtures/omp-fixtures.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { METHOD } from "../../src/protocol/methods.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain, stripAnsi } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const ALT_M = "\x1bm";
const teardown: Array<() => void> = [];

beforeEach(() => initTheme({ colorLevel: 0 }));
afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

async function bootApp() {
	const server = await FakeControlPlane.start({
		methods: [...OMP_FAKE_METHODS],
		events: [...OMP_FAKE_EVENTS],
	});
	teardown.push(() => server.stop());
	installOmpFixtures(server);
	server.onMethod("chat.send", (params: { sessionKey: string }) => ({
		runId: "run-1",
		sessionKey: params.sessionKey,
	}));
	server.respondWith("chat.history", { messages: [] });
	const terminal = new MemoryTerminal();
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		sessionKey: "tui-omp",
		version: "test",
		client,
		terminal,
		cwd: "/work/lemon",
		readBranch: async () => "main",
	});
	teardown.push(() => app.stop());
	await app.start();
	await waitFor(() => app.store.omp.size === 3, { what: "omp sync on handshake" });
	const dock = () => renderPlain(app.statusContainer.render(200));
	return { app, server, terminal, dock };
}

describe("omp in the app", () => {
	test("the handshake syncs sessions and the status line shows running ones", async () => {
		const { app, server } = await bootApp();
		expect(server.requestsFor(METHOD.ompStatus)).toHaveLength(1);
		expect(stripAnsi(app.statusBar.render(200)[0] ?? "")).toContain("omp 1▶");
		server.pushEvent("omp.session", {
			reason: "settled",
			session: ompSessionWire({ status: "idle", lastTurn: "completed", updatedAt: Date.now() }),
		});
		await waitFor(() => app.store.omp.busyCount() === 0);
		expect(stripAnsi(app.statusBar.render(200)[0] ?? "")).not.toContain("omp ");
	});

	test("Alt+M opens the focused panel; Escape returns to the editor", async () => {
		const { app, terminal, dock } = await bootApp();
		terminal.sendInput(ALT_M);
		await waitFor(() => dock().includes("omp · 2 live · 1 running · 1 ended"));
		expect(dock()).toContain("enter detail");
		terminal.sendInput("\r");
		await waitFor(() => dock().includes("omp · Fix the flaky reconnect test (omp_3f9a1c2b7d4e)"));
		terminal.sendInput("\x1b");
		await waitFor(() => !dock().includes("omp ·"));
		expect(app.tui.getFocused()).toBe(app.editor);
	});

	test("/omp opens the panel and /omp run starts in the chat working directory", async () => {
		const { app, server, dock } = await bootApp();
		await app.submit("/omp");
		expect(dock()).toContain("omp · 2 live");
		await app.submit("/omp run tidy the README");
		await app.submit("hello");
		const start = server.requestsFor(METHOD.ompSessionsStart)[0]?.params as Record<string, unknown>;
		const chat = server.requestsFor("chat.send")[0]?.params as Record<string, unknown>;
		expect(start).toEqual({ prompt: "tidy the README", cwd: "/work/lemon" });
		expect(chat.cwd).toBe(start.cwd);
		await waitFor(() => dock().includes("tidy the README"));
	});
});
