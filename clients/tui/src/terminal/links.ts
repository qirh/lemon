import { homedir } from "node:os";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { TERMINAL } from "@oh-my-pi/pi-tui/terminal-capabilities";
import type { ToolBlock } from "../store/transcript-model.ts";
import { toolArgs, toolDetails } from "../ui/tool-view.ts";

/** Encode paths, including spaces and #, without interpreting terminal controls. */
export function fileTarget(path: string, line?: number, cwd = process.cwd()): string | undefined {
	if (!path || /\p{Cc}/u.test(path)) return undefined;
	const expanded = path.startsWith("~/") ? resolve(homedir(), path.slice(2)) : resolve(cwd, path);
	const url = pathToFileURL(expanded);
	if (line !== undefined && Number.isSafeInteger(line) && line > 0) url.hash = `L${line}`;
	return url.href;
}

export function hyperlink(label: string, target: string | undefined): string {
	if (!TERMINAL.hyperlinks || !target || /\p{Cc}/u.test(target)) return label;
	return `\x1b]8;;${target}\x07${label}\x1b]8;;\x07`;
}

/** Inline code paths are common in coding replies; don't turn arbitrary code into links. */
export function codeLink(text: string, styled: string): string {
	if (!TERMINAL.hyperlinks || /\s/.test(text)) return styled;
	if (/^https?:\/\//i.test(text)) return hyperlink(styled, text);
	if (
		!/^(?:(?:\.{0,2}\/|~\/)[\w@./-]+|[\w@.-]+(?:\/[\w@.-]+)+|[\w.-]+\.[a-zA-Z\d]+)(?::\d+(?::\d+)?|#L\d+)?$/.test(
			text,
		)
	)
		return styled;
	const location = /^(.*?)(?::(\d+)(?::\d+)?|#L(\d+))$/.exec(text);
	return hyperlink(
		styled,
		fileTarget(location?.[1] ?? text, Number(location?.[2] ?? location?.[3] ?? 0)),
	);
}

function positiveLine(value: unknown): number | undefined {
	return typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : undefined;
}

/** CodingTools snapshots are complete and bounded; never infer locations from result prose. */
function snapshotLine(details: Record<string, unknown>): number | undefined {
	const { oldText, newText } = details;
	if (typeof newText !== "string") return undefined;
	if (oldText === null) return 1;
	if (typeof oldText !== "string" || oldText === newText) return undefined;
	let line = 1;
	for (let i = 0; i < Math.min(oldText.length, newText.length); i++) {
		if (oldText[i] !== newText[i]) break;
		if (newText[i] === "\n") line++;
	}
	return line;
}

/** One structured location for both OSC 8 rows and native tool targets. */
export function toolLocation(block: ToolBlock): { path: string; line?: number } | undefined {
	const args = toolArgs(block);
	const details = toolDetails(block);
	let path = details.path ?? args.path ?? args.file_path;
	let file = details;
	if (typeof path !== "string" && Array.isArray(details.changed)) {
		// Patch receipts name their actual destinations, including moves. A card has
		// one target: the first surviving changed file, never a deleted snapshot.
		const files = Array.isArray(details.perFileResults) ? details.perFileResults : [];
		for (const changed of details.changed) {
			if (typeof changed !== "string") continue;
			const result = files.find(
				(value) => value && typeof value === "object" && value.path === changed,
			);
			if (result?.newText === null) continue;
			path = changed;
			file = result ?? {};
			break;
		}
	}
	if (typeof path !== "string" || !path || /\p{Cc}/u.test(path)) return undefined;
	return {
		path,
		line: positiveLine(file.first_changed_line) ?? positiveLine(args.offset) ?? snapshotLine(file),
	};
}

/** Link the card title, leaving pure formatter strings free of ANSI bytes. */
export function toolLink(label: string, block: ToolBlock): string {
	if (!TERMINAL.hyperlinks) return label;
	const location = toolLocation(block);
	if (location) return hyperlink(label, fileTarget(location.path, location.line));
	const args = toolArgs(block);
	if (typeof args.url === "string" && /^https?:\/\//i.test(args.url))
		return hyperlink(label, args.url);
	return label;
}
