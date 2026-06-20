import hashlib
import random
import time

from fastapi import FastAPI
from fastapi.responses import Response
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST

app = FastAPI()

QUOTES = [
    {"quote": "The only way to do great work is to love what you do.", "author": "Steve Jobs"},
    {"quote": "Innovation distinguishes between a leader and a follower.", "author": "Steve Jobs"},
    {"quote": "Stay hungry, stay foolish.", "author": "Steve Jobs"},
    {"quote": "The best way to predict the future is to invent it.", "author": "Alan Kay"},
    {"quote": "Any fool can write code that a computer can understand. Good programmers write code that humans can understand.", "author": "Martin Fowler"},
    {"quote": "First, solve the problem. Then, write the code.", "author": "John Johnson"},
    {"quote": "Simplicity is the soul of efficiency.", "author": "Austin Freeman"},
    {"quote": "Make it work, make it right, make it fast.", "author": "Kent Beck"},
    {"quote": "Premature optimization is the root of all evil.", "author": "Donald Knuth"},
    {"quote": "Talk is cheap. Show me the code.", "author": "Linus Torvalds"},
]

quote_requests_total = Counter(
    "quote_requests_total",
    "Total number of requests to the /api/quote endpoint",
)


def _cpu_burn_100ms() -> None:
    # SHA-256 hashing chosen over a bare busy-loop: the hash kernel does real
    # memory reads/writes and ALU work, so CPUs can't silently no-op it the
    # way they can a plain spin. Each call transforms 32 bytes; ~100 ms of
    # hashing = hundreds of thousands of iterations at typical clock speeds.
    deadline = time.perf_counter() + 0.100
    data = b"x" * 64
    while time.perf_counter() < deadline:
        data = hashlib.sha256(data).digest()


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    return {"status": "ready"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/quote")
def get_quote():
    _cpu_burn_100ms()
    quote_requests_total.inc()
    return random.choice(QUOTES)
