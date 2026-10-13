/**
 * The tool shelf: consecutive tool calls, merged.
 *
 * A run of tool activity with nothing else between it — five reads, a grep, a
 * bash — is scaffolding, not content. The shelf owns such a run and renders
 * each finished member as **one line** (icon · title · summary) once there is
 * more than one of them, so a burst of ten tools costs ten rows instead of
 * fifty. A run of exactly one keeps its full card: a lone `bash` is usually the
 * thing the user actually wanted to read.
 *
 * ## Barriers
 *
 * The shelf accepts tool blocks until a barrier closes it — any non-tool block
 * (an assistant reply, a notice, an approval) or the end of the run. The
 * {@link EventController} owns that decision and calls {@link seal}.
 *
 * ## Why sealing matters
 *
 * The shelf's *shape* changes as it grows: entry one is a full card until entry
 * two arrives, at which point both collapse to single lines. Rewriting rows
 * that already reached native scrollback would strand stale copies in immutable
 * terminal history, so an unsealed shelf reports itself unfinalized. The
 * semantic retirement ledger keeps it and everything following it mutable
 * until the controller seals the shelf at a transcript barrier.
 */

import { col } from "@oh-my-pi/pi-tui/native/describe";
import type { NativeNode } from "@oh-my-pi/pi-tui/native/node";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import type { Block, ToolBlock } from "../../store/transcript-model.ts";
import { type AccordionState, accordionSettings, resolveAccordionState } from "./accordion.ts";
import { ToolCardComponent, type ToolCardOptions } from "./tool-card.ts";

/** Entries a shelf needs before it starts merging them into single lines. */
export const SHELF_MERGE_THRESHOLD = 2;

/**
 * Group a block list the way the shelf does: maximal runs of consecutive tool
 * blocks. Pure, and exported for the gallery and for tests — the component's
 * own grouping is the incremental version of this.
 */
export function planToolShelves(blocks: readonly Block[]): ToolBlock[][] {
	const groups: ToolBlock[][] = [];
	let current: ToolBlock[] | undefined;
	for (const block of blocks) {
		if (block.kind !== "tool") {
			current = undefined;
			continue;
		}
		if (!current) {
			current = [];
			groups.push(current);
		}
		current.push(block);
	}
	return groups;
}

export class ToolShelfComponent implements Component {
	readonly #entries: ToolCardComponent[] = [];
	readonly #byBlockId = new Map<string, ToolCardComponent>();
	/** Finished cards the user expanded out of their one-line shelf form. */
	readonly #pinnedOpen = new Set<ToolCardComponent>();
	readonly #cardOptions: ToolCardOptions;

	#sealed = false;
	#version = 0;
	#cachedKey = "";
	#cachedWidth = -1;
	#cached: readonly string[] = [];
	#native: NativeNode | undefined;
	#nativeSize = -1;

	constructor(cardOptions: ToolCardOptions = {}) {
		// Cards live inside the shelf, not directly under a root child, so their
		// animation ticks must name the shelf as the render target — that is the
		// component the TUI can locate in the tree.
		const requestRender = cardOptions.requestRender;
		this.#cardOptions = requestRender
			? { ...cardOptions, requestRender: () => requestRender(this) }
			: cardOptions;
	}

	get size(): number {
		return this.#entries.length;
	}

	get sealed(): boolean {
		return this.#sealed;
	}

	get cards(): readonly ToolCardComponent[] {
		return this.#entries;
	}

	/** Whether a further tool block may join. False once a barrier sealed it. */
	get open(): boolean {
		return !this.#sealed;
	}

	has(blockId: string): boolean {
		return this.#byBlockId.has(blockId);
	}

	cardFor(blockId: string): ToolCardComponent | undefined {
		return this.#byBlockId.get(blockId);
	}

