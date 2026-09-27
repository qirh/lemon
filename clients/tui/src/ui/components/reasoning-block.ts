/**
 * The model's thinking, as its own dimmed transcript block.
 *
 * A header line (`✻ thinking`) over an {@link AccordionComponent} that starts
 * collapsed to the first line of the thought — reasoning is context, not the
 * answer. The expand key (see `input-controller.ts`) opens it to the full text,
 * word-wrapped at the render width.
 *
 * The block is live (unfinalized) while the model is still thinking, so its
 * rows stay repaintable; once the reasoning phase completes — or the run ends,
 * which {@link SessionStore.finalizeRun} treats as completing it — its bytes
 * may reach native scrollback. An expand toggle after that still repaints
 * whatever is inside the window (the container re-renders on a version bump).
 */

import type { Component } from "@oh-my-pi/pi-tui/tui";
import { truncateToWidth } from "@oh-my-pi/pi-tui/utils";
import type { ReasoningBlock } from "../../store/transcript-model.ts";
import { getTheme } from "../theme/theme.ts";
import { AccordionComponent, type AccordionState, resolveAccordionState } from "./accordion.ts";

export class ReasoningComponent implements Component {
	readonly #accordion: AccordionComponent;
	#block: ReasoningBlock;
	#text = "";
	#live = true;

	#version = 0;
	#cachedVersion = -1;
	#cachedAccordion = -1;
	#cachedWidth = -1;
	#cached: readonly string[] = [];

	constructor(block: ReasoningBlock, options: { accordion?: AccordionState } = {}) {
		this.#block = block;
		this.#accordion = new AccordionComponent(
			options.accordion ?? resolveAccordionState("reasoning"),
			{ indent: 2, wrap: true, moreHint: (hidden) => `+${hidden} more lines` },
		);
		this.update(block);
	}

	get block(): ReasoningBlock {
		return this.#block;
	}

	get accordion(): AccordionComponent {
		return this.#accordion;
	}

	/** Re-derive from the block's current text and phase. No-op when neither moved. */
	update(block: ReasoningBlock): void {
		this.#block = block;
		const live = block.phase !== "completed";
		if (block.text === this.#text && live === this.#live) return;
		this.#text = block.text;
		this.#live = live;
		this.#applyText();
	}

	toggleAccordion(): AccordionState {
		return this.#accordion.toggle();
	}

	setAccordionState(state: AccordionState): void {
		this.#accordion.setState(state);
	}

	// -- FinalizableBlock ----------------------------------------------------

	isTranscriptBlockFinalized(): boolean {
		return !this.#live;
	}

	getTranscriptBlockVersion(): number {
		return this.#version + this.#accordion.version;
	}

	// -- render --------------------------------------------------------------

	render(width: number): readonly string[] {
		if (
			this.#cachedVersion === this.#version &&
			this.#cachedAccordion === this.#accordion.version &&
			this.#cachedWidth === width
		) {
			return this.#cached;
		}
		this.#cachedVersion = this.#version;
		this.#cachedAccordion = this.#accordion.version;
		this.#cachedWidth = width;
		const theme = getTheme();
		const glyph = theme.getSymbolPreset() === "ascii" ? "*" : "✻";
		const label = this.#live ? "thinking…" : "thinking";
		const rows = [truncateToWidth(theme.fg("dim", `${glyph} ${label}`), width)];
		for (const row of this.#accordion.render(width)) rows.push(row);
		this.#cached = rows;
		return rows;
	}

	/** Theme change: the body lines carry baked-in colour, so restyle them. */
	invalidate(): void {
		this.#cachedVersion = -1;
		this.#applyText();
	}

	#applyText(): void {
		const theme = getTheme();
		const style = (line: string) => theme.fg("dim", theme.italic(line));
		const text = this.#text.trim();
		this.#accordion.setLines(text.length > 0 ? text.split(/\r?\n/).map(style) : []);
		const summary = text.split(/\r?\n/, 1)[0] ?? "";
		this.#accordion.setSummary(summary.length > 0 ? style(summary) : "");
		this.#version++;
	}
}
