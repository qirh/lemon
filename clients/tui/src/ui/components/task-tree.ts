import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth } from "@oh-my-pi/pi-tui/utils";
import { isTaskTerminal, type TaskTreeRow, taskElapsedMs } from "../../store/task-store.ts";
import { taskDisplayText } from "../task-progress.ts";
import { getTheme } from "../theme/theme.ts";

/** A bounded live region; selection makes every remaining child reachable. */
export const TASK_TREE_WINDOW = 4;

export interface TaskTreeOptions {
	requestRender: () => void;
	onBlur: () => void;
	now?: () => number;
}

/** Mount outside the transcript: keyed child updates must never enter scrollback. */
export class TaskTreeComponent implements Component {
	focused = false;
	readonly #options: TaskTreeOptions;
	#rows: readonly TaskTreeRow[] = [];
	#selected = 0;
	#visible = false;

	constructor(options: TaskTreeOptions) {
		this.#options = options;
	}

	get visible(): boolean {
		return this.#visible;
	}

	get selected(): TaskTreeRow | undefined {
		return this.#rows[this.#selected];
	}

	setVisible(visible: boolean): void {
		this.#visible = visible;
	}

	update(rows: readonly TaskTreeRow[]): void {
		const selectedId = this.selected?.task.taskId;
		this.#rows = rows;
		const index = selectedId ? rows.findIndex((row) => row.task.taskId === selectedId) : -1;
		this.#selected = index >= 0 ? index : Math.max(0, Math.min(this.#selected, rows.length - 1));
	}

	handleInput(data: string): void {
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
			this.#options.onBlur();
			return;
		}
		let delta = 0;
		if (matchesKey(data, "up") || matchesKey(data, "ctrl+p")) delta = -1;
		if (matchesKey(data, "down") || matchesKey(data, "ctrl+n")) delta = 1;
		if (matchesKey(data, "pageUp")) delta = -TASK_TREE_WINDOW;
		if (matchesKey(data, "pageDown")) delta = TASK_TREE_WINDOW;
		const next = Math.max(0, Math.min(this.#rows.length - 1, this.#selected + delta));
		if (next === this.#selected) return;
		this.#selected = next;
		this.#options.requestRender();
	}

	invalidate(): void {
		// No cached rows: theme, focus and elapsed time are read at render time.
	}

	render(width: number): readonly string[] {
		if (!this.#visible || width <= 0) return EMPTY;
		const theme = getTheme();
		const clamp = (text: string) => truncateToWidth(text, width);
		const active = this.#rows.filter((row) => !isTaskTerminal(row.task.status)).length;
		const hint = this.focused ? " · ↑↓ browse · esc done" : "";
		const lines = [
			theme.fg("accent", clamp(`tasks · ${this.#rows.length} children · ${active} active${hint}`)),
		];
		if (this.#rows.length === 0) {
			lines.push(theme.fg("dim", clamp("No child task updates in this session.")));
			return lines;
		}
		const now = this.#options.now?.() ?? Date.now();
		const start = Math.max(
			0,
			Math.min(this.#selected - TASK_TREE_WINDOW + 1, this.#rows.length - TASK_TREE_WINDOW),
		);
		const end = Math.min(start + TASK_TREE_WINDOW, this.#rows.length);
		for (let index = start; index < end; index++) {
			const { task, depth } = this.#rows[index]!;
			const selected = this.focused && index === this.#selected;
			// Bound indentation even if the wire contains a very deep hierarchy.
			const indent = "  ".repeat(Math.min(depth, 5));
			const branch = depth > 0 ? "└─ " : "";
			const marker = selected ? theme.cursor : " ";
			const seconds = Math.floor(taskElapsedMs(task, now) / 1000);
			const elapsed = seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m${seconds % 60}s`;
			const agent = task.agent ? ` @${task.agent}` : "";
			const id = taskDisplayText(task.taskId);
			const label = task.description || id;
			const identity = label !== id ? ` · ${id}` : "";
			const text = `${marker} ${indent}${branch}${task.status} ${elapsed} · ${label}${agent}${identity}`;
			const color =
				task.status === "error"
					? "error"
					: task.status === "aborted"
						? "warning"
						: task.status === "completed"
							? "success"
							: "text";
			lines.push(theme.fg(selected ? "accent" : color, clamp(text)));
			if (task.progress) lines.push(theme.fg("muted", clamp(`    ${indent}${task.progress}`)));
		}
		const hidden = this.#rows.length - (end - start);
		if (hidden > 0) lines.push(theme.fg("dim", clamp(`  …${hidden} more · ↑↓ browse`)));
		return lines;
	}
}

const EMPTY: readonly string[] = Object.freeze([]);
