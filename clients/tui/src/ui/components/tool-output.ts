import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { ansi, col, span, text } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode } from "@oh-my-pi/pi-tui/native/node";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth, wrapTextWithAnsi } from "@oh-my-pi/pi-tui/utils";
import { extractText, safeText } from "../../formatters/base.ts";
import type { ToolBlock } from "../../store/transcript-model.ts";
import { diffNode } from "../../terminal/native-tool-view.ts";
import { getTheme } from "../theme/theme.ts";
import { buildToolView, type ToolView } from "../tool-view.ts";
import { renderDiff } from "./diff.ts";

export interface ToolOutputOptions {
	rows: () => number;
	close: () => void;
	repaint: () => void;
	mode?: "output" | "diff";
}

/** A viewport over the complete bounded server receipt, not the card's 24-line preview. */
export class ToolOutputComponent implements Component {
	readonly #options: ToolOutputOptions;
	#block: ToolBlock;
	#view: ToolView;
	#mode: "output" | "diff";
	#offset = 0;
	#width = -1;
	#body: string[] = [];
	#total = 0;
	#native: NativeNode | undefined;

	constructor(block: ToolBlock, options: ToolOutputOptions) {
		this.#options = options;
		this.#block = block;
		this.#view = buildToolView(block);
		this.#mode = options.mode === "diff" && this.#view.diff ? "diff" : "output";
	}

	get blockId(): string {
		return this.#block.id;
	}
	get mode(): "output" | "diff" {
		return this.#mode;
	}
	get offset(): number {
		return this.#offset;
	}
	get totalRows(): number {
		return this.#total;
	}

	update(block: ToolBlock): void {
		this.#block = block;
		this.#view = buildToolView(block);
		if (!this.#view.diff) this.#mode = "output";
		this.invalidate();
	}

	invalidate(): void {
		this.#width = -1;
		this.#native = undefined;
	}

	/**
	 * The receipt as semantic nodes: a native diff (hunks, language) or the
	 * full output, which the terminal scrolls itself; the keys still switch
	 * diff/output and close.
	 */
	describe(): NativeNode {
		if (this.#native) return this.#native;
		const diff = this.#mode === "diff" ? this.#view.diff : undefined;
		const where = this.#view.diff?.path ? ` · ${safeText(this.#view.diff.path)}` : "";
		this.#native = col(
			[
				text([span(`${this.#mode} · ${safeText(this.#view.title)}`, "toolTitle strong")], {
					lines: 1,
					truncate: "end",
				}),
				text(
					[span(`${this.#view.state}${where} · server receipt (may be bounded upstream)`, "muted")],
					{
						lines: 1,
						truncate: "end",
					},
				),
				diff ? diffNode(safeText(diff.text), diff.path) : ansi(this.#output()),
				text([span(`esc back${this.#view.diff ? " · d diff/output" : ""}`, "dim")], { lines: 1 }),
			],
			{ gap: "sm" },
		);
		return this.#native;
	}

	handleInput(data: string): void {
		if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
			this.#options.close();
			return;
		}
		if (data === "d" && this.#view.diff) {
			this.#mode = this.#mode === "diff" ? "output" : "diff";
			this.#offset = 0;
			this.invalidate();
		} else if (matchesKey(data, "down") || data === "j") this.#offset++;
		else if (matchesKey(data, "up") || data === "k") this.#offset--;
		else if (matchesKey(data, "pageDown") || data === " ") this.#offset += this.#pageSize();
		else if (matchesKey(data, "pageUp")) this.#offset -= this.#pageSize();
		else if (matchesKey(data, "home") || data === "g") this.#offset = 0;
		else if (matchesKey(data, "end") || data === "G")
			this.#offset = Math.max(0, this.#total - this.#pageSize());
		else return;
		this.#offset = Math.max(0, Math.min(this.#offset, this.#total - this.#pageSize()));
		this.#options.repaint();
	}

	render(width: number): string[] {
		if (width < 1) return [];
		const inner = Math.max(1, width - 2);
		if (this.#width !== inner) {
			this.#width = inner;
			const lines =
				this.#mode === "diff" && this.#view.diff
					? renderDiff(safeText(this.#view.diff.text), { path: this.#view.diff.path })
					: this.#output().split("\n");
			this.#body = lines.flatMap((line) => wrapTextWithAnsi(line, inner));
			this.#total = this.#body.length;
		}
		const height = this.#pageSize();
		this.#offset = Math.max(0, Math.min(this.#offset, this.#total - height));
		const theme = getTheme();
		const line = (text: string) => truncateToWidth(text, width);
		return [
			line(theme.fg("toolTitle", `${this.#mode} · ${safeText(this.#view.title)}`)),
			line(
				theme.fg(
					"dim",
					`${this.#view.state}${this.#view.diff?.path ? ` · ${safeText(this.#view.diff.path)}` : ""} · server receipt (may be bounded upstream)`,
				),
			),
			...this.#body.slice(this.#offset, this.#offset + height).map((row) => line(` ${row}`)),
			line(
				theme.fg(
					"dim",
					`${this.#total ? this.#offset + 1 : 0}–${Math.min(this.#total, this.#offset + height)}/${this.#total} · ↑↓/pgup/pgdn scroll · g/G first/last${this.#view.diff ? " · d diff/output" : ""} · esc back`,
				),
			),
		];
	}

	#pageSize(): number {
		return Math.max(1, this.#options.rows() - 3);
	}

	#output(): string {
		const detail = this.#block.detail;
		const receipt =
			typeof detail?.result === "string" ? detail.result : extractText(detail?.partial_result);
		return safeText(
			receipt || this.#block.message || this.#view.body.join("\n") || "No output has arrived yet.",
		);
	}
}
