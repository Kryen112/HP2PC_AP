"""HP2PC_AP sidecar stub for M2/M3 — proves the UScript ↔ Python TCP path.

Listens on localhost:38281, accepts game connections in a loop. Echoes incoming
lines from the game to stdout, forwards stdin lines to the active connection,
and (M3 test) auto-replies GRANT WCAgrippa to the first CHECK it sees so we can
verify the round-trip without triggering an infinite grant→pickup→check→grant
loop.
"""

from __future__ import annotations

import queue
import socket
import sys
import threading

HOST = "127.0.0.1"
PORT = 38281
TEST_GRANT_CARD = "WCAgrippa"

stdin_queue: queue.Queue[str] = queue.Queue()
checks_seen = 0
sent_test_grant = False  # M3 test: only auto-reply with GRANT once per session


def stdin_reader() -> None:
    for line in sys.stdin:
        stdin_queue.put(line.rstrip("\n"))


def reader_loop(conn: socket.socket) -> None:
    global sent_test_grant, checks_seen
    buf = b""
    while True:
        try:
            chunk = conn.recv(4096)
        except OSError:
            return
        if not chunk:
            return
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            decoded = line.decode("utf-8", errors="replace").rstrip("\r")
            print(f"[game→sidecar] {decoded}", flush=True)

            if decoded.startswith("CHECK "):
                checks_seen += 1
                # M3 test: skip the first CHECK (typically cutscene-granted, state
                # gets reverted by HP2 cutscene finalize). Reply to second CHECK
                # which should be a stable non-cutscene pickup (chest, walking).
                if checks_seen >= 2 and not sent_test_grant:
                    sent_test_grant = True
                    msg = f"GRANT {TEST_GRANT_CARD}\n"
                    try:
                        conn.sendall(msg.encode("utf-8"))
                        print(f"[sidecar→game] auto-reply: GRANT {TEST_GRANT_CARD}", flush=True)
                    except OSError:
                        pass


def writer_loop(conn: socket.socket, stop: threading.Event) -> None:
    while not stop.is_set():
        try:
            line = stdin_queue.get(timeout=0.5)
        except queue.Empty:
            continue
        try:
            conn.sendall((line + "\n").encode("utf-8"))
            print(f"[sidecar→game] {line}", flush=True)
        except OSError:
            return


def handle_connection(conn: socket.socket) -> None:
    stop = threading.Event()
    reader = threading.Thread(target=reader_loop, args=(conn,), daemon=True)
    writer = threading.Thread(target=writer_loop, args=(conn, stop), daemon=True)
    reader.start()
    writer.start()
    reader.join()
    stop.set()
    writer.join(timeout=1)


def main() -> None:
    threading.Thread(target=stdin_reader, daemon=True).start()
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((HOST, PORT))
        srv.listen(5)
        srv.settimeout(0.5)
        print(f"[sidecar] listening on {HOST}:{PORT}", flush=True)
        print("[sidecar] waiting for game connection...", flush=True)
        try:
            while True:
                try:
                    conn, addr = srv.accept()
                except socket.timeout:
                    continue
                with conn:
                    print(f"[sidecar] game connected from {addr}", flush=True)
                    handle_connection(conn)
                print("[sidecar] connection closed, ready for next", flush=True)
                print("[sidecar] waiting for game connection...", flush=True)
        except KeyboardInterrupt:
            print("[sidecar] shutting down", flush=True)


if __name__ == "__main__":
    main()
