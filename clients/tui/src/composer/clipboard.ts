import { readImageFromClipboard } from "@oh-my-pi/pi-natives/clipboard";
import { imageFromBytes, type PendingImage } from "./images.ts";

export type ClipboardContent =
	| { kind: "image"; image: PendingImage }
	| { kind: "paths"; paths: string[] }
	| { kind: "text"; text: string };

// Same public.file-url guard as oh-my-pi's clipboard helper. An unguarded
// AppleScript coercion can mistake arbitrary clipboard text for an HFS path.
const MAC_FILE_URLS = `
set output to ""
try
	if (clipboard info for «class furl») is {} then return output
	set theClip to the clipboard as «class furl»
	if class of theClip is list then
		repeat with anItem in theClip
			set output to output & POSIX path of anItem & linefeed
		end repeat
	else
		set output to POSIX path of theClip & linefeed
	end if
end try
return output
`;

async function clipboardCommand(command: string[], limit: number): Promise<string> {
	const child = Bun.spawn(command, { stdin: "ignore", stdout: "pipe", stderr: "ignore" });
	let timedOut = false;
	const timer = setTimeout(() => {
		timedOut = true;
		child.kill("SIGKILL");
	}, 2000);
	const reader = child.stdout.getReader();
	const chunks: Uint8Array[] = [];
	let size = 0;
	try {
		while (true) {
			const { done, value } = await reader.read();
			if (done) break;
			size += value.byteLength;
			if (size > limit) throw new Error("Clipboard text is too large.");
			chunks.push(value);
		}
		if ((await child.exited) !== 0 || timedOut) throw new Error("Clipboard is unavailable.");
		return Buffer.concat(chunks, size).toString("utf8");
	} finally {
		clearTimeout(timer);
		reader.releaseLock();
		if (child.exitCode === null) child.kill("SIGKILL");
		await child.exited;
	}
}

/** Native PNG bytes for screenshots; Finder files and pbpaste use real macOS CLIs. */
export async function readComposerClipboard(): Promise<ClipboardContent | undefined> {
	if (process.platform === "darwin") {
		let paths: string[] = [];
		try {
			paths = (await clipboardCommand(["osascript", "-e", MAC_FILE_URLS], 64 * 1024))
				.split(/\r?\n/)
				.filter((path) => path.length > 0);
		} catch {
			// A screenshot/text pasteboard has no public.file-url representation.
		}
		if (paths.length > 0) return { kind: "paths", paths };
	}

	let image: { data: Uint8Array; mimeType: string } | null | undefined;
	try {
		// The upstream helper loads its native addon only when called.
		image = await readImageFromClipboard();
	} catch {
		// Native clipboard access can be absent over SSH or on a headless host.
	}
	if (image) {
		return {
			kind: "image",
			image: imageFromBytes(image.data, "Clipboard image", image.mimeType),
		};
	}
	if (process.platform === "darwin") {
		const text = await clipboardCommand(["pbpaste"], 1024 * 1024);
		if (text.length > 0) return { kind: "text", text };
	}
	return undefined;
}
