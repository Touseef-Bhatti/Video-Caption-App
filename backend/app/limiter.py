"""Shared slowapi limiter. Lives in its own module so route files can import
it without a circular import through app.main.

Keyed on the client IP. Behind a reverse proxy/load balancer, run uvicorn/
gunicorn with --forwarded-allow-ips so the real client address (not the
proxy's) is what gets limited."""
from slowapi import Limiter
from slowapi.util import get_remote_address

limiter = Limiter(key_func=get_remote_address)
