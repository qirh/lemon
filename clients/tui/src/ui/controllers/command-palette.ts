import {
	commandPaletteEntries,
	discoverPaletteResources,
	type PaletteDiscovery,
	type PaletteEntry,
	type PaletteSourceOptions,
	rankPaletteEntries,
} from "../../commands/palette-source.ts";
import type { CommandContext } from "../../commands/registry.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { PickerOverlay } from "../components/pickers.ts";

export interface CommandPaletteHost {
	/** Resolve at open and selection time so capabilities/session never go stale. */
	context(): CommandContext;
	getDraft(): string;
	setDraft(text: string): void;
	present(overlay: PickerOverlay): () => void;
	repaint(): void;
	notice(text: string, level?: NoticeLevel): void;
	/** Local filesystem configuration, not the daemon's remote/profile workspace. */
	resources?: Omit<PaletteSourceOptions, "cwd">;
}

// Only read-only actions and existing draft-preserving UI entrypoints execute
// directly. Having no usage alone must not make /reset, /quit or /clear execute.
const IMMEDIATE_COMMANDS: Record<string, true> = {
	profiles: true,
	tree: true,
	editor: true,
	status: true,
	usage: true,
	agents: true,
	approvals: true,
};

/** Replace only a leading slash query; all remaining draft text survives. */
export function insertPaletteEntry(entry: PaletteEntry, draft: string): string {
	const token = draft.match(/^\s*\/[^\s/]*(?=\s|$)/);
	const remainder = token ? draft.slice(token[0].length).replace(/^[ \t]/, "") : draft;
	if (entry.kind === "command") {
		return `${entry.insertText}${remainder ? ` ${remainder}` : " "}`;
	}
	if (entry.kind === "skill") return `${entry.insertText}${remainder}`;
	return `${entry.insertText}${remainder ? `\n\n${remainder}` : ""}`;
}

export class CommandPalette {
	readonly #host: CommandPaletteHost;
	#overlay: PickerOverlay | undefined;
	#close: (() => void) | undefined;
	#entries: PaletteEntry[] = [];
	#resources: PaletteDiscovery = { entries: [], issues: [] };
	#generation = 0;
	#draft = "";
	#sessionKey = "";
	#loading = false;

	constructor(host: CommandPaletteHost) {
		this.#host = host;
	}

	get overlay(): PickerOverlay | undefined {
		return this.#overlay;
	}

	/** Open from Ctrl+P, or when a leading slash is typed. Never clears the editor. */
	async open(filter?: string): Promise<void> {
		this.close();
		const generation = this.#generation;
		const ctx = this.#host.context();
		this.#draft = this.#host.getDraft();
		this.#sessionKey = ctx.session.key;
		this.#resources = { entries: [], issues: [] };
		this.#entries = commandPaletteEntries(ctx);
		this.#loading = true;
		const query = filter ?? this.#draft.match(/^\s*\/([^\s/]*)/)?.[1] ?? "";
		this.#overlay = new PickerOverlay({
			title: "commands · skills · prompts",
			items: rankPaletteEntries(this.#entries, query),
			filter: query,
			// Ranking includes aliases and gives exact aliases priority.
			remoteFilter: true,
			footer: "enter inserts / opens action · esc keeps draft",
			detail: () =>
				this.#loading ? "Discovering local skills and prompts…" : this.#resources.issues,
			onFilterChange: (value) => {
				this.#overlay?.setItems(rankPaletteEntries(this.#entries, value), value);
				this.#host.repaint();
			},
			onSelect: (item) => {
				void this.#select(item.value);
			},
			onCancel: () => this.close(),
		});
		this.#close = this.#host.present(this.#overlay);
		try {
			const resources = await discoverPaletteResources({
				...this.#host.resources,
				cwd: ctx.cwd ?? process.cwd(),
			});
			if (generation !== this.#generation) return;
			this.#resources = resources;
		} catch {
			if (generation !== this.#generation) return;
			this.#resources = {
				entries: [],
				issues: ["Local resource discovery failed; command results remain available."],
			};
		}
		this.#loading = false;
		this.#entries = [...commandPaletteEntries(this.#host.context()), ...this.#resources.entries];
		const currentFilter = this.#overlay?.filter ?? query;
		this.#overlay?.setItems(rankPaletteEntries(this.#entries, currentFilter), currentFilter);
		this.#host.repaint();
	}

	/** Also call on session switches/shutdown to ignore outstanding discovery. */
	close(): void {
		this.#generation += 1;
		this.#close?.();
		this.#close = undefined;
		this.#overlay = undefined;
	}

	async #select(value: string): Promise<void> {
		const entry = this.#entries.find((candidate) => candidate.value === value);
		if (!entry) return;
		const ctx = this.#host.context();
		if (ctx.session.key !== this.#sessionKey || this.#host.getDraft() !== this.#draft) {
			this.close();
			this.#host.notice(
				"Draft or session changed; reopen the command palette to insert safely.",
				"warning",
			);
			return;
		}
		const availability = entry.command
			? ctx.registry.availability(entry.command, { ...ctx, name: entry.name, rest: "" })
			: entry;
		if (!availability.available) {
			this.#host.notice(
				`${entry.label} is unavailable: ${availability.reason ?? "unavailable"}`,
				"warning",
			);
			return;
		}
		this.close();
		if (entry.command && !entry.command.usage && IMMEDIATE_COMMANDS[entry.name]) {
			// Remove only an exact palette query, not arguments or a prose draft.
			if (/^\s*\/[^\s/]*$/.test(this.#draft)) this.#host.setDraft("");
			await ctx.registry.dispatch(entry.insertText, ctx);
			return;
		}
		this.#host.setDraft(insertPaletteEntry(entry, this.#draft));
		this.#host.repaint();
	}
}
