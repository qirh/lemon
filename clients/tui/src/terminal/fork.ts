import {
	closeSync,
	constants,
	existsSync,
	fstatSync,
	lstatSync,
	mkdtempSync,
	openSync,
	readFileSync,
	rmdirSync,
	unlinkSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { detectTerminalCapabilities } from "./capabilities.ts";

export interface ForkLaunch {
	url: string;
	sessionKey: string;
	cwd: string;
	operatorToken?: string;
}

/** Same executable and source entry point, never a different installed Lemon. */
export function forkClientCommand(execPath = process.execPath, main = Bun.main): string[] {
	return /(?:^\/\$bunfs\/|^[A-Za-z]:[\\/]~BUN[\\/])/.test(main)
		? [execPath]
		: [execPath, resolve(main)];
}

/** Tern's CLI does not promise to forward its environment to the pane daemon. */
export function createForkHandoff(launch: ForkLaunch): { path: string; dispose(): void } {
	const directory = mkdtempSync(join(tmpdir(), "lemon-tui-fork-"));
	const path = join(directory, "launch.json");
	const dispose = () => {
		try {
			unlinkSync(path);
		} catch {}
		try {
			rmdirSync(directory);
		} catch {}
	};
	try {
		writeFileSync(path, JSON.stringify(launch), { mode: 0o600, flag: "wx" });
		return { path, dispose };
	} catch {
		dispose();
		throw new Error("could not prepare fork launch");
	}
}

/** Consume once before connecting; never expose credentials in argv or diagnostics. */
export function consumeForkHandoff(path: string): ForkLaunch {
	let descriptor: number | undefined;
	let owned = false;
	try {
		const directory = dirname(path);
		const parent = lstatSync(directory);
		const uid = process.getuid?.();
		if (
			uid === undefined ||
			basename(path) !== "launch.json" ||
			!basename(directory).startsWith("lemon-tui-fork-") ||
			!parent.isDirectory() ||
			parent.uid !== uid ||
			(parent.mode & 0o777) !== 0o700
		) {
			throw new Error();
		}
		descriptor = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
		const stat = fstatSync(descriptor);
		if (!stat.isFile() || stat.uid !== uid || (stat.mode & 0o777) !== 0o600) {
			throw new Error();
		}
		owned = true;
		if (stat.size > 65_536) throw new Error();
		const value: unknown = JSON.parse(readFileSync(descriptor, "utf8"));
		if (typeof value !== "object" || value === null) throw new Error();
		const launch = value as Record<string, unknown>;
		if (
			typeof launch.url !== "string" ||
			typeof launch.sessionKey !== "string" ||
			!launch.sessionKey ||
			typeof launch.cwd !== "string" ||
			(launch.operatorToken !== undefined && typeof launch.operatorToken !== "string")
		) {
			throw new Error();
		}
		return launch as unknown as ForkLaunch;
	} catch {
		throw new Error("invalid fork launch handoff");
	} finally {
		if (descriptor !== undefined) closeSync(descriptor);
		if (owned) {
			unlinkSync(path);
			rmdirSync(dirname(path));
		}
	}
}

export interface ForkSplitRequest {
	argv: string[];
	cwd: string;
	env: NodeJS.ProcessEnv;
}

export type ForkSplitRunner = (request: ForkSplitRequest) => Promise<number>;

const runSplit: ForkSplitRunner = async ({ argv, cwd, env }) => {
	const child = Bun.spawn(argv, { cwd, env, stdin: "ignore", stdout: "ignore", stderr: "ignore" });
	return await child.exited;
};

/** Explicit argv (no shell interpolation), targeting the originating pane rather than focus. */
export async function launchForkSplit(
	launch: ForkLaunch,
	runner: ForkSplitRunner = runSplit,
	env: NodeJS.ProcessEnv = process.env,
	command: string[] = forkClientCommand(),
): Promise<void> {
	const handoff = createForkHandoff(launch);
	try {
		const status = await runner({
			argv: [
				"tern",
				"split",
				env.TERN_PANE || "@focused",
				"right",
				"--cwd",
				launch.cwd,
				"--",
				...command,
				"--internal-fork-launch",
				handoff.path,
			],
			cwd: launch.cwd,
			env,
		});
		if (status !== 0) throw new Error();
		// A successful CLI response only means Tern accepted the split. Wait for
		// the child to consume the handoff, so startup failures cannot strand it.
		const deadline = Date.now() + 10_000;
		while (existsSync(handoff.path)) {
			if (Date.now() >= deadline) throw new Error();
			await Bun.sleep(25);
		}
	} catch {
		handoff.dispose();
		throw new Error("Tern split launch failed");
	}
}

export async function openForkSession(
	launch: ForkLaunch,
	switchSession: (key: string) => Promise<void>,
	env: NodeJS.ProcessEnv = process.env,
	launchSplit: (launch: ForkLaunch) => Promise<void> = launchForkSplit,
): Promise<void> {
	if (detectTerminalCapabilities(env).tern) await launchSplit(launch);
	else await switchSession(launch.sessionKey);
}
