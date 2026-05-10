/**
 * pi-sticky-prompt
 *
 * Exposes the active pi session over a Unix domain socket so an external,
 * always-on-top input HUD (PiStickyPrompt.app) can send prompts and receive
 * basic state. Each pi process gets its own socket; a sibling JSON
 * descriptor file is published so the HUD can list and pick a session.
 *
 * Layout:
 *   ~/.pi/agent/sockets/pi-<pid>.sock   — server socket
 *   ~/.pi/agent/sockets/pi-<pid>.json   — descriptor (pid, cwd, started, ...)
 *
 * Wire protocol (line-delimited JSON, both directions, LF only):
 *
 *   server -> client
 *     {"type":"hello", pid, cwd, sessionFile, sessionName?, model?, streaming, started}
 *     {"type":"state", streaming, model?, sessionName?}
 *     {"type":"ack",   ok:bool, command:"prompt"|"abort", error?:string}
 *     {"type":"bye"}
 *
 *   client -> server
 *     {"type":"prompt", text:string}
 *     {"type":"abort"}
 *     {"type":"ping"}
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { createServer, type Server, type Socket } from "node:net";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const SOCK_DIR = join(homedir(), ".pi", "agent", "sockets");
const SOCK_PATH = join(SOCK_DIR, `pi-${process.pid}.sock`);
const DESC_PATH = join(SOCK_DIR, `pi-${process.pid}.json`);

interface ClientLine {
	type?: string;
	text?: string;
}

interface ExtState {
	streaming: boolean;
	model?: string;
	sessionName?: string;
	sessionFile?: string;
}

export default function (pi: ExtensionAPI) {
	let server: Server | null = null;
	const clients = new Set<Socket>();
	const state: ExtState = { streaming: false };

	const send = (sock: Socket, msg: unknown) => {
		try {
			sock.write(JSON.stringify(msg) + "\n");
		} catch {
			/* client gone */
		}
	};
	const broadcast = (msg: unknown) => {
		for (const c of clients) send(c, msg);
	};

	const writeDescriptor = async () => {
		const desc = {
			pid: process.pid,
			cwd: process.cwd(),
			socket: SOCK_PATH,
			started: Date.now(),
			sessionFile: state.sessionFile,
			sessionName: state.sessionName,
			model: state.model,
			streaming: state.streaming,
		};
		await writeFile(DESC_PATH, JSON.stringify(desc, null, 2));
	};

	const handleLine = async (sock: Socket, line: string, ctx: any) => {
		let msg: ClientLine;
		try {
			msg = JSON.parse(line);
		} catch {
			send(sock, { type: "ack", ok: false, command: "?", error: "bad json" });
			return;
		}

		if (msg.type === "ping") {
			send(sock, { type: "pong" });
			return;
		}

		if (msg.type === "prompt") {
			const text = (msg.text ?? "").trim();
			if (!text) {
				send(sock, { type: "ack", ok: false, command: "prompt", error: "empty" });
				return;
			}
			try {
				if (state.streaming) {
					pi.sendUserMessage(text, { deliverAs: "steer" });
				} else {
					pi.sendUserMessage(text);
				}
				send(sock, { type: "ack", ok: true, command: "prompt" });
			} catch (e: any) {
				send(sock, { type: "ack", ok: false, command: "prompt", error: String(e?.message ?? e) });
			}
			return;
		}

		if (msg.type === "abort") {
			try {
				if (typeof ctx?.abort === "function") {
					ctx.abort();
				}
				send(sock, { type: "ack", ok: true, command: "abort" });
			} catch (e: any) {
				send(sock, { type: "ack", ok: false, command: "abort", error: String(e?.message ?? e) });
			}
			return;
		}

		send(sock, { type: "ack", ok: false, command: msg.type ?? "?", error: "unknown command" });
	};

	const onConnection = (sock: Socket, ctx: any) => {
		clients.add(sock);
		sock.setEncoding("utf8");

		send(sock, {
			type: "hello",
			pid: process.pid,
			cwd: process.cwd(),
			sessionFile: state.sessionFile,
			sessionName: state.sessionName,
			model: state.model,
			streaming: state.streaming,
			started: Date.now(),
		});

		let buf = "";
		sock.on("data", (chunk) => {
			buf += chunk.toString();
			let idx: number;
			while ((idx = buf.indexOf("\n")) !== -1) {
				const line = buf.slice(0, idx).replace(/\r$/, "");
				buf = buf.slice(idx + 1);
				if (line.length > 0) void handleLine(sock, line, ctx);
			}
		});
		const cleanup = () => {
			clients.delete(sock);
			try { sock.destroy(); } catch { /* ignore */ }
		};
		sock.on("error", cleanup);
		sock.on("close", cleanup);
	};

	const startServer = async (ctx: any) => {
		await mkdir(SOCK_DIR, { recursive: true });
		// Stale socket from a previous crashed pi with same pid (very unlikely)
		await rm(SOCK_PATH, { force: true });

		server = createServer((sock) => onConnection(sock, ctx));
		await new Promise<void>((resolve, reject) => {
			server!.once("error", reject);
			server!.listen(SOCK_PATH, () => {
				server!.removeListener("error", reject);
				resolve();
			});
		});
		await writeDescriptor();
	};

	const stopServer = async () => {
		broadcast({ type: "bye" });
		for (const c of clients) {
			try { c.end(); } catch { /* ignore */ }
		}
		clients.clear();
		if (server) {
			await new Promise<void>((resolve) => server!.close(() => resolve()));
			server = null;
		}
		await rm(SOCK_PATH, { force: true });
		await rm(DESC_PATH, { force: true });
	};

	const refreshState = (next: Partial<ExtState>) => {
		Object.assign(state, next);
		broadcast({
			type: "state",
			streaming: state.streaming,
			model: state.model,
			sessionName: state.sessionName,
		});
		// Best-effort descriptor refresh; non-fatal if it fails.
		writeDescriptor().catch(() => undefined);
	};

	pi.on("session_start", async (_event, ctx) => {
		state.sessionFile = ctx.sessionManager.getSessionFile() ?? undefined;
		state.sessionName = pi.getSessionName?.() ?? undefined;
		state.model = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined;
		state.streaming = false;

		try {
			await startServer(ctx);
			ctx.ui?.notify?.(`pi-sticky-prompt listening on ${SOCK_PATH}`, "info");
		} catch (e: any) {
			ctx.ui?.notify?.(`pi-sticky-prompt failed to start: ${e?.message ?? e}`, "error");
		}
	});

	pi.on("session_shutdown", async () => {
		await stopServer();
	});

	pi.on("agent_start", async () => {
		refreshState({ streaming: true });
	});
	pi.on("agent_end", async () => {
		refreshState({ streaming: false });
	});

	pi.on("model_select", async (event) => {
		const m = event.model;
		refreshState({ model: m ? `${m.provider}/${m.id}` : undefined });
	});

	// Reflect /set-session-name etc. — there is no dedicated event, so we
	// poll on each turn end (cheap, only runs once per LLM turn).
	pi.on("turn_end", async () => {
		const name = pi.getSessionName?.();
		if (name !== state.sessionName) refreshState({ sessionName: name });
	});

	pi.registerCommand("prompt-bar-status", {
		description: "Show pi-sticky-prompt status",
		handler: async (_args, ctx) => {
			const lines = [
				`socket : ${SOCK_PATH}`,
				`desc   : ${DESC_PATH}`,
				`clients: ${clients.size}`,
				`stream : ${state.streaming}`,
				`model  : ${state.model ?? "-"}`,
			];
			ctx.ui.notify(lines.join("\n"), "info");
		},
	});
}
