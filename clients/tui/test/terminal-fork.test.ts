import { expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, symlinkSync, unlinkSync } from "node:fs";
import { dirname } from "node:path";
import { parseArgs } from "../src/main.ts";
import {
	consumeForkHandoff,
	createForkHandoff,
	type ForkLaunch,
	forkClientCommand,
	launchForkSplit,
	openForkSession,
} from "../src/terminal/fork.ts";

const launch: ForkLaunch = {
	url: "ws://127.0.0.1:4140/ws",
	sessionKey: "tui-child",
	cwd: "/work/project ; $(touch nope)",
	operatorToken: "private-operator-token",
};

test("source and compiled launches use the running executable, not PATH Lemon", () => {
	expect(forkClientCommand("/bin/bun", "/source with spaces/main.ts")).toEqual([
		"/bin/bun",
		"/source with spaces/main.ts",
	]);
	expect(forkClientCommand("/version/lemon-tui", "/$bunfs/root/main.ts")).toEqual([
		"/version/lemon-tui",
	]);
});

test("Tern split targets the source pane with literal argv and a private one-shot handoff", async () => {
	let handoffPath = "";
	await launchForkSplit(
		launch,
		async (request) => {
			handoffPath = request.argv.at(-1)!;
			expect(request.argv).toEqual([
				"tern",
				"split",
				"pane-123",
				"right",
				"--cwd",
				launch.cwd,
				"--",
				"/bin/bun",
				"/source with spaces/main.ts",
				"--internal-fork-launch",
				handoffPath,
			]);
			expect(request.cwd).toBe(launch.cwd);
			expect(request.env.TERN_WINDOW_KEY).toBe("window-456");
			expect(JSON.stringify(request.argv)).not.toContain(launch.operatorToken!);
			expect(lstatSync(dirname(handoffPath)).mode & 0o777).toBe(0o700);
			expect(lstatSync(handoffPath).mode & 0o777).toBe(0o600);
			expect(parseArgs(request.argv.slice(9)).forkLaunchFile).toBe(handoffPath);
			expect(consumeForkHandoff(handoffPath)).toEqual(launch);
			return 0;
		},
		{ TERN_PANE: "pane-123", TERN_WINDOW_KEY: "window-456" },
		["/bin/bun", "/source with spaces/main.ts"],
	);
	expect(existsSync(handoffPath)).toBe(false);
	expect(existsSync(dirname(handoffPath))).toBe(false);
});

test("a failed split removes the credential handoff and never leaks its diagnostics", async () => {
	let path = "";
	await expect(
		launchForkSplit(
			launch,
			async (request) => {
				path = request.argv.at(-1)!;
				throw new Error(launch.operatorToken);
			},
			{ TERN_PANE: "pane" },
			["/version/lemon-tui"],
		),
	).rejects.toThrow("Tern split launch failed");
	expect(existsSync(path)).toBe(false);
	expect(existsSync(dirname(path))).toBe(false);
});

test("handoff rejects broad permissions and symlinks", () => {
	const handoff = createForkHandoff(launch);
	try {
		chmodSync(handoff.path, 0o644);
		expect(() => consumeForkHandoff(handoff.path)).toThrow("invalid fork launch handoff");
		chmodSync(handoff.path, 0o600);
		// Keep the credential target private while replacing launch.json with a link.
		const target = createForkHandoff(launch);
		try {
			unlinkSync(handoff.path);
			symlinkSync(target.path, handoff.path);
			expect(() => consumeForkHandoff(handoff.path)).toThrow("invalid fork launch handoff");
			expect(existsSync(target.path)).toBe(true);
		} finally {
			target.dispose();
		}
	} finally {
		handoff.dispose();
	}
});

test("outside Tern the existing client switches to the durable child; Tern leaves it on source", async () => {
	const switched: string[] = [];
	const split: ForkLaunch[] = [];
	const switchSession = async (key: string) => {
		switched.push(key);
	};
	const launchSplit = async (child: ForkLaunch) => {
		split.push(child);
	};
	await openForkSession(launch, switchSession, { TERM_PROGRAM: "other" }, launchSplit);
	expect(switched).toEqual([launch.sessionKey]);
	expect(split).toEqual([]);
	await openForkSession(launch, switchSession, { TERM_PROGRAM: "Tern" }, launchSplit);
	expect(switched).toEqual([launch.sessionKey]);
	expect(split).toEqual([launch]);
});
