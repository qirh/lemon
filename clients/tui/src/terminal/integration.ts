import type { Terminal } from "@oh-my-pi/pi-tui/terminal";
import { TERMINAL } from "@oh-my-pi/pi-tui/terminal-capabilities";
import type { ControlPlaneClient } from "../protocol/client.ts";
import type { AppStore } from "../store/app-store.ts";
import { detectTerminalCapabilities, oscText, type TerminalCapabilities } from "./capabilities.ts";

/** Interactive-only side channels. Never sends prompts, answers, or tool arguments. */
export class TerminalIntegration {
	readonly capabilities: TerminalCapabilities;
	readonly #terminal: Terminal;
	readonly #store: AppStore;
	readonly #client: ControlPlaneClient;
	readonly #disposers: Array<() => void> = [];
	readonly #runs = new Set<string>();
	readonly #approvals = new Set<string>();
	#active = false;
	#title = "";
	#session = "";
	#status = "";
	#progress = false;
	#previousHyperlinks: boolean;

	constructor(
		terminal: Terminal,
		store: AppStore,
		client: ControlPlaneClient,
		capabilities = detectTerminalCapabilities(),
	) {
		this.#terminal = terminal;
		this.#store = store;
		this.#client = client;
		this.capabilities = capabilities;
		this.#previousHyperlinks = TERMINAL.hyperlinks;
		if (this.capabilities.enabled) TERMINAL.hyperlinks = this.capabilities.hyperlinks;
	}

	start(): void {
		if (!this.capabilities.enabled || this.#disposers.length > 0) return;
		this.#disposers.push(
			this.#store.events.on("session-changed", () => this.update()),
			this.#store.events.on("conn-changed", () => this.update()),
			this.#store.events.on("blocks-changed", () => this.update()),
			this.#store.events.on("approvals-changed", () => {
				for (const id of this.#approvals) {
					if (!this.#store.approvals.has(id)) this.#approvals.delete(id);
				}
				for (const id of this.#store.approvals.keys()) {
					if (this.#approvals.has(id)) continue;
					this.#approvals.add(id);
					this.#notify("Approval needed", "A tool is waiting for your decision");
				}
				this.update();
			}),
			this.#client.events.on("agent", (event) => {
				if (event.type === "started") this.#runs.add(event.runId);
				if (event.type === "completed" && this.#runs.delete(event.runId)) {
					this.#notify(
						event.ok === false ? "Turn failed" : "Turn complete",
						"Return to Lemon to continue",
					);
				}
				this.update();
			}),
		);
		this.resume();
	}

	/** Paired with TUI.stop(), including the external-editor handoff. */
	suspend(): void {
		if (!this.#active) return;
		this.#terminal.setProgress(false);
		this.#progress = false;
		this.#setUserVar("lemon_session", "");
		this.#setUserVar("lemon_status", "");
		// Balance xterm's title stack instead of guessing the parent's title.
		this.#terminal.write("\x1b[23;0t");
		this.#active = false;
		this.#title = this.#session = this.#status = "";
	}

	resume(): void {
		if (!this.capabilities.enabled || this.#active) return;
		this.#active = true;
		this.#terminal.write("\x1b[22;0t");
		this.update();
	}

	update(): void {
		if (!this.#active) return;
		const store = this.#store;
		for (const session of store.sessions.values()) {
			if (session.busy && session.activeRunId) this.#runs.add(session.activeRunId);
		}
		const status =
			store.pendingApprovals > 0
				? "approval needed"
				: store.connection !== "online"
					? store.connection
					: store.busySessions() > 0
						? "working"
						: "ready";
		const session = oscText(store.focusedKey);
		const title = `Lemon · ${session} · ${status}`;
		if (title !== this.#title) {
			this.#terminal.setTitle(title);
			this.#title = title;
		}
		if (session !== this.#session) {
			this.#setUserVar("lemon_session", session);
			this.#session = session;
		}
		if (status !== this.#status) {
			this.#setUserVar("lemon_status", status);
			this.#status = status;
		}
		const progress = status === "working";
		if (progress !== this.#progress) {
			// pi-tui owns the keepalive and clears its timer on stop.
			this.#terminal.setProgress(progress);
			this.#progress = progress;
		}
	}

	stop(): void {
		this.suspend();
		for (const dispose of this.#disposers.splice(0)) dispose();
		this.#runs.clear();
		this.#approvals.clear();
		TERMINAL.hyperlinks = this.#previousHyperlinks;
	}

	#setUserVar(name: string, value: string): void {
		const encoded = Buffer.from(value).toString("base64");
		this.#terminal.write(`\x1b]1337;SetUserVar=${name}=${encoded}\x07`);
	}

	#notify(title: string, body: string): void {
		if (!this.#active) return;
		if (this.capabilities.notifications === "osc9") {
			this.#terminal.write(`\x1b]9;Lemon: ${title} — ${body}\x07`);
		} else if (this.capabilities.notifications === "osc777") {
			this.#terminal.write(`\x1b]777;notify;Lemon: ${title};${body}\x07`);
		}
	}
}