	/** Add a tool block. Returns its card, or undefined if the shelf is sealed. */
	add(block: ToolBlock): ToolCardComponent | undefined {
		if (this.#sealed) return undefined;
		const existing = this.#byBlockId.get(block.id);
		if (existing) {
			this.update(block);
			return existing;
		}
		const card = new ToolCardComponent(block, this.#cardOptions);
		this.#entries.push(card);
		this.#byBlockId.set(block.id, card);
		this.#recompute();
		return card;
	}

	update(block: ToolBlock): void {
		const card = this.#byBlockId.get(block.id);
		if (!card) return;
		card.update(block);
		this.#recompute();
	}

	/**
	 * The expand key, for one card. A card merged into a shelf line opens as a
	 * full, expanded card; an open card toggles expanded ↔ collapsed, and a card
	 * the user had opened out of its shelf line folds back into it.
	 */
	toggle(blockId: string): AccordionState | undefined {
		const card = this.#byBlockId.get(blockId);
		if (!card) return undefined;
		if (card.compact) {
			this.#pinnedOpen.add(card);
			card.setAccordionState("expanded");
			this.#recompute();
			return "expanded";
		}
		const state = card.toggleAccordion();
		if (state === "collapsed" && this.#pinnedOpen.delete(card)) this.#recompute();
		return state;
	}

	/**
	 * Re-apply the global accordion override (Ctrl+T) to every card. `expanded`
	 * also opens merged shelf lines into full cards; `default` merges them again.
	 */
	applyAccordionOverride(): void {
		this.#pinnedOpen.clear();
		for (const card of this.#entries) card.setAccordionState(resolveAccordionState(card.view.kind));
		this.#recompute();
	}

	/**
	 * Freeze the shelf as history: no further entries, no animation, rows become
	 * commit-eligible. Idempotent.
	 */
	seal(): void {
		if (this.#sealed) return;
		this.#sealed = true;
		for (const card of this.#entries) {
			if (card.view.kind !== "subagent" || card.isTranscriptBlockFinalized()) card.dispose();
		}
		this.#version++;
	}

	dispose(): void {
		for (const card of this.#entries) card.dispose();
	}

	// -- FinalizableBlock ----------------------------------------------------

	isTranscriptBlockFinalized(): boolean {
		return (
			this.#sealed &&
			!this.#entries.some(
				(card) => card.view.kind === "subagent" && !card.isTranscriptBlockFinalized(),
			)
		);
	}


	getTranscriptBlockVersion(): number {
		return this.#version + this.#entryVersions();
	}

	// -- render --------------------------------------------------------------

	describe(): NativeNode {
		if (!this.#native || this.#nativeSize !== this.#entries.length) {
			this.#native = col(this.#entries.slice());
			this.#nativeSize = this.#entries.length;
		}
		return this.#native;
	}

	render(width: number): readonly string[] {
		const key = `${this.#version}|${this.#entryVersions()}|${this.#entries.length}`;
		if (this.#cachedWidth === width && this.#cachedKey === key) return this.#cached;
		this.#cachedWidth = width;
		this.#cachedKey = key;
		const rows: string[] = [];
		for (const card of this.#entries) {
			for (const row of card.render(width)) rows.push(row);
		}
		this.#cached = rows;
		return rows;
	}

	invalidate(): void {
		this.#cachedKey = "";
		this.#cachedWidth = -1;
		for (const card of this.#entries) card.invalidate?.();
	}

	// -- internals -----------------------------------------------------------

	#entryVersions(): number {
		let total = 0;
		for (const card of this.#entries) total += card.getTranscriptBlockVersion();
		return total;
	}

	/**
	 * A finished entry merges to a single line once the shelf holds a run worth
	 * merging; a still-running entry always keeps its card so its progress is
	 * readable.
	 */
	#recompute(): void {
		const merge =
			this.#entries.length >= SHELF_MERGE_THRESHOLD && accordionSettings.override !== "expanded";
		let changed = false;
		for (const card of this.#entries) {
			const compact = merge && card.isTranscriptBlockFinalized() && !this.#pinnedOpen.has(card);
			if (card.compact !== compact) changed = true;
			card.setCompact(compact);
		}
		// Only a real shape change bumps the version. An update the card dropped
		// (a replayed phase regression) must leave this block byte-identical, and
		// a version bump alone would force the transcript to re-emit its rows.
		if (changed) this.#version++;
	}
}
