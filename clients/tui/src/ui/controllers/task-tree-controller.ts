import type { AgentEvent } from "../../protocol/types.ts";
import { isTaskTerminal, TaskStore } from "../../store/task-store.ts";
import { TaskTreeComponent } from "../components/task-tree.ts";
import { taskUpdatesFromEvent } from "../task-progress.ts";

export interface TaskTreeControllerOptions {
	requestRender: () => void;
	/** Host restores editor focus; Escape also hides the panel. */
	onBlur?: () => void;
	store?: TaskStore;
	now?: () => number;
	tickMs?: number;
}

/**
 * Feed raw client agent events into ingest(), not the transcript's synthetic
 * child ToolBlocks. The host owns mounting, focus and the toggle keybinding.
 * No session reducer changes or parent-run lifecycle subscriptions are needed.
 */
export class TaskTreeController {
	readonly panel: TaskTreeComponent;
	readonly store: TaskStore;
	readonly #options: TaskTreeControllerOptions;
	readonly #unsubscribe: () => void;
	#sessionKey: string | null = null;
	#timer: ReturnType<typeof setInterval> | undefined;
	#disposed = false;

	constructor(options: TaskTreeControllerOptions) {
		this.#options = options;
		this.store = options.store ?? new TaskStore();
		this.panel = new TaskTreeComponent({
			requestRender: options.requestRender,
			now: options.now,
			onBlur: () => {
				this.setVisible(false);
				options.onBlur?.();
			},
		});
		this.#unsubscribe = this.store.events.on("changed", ({ sessionKey }) => {
			if (sessionKey === this.#sessionKey) this.#present();
		});
	}

	get ticking(): boolean {
		return this.#timer !== undefined;
	}

	/** A session-less event is never assigned to whichever chat is on screen. */
	ingest(event: AgentEvent): boolean {
		if (this.#disposed || event.type !== "tool_use" || !event.sessionKey) return false;
		const updates = taskUpdatesFromEvent(event);
		if (updates.length === 0) return false;
		this.store.upsert(event.sessionKey, updates, this.#options.now?.() ?? Date.now());
		return true;
	}

	setSession(sessionKey: string | null): void {
		if (this.#disposed || this.#sessionKey === sessionKey) return;
		this.#sessionKey = sessionKey;
		this.panel.update([]);
		this.#present();
	}

	/** Returns the new visibility; the host may focus panel when it opens. */
	toggle(): boolean {
		this.setVisible(!this.panel.visible);
		return this.panel.visible;
	}

	setVisible(visible: boolean): void {
		if (this.#disposed) return;
		this.panel.setVisible(visible);
		this.#present();
	}

	dispose(): void {
		this.#disposed = true;
		this.#unsubscribe();
		this.#stopTicker();
		this.panel.setVisible(false);
	}

	#present(): void {
		const rows = this.#sessionKey ? this.store.tree(this.#sessionKey) : [];
		this.panel.update(rows);
		const active = this.panel.visible && rows.some((row) => !isTaskTerminal(row.task.status));
		if (active && this.#timer === undefined) {
			this.#timer = setInterval(this.#options.requestRender, this.#options.tickMs ?? 1000);
			this.#timer.unref?.();
		} else if (!active) {
			this.#stopTicker();
		}
		this.#options.requestRender();
	}

	#stopTicker(): void {
		if (this.#timer === undefined) return;
		clearInterval(this.#timer);
		this.#timer = undefined;
	}
}
