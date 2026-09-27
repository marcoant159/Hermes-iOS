from __future__ import annotations

from app.config import Settings, normalize_database_url


def test_connector_idle_poll_interval_is_fast_by_default():
    # The connector only notices a queued job when its WebSocket loop wakes up,
    # so the idle timeout is added to every message's dispatch latency. Keep it
    # short so a job created just after a poll is claimed quickly.
    assert Settings().connector_idle_poll_interval_seconds <= 0.25


def test_normalize_database_url_maps_postgres_urls_to_psycopg():
    assert (
        normalize_database_url("postgresql://user:pass@db.example.com/app")
        == "postgresql+psycopg://user:pass@db.example.com/app"
    )
    assert (
        normalize_database_url("postgres://user:pass@db.example.com/app")
        == "postgresql+psycopg://user:pass@db.example.com/app"
    )
    assert normalize_database_url("sqlite:///./relay.db") == "sqlite:///./relay.db"
