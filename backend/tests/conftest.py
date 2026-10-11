import pytest

from app.limiter import limiter


@pytest.fixture(autouse=True)
def _limiter_off_by_default():
    """Rate limits are real in the app; tests that don't exercise them run
    with the limiter off so many calls from one 'IP' don't trip it."""
    limiter.enabled = False
    limiter.reset()
    yield
    limiter.enabled = False
