import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { basename } from "node:path";
import type { ImageContent } from "../protocol/types.ts";

export const MAX_IMAGES = 5;
export const MAX_IMAGE_BYTES = 10 * 1024 * 1024;

export interface PendingImage {
	readonly id: string;
	readonly name: string;
	readonly byteLength: number;
	readonly content: Readonly<ImageContent>;
}

export function imageMimeType(bytes: Uint8Array): ImageContent["mime_type"] | undefined {
	if (
		bytes.length >= 8 &&
		bytes[0] === 0x89 &&
		bytes[1] === 0x50 &&
		bytes[2] === 0x4e &&
		bytes[3] === 0x47 &&
		bytes[4] === 0x0d &&
		bytes[5] === 0x0a &&
		bytes[6] === 0x1a &&
		bytes[7] === 0x0a
	)
		return "image/png";
	if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
		return "image/jpeg";
	}
	const header = Buffer.from(bytes.buffer, bytes.byteOffset, Math.min(bytes.length, 12)).toString(
		"latin1",
	);
	if (header.startsWith("GIF87a") || header.startsWith("GIF89a")) return "image/gif";
	if (header.startsWith("RIFF") && header.slice(8, 12) === "WEBP") return "image/webp";
	return undefined;
}

/** One bounded payload is shared by draft, submission snapshot, and queue. */
export function imageFromBytes(
	bytes: Uint8Array,
	name: string,
	expectedMime?: string,
): PendingImage {
	if (bytes.byteLength === 0 || bytes.byteLength > MAX_IMAGE_BYTES) {
		throw new Error("Images must contain between 1 byte and 10 MiB.");
	}
	const mime = imageMimeType(bytes);
	if (!mime || (expectedMime !== undefined && expectedMime !== mime)) {
		throw new Error("Only PNG, JPEG, GIF, and WebP image bytes are supported.");
	}
	const content: ImageContent = {
		type: "image",
		mime_type: mime,
		data: Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString("base64"),
	};
	return Object.freeze({
		id: crypto.randomUUID(),
		name,
		byteLength: bytes.byteLength,
		content: Object.freeze(content),
	});
}

/** Never read a directory/device/FIFO, or allocate from an unbounded file size. */
export async function readImageFile(
	path: string,
	byteLimit = MAX_IMAGE_BYTES,
): Promise<PendingImage> {
	const file = await open(path, constants.O_RDONLY | constants.O_NONBLOCK);
	try {
		const stat = await file.stat();
		if (!stat.isFile()) throw new Error("Image attachments must be regular files.");
		if (stat.size === 0 || stat.size > Math.min(byteLimit, MAX_IMAGE_BYTES)) {
			throw new Error("Image attachments exceed the remaining 10 MiB limit or are empty.");
		}
		const bytes = Buffer.allocUnsafe(stat.size);
		let offset = 0;
		while (offset < bytes.length) {
			const { bytesRead } = await file.read(bytes, offset, bytes.length - offset, null);
			if (bytesRead === 0)
				throw new Error("Image changed while it was being attached; paste it again.");
			offset += bytesRead;
		}
		const probe = Buffer.allocUnsafe(1);
		if ((await file.read(probe, 0, 1, null)).bytesRead !== 0) {
			throw new Error("Image changed while it was being attached; paste it again.");
		}
		return imageFromBytes(bytes, basename(path));
	} finally {
		await file.close();
	}
}
