"""HP2PC_AP sidecar stub for M2 — proves the UScript ↔ Python TCP path works.

Listens on localhost:38281, accepts game connections in a loop so each level
transition (which spawns a fresh APIPCActor) reconnects cleanly. Echoes
incoming lines from the game to stdout, and forwards any line typed on stdin
to the currently-connected game instance.
"""

from __future__ import annotations

import queue
import socket
import sys
import threading

HOST = "127.0.0.1"
PORT = 38281

stdin_queue: queue.Queue[str] = queue.Queue()


def stdin_reader() -> None:
    for line in sys.stdin:
        stdin_queue.put(line.rstrip("\n"))


def reader_loop(conn: socket.socket) -> None:
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
            print(f"[game→sidecar] {line.decode('utf-8', errors='replace')}", flush=True)


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
    reader.join()  # blocks until the game closes the connection
    stop.set()
    writer.join(timeout=1)


def main() -> None:
    threading.Thread(target=stdin_reader, daemon=True).start()
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((HOST, PORT))
        srv.listen(5)
        print(f"[sidecar] listening on {HOST}:{PORT}", flush=True)
        try:
            while True:
                print("[sidecar] waiting for game connection...", flush=True)
                conn, addr = srv.accept()
                with conn:
                    print(f"[sidecar] game connected from {addr}", flush=True)
                    handle_connection(conn)
                print("[sidecar] connection closed, ready for next", flush=True)
        except KeyboardInterrupt:
            print("[sidecar] shutting down", flush=True)


if __name__ == "__main__":
    main()
