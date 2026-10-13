import { ControlPlaneError, NotConnectedError } from "../protocol/errors.ts";
import { METHOD } from "../protocol/methods.ts";
import type {
	SessionRewindPreview,
	SessionRewindTarget,
	SessionTreeEntry,
} from "../protocol/session-tree.ts";
import type { CommandContext, PickerChoice, SlashCommand } from "./registry.ts";

const PAGE_SIZE = 100;
const NEXT_PAGE = "page:next";
const PREVIOUS_PAGE = "page:previous";

type TreeMode = "inspect" | "rewind";

export const treeCommand: SlashCommand = {
	name: "tree",
	summary: "browse this session's message tree and preserved branches",
	group: "sessions",
	methods: [METHOD.sessionsTree],
	async run(ctx) {
		await openTree(ctx, "inspect", false, 0);
	},
};

export const rewindCommand: SlashCommand = {
	name: "rewind",
	summary: "rewind before an earlier prompt after an exact preview and confirmation",
	usage: "[--files]",
	group: "sessions",
	methods: [METHOD.sessionsTree, METHOD.sessionsRewind, METHOD.chatHistory],
	availableWhen: (ctx) => (ctx.session.busy ? "stop the current run before rewinding" : true),
	async run(ctx, argv) {
		if (argv.some((arg) => arg !== "--files") || argv.length > 1) {
			ctx.ui.notice("usage: /rewind [--files] · file restoration is opt-in", "error");
			return;
		}
		if (!ctx.ui.reloadSession) {
			ctx.ui.notice("this client cannot reload a rewound session", "error");
			return;
		}
		await openTree(ctx, "rewind", argv.includes("--files"), 0);
	},
};

async function openTree(
	ctx: CommandContext,
	mode: TreeMode,
	restoreFiles: boolean,
	offset: number,
): Promise<void> {
	try {
		const tree = await ctx.methods.sessionsTree({
			sessionKey: ctx.session.key,
			cwd: ctx.cwd ?? process.cwd(),
			limit: PAGE_SIZE,
			offset,
		});
		if (ctx.store.focusedKey !== ctx.session.key) return;
		if (tree.sessionKey !== ctx.session.key || !Array.isArray(tree.entries)) {
			throw new Error("unexpected session tree receipt");
		}
		const entries =
			mode === "rewind"
				? tree.entries.filter(
						(entry) => entry.role === "user" && entry.rewindable && entry.isActive,
					)
				: tree.entries;
		const byId = new Map(tree.entries.map((entry) => [entry.id, entry]));
		const items: PickerChoice[] = entries.map((entry) => describeEntry(entry, byId));
		if (offset > 0) items.push({ value: PREVIOUS_PAGE, label: "Previous page" });
		if (tree.hasMore) items.push({ value: NEXT_PAGE, label: "Next page" });
		if (items.length === 0) {
			ctx.ui.notice(
				mode === "rewind"
					? "no earlier user prompts can be rewound"
					: "this session has no stored message tree",
			);
			return;
		}
		ctx.ui.openPicker({
			title: `${mode === "rewind" ? "rewind before a prompt" : "session tree"} · ${offset + 1}–${offset + tree.entries.length}/${tree.totalEntries}`,
			items,
			footer:
				mode === "rewind"
					? `enter previews ${restoreFiles ? "history + files" : "history only"} · esc cancels`
					: "active = current branch · enter inspects · /rewind changes history",
			onSelect: async (choice) => {
				if (choice.value === NEXT_PAGE || choice.value === PREVIOUS_PAGE) {
					const next =
						choice.value === NEXT_PAGE ? offset + PAGE_SIZE : Math.max(0, offset - PAGE_SIZE);
					await openTree(ctx, mode, restoreFiles, next);
					return;
				}
				const entry = entries.find((candidate) => candidate.id === choice.value);
				if (!entry) return;
				if (mode === "rewind") {
					await previewRewind(ctx, entry, restoreFiles);
				} else {
					ctx.ui.noticeBlock([
						`entry ${entry.id} · ${entry.role ?? entry.type} · ${entry.isActive ? "active" : "preserved branch"}`,
						`parent: ${entry.parentId ?? "root"}${entry.isLeaf ? " · leaf" : ""}`,
						entry.text ?? "(no text preview)",
					]);
				}
			},
		});
	} catch (error) {
		failure(ctx, "tree", error);
	}
}

function describeEntry(
	entry: SessionTreeEntry,
	byId: ReadonlyMap<string, SessionTreeEntry>,
): PickerChoice {
	let depth = 0;
	let parent = entry.parentId;
	const visited = new Set<string>([entry.id]);
	while (parent && byId.has(parent) && !visited.has(parent) && depth < 8) {
		visited.add(parent);
		depth++;
		parent = byId.get(parent)?.parentId ?? null;
	}
	const preview = (entry.text ?? entry.type).replace(/\s+/g, " ").slice(0, 100);
	return {
		value: entry.id,
		label: `${"  ".repeat(depth)}${depth > 0 ? "└─ " : ""}${entry.role ?? entry.type}: ${preview}`,
		description: `${entry.isActive ? "active" : "branch"}${entry.isLeaf ? " · leaf" : ""} · ${entry.id}`,
	};
}

