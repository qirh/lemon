import type { Component } from "@oh-my-pi/pi-tui/tui";
import type { AppStore } from "../../store/app-store.ts";
import type { ToolBlock } from "../../store/transcript-model.ts";
import { PickerOverlay } from "../components/pickers.ts";
import { ToolOutputComponent } from "../components/tool-output.ts";
import { buildToolView } from "../tool-view.ts";

export interface ToolInspectorHost {
	store: AppStore;
	rows: () => number;
	present: (component: Component) => () => void;
	repaint: () => void;
	notice: (text: string) => void;
}

export class ToolInspector {
	readonly #host: ToolInspectorHost;
	#viewer: ToolOutputComponent | undefined;
	#sessionKey: string | undefined;
	#close: (() => void) | undefined;

	constructor(host: ToolInspectorHost) {
		this.#host = host;
	}

	open(mode: "output" | "diff" = "output"): void {
		const session = this.#host.store.focused;
		const blocks = session.blocks
			.filter((block): block is ToolBlock => block.kind === "tool")
			.reverse();
		if (mode === "diff") {
			const latest = blocks.find((block) => buildToolView(block).diff !== undefined);
			if (latest) this.#show(latest, session.key, "diff");
			else this.#host.notice("this session has no successful edit diff to inspect");
			return;
		}
		if (!blocks.length) {
			this.#host.notice("this session has no tool output yet");
			return;
		}
		this.close();
		this.#close = this.#host.present(
			new PickerOverlay({
				title: "tool output · newest first",
				items: blocks.map((block) => {
					const view = buildToolView(block);
					return {
						value: block.id,
						label: view.title.replace(/\p{Cc}/gu, ""),
						description: `${view.state}${view.diff ? " · diff" : ""}`,
					};
				}),
				footer: "enter inspects full receipt · d switches diff/output in viewer · esc cancels",
				onSelect: (item) => {
					if (this.#host.store.focusedKey !== session.key) {
						this.close();
						return;
					}
					const block = blocks.find((candidate) => candidate.id === item.value);
					if (block) this.#show(block, session.key, "output");
				},
				onCancel: () => this.close(),
			}),
		);
	}

	/** Called after event reduction, only rebuilding a receipt while it is inspected. */
	refresh(): void {
		if (!this.#viewer) return;
		if (this.#host.store.focusedKey !== this.#sessionKey) {
			this.close();
			return;
		}
		const block = this.#host.store.focused.blocks.find(
			(candidate) => candidate.id === this.#viewer?.blockId,
		);
		if (block?.kind !== "tool") {
			this.close();
			return;
		}
		this.#viewer.update(block);
		this.#host.repaint();
	}

	close(): void {
		this.#close?.();
		this.#close = undefined;
		this.#viewer = undefined;
		this.#sessionKey = undefined;
	}

	#show(block: ToolBlock, sessionKey: string, mode: "output" | "diff"): void {
		this.close();
		this.#sessionKey = sessionKey;
		this.#viewer = new ToolOutputComponent(block, {
			rows: this.#host.rows,
			mode,
			close: () => this.close(),
			repaint: this.#host.repaint,
		});
		this.#close = this.#host.present(this.#viewer);
	}
}
