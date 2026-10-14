/**
 * omp's dock working row for native terminals.
 *
 * The row renderer already says a run is busy (the status line's `esc:stop`
 * and the terminal progress indicator), so this paints nothing there. A TSP
 * terminal gets omp's `omp.working` row instead: spinner, terminal-clocked
 * elapsed time, the label, and a Stop control that takes Esc's path.
 */

import { describeWorkingRow } from "@oh-my-pi/pi-tui/components/loader";
import { EMPTY_NODE } from "@oh-my-pi/pi-tui/native/describe";
import type { DescribeContext, NativeNode, NativeUiEvent } from "@oh-my-pi/pi-tui/native/node";
import type { Component } from "@oh-my-pi/pi-tui/tui";

export interface WorkingIndicatorOptions {
	/** The focused session's run in flight, if any. */
	activeRun: () => string | undefined;
	/** The Stop control: the same abort Esc runs. */
	onInterrupt: () => void;
	now?: () => number;
}

export class WorkingIndicatorComponent implements Component {
	readonly #options: WorkingIndicatorOptions;
	/** Client-observed start of the run on screen; elapsed is counted terminal-side from here. */
	#run: { id: string; startedAt: number; node?: NativeNode } | undefined;

	constructor(options: WorkingIndicatorOptions) {
		this.#options = options;
	}

	render(): readonly string[] {
		return NO_ROWS;
	}

	invalidate(): void {
		if (this.#run) this.#run.node = undefined;
	}

	describe(cx: DescribeContext): NativeNode {
		const id = this.#options.activeRun();
		if (!id) {
			this.#run = undefined;
			return EMPTY_NODE;
		}
		const now = this.#options.now?.() ?? Date.now();
		if (this.#run?.id !== id) this.#run = { id, startedAt: now };
		this.#run.node ??= describeWorkingRow(
			{ label: "Working…", startedAt: this.#run.startedAt, interruptKey: "escape" },
			cx,
			now,
		);
		return this.#run.node;
	}

	handleNativeEvent(event: NativeUiEvent): void {
		if (event.type === "action" && event.act === "interrupt") this.#options.onInterrupt();
	}
}

const NO_ROWS: readonly string[] = Object.freeze([]);