async function previewRewind(
	ctx: CommandContext,
	entry: SessionTreeEntry,
	restoreFiles: boolean,
): Promise<void> {
	const target: SessionRewindTarget = {
		sessionKey: ctx.session.key,
		cwd: ctx.cwd ?? process.cwd(),
		entryId: entry.id,
		restoreFiles,
	};
	try {
		const preview = await ctx.methods.sessionsRewindPreview(target);
		if (ctx.store.focusedKey !== target.sessionKey) return;
		if (!matchesPreview(preview, target)) throw new Error("unexpected rewind preview");
		const previewLines = [
			`${preview.discardedMessages} message(s) leave the active branch (preserved in /tree)`,
			restoreFiles
				? `restore ${preview.restorePaths.length} checkpointed file(s)`
				: "history only · files stay unchanged",
			...preview.restorePaths.map((path) => `restore: ${path}`),
			...(preview.unrestorableTools.length
				? [`non-restorable tool effects: ${preview.unrestorableTools.join(", ")}`]
				: []),
			"The selected prompt returns to the editor; nothing is sent automatically.",
		];
		ctx.ui.noticeBlock(["rewind preview", ...previewLines], "warning");
		ctx.ui.openPicker({
			title: "confirm this exact rewind?",
			detail: [
				`Before: ${entry.text ?? entry.id}`,
				...previewLines.slice(0, 6),
				...(previewLines.length > 6
					? ["More preview details in transcript; choose read full preview below."]
					: []),
			],
			items: [
				{ value: "cancel", label: "Cancel — keep history, files and draft" },
				{
					value: "confirm",
					label: restoreFiles
						? "Rewind history and restore previewed files"
						: "Rewind history only",
					description: `${preview.discardedMessages} message(s) · ${entry.id}`,
				},
				{ value: "inspect", label: "Read full preview in transcript (cancel)" },
			],
			footer: "cancel is selected by default · choose rewind then enter to confirm",
			onSelect: async (choice) => {
				if (choice.value !== "confirm") return;
				if (ctx.store.focusedKey !== target.sessionKey) {
					ctx.ui.notice("rewind canceled because the focused session changed", "warning");
					return;
				}
				try {
					const result = await ctx.methods.sessionsRewindConfirm({
						...target,
						confirmationToken: preview.confirmationToken,
					});
					if (
						result.sessionKey !== target.sessionKey ||
						result.entryId !== target.entryId ||
						result.sessionId !== preview.sessionId ||
						typeof result.prompt !== "string" ||
						!Array.isArray(result.restoredPaths)
					) {
						ctx.ui.notice(
							"rewind outcome could not be verified; inspect /tree before doing anything else",
							"error",
						);
						return;
					}
					ctx.ui.resetSession?.(target.sessionKey);
					ctx.store.setDraft(target.sessionKey, result.prompt);
					if (ctx.store.focusedKey === target.sessionKey) ctx.ui.setDraft(result.prompt);
					try {
						await ctx.ui.reloadSession!(target.sessionKey);
						ctx.ui.notice(
							`rewound · ${result.restoredPaths.length} file(s) restored · edit the recalled prompt to continue`,
						);
					} catch (error) {
						ctx.ui.notice(
							`rewind succeeded; history reload failed (${errorCode(error)}). The recalled prompt is preserved; use /resume to reload.`,
							"warning",
						);
					}
				} catch (error) {
					failure(ctx, "rewind", error, true);
				}
			},
		});
	} catch (error) {
		failure(ctx, "rewind preview", error);
	}
}

function matchesPreview(preview: SessionRewindPreview, target: SessionRewindTarget): boolean {
	return (
		preview.sessionKey === target.sessionKey &&
		preview.entryId === target.entryId &&
		typeof preview.sessionId === "string" &&
		typeof preview.confirmationToken === "string" &&
		preview.confirmationToken.length > 0 &&
		typeof preview.prompt === "string" &&
		Number.isInteger(preview.discardedMessages) &&
		Array.isArray(preview.restorePaths) &&
		preview.restorePaths.every((path) => typeof path === "string") &&
		Array.isArray(preview.unrestorableTools) &&
		preview.unrestorableTools.every((tool) => typeof tool === "string")
	);
}

function errorCode(error: unknown): string {
	if (error instanceof ControlPlaneError && error.details && typeof error.details === "object") {
		const reason = (error.details as Record<string, unknown>).reason;
		if (typeof reason === "string" && /^[a-z_]{1,64}$/.test(reason))
			return `${error.code}: ${reason}`;
	}
	return error instanceof ControlPlaneError || error instanceof NotConnectedError
		? error.code
		: "INVALID_RESPONSE";
}

function failure(ctx: CommandContext, operation: string, error: unknown, mutation = false): void {
	const unsafe =
		mutation &&
		(!(error instanceof ControlPlaneError || error instanceof NotConnectedError) ||
			(error instanceof ControlPlaneError &&
				error.details &&
				typeof error.details === "object" &&
				(error.details as Record<string, unknown>).retrySafe === false));
	ctx.ui.notice(
		`session ${operation} did not complete (${errorCode(error)}); no local history or draft was discarded${unsafe ? ". The remote outcome is uncertain; inspect /tree and the affected files before retrying." : ""}`,
		"error",
	);
}
