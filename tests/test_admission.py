"""Requests must serialize admission, even when the worker has not started yet."""

import threading
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

import pytest
from test_provisioner import CATALOG, CONFIG, FakeTerraform, ReadyChecker, body

from provisioner.service import Conflict, Service
from provisioner.store import Store


@pytest.mark.parametrize("same_key", [False, True])
def test_overlapping_create_has_one_environment_and_one_job(tmp_path, same_key):
    store = Store(tmp_path / "journal.db")
    service = Service(store, FakeTerraform(tmp_path), CATALOG, CONFIG, ReadyChecker())
    checked, release, started = threading.Event(), threading.Event(), threading.Event()
    original = store.active_environment

    def check(*args):
        result = original(*args)
        if not checked.is_set():
            checked.set()
            assert release.wait(5)
        return result

    def second():
        started.set()
        try:
            return service.create(body(), "one" if same_key else "two")
        except Conflict as error:
            return error.code

    try:
        with (
            patch.object(store, "active_environment", check),
            ThreadPoolExecutor(2) as pool,
        ):
            first = pool.submit(service.create, body(), "one")
            assert checked.wait(5)
            duplicate = pool.submit(second)
            assert started.wait(5)
            # Wait until the second request either blocks on admission or completes the race.
            try:
                duplicate.result(timeout=0.1)
            except TimeoutError:
                pass
            release.set()
            accepted = first.result(5)
            result = duplicate.result(5)
        assert len(store.environments()) == 1
        assert store.db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0] == 1
        assert result == (accepted if same_key else "ENVIRONMENT_EXISTS")
    finally:
        release.set()
        store.db.close()
